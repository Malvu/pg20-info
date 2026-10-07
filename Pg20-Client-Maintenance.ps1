<#
.SYNOPSIS
    Pg20 Info : tâche de maintenance installée avec RustDesk (compte système, toutes les 3 minutes, sans fenêtre).

.DESCRIPTION
    Elle ne sait faire qu'UNE chose : si le technicien a demandé la désinstallation de ce poste, la faire. Ce n'est PAS un moyen d'exécuter
    du code à distance : le seul « ordre » possible est « désinstaller », et son code est dans ce fichier.

    Chaque passage :
      1. lit l'ID RustDesk de ce poste ;
      2. demande au serveur du technicien (TLS, certificat vérifié par empreinte) s'il y a un ordre pour cet ID (GET /v1/order?id=...) ;
      3. si oui, VÉRIFIE la signature (RSA-SHA256, clé publique du technicien intégrée à ce poste), l'ID, la date limite, et que l'ordre date
         d'après l'installation de cette tâche (un ordre ancien ne peut pas être rejoué après une réinstallation) ;
      4. seulement alors : désinstalle RustDesk et efface sa configuration, prévient le serveur (POST /v1/order-done), puis supprime cette tâche.
    Sans ordre, un passage ne fait que la demande de l'étape 2 et ne laisse aucune trace. Si RustDesk n'est plus installé, la tâche se supprime.

    Installée par Pg20-Client-Installation.ps1 (Install-MaintenanceAgent) dans « C:\Program Files\Pg20-Info\Agent », dossier réservé au système et aux
    administrateurs (un utilisateur ordinaire ne peut pas le modifier), avec agent.json : serveur, empreinte du certificat, clé publique du
    technicien, date d'installation. Le journal (agent.log) est dans ce même dossier.

    Le marqueur « __UNINSTALL_FUNCTION__ » ci-dessous est remplacé, à l'installation, par le texte de Uninstall-RustDeskFully (Pg20-Client-Installation.ps1).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$DryRun,                                 # (tests) n'efface rien
    [switch]$SkipProgram,                            # (tests) ne touche ni au service ni au programme
    [switch]$NoSelfClean,                            # (tests) ne supprime pas la tâche ni le dossier à la fin
    [string]$CurrentId = '',                         # (tests) ID simulé
    [string]$ProfileRoot = 'C:\Users',               # (tests)
    [string]$ServiceProfile = 'C:\Windows\ServiceProfiles\LocalService',   # (tests)
    [string]$LogDir = '',                            # (tests) journaux ailleurs que dans le dossier de l'agent / C:\ProgramData\Pg20-Info
    [string]$NowOverride = '',                       # (tests) heure simulée, UTC ISO
    [int]$DoneRetrySeconds = 10                      # pause entre deux essais d'accusé au serveur
)
$ErrorActionPreference = 'Stop'

# __UNINSTALL_FUNCTION__

function Write-AgentLog([string]$Text) {
    try {
        New-Item -ItemType Directory -Force -Path $script:LogDirResolved | Out-Null
        $log = Join-Path $script:LogDirResolved 'agent.log'
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 100KB) { Move-Item -LiteralPath $log ($log + '.old') -Force }
        Add-Content -LiteralPath $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Text) -Encoding UTF8
    }
    catch { }
}

# Requête HTTPS directe, sans proxy, certificat vérifié par EMPREINTE (pas par autorité) : le poste ne parle qu'à CE serveur.
# Renvoie status (0 = pas de réponse), body et date (heure du serveur, lue dans l'en-tête Date : l'horloge du poste peut être fausse).
function Invoke-PinnedRequest([string]$Endpoint, [string]$Pin, [string]$Method, [string]$PathAndQuery, [string]$Body = '') {
    $none = { [pscustomobject]@{ status = 0; body = ''; date = $null } }
    $hostName = $Endpoint; $port = 21120
    if ($Endpoint -match '^(?<h>[^:]+):(?<p>\d{1,5})$') { $hostName = $Matches.h; $port = [int]$Matches.p }
    $script:PinWanted = $Pin.ToLower()
    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($hostName, $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(8000)) { return (& $none) }
        try { $client.EndConnect($ar) } catch { return (& $none) }
        $client.ReceiveTimeout = 10000; $client.SendTimeout = 10000
        $callback = [Net.Security.RemoteCertificateValidationCallback]{
            param($sender, $cert, $chain, $errors)
            if (-not $cert) { return $false }
            $h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($cert.GetRawCertData())) -replace '-', ''
            $h.ToLower() -eq $script:PinWanted
        }
        $ssl = New-Object Net.Security.SslStream($client.GetStream(), $false, $callback)
        try { $ssl.AuthenticateAsClient($hostName, $null, [Security.Authentication.SslProtocols]::Tls12, $false) }
        catch { return (& $none) }
        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $head = "$Method $PathAndQuery HTTP/1.0`r`nHost: $hostName`r`nConnection: close`r`n"
        if ($Method -eq 'POST') { $head += "Content-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`n" }
        $headBytes = [Text.Encoding]::ASCII.GetBytes($head + "`r`n")
        $ssl.Write($headBytes, 0, $headBytes.Length)
        if ($bodyBytes.Length) { $ssl.Write($bodyBytes, 0, $bodyBytes.Length) }
        $ssl.Flush()
        $ms = New-Object IO.MemoryStream; $buf = New-Object byte[] 2048
        try { while (($n = $ssl.Read($buf, 0, $buf.Length)) -gt 0 -and $ms.Length -lt 16384) { $ms.Write($buf, 0, $n) } } catch { }
        $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        if ($text -match '(?s)^HTTP/\d\.\d\s+(?<c>\d{3})[^\r\n]*\r?\n(?<h>.*?)\r?\n\r?\n(?<b>.*)$') {
            $code = [int]$Matches.c; $payload = $Matches.b; $when = $null
            if ($Matches.h -match '(?im)^Date:\s*(?<d>[^\r\n]+)') {
                $parsed = [datetime]::MinValue
                $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
                if ([datetime]::TryParse($Matches.d.Trim(), [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { $when = $parsed }
            }
            return [pscustomobject]@{ status = $code; body = $payload; date = $when }
        }
        & $none
    }
    catch { & $none }
    finally { $client.Close() }
}

function ConvertTo-OrderTime([string]$Text) {
    [datetime]::ParseExact($Text, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
}

# Texte signé : identique, caractère pour caractère, à celui que produit New-UninstallOrder dans Pg20-Clients-Carnet.ps1
function Get-OrderMessage($Order) {
    'pg20-order-v1|{0}|{1}|{2}|{3}|{4}' -f $Order.id, $Order.action, $Order.nonce, $Order.iat, $Order.exp
}

# Renvoie '' si l'ordre est bon, sinon la raison du refus. La signature est vérifiée AVANT tout le reste.
function Test-UninstallOrder($Order, [string]$Sig, [string]$PublicKeyXml, [string]$OwnId, [datetime]$InstalledAt, [datetime]$Now) {
    try {
        foreach ($k in 'v', 'action', 'id', 'nonce', 'iat', 'exp') { if ($null -eq $Order.$k) { return 'ordre incomplet' } }
        if ([string]$Order.nonce -notmatch '^[0-9a-f]{32}$' -or [string]$Order.id -notmatch '^[0-9]{6,12}$') { return 'ordre mal formé' }
        $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
        $rsa.PersistKeyInCsp = $false
        try {
            $rsa.FromXmlString($PublicKeyXml)
            $good = $rsa.VerifyData([Text.Encoding]::UTF8.GetBytes((Get-OrderMessage $Order)), 'SHA256', [Convert]::FromBase64String($Sig))
        }
        finally { $rsa.Dispose() }
        if (-not $good) { return 'signature invalide' }
        if ([int]$Order.v -ne 1 -or [string]$Order.action -ne 'uninstall') { return 'action inconnue' }
        if ([string]$Order.id -ne $OwnId) { return "ordre pour un autre poste ($($Order.id))" }
        $iat = ConvertTo-OrderTime ([string]$Order.iat); $exp = ConvertTo-OrderTime ([string]$Order.exp)
        if ($Now -gt $exp) { return 'ordre périmé' }
        if ($iat -gt $Now.AddMinutes(10)) { return 'ordre daté du futur' }
        if ($iat -lt $InstalledAt.AddHours(-24)) { return "ordre antérieur à l'installation de cette tâche" }
        ''
    }
    catch { "ordre illisible ($($_.Exception.Message))" }
}

# Suppression de la tâche et du dossier par un petit processus détaché : on ne supprime pas, depuis la tâche elle-même, la tâche qui nous exécute
function Remove-AgentSelf([string]$Dir, [string]$TaskName) {
    if ($TaskName -notmatch '^[A-Za-z0-9_\-]{3,64}$' -or $Dir -match '["&|<>^%]') { return }
    $cmd = 'ping -n 16 127.0.0.1 >nul & schtasks /Delete /TN "' + $TaskName + '" /F >nul 2>&1 & rmdir /s /q "' + $Dir + '" & rmdir "' + (Split-Path -Parent $Dir) + '" >nul 2>&1'
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -ArgumentList ('/c ' + $cmd) -WindowStyle Hidden
}

function Get-OwnRustDeskId([string]$Override, [string]$ServiceProfile, [bool]$Skip) {
    if ($Override) { return $Override }
    $toml = Join-Path $ServiceProfile 'AppData\Roaming\RustDesk\config\RustDesk.toml'
    if (Test-Path -LiteralPath $toml) {
        $m = Select-String -LiteralPath $toml -Pattern "^id\s*=\s*'(?<id>[0-9]{6,12})'" | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups['id'].Value }
    }
    $exe = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
    if (-not $Skip -and (Test-Path -LiteralPath $exe)) {
        $o = Join-Path $env:TEMP ('pg20-id-' + [guid]::NewGuid().ToString('N') + '.txt')
        try {
            $p = Start-Process -FilePath $exe -ArgumentList '--get-id' -RedirectStandardOutput $o -PassThru -WindowStyle Hidden
            if (-not $p.WaitForExit(20000)) { try { $p.Kill() } catch { } }
            Start-Sleep -Milliseconds 300
            $t = [string](Get-Content -LiteralPath $o -Raw -ErrorAction SilentlyContinue)
            if ($t.Trim() -match '^[0-9]{6,12}$') { return $t.Trim() }
        }
        catch { }
        finally { [IO.File]::Delete($o) }
    }
    ''
}

# Accusé « ordre exécuté » : 'ok' (enregistré), 'gone' (ordre annulé, périmé ou déjà accusé : plus rien à signaler) ou 'fail' (à retenter plus tard)
function Send-OrderDone($Cfg, [string]$Id, [string]$Nonce) {
    $body = ConvertTo-Json -InputObject ([ordered]@{ v = 1; id = $Id; nonce = $Nonce }) -Compress
    $d = Invoke-PinnedRequest ([string]$Cfg.server) ([string]$Cfg.pin) 'POST' '/v1/order-done' $body
    if ($d.status -eq 200) { return 'ok' }
    if ($d.status -in 400, 404) { return 'gone' }
    'fail'
}

function Test-RustDeskPresent {
    if (Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue) { return $true }
    if (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe')) { return $true }
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    [bool](Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'RustDesk' } | Select-Object -First 1)
}

# ------------------------------------------------------------------------------------------------ un passage
$agentDir = $(if ($ConfigPath) { Split-Path -Parent $ConfigPath } else { $PSScriptRoot })
$script:LogDirResolved = $(if ($LogDir) { $LogDir } else { $agentDir })
try {
    if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'agent.json' }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in 'server', 'pin', 'pubkey', 'installedAt', 'task') { if (-not $cfg.$k) { throw "configuration incomplète ($k)" } }
    if ([string]$cfg.pin -notmatch '^[0-9a-fA-F]{64}$') { throw 'empreinte de certificat invalide' }
    $installedAt = ConvertTo-OrderTime ([string]$cfg.installedAt)

    # Accusé non encore enregistré par le serveur (réseau coupé juste après la désinstallation) : retenté à chaque passage, 14 jours au plus
    $marker = Join-Path $agentDir 'done.json'
    $pendingDone = $null
    if (Test-Path -LiteralPath $marker) {
        try { $pendingDone = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if (-not $pendingDone -or [string]$pendingDone.id -notmatch '^[0-9]{6,12}$' -or [string]$pendingDone.nonce -notmatch '^[0-9a-f]{32}$') { [IO.File]::Delete($marker); $pendingDone = $null }
    }

    $present = $(if ($SkipProgram) { $true } else { Test-RustDeskPresent })
    if ($pendingDone -and $present) { [IO.File]::Delete($marker); $pendingDone = $null }       # RustDesk est de retour (réinstallé) : l'accusé ne sert plus
    if (-not $present) {
        if ($pendingDone) {
            $age = 0; try { $age = ((Get-Date).ToUniversalTime() - (ConvertTo-OrderTime ([string]$pendingDone.at))).TotalDays } catch { }
            $res = Send-OrderDone $cfg ([string]$pendingDone.id) ([string]$pendingDone.nonce)
            if ($res -eq 'fail' -and $age -lt 14) { return [pscustomobject]@{ result = 'rien'; detail = 'accusé de désinstallation en attente (serveur injoignable)' } }
            [IO.File]::Delete($marker)
            Write-AgentLog $(if ($res -eq 'ok') { 'Désinstallation signalée au serveur (accusé retardé).' } else { "Accusé de désinstallation abandonné ($res)." })
        }
        Write-AgentLog "RustDesk n'est plus installé : la tâche de maintenance se supprime."
        if (-not $NoSelfClean) { Remove-AgentSelf $agentDir ([string]$cfg.task) }
        return [pscustomobject]@{ result = 'auto-nettoyage'; detail = 'RustDesk absent' }
    }
    $id = Get-OwnRustDeskId $CurrentId $ServiceProfile ([bool]$SkipProgram)
    if (-not $id) { return [pscustomobject]@{ result = 'rien'; detail = 'ID illisible (service pas prêt ?)' } }

    $r = Invoke-PinnedRequest ([string]$cfg.server) ([string]$cfg.pin) 'GET' ('/v1/order?id=' + $id)
    if ($r.status -ne 200) { return [pscustomobject]@{ result = 'rien'; detail = "pas d'ordre (HTTP $($r.status))" } }

    # Heure de référence : celle du serveur (l'horloge d'un poste peut être fausse), sinon celle du poste
    $now = $(if ($NowOverride) { ConvertTo-OrderTime $NowOverride } elseif ($r.date) { $r.date } else { (Get-Date).ToUniversalTime() })
    $data = $r.body | ConvertFrom-Json
    $why = Test-UninstallOrder $data.order ([string]$data.sig) ([string]$cfg.pubkey) $id $installedAt $now
    if ($why) {
        Write-AgentLog "Ordre REFUSÉ : $why"
        return [pscustomobject]@{ result = 'ordre-refuse'; detail = $why }
    }

    $nonce = [string]$data.order.nonce
    Write-AgentLog "Ordre de désinstallation valide (n° $nonce) : exécution."
    $logArg = @{}; if ($LogDir) { $logArg['LogDir'] = $LogDir }
    $u = Uninstall-RustDeskFully -ExpectedId $id -KeepAgent -DryRun:$DryRun -SkipProgram:$SkipProgram -CurrentId $CurrentId -ProfileRoot $ProfileRoot -ServiceProfile $ServiceProfile @logArg
    if (-not $u.ok) {
        if ($u.aborted) { Write-AgentLog "Désinstallation abandonnée (ID ou droits)." } else { Write-AgentLog ('Désinstallation incomplète : ' + (@($u.left) -join ' ; ') + ' : nouvel essai au prochain passage.') }
        return [pscustomobject]@{ result = $(if ($u.aborted) { 'abandon' } else { 'incomplet' }); detail = (@($u.left) -join ' ; ') }
    }
    if ($DryRun) { return [pscustomobject]@{ result = 'simulation'; detail = 'ordre valide, rien exécuté' } }

    # Accusé au serveur (quelques essais : le réseau peut être lent juste après la désinstallation), puis la tâche disparaît. Si le serveur reste
    # injoignable, un repère (done.json) est gardé et la tâche reste : l'accusé est retenté à chaque passage, sans quoi le technicien ne saurait jamais
    # que le poste est désinstallé.
    [IO.File]::WriteAllText($marker, (ConvertTo-Json -InputObject ([ordered]@{ id = $id; nonce = $nonce; at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }) -Compress), (New-Object Text.UTF8Encoding($false)))
    $res = 'fail'
    for ($i = 1; $i -le 4 -and $res -eq 'fail'; $i++) {
        $res = Send-OrderDone $cfg $id $nonce
        if ($res -eq 'fail' -and $i -lt 4) { Start-Sleep -Seconds $DoneRetrySeconds }
    }
    if ($res -eq 'fail') {
        Write-AgentLog "Désinstallation terminée, serveur injoignable : l'accusé sera retenté."
        return [pscustomobject]@{ result = 'desinstalle'; detail = 'non signalé' }
    }
    [IO.File]::Delete($marker)
    Write-AgentLog 'Désinstallation terminée et signalée au serveur.'
    if (-not $NoSelfClean) { Remove-AgentSelf $agentDir ([string]$cfg.task) }
    [pscustomobject]@{ result = 'desinstalle'; detail = 'signalé' }
}
catch {
    Write-AgentLog "Erreur : $($_.Exception.Message)"
    [pscustomobject]@{ result = 'erreur'; detail = $_.Exception.Message }
}
