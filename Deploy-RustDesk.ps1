<#
.SYNOPSIS
    Déploie RustDesk chez un client en accès sans surveillance (service Windows + mot de passe permanent).

.DESCRIPTION
    1. Télécharge l'installeur officiel (GitHub) ou utilise -InstallerPath, vérifie la signature Authenticode.
    2. Installe en silencieux, avec le service Windows (démarrage automatique).
    3. Applique votre serveur (-ConfigString, ou -Server/-Key) si fourni, sinon garde le serveur public.
    4. Définit un mot de passe permanent (généré si absent) et n'accepte que ce mot de passe
       (pas de clic de validation côté client, pas de mot de passe temporaire).
    5. Affiche l'ID + le mot de passe et les ajoute à un CSV (à ranger dans votre gestionnaire de mots de passe).

    À lancer en administrateur, avec l'accord du client.

.EXAMPLE
    # Serveur public RustDesk, mot de passe généré
    .\Deploy-RustDesk.ps1 -ClientName "Dupont SARL"

.EXAMPLE
    # Votre serveur auto-hébergé
    .\Deploy-RustDesk.ps1 -ClientName "Dupont SARL" -Server rd.mondomaine.fr -Key "AbCdEf...="

.EXAMPLE
    # Avec la chaîne exportée depuis RustDesk (Paramètres > Réseau > Exporter la config serveur)
    .\Deploy-RustDesk.ps1 -ClientName "Dupont SARL" -ConfigString "0nI9...."

.EXAMPLE
    # Désinstallation
    .\Deploy-RustDesk.ps1 -Uninstall
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ClientName,                    # demandé à l'écran si absent (Entrée = nom du poste)
    [string]$InstallerPath,                 # installeur local (sinon téléchargé depuis GitHub)
    [string]$Version,                       # ex. 1.4.9 ; vide = dernière version stable
    [string]$ConfigString,                  # chaîne "Exporter la config serveur"
    [string]$Server,                        # ex. rd.mondomaine.fr
    [string]$Relay,                         # facultatif, par défaut = $Server
    [string]$ApiServer,                     # facultatif (RustDesk Pro / console web)
    [string]$Key,                           # clé publique du serveur (id_ed25519.pub)
    [string]$Password,                      # demandé à l'écran si absent (Entrée = généré aléatoirement)
    [ValidateRange(12, 64)][int]$PasswordLength = 20,
    [string]$OutDir,                        # dossier du CSV (défaut : dossier du script)
    [switch]$NoSaveCredentials,             # ne pas écrire le CSV
    [switch]$SkipAuthPolicy,                # ne pas forcer "mot de passe permanent uniquement"
    [switch]$ForceReinstall,
    [switch]$NoPrompt,                      # aucune question à l'écran (déploiement par script, GPO, RMM)
    [string]$TechPublicKey,                 # clé publique RSA (XML) du technicien : le mot de passe est chiffré dans le CSV
    [string]$InboxUrl,                      # réception des fiches sur votre serveur : hôte[:port], port par défaut 21120
    [string]$InboxPin,                      # empreinte SHA-256 (64 hex) du certificat TLS de ce service : seul ce certificat est accepté
    [switch]$NoInbox,                       # ne pas envoyer la fiche au serveur
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RdExe       = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
$ServiceName = 'RustDesk'
$ServiceToml = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml'

function Write-Step($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

# RustDesk est une appli GUI : passer par un pipe force PowerShell à attendre la fin et à capturer la sortie.
# Exécute rustdesk.exe avec un délai maximal : une commande qui ne rend pas la main ne bloque plus le script
function Invoke-RustDesk {
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSec = 60)
    $argLine = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    # La sortie passe par des fichiers temporaires : un processus enfant resté vivant ne bloque pas la lecture
    $o = Join-Path $env:TEMP ('rd-out-' + [guid]::NewGuid().ToString('N') + '.txt'); $e = $o + '.err'
    try {
        $p = Start-Process -FilePath $RdExe -ArgumentList $argLine -RedirectStandardOutput $o -RedirectStandardError $e -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { } }
        Start-Sleep -Milliseconds 200
        $text = ''
        foreach ($f in $o, $e) { if (Test-Path $f) { $text += (Get-Content $f -Raw -ErrorAction SilentlyContinue) } }
        "$text".Trim()
    }
    finally { Remove-Item $o, $e -Force -ErrorAction SilentlyContinue }
}

function Get-InstalledRustDesk {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'RustDesk' } |
        Select-Object -First 1
}

function Test-PasswordPolicy([string]$Value) {
    if ($Value.Length -lt 12) { return 'Mot de passe trop court (12 caractères minimum).' }
    if ($Value -match '\s')   { return 'Le mot de passe ne doit pas contenir d''espace.' }
    $null
}

function ConvertFrom-SecureInput([securestring]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Commande de désinstallation SILENCIEUSE. RustDesk s'installe via MSI : son UninstallString est "MsiExec.exe /X {GUID}", qui ouvrirait
# un assistant... invisible dans une fenêtre cachée. On relance donc msiexec avec /qn. Autres installeurs : on garde la commande d'origine.
function Get-UninstallCommand($Entry) {
    $us = [string]$Entry.UninstallString
    if ($us -match '(?i)msiexec(\.exe)?\s+/[IX]\s*(\{[0-9A-F\-]{36}\})') {
        return [pscustomobject]@{ File = 'msiexec.exe'; Args = "/x $($Matches[2]) /qn /norestart" }
    }
    [pscustomobject]@{ File = 'cmd.exe'; Args = '/c "' + $us + '"' }
}

function New-RandomPassword([int]$Length) {
    # Alphabet sans caractères ambigus (0/O, 1/l/I) ni caractères spéciaux (pas de souci de quoting)
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $rng   = [Security.Cryptography.RandomNumberGenerator]::Create()
    $buf   = New-Object byte[] 4
    -join (1..$Length | ForEach-Object {
        $rng.GetBytes($buf)
        $chars[[BitConverter]::ToUInt32($buf, 0) % $chars.Length]
    })
}

# RSA-OAEP : seul le technicien (qui détient la clé privée sur son PC) peut relire ce mot de passe
function Protect-ForTechnician([string]$Plain, [string]$PublicKeyXml) {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.FromXmlString($PublicKeyXml)
        [Convert]::ToBase64String($rsa.Encrypt([Text.Encoding]::UTF8.GetBytes($Plain), $true))
    }
    finally { $rsa.Dispose() }
}

# Fiche enregistrée dans le CSV ; avec une clé publique, la colonne Password reste vide et PasswordEnc contient le mot de passe chiffré
function New-DeploymentRecord {
    param([string]$ClientName, [string]$ComputerName, [string]$Id, [string]$Password, [string]$Version, [string]$ServerLabel, [string]$TechPublicKey)
    $plain = $Password; $enc = ''
    if ($TechPublicKey) { $enc = Protect-ForTechnician $Password $TechPublicKey; $plain = '' }
    [pscustomobject]@{
        Date        = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Client      = $ClientName
        Poste       = $ComputerName
        ID          = $Id
        Password    = $plain
        PasswordEnc = $enc
        Version     = $Version
        Serveur     = $ServerLabel
    }
}

# ---------------------------------------------------------------- Envoi de la fiche au serveur du technicien
# La fiche (nom, poste, ID, mot de passe, code de contrôle) est chiffrée pour le technicien : AES-256-CBC + HMAC-SHA256, dont les clés
# sont enveloppées en RSA-OAEP avec sa clé publique. Le serveur qui la reçoit ne peut donc pas la lire. Format : RSA | IV (16) | AES | HMAC (32).
function Join-Bytes([byte[][]]$Parts) {
    $ms = New-Object IO.MemoryStream
    foreach ($p in $Parts) { $ms.Write($p, 0, $p.Length) }
    $ms.ToArray()
}

function New-Envelope($Record, [string]$PublicKeyXml) {
    $plain = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Record -Compress))
    $rng   = [Security.Cryptography.RandomNumberGenerator]::Create()
    $keys  = New-Object byte[] 64; $rng.GetBytes($keys)
    $iv    = New-Object byte[] 16; $rng.GetBytes($iv)
    $encKey = New-Object byte[] 32; $macKey = New-Object byte[] 32
    [Array]::Copy($keys, 0, $encKey, 0, 32); [Array]::Copy($keys, 32, $macKey, 0, 32)

    $aes = [Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.Mode = [Security.Cryptography.CipherMode]::CBC; $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $encKey; $aes.IV = $iv
    $ct = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
    $aes.Dispose()

    $hmac = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (, $macKey)
    $tag  = $hmac.ComputeHash((Join-Bytes @($iv, $ct, [Text.Encoding]::ASCII.GetBytes('pg20v1'))))
    $hmac.Dispose()

    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try { $rsa.FromXmlString($PublicKeyXml); $wrapped = $rsa.Encrypt($keys, $true) } finally { $rsa.Dispose() }
    [Convert]::ToBase64String((Join-Bytes @($wrapped, $iv, $ct, $tag)))
}

# Un envoi : TLS 1.2 direct (sans proxy), certificat vérifié par EMPREINTE (pas par autorité), requête HTTP/1.0 minimale.
# Renvoie status = code HTTP (0 = pas de réponse), error ('connect', 'certificate', 'tls', 'io') le cas échéant,
# et, pour une réponse 200, code = code de contrôle à 4 chiffres choisi par le serveur et follow = numéro de suivi (/v1/record), ou
# validated = fiche validée par le technicien (/v1/wait : le serveur garde la demande ouverte 20 s au plus).
function Send-InboxOnce([string]$Endpoint, [string]$Pin, [string]$Body, [string]$Path = '/v1/record', [int]$ReadTimeoutMs = 10000) {
    $hostName = $Endpoint; $port = 21120
    if ($Endpoint -match '^(?<h>[^:]+):(?<p>\d{1,5})$') { $hostName = $Matches.h; $port = [int]$Matches.p }
    $script:PinWanted = $Pin.ToLower()
    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($hostName, $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(8000)) { return [pscustomobject]@{ status = 0; error = 'connect' } }
        try { $client.EndConnect($ar) } catch { return [pscustomobject]@{ status = 0; error = 'connect' } }
        $client.ReceiveTimeout = $ReadTimeoutMs; $client.SendTimeout = 10000

        $callback = [Net.Security.RemoteCertificateValidationCallback]{
            param($sender, $cert, $chain, $errors)
            if (-not $cert) { return $false }
            $h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($cert.GetRawCertData())) -replace '-', ''
            $h.ToLower() -eq $script:PinWanted
        }
        $ssl = New-Object Net.Security.SslStream($client.GetStream(), $false, $callback)
        try { $ssl.AuthenticateAsClient($hostName, $null, [Security.Authentication.SslProtocols]::Tls12, $false) }
        catch {
            $msg = "$($_.Exception.Message) $($_.Exception.InnerException.Message)"
            return [pscustomobject]@{ status = 0; error = $(if ($msg -match '(?i)certificate|certificat|validation|authentication failed|authentification') { 'certificate' } else { 'tls' }) }
        }

        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $head = "POST $Path HTTP/1.0`r`nHost: $hostName`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
        $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
        $ssl.Write($headBytes, 0, $headBytes.Length); $ssl.Write($bodyBytes, 0, $bodyBytes.Length); $ssl.Flush()

        $ms = New-Object IO.MemoryStream; $buf = New-Object byte[] 2048
        try { while (($n = $ssl.Read($buf, 0, $buf.Length)) -gt 0 -and $ms.Length -lt 16384) { $ms.Write($buf, 0, $n) } } catch { }
        $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        if ($text -match '^HTTP/\d\.\d\s+(?<c>\d{3})') {
            $status = [int]$Matches.c; $ctl = ''; $flw = ''; $val = $false
            if ($status -eq 200 -and $text -match '"code"\s*:\s*"(?<k>\d{4})"') { $ctl = $Matches.k }
            if ($status -eq 200 -and $text -match '"follow"\s*:\s*"(?<f>[0-9a-f]{32})"') { $flw = $Matches.f }
            if ($status -eq 200 -and $text -match '"validated"\s*:\s*true') { $val = $true }
            return [pscustomobject]@{ status = $status; error = ''; code = $ctl; follow = $flw; validated = $val }
        }
        [pscustomobject]@{ status = 0; error = 'io'; code = '' }
    }
    catch { [pscustomobject]@{ status = 0; error = 'io'; code = '' } }
    finally { $client.Close() }
}

# Envoi avec nouvelles tentatives : le serveur ne reconnaît le poste qu'une fois son enregistrement relevé (quelques secondes)
function Send-InboxRecord([string]$Endpoint, [string]$Pin, [string]$Id, [string]$Label, [string]$Blob, [int]$MaxAttempts = 6, [int]$DelaySec = 10) {
    $body = ConvertTo-Json -InputObject ([ordered]@{ v = 1; id = $Id; label = $Label; blob = $Blob }) -Compress
    $connectFails = 0; $last = 0
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $r = Send-InboxOnce $Endpoint $Pin $body
        $last = $r.status
        if ($r.status -eq 200) { return [pscustomobject]@{ ok = $true; message = ''; code = $r.code; follow = $r.follow } }
        if ($r.error -eq 'certificate') { return [pscustomobject]@{ ok = $false; message = 'le certificat du serveur ne correspond pas à celui attendu (connexion refusée par sécurité)'; code = '' } }
        if ($r.status -eq 429) { return [pscustomobject]@{ ok = $false; message = 'trop de tentatives depuis cette adresse'; code = '' } }
        if ($r.status -in 400, 411, 413) { return [pscustomobject]@{ ok = $false; message = "fiche refusée par le serveur (code $($r.status))"; code = '' } }
        if ($r.status -eq 0) {
            $connectFails++
            if ($connectFails -ge 3) { return [pscustomobject]@{ ok = $false; message = $(if ($r.error -eq 'connect') { 'serveur injoignable (port 21120 bloqué par le réseau du client ?)' } else { 'échange sécurisé impossible avec le serveur' }); code = '' } }
        }
        Start-Sleep -Seconds $DelaySec      # 409 : poste pas encore reconnu, 503 : serveur occupé
    }
    if ($last -eq 409) {
        return [pscustomobject]@{ ok = $false; code = ''; message = "le serveur n'a enregistré aucune nouvelle inscription récente de ce poste (ID $Id) : cas d'une réinstallation sur un PC déjà connu du serveur. La fiche reste sur la clé USB ; pour l'envoyer au serveur, retirez d'abord ce poste du serveur (sudo pg20-forget-peer $Id) puis relancez l'exe" }
    }
    [pscustomobject]@{ ok = $false; message = 'le serveur n''a pas répondu correctement à temps'; code = '' }
}

# Attend que le technicien valide la fiche : UNE demande que le serveur garde ouverte (20 s au plus) et qu'on renouvelle tant qu'il n'y a
# pas de réponse, donc pas d'interrogation répétée toutes les quelques secondes. Renvoie 'validated', 'timeout' (délai dépassé),
# 'unknown' (suivi expiré ou refusé) ou 'error' (serveur injoignable, occupé ou certificat inattendu : on n'insiste pas).
function Wait-InboxValidation([string]$Endpoint, [string]$Pin, [string]$Follow, [int]$MaxSec = 600) {
    $body = ConvertTo-Json -InputObject ([ordered]@{ v = 1; follow = $Follow }) -Compress
    $deadline = (Get-Date).AddSeconds($MaxSec); $fails = 0
    while ((Get-Date) -lt $deadline) {
        $t0 = Get-Date
        $r = Send-InboxOnce $Endpoint $Pin $body '/v1/wait' 35000
        if ($r.status -eq 200) {
            $fails = 0
            if ($r.validated) { return 'validated' }
        }
        elseif ($r.status -eq 409) { return 'unknown' }
        elseif ($r.error -eq 'certificate') { return 'error' }
        else {
            $fails++
            if ($fails -ge 4) { return 'error' }
        }
        # une réponse rapide qui n'est pas « validée » ne doit jamais faire tourner la boucle à vide
        $spent = ((Get-Date) - $t0).TotalSeconds
        if ($spent -lt 10) { Start-Sleep -Seconds ([int][math]::Ceiling(10 - $spent)) }
    }
    'timeout'
}

function Get-InstallerFromGitHub([string]$Version) {
    $api = if ($Version) { "https://api.github.com/repos/rustdesk/rustdesk/releases/tags/$Version" }
           else          { 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' }
    Write-Step "Recherche de l'installeur ($(if ($Version) { $Version } else { 'dernière version' }))"
    $rel   = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'Deploy-RustDesk' }
    $asset = $rel.assets | Where-Object { $_.name -match '^rustdesk-[\d.]+-x86_64\.exe$' } | Select-Object -First 1
    if (-not $asset) { throw "Aucun installeur Windows x86_64 trouvé dans la release $($rel.tag_name)." }

    $dest = Join-Path $env:TEMP $asset.name
    Write-Step "Téléchargement de $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) Mo)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing

    if ($asset.PSObject.Properties['digest'] -and $asset.digest -match '^sha256:(?<h>[0-9a-f]{64})$') {
        $actual = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $Matches.h) { Remove-Item $dest -Force; throw 'SHA256 incorrect : téléchargement corrompu ou altéré.' }
        Write-Ok 'SHA256 conforme à celui publié par GitHub'
    }
    $dest
}

# ---------------------------------------------------------------- Désinstallation
if ($Uninstall) {
    $inst = Get-InstalledRustDesk
    if (-not $inst) { Write-Warn 'RustDesk n''est pas installé.'; return }
    Write-Step "Désinstallation de RustDesk $($inst.DisplayVersion)"
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    Get-Process rustdesk -ErrorAction SilentlyContinue | Stop-Process -Force
    $cmd = Get-UninstallCommand $inst
    $un = Start-Process -FilePath $cmd.File -ArgumentList $cmd.Args -PassThru -WindowStyle Hidden
    if (-not $un.WaitForExit(300000)) { Write-Warn 'Le désinstalleur est encore en cours après 5 minutes.' }
    $code = if ($un.HasExited) { $un.ExitCode } else { -1 }
    Start-Sleep 3
    $still = [bool](Get-Service $ServiceName -ErrorAction SilentlyContinue) -or (Test-Path $RdExe)
    if (-not $still) { Write-Ok 'RustDesk désinstallé.' }
    elseif ($code -eq 3010) { Write-Warn 'RustDesk est désinstallé : redémarrez le poste pour terminer.' }
    else { Write-Warn "RustDesk est encore présent (code de sortie $code). Redémarrez le poste puis relancez -Uninstall, ou utilisez « Applications et fonctionnalités »." }
    return
}

# ---------------------------------------------------------------- Contrôle des paramètres
if ($Server -and $ConfigString) { throw 'Utilisez -ConfigString OU -Server/-Key, pas les deux.' }
if ($Password) { $problem = Test-PasswordPolicy $Password; if ($problem) { throw $problem } }

# ---------------------------------------------------------------- Questions (nom du client, mot de passe)
# Posées d'emblée : on répond, puis tout le reste s'exécute sans intervention.
$interactive = -not $NoPrompt -and [Environment]::UserInteractive
if ($interactive) {
    try {
        if (-not $ClientName) {
            Write-Host ''
            $ClientName = (Read-Host "Nom du client (Entrée = $env:COMPUTERNAME)").Trim()
        }
        if (-not $Password) {
            Write-Host ''
            Write-Host 'Mot de passe permanent de ce poste (12 caractères minimum, sans espace).' -ForegroundColor Cyan
            Write-Host 'Entrée sans rien saisir = mot de passe généré automatiquement.'
            while (-not $Password) {
                $first = ConvertFrom-SecureInput (Read-Host 'Mot de passe' -AsSecureString)
                if (-not $first) { break }
                $problem = Test-PasswordPolicy $first
                if ($problem) { Write-Warn $problem; continue }
                if ($first -ne (ConvertFrom-SecureInput (Read-Host 'Confirmation' -AsSecureString))) { Write-Warn 'Les deux saisies sont différentes.'; continue }
                $Password = $first
            }
        }
    }
    catch { Write-Warn "Saisie impossible dans cette session ($($_.Exception.Message)) : valeurs par défaut utilisées." }
}
if (-not $ClientName) { $ClientName = $env:COMPUTERNAME }

# ---------------------------------------------------------------- Installation
$installed = Get-InstalledRustDesk
if ($installed -and -not $ForceReinstall) {
    Write-Ok "RustDesk $($installed.DisplayVersion) déjà installé : installation ignorée (utilisez -ForceReinstall pour réinstaller)."
}
else {
    if (-not $InstallerPath) { $InstallerPath = Get-InstallerFromGitHub $Version }
    if (-not (Test-Path $InstallerPath)) { throw "Installeur introuvable : $InstallerPath" }

    $sig = Get-AuthenticodeSignature $InstallerPath
    if ($sig.Status -ne 'Valid') { throw "Signature de l'installeur invalide ($($sig.Status)) : abandon." }
    Write-Ok "Signature valide : $($sig.SignerCertificate.Subject)"

    Write-Step 'Installation silencieuse'
    # On attend l'installeur SEUL : "Start-Process -Wait" attend aussi ses descendants, donc RustDesk lui-même
    # (lancé en fin d'installation, il ne se termine jamais) et le script restait bloqué sur cette ligne.
    $setup = Start-Process -FilePath $InstallerPath -ArgumentList '--silent-install' -PassThru
    if (-not $setup.WaitForExit(180000)) { Write-Warn 'L''installeur est encore en cours après 3 minutes : suite dès que RustDesk est présent.' }

    # --silent-install rend la main avant la fin de l'installation : on attend l'exécutable
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-Path $RdExe) -and (Get-Date) -lt $deadline) { Start-Sleep 2 }
    if (-not (Test-Path $RdExe)) { throw 'RustDesk introuvable après installation (délai de 90 s dépassé).' }
    Write-Ok 'RustDesk installé'
}

# ---------------------------------------------------------------- Service Windows
Write-Step 'Vérification du service Windows'
if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) {
    Invoke-RustDesk '--install-service' | Out-Null
    Start-Sleep 3
}
Set-Service $ServiceName -StartupType Automatic
if ((Get-Service $ServiceName).Status -ne 'Running') { Start-Service $ServiceName }
Write-Ok 'Service RustDesk en cours d''exécution (démarrage automatique)'

# Le service met quelques secondes à répondre : on attend qu'il renvoie un ID valide
function Get-RustDeskId {
    $id = Invoke-RustDesk '--get-id'
    if ($id -match '^\d{6,}$') { return $id }
    if (Test-Path $ServiceToml) {
        $m = Select-String -Path $ServiceToml -Pattern "^id\s*=\s*'(?<id>[^']+)'" | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups['id'].Value }
    }
    $null
}

Write-Step 'Attente de la disponibilité du service'
$rdId = $null
for ($i = 0; $i -lt 20 -and -not $rdId; $i++) { $rdId = Get-RustDeskId; if (-not $rdId) { Start-Sleep 3 } }
if (-not $rdId) { throw 'Impossible de récupérer l''ID RustDesk (service non prêt).' }

# ---------------------------------------------------------------- Serveur
if ($ConfigString) {
    Write-Step 'Application de la configuration serveur (chaîne exportée)'
    Invoke-RustDesk '--config', $ConfigString | Out-Null
}
elseif ($Server) {
    Write-Step "Application du serveur $Server"
    Invoke-RustDesk '--option', 'custom-rendezvous-server', $Server | Out-Null
    Invoke-RustDesk '--option', 'relay-server', $(if ($Relay) { $Relay } else { $Server }) | Out-Null
    if ($ApiServer) { Invoke-RustDesk '--option', 'api-server', $ApiServer | Out-Null }
    if ($Key)       { Invoke-RustDesk '--option', 'key', $Key | Out-Null }
    else            { Write-Warn 'Aucune clé (-Key) fournie : la connexion chiffrée au serveur ne sera pas vérifiée.' }
}
else {
    Write-Warn 'Aucun serveur fourni : le serveur public RustDesk est utilisé.'
}

# ---------------------------------------------------------------- Accès sans surveillance
Write-Step 'Définition du mot de passe permanent'
$generated = -not $Password
if ($generated) { $Password = New-RandomPassword $PasswordLength }
Invoke-RustDesk '--password', $Password | Out-Null

if (-not $SkipAuthPolicy) {
    Write-Step 'Politique d''accès : mot de passe permanent uniquement'
    Invoke-RustDesk '--option', 'approve-mode', 'password' | Out-Null
    Invoke-RustDesk '--option', 'verification-method', 'use-permanent-password' | Out-Null
}

Restart-Service $ServiceName
Start-Sleep 5
$rdId = Get-RustDeskId   # l'ID peut changer si le serveur a changé

# ---------------------------------------------------------------- Vérification
Write-Step 'Vérification finale'
$ver = (Get-InstalledRustDesk).DisplayVersion
$svc = Get-Service $ServiceName
if ($svc.Status -ne 'Running') { Write-Warn "Service : $($svc.Status)" } else { Write-Ok 'Service : Running' }
foreach ($opt in 'custom-rendezvous-server', 'approve-mode', 'verification-method') {
    $v = Invoke-RustDesk '--option', $opt
    Write-Host ("    {0,-26} = {1}" -f $opt, $(if ($v) { $v } else { '(par défaut)' }))
}

# ---------------------------------------------------------------- Envoi de la fiche au serveur du technicien
$inboxSent = $false; $controlCode = ''; $follow = ''
if ($TechPublicKey -and $InboxUrl -and $InboxPin -and -not $NoInbox) {
    Write-Step 'Envoi de la fiche (chiffrée) à votre serveur'
    try {
        if ($InboxPin -notmatch '^[0-9a-fA-F]{64}$') { throw 'empreinte du certificat (-InboxPin) invalide' }
        $record = [ordered]@{
            v = 1; id = $rdId; name = $ClientName; host = $env:COMPUTERNAME; password = $Password
            ver = $ver; ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        $sent = Send-InboxRecord -Endpoint $InboxUrl -Pin $InboxPin -Id $rdId -Label $ClientName -Blob (New-Envelope $record $TechPublicKey)
        if ($sent.ok) { $inboxSent = $true; $controlCode = [string]$sent.code; $follow = [string]$sent.follow; Write-Ok 'Fiche reçue par votre serveur' }
        else { Write-Warn "Fiche non envoyée : $($sent.message)." }
    }
    catch { Write-Warn "Fiche non envoyée : $($_.Exception.Message)." }
    if (-not $inboxSent) { $controlCode = ''; $follow = '' }
}

# ---------------------------------------------------------------- Résultat
if (-not $NoSaveCredentials) {
    if (-not $OutDir) { $OutDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }
    $csv = Join-Path $OutDir 'rustdesk-deployments.csv'
    # Un ancien CSV (sans colonne PasswordEnc) est mis de côté pour ne pas décaler les colonnes
    if ((Test-Path $csv) -and -not ((Get-Content $csv -TotalCount 1) -match 'PasswordEnc')) {
        Rename-Item $csv ('rustdesk-deployments.ancien-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))
    }
    $new = -not (Test-Path $csv)
    $serverLabel = $(if ($Server) { $Server } elseif ($ConfigString) { '(config importée)' } else { 'public' })
    New-DeploymentRecord -ClientName $ClientName -ComputerName $env:COMPUTERNAME -Id $rdId -Password $Password `
        -Version $ver -ServerLabel $serverLabel -TechPublicKey $TechPublicKey |
        Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8
    # Mot de passe en clair : accès limité aux administrateurs. Chiffré : aucune restriction nécessaire (et l'outil du technicien peut le lire sans élévation).
    if ($new -and -not $TechPublicKey) { icacls $csv /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null }
}

Write-Host ''
Write-Host '================ RustDesk prêt ================' -ForegroundColor Green
Write-Host "  Client   : $ClientName ($env:COMPUTERNAME)"
Write-Host "  ID       : $rdId"
$encrypted = [bool]$TechPublicKey -and -not $NoSaveCredentials
$delivered = $encrypted -or $inboxSent        # le technicien recevra le mot de passe (chiffré) : inutile de l'afficher ici
$pwShown = if ($delivered) { '(transmis au technicien, chiffré : rien à noter)' }
           elseif ($generated) { "$Password  (généré)" }
           else { '(celui que vous avez défini)' }
Write-Host "  Mot de passe permanent : $pwShown"
if ($inboxSent) { Write-Host '  Fiche envoyée au serveur du technicien : oui' }
if ($controlCode) { Write-Host "  Code de contrôle : $controlCode   (le technicien le compare avec celui de son téléphone)" -ForegroundColor Yellow }
if (-not $NoSaveCredentials) { Write-Host "  Enregistré dans : $csv$(if (-not $encrypted) { ' (accès limité aux administrateurs)' })" }
Write-Host '================================================' -ForegroundColor Green
if ($inboxSent) { Write-Warn 'Rien à noter : la fiche est arrivée sur le serveur du technicien, qui la validera depuis son téléphone avec le code de contrôle ci-dessus.' }
elseif ($encrypted) { Write-Warn 'Rien à noter : branchez la clé sur votre PC et ouvrez Pg20-Clients, le client sera importé automatiquement.' }
else { Write-Warn 'Transférez ces informations dans votre gestionnaire de mots de passe, puis supprimez le CSV s''il est sur une clé USB partagée.' }

# ---------------------------------------------------------------- Attente de la validation du technicien
# La fenêtre reste ouverte jusqu'à ce que le technicien valide la fiche depuis son téléphone, puis se ferme toute seule (code de sortie 10, que le
# lanceur reconnaît). Pas d'attente en mode silencieux. Fermer la fenêtre avant n'a aucune conséquence : tout est déjà installé et envoyé.
if ($inboxSent -and $follow -and $interactive) {
    Write-Host ''
    Write-Host "En attente de la validation du technicien... (vous pouvez aussi fermer cette fenêtre : l'installation est terminée)" -ForegroundColor Cyan
    $outcome = try { Wait-InboxValidation -Endpoint $InboxUrl -Pin $InboxPin -Follow $follow } catch { 'error' }
    switch ($outcome) {
        'validated' { Write-Host 'Validé par le technicien. Cette fenêtre va se fermer.' -ForegroundColor Green; Start-Sleep -Seconds 3; exit 10 }
        'timeout'   { Write-Warn "Le technicien n'a pas encore validé : il le fera depuis son téléphone. Vous pouvez fermer cette fenêtre." }
        default     { Write-Warn 'Suivi de la validation indisponible : le technicien validera depuis son téléphone. Vous pouvez fermer cette fenêtre.' }
    }
}
