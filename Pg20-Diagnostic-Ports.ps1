<#
.SYNOPSIS
    Pg20 Info : mesure ce que RustDesk laisse ouvert sur CE poste (ports en écoute, règles du pare-feu Windows, options réseau). LECTURE SEULE : rien n'est
    installé, créé ni modifié, sauf le fichier de rapport.

.DESCRIPTION
    À lancer sur un poste où RustDesk est installé ET lancé (de préférence en administrateur : le pare-feu et la configuration du service ne se lisent
    pas autrement) :
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Pg20-Diagnostic-Ports.ps1
    ou double-clic sur Pg20-Diagnostic-Ports.cmd. Le rapport Ports-<date>.txt s'écrit à côté du script (sur la clé USB, ou dans TEMP si la clé est protégée
    en écriture). Il liste : les processus rustdesk, chaque port TCP/UDP en écoute (et s'il est joignable depuis le réseau ou seulement depuis le poste), les
    options direct-server / enable-lan-discovery / whitelist de la configuration du service, les règles du pare-feu qui concernent rustdesk.exe, puis un VERDICT.
    Jamais de mot de passe ni de clé : seule la configuration d'options (RustDesk2.toml) est lue, pas RustDesk.toml.
#>
[CmdletBinding()]
param(
    [string]$OutDir,            # dossier du rapport (défaut : celui du script, sinon TEMP)
    [string]$ConfigPath         # (tests) fichier RustDesk2.toml à lire à la place de celui du service
)
$ErrorActionPreference = 'Continue'
$script:out = New-Object System.Collections.Generic.List[string]
function Add-Out([string]$Text = '') { $script:out.Add($Text); Write-Host $Text }
function Section([string]$Title) { Add-Out ''; Add-Out ('== ' + $Title) }
function Try-Get([scriptblock]$Block) { try { & $Block } catch { $null } }

# Valeur d'une option « nom = 'valeur' » dans un fichier RustDesk2.toml (section [options] ou haut de fichier) ; $null si absente
function Get-TomlOption([string[]]$Lines, [string]$Name) {
    foreach ($l in $Lines) {
        if ($l -match ('^\s*' + [regex]::Escape($Name) + '\s*=\s*(?<v>.*?)\s*$')) { return $Matches['v'].Trim().Trim("'", '"') }
    }
    $null
}
# Un port en écoute est-il joignable depuis le réseau (adresse non locale) ?
function Test-ExposedAddress([string]$Address) { -not ($Address -in '127.0.0.1', '::1', 'localhost') }
# Verdict en clair à partir de ce qui a été mesuré
function Get-PortsVerdict {
    param($Listeners, $Options, [bool]$InboundAllowRule, [bool]$InboundBlockRule, [bool]$RulesReadable, [bool]$RustDeskRunning, [int[]]$BlockedPorts = @())
    $v = New-Object System.Collections.Generic.List[string]
    $direct = @($Listeners | Where-Object { $_.Proto -eq 'TCP' -and $_.Exposed -and $_.Port -eq 21118 })
    $lanSock = @($Listeners | Where-Object { $_.Proto -eq 'UDP' -and $_.Exposed -and $_.Port -eq 21119 })      # socket de la découverte du réseau local : RustDesk le lie toujours
    $ds = $Options.'direct-server'; $ld = $Options.'enable-lan-discovery'
    $optionsOk = ($null -ne $Options.Readable -and $Options.Readable)
    if (-not $RustDeskRunning) { $v.Add('RustDesk n''est pas lancé : les ports en écoute n''ont pas pu être mesurés (lancez-le, puis recommencez).') }
    else {
        if ($direct.Count) { $v.Add('A CORRIGER : l''accès direct par IP écoute sur TCP 21118 et est joignable depuis le réseau.') }
        else { $v.Add('OK : aucun port d''accès direct par IP (TCP 21118) n''écoute.') }
        if ($lanSock.Count -and $optionsOk -and $ld -eq 'N' -and 21119 -in $BlockedPorts) { $v.Add('OK : UDP 21119 (découverte du réseau local) reste lié par RustDesk, mais enable-lan-discovery = N et une règle du pare-feu bloque l''entrant sur ce port.') }
        elseif ($lanSock.Count -and $optionsOk -and $ld -eq 'N') { $v.Add('INFO : UDP 21119 (découverte du réseau local) reste ouvert, RustDesk lie toujours ce socket ; avec enable-lan-discovery = N il ne répond plus aux sondes (d''après le code de RustDesk, à confirmer depuis un autre PC). Une règle de pare-feu entrante le fermerait aussi.') }
        elseif ($lanSock.Count -and $optionsOk) { $v.Add('A CORRIGER : UDP 21119 (découverte du réseau local) est ouvert et enable-lan-discovery n''est pas à N : le poste répond aux sondes du réseau local.') }
        elseif ($lanSock.Count) { $v.Add('A VERIFIER : UDP 21119 (découverte du réseau local) est ouvert et la configuration est illisible : on ne sait pas si le poste répond aux sondes.') }
        else { $v.Add('OK : aucun socket de découverte du réseau local (UDP 21119) n''écoute.') }
    }
    if ($null -eq $Options.Readable -or -not $Options.Readable) { $v.Add('Options : configuration du service illisible (relancez en administrateur) ou absente.') }
    else {
        $v.Add($(if ($ds -eq 'Y') { 'A CORRIGER : direct-server = Y (accès direct par IP activé).' } elseif ($ds -eq 'N') { 'OK : direct-server = N.' } else { 'direct-server non défini : valeur par défaut de RustDesk (désactivé).' }))
        $v.Add($(if ($ld -eq 'N') { 'OK : enable-lan-discovery = N.' } else { 'A CORRIGER : enable-lan-discovery non défini ou activé : valeur par défaut de RustDesk = poste visible sur le réseau local.' }))
        $tcpOther = @($Listeners | Where-Object { $_.Proto -eq 'TCP' -and $_.Exposed -and $_.Port -ne 21118 })
        if ($tcpOther.Count) { $v.Add('INFO : ' + $tcpOther.Count + ' port(s) TCP éphémère(s) joignable(s) depuis le réseau (' + (($tcpOther | ForEach-Object { $_.Port }) -join ', ') + ') ouvert(s) par RustDesk, sans doute pour une connexion directe depuis le réseau local (session en cours ou récente) ; relancez le diagnostic hors session pour voir s''il se ferme. La règle entrante de RustDesk les autorise : seuls TCP 21118 et UDP 21119 sont bloqués.') }
    }
    if (-not $RulesReadable) { $v.Add('Pare-feu : règles illisibles (relancez en administrateur).') }
    elseif ($InboundBlockRule) { $v.Add('OK : une règle BLOQUE les connexions entrantes de rustdesk.exe.') }
    elseif ($InboundAllowRule) {
        $sensibles = @(21118, 21119); $fermes = @($sensibles | Where-Object { $_ -in $BlockedPorts })
        $etat = $(if ($fermes.Count -eq $sensibles.Count) { 'les ports sensibles (TCP 21118, UDP 21119) sont bloqués par une règle ciblée' } elseif ($fermes.Count) { 'ports sensibles bloqués par règle : ' + ($fermes -join ', ') } else { 'aucune règle ciblée sur les ports sensibles (TCP 21118, UDP 21119)' })
        $v.Add('INFO : une règle entrante créée par l''installeur de RustDesk AUTORISE tous les ports de rustdesk.exe (acceptée pour l''instant : le poste n''en a pas besoin, mais direct-server et enable-lan-discovery à N limitent l''exposition) ; ' + $etat + '.')
    }
    else { $v.Add('Pare-feu : aucune règle propre à rustdesk.exe (le pare-feu par défaut bloque l''entrant non sollicité).') }
    $v.ToArray()
}

Add-Out ('Pg20 Info : mesure des ports de RustDesk, ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Out ('Session : ' + $(if ($isAdmin) { 'administrateur' } else { 'utilisateur standard (le pare-feu et la configuration du service ne sont pas lisibles : relancez en administrateur)' }))
Add-Out ('PC : ' + $env:COMPUTERNAME)

# ------------------------------------------------------------------ RustDesk
Section 'RustDesk'
$keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$inst = Try-Get { Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'RustDesk' } | Select-Object -First 1 }
Add-Out $(if ($inst) { '  Installé : version ' + $inst.DisplayVersion } else { '  Non installé (aucune entrée « RustDesk » dans les programmes).' })
$svc = Try-Get { Get-Service -Name 'RustDesk' -ErrorAction Stop }
Add-Out $(if ($svc) { '  Service : {0} (démarrage : {1})' -f $svc.Status, $svc.StartType } else { '  Service RustDesk : absent' })
$procs = @(Try-Get { Get-Process -Name rustdesk -ErrorAction SilentlyContinue } | Where-Object { $_ })
$pids = @($procs | ForEach-Object { [int]$_.Id })
$roles = @{}
foreach ($cp in @(Try-Get { Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" } | Where-Object { $_ })) {
    $cl = [string]$cp.CommandLine
    $roles[[int]$cp.ProcessId] = $(if ($cl -match '--service') { 'service' } elseif ($cl -match '--server') { 'serveur de la session' } elseif ($cl -match '--tray') { 'icône de la zone de notification' } elseif ($cl -match '--cm') { 'fenêtre de connexion' } else { 'interface' })
}
foreach ($p in $procs) { Add-Out ('  Processus rustdesk.exe : PID {0} ({1})' -f $p.Id, $(if ($roles.ContainsKey([int]$p.Id)) { $roles[[int]$p.Id] } else { 'rôle non lu' })) }
if (-not $procs.Count) { Add-Out '  Aucun processus rustdesk.exe en cours.' }

# ------------------------------------------------------------------ Ports en écoute
Section 'Ports en écoute par rustdesk.exe'
$listeners = New-Object System.Collections.Generic.List[object]
if ($pids.Count) {
    $tcp = @(Try-Get { Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.OwningProcess -in $pids } } | Where-Object { $_ })
    foreach ($c in $tcp) { $listeners.Add([pscustomobject]@{ Proto = 'TCP'; Address = [string]$c.LocalAddress; Port = [int]$c.LocalPort; Pid = [int]$c.OwningProcess; Exposed = (Test-ExposedAddress ([string]$c.LocalAddress)) }) }
    $udp = @(Try-Get { Get-NetUDPEndpoint -ErrorAction Stop | Where-Object { $_.OwningProcess -in $pids } } | Where-Object { $_ })
    foreach ($c in $udp) { $listeners.Add([pscustomobject]@{ Proto = 'UDP'; Address = [string]$c.LocalAddress; Port = [int]$c.LocalPort; Pid = [int]$c.OwningProcess; Exposed = (Test-ExposedAddress ([string]$c.LocalAddress)) }) }
    foreach ($l in ($listeners | Sort-Object Proto, Port)) {
        $role = if ($l.Proto -eq 'TCP' -and $l.Port -eq 21118) { 'accès direct par IP' } elseif ($l.Proto -eq 'TCP') { 'port TCP éphémère (connexion directe depuis le réseau local ? à confirmer hors session)' } elseif ($l.Proto -eq 'UDP' -and $l.Port -eq 21119) { 'découverte du réseau local (socket toujours ouvert ; il ne répond que si enable-lan-discovery n''est pas à N)' } elseif ($l.Proto -eq 'UDP') { 'port éphémère (connexion sortante / liaison directe entre postes)' } else { '' }
        Add-Out ('  {0} {1}:{2}  PID {3} ({4})  {5}  {6}' -f $l.Proto, $l.Address, $l.Port, $l.Pid, $(if ($roles.ContainsKey($l.Pid)) { $roles[$l.Pid] } else { '?' }), $(if ($l.Exposed) { 'joignable depuis le réseau' } else { 'local seulement' }), $role)
    }
    if (-not $listeners.Count) { Add-Out '  (aucun)' }
}
else { Add-Out '  RustDesk n''est pas lancé : rien à mesurer.' }

# ------------------------------------------------------------------ Options
Section 'Options réseau de la configuration RustDesk (RustDesk2.toml du service)'
$cfg = $ConfigPath; if (-not $cfg) { $cfg = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml' }
$options = @{ Readable = $false }
$lines = $null
try { if (Test-Path -LiteralPath $cfg -ErrorAction Stop) { $lines = @(Get-Content -LiteralPath $cfg -Encoding UTF8 -ErrorAction Stop) } } catch { $lines = $null }
if ($null -ne $lines) {
    $options.Readable = $true
    foreach ($n in 'direct-server', 'enable-lan-discovery', 'whitelist', 'id-whitelist', 'approve-mode', 'verification-method', 'custom-rendezvous-server') {
        $val = Get-TomlOption $lines $n; $options[$n] = $val
        Add-Out ('  {0,-26} = {1}' -f $n, $(if ($null -ne $val) { $val } else { '(non défini : valeur par défaut)' }))
    }
}
else { Add-Out ('  Illisible ou absente : ' + $cfg + $(if (-not $isAdmin) { ' (relancez en administrateur)' } else { '' })) }
if (-not $ConfigPath) {
    foreach ($ud in @(Try-Get { Get-ChildItem 'C:\Users' -Directory -ErrorAction Stop } | Where-Object { $_ })) {
        $uc = Join-Path $ud.FullName 'AppData\Roaming\RustDesk\config\RustDesk2.toml'
        if (-not (Test-Path -LiteralPath $uc -ErrorAction SilentlyContinue)) { continue }
        $ul = $null; try { $ul = @(Get-Content -LiteralPath $uc -Encoding UTF8 -ErrorAction Stop) } catch { }
        if ($null -eq $ul) { Add-Out ('  Profil {0} : configuration illisible' -f $ud.Name); continue }
        Add-Out ('  Profil utilisateur {0} : direct-server = {1} ; enable-lan-discovery = {2}' -f $ud.Name, $(if ($null -ne (Get-TomlOption $ul 'direct-server')) { Get-TomlOption $ul 'direct-server' } else { '(non défini)' }), $(if ($null -ne (Get-TomlOption $ul 'enable-lan-discovery')) { Get-TomlOption $ul 'enable-lan-discovery' } else { '(non défini)' }))
    }
}

# ------------------------------------------------------------------ Pare-feu
Section 'Pare-feu Windows : règles concernant rustdesk.exe'
$allRules = @(Try-Get { Get-NetFirewallRule -ErrorAction Stop } | Where-Object { $_ })
$rulesReadable = ($allRules.Count -gt 0)
$allow = $false; $block = $false; $blockedPorts = New-Object System.Collections.Generic.List[int]
if ($rulesReadable) {
    foreach ($pr in Try-Get { Get-NetFirewallProfile -ErrorAction Stop }) { Add-Out ('  Profil {0} : pare-feu {1} ; entrant par défaut : {2}' -f $pr.Name, $(if ($pr.Enabled) { 'activé' } else { 'DÉSACTIVÉ' }), $pr.DefaultInboundAction) }
    $apps = @(Try-Get { Get-NetFirewallApplicationFilter -ErrorAction Stop | Where-Object { $_.Program -like '*rustdesk*' } } | Where-Object { $_ })
    $names = @{}; foreach ($a in $apps) { $names[[string]$a.InstanceID] = [string]$a.Program }
    $mine = @($allRules | Where-Object { $_.DisplayName -like '*RustDesk*' -or $names.ContainsKey([string]$_.InstanceID) })
    foreach ($r in $mine) {
        $prog = ''; try { $prog = [string](($r | Get-NetFirewallApplicationFilter -ErrorAction Stop).Program) } catch { }
        $pf = Try-Get { $r | Get-NetFirewallPortFilter -ErrorAction Stop }
        Add-Out ('  « {0} » : {1}, {2}, activée : {3}, profils : {4}, programme : {5}, protocole : {6}, port local : {7}' -f $r.DisplayName, $r.Direction, $r.Action, $r.Enabled, $r.Profile, $prog, $pf.Protocol, $pf.LocalPort)
        if ([string]$r.Enabled -eq 'True' -and [string]$r.Direction -eq 'Inbound') {
            if ([string]$r.Action -eq 'Allow') { $allow = $true }
            elseif ([string]$r.Action -eq 'Block') {
                $lp = @($pf.LocalPort | ForEach-Object { [string]$_ })
                if (-not $lp.Count -or $lp -contains 'Any') { $block = $true }                       # bloque tout rustdesk.exe
                else { foreach ($x in $lp) { $n = 0; if ([int]::TryParse($x, [ref]$n)) { $blockedPorts.Add($n) } } }       # bloque seulement ces ports
            }
        }
    }
    if (-not $mine.Count) { Add-Out '  Aucune règle propre à rustdesk.exe.' }
}
else { Add-Out '  Règles illisibles (relancez en administrateur).' }

# ------------------------------------------------------------------ Verdict
Section 'VERDICT'
foreach ($line in (Get-PortsVerdict -Listeners $listeners.ToArray() -Options ([pscustomobject]$options) -InboundAllowRule $allow -InboundBlockRule $block -RulesReadable $rulesReadable -RustDeskRunning ($pids.Count -gt 0) -BlockedPorts $blockedPorts.ToArray())) { Add-Out ('  ' + $line) }

# ------------------------------------------------------------------ Écriture du rapport
$dirOut = $OutDir; if (-not $dirOut) { $dirOut = $PSScriptRoot }; if (-not $dirOut) { $dirOut = (Get-Location).Path }
$file = Join-Path $dirOut ('Ports-{0:yyyyMMdd-HHmm}.txt' -f (Get-Date))
try { [IO.File]::WriteAllLines($file, $script:out, (New-Object Text.UTF8Encoding($true))) }
catch { $file = Join-Path $env:TEMP ('Ports-{0:yyyyMMdd-HHmm}.txt' -f (Get-Date)); [IO.File]::WriteAllLines($file, $script:out, (New-Object Text.UTF8Encoding($true))) }
Write-Host ''
Write-Host "Rapport écrit : $file" -ForegroundColor Green
