<#
.SYNOPSIS
    Compile RustDesk-Deploy.exe : un lanceur Windows autonome qui embarque Deploy-RustDesk.ps1.

.DESCRIPTION
    Utilise uniquement le compilateur C# fourni avec Windows (aucun téléchargement, aucun outil à installer).
    L'exe demande les droits administrateur (UAC), télécharge RustDesk depuis GitHub, l'installe et le configure.
    Les paramètres passés ici (-Server, -Key, -ConfigString, -ClientName...) sont figés dans l'exe :
    le client n'a plus qu'à double-cliquer.

.EXAMPLE
    .\Build-Installer.ps1
.EXAMPLE
    .\Build-Installer.ps1 -Server rd.mondomaine.fr -Key "AbCdEf...=" -Output .\dist\RustDesk-Dupont.exe
.EXAMPLE
    .\Build-Installer.ps1 -ConfigString "0nI9..." -ClientName "Dupont SARL"
.EXAMPLE
    # Exe hors ligne : télécharge l'installeur RustDesk maintenant et l'embarque (aucun accès GitHub chez le client)
    .\Build-Installer.ps1 -Bundle -Server rd.mondomaine.fr -Key "AbCdEf...="
.EXAMPLE
    # Embarquer une version précise, ou un installeur déjà téléchargé
    .\Build-Installer.ps1 -Bundle -Version 1.4.9
    .\Build-Installer.ps1 -InstallerFile C:\Soft\rustdesk-1.4.9-x86_64.exe

.NOTES
    Options du lanceur au moment de l'exécution :
      (aucune option)  demande le nom du client puis le mot de passe permanent (Entrée = généré), puis installe seul
      /silent   aucune question ni pause finale (déploiement par script, GPO, RMM) : mot de passe généré ou -Password
      /save     écrit le CSV (ID + mot de passe) à côté de l'exe même s'il n'est pas sur une clé USB
    Tous les autres arguments sont transmis au script (ex. -Password "...", -Uninstall).
#>
[CmdletBinding()]
param(
    [string]$Script,                  # par défaut : Deploy-RustDesk.ps1 à côté de ce script
    [string]$Output,                  # par défaut : dist\RustDesk-Deploy.exe
    [string]$ClientName,
    [string]$ConfigString,
    [string]$Server,
    [string]$Relay,
    [string]$ApiServer,
    [string]$Key,
    [switch]$Bundle,          # télécharge l'installeur RustDesk (GitHub) au moment du build et l'embarque
    [string]$Version,         # avec -Bundle : version précise (ex. 1.4.9), sinon la dernière
    [string]$InstallerFile,   # ou : installeur local déjà téléchargé (rustdesk-X.Y.Z-x86_64.exe)
    [string]$TechnicianPublicKey,   # fichier technician.pub.xml (Setup-Technician.ps1) : les mots de passe des clients sont chiffrés avec cette clé
    [string]$InboxUrl,        # réception des fiches sur votre serveur : hôte[:port] ; par défaut <Server>:21120 quand -InboxPin est donné
    [string]$InboxPin,        # empreinte SHA-256 (64 hex) du certificat TLS du serveur (affichée par install-inbox.sh) : l'exe n'envoie qu'à ce certificat
    [string]$TermsFile,       # texte des conditions d'installation (UTF-8, ligne « Version : ... ») : l'exe exige leur acceptation et en garde la preuve
    [switch]$NoAgent,         # n'embarque pas la tâche de maintenance (désinstallation à distance sur ordre signé) : sans elle, la désinstallation se fait à la main
    [switch]$NoElevate        # pour tester la compilation sans droits admin
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot est vide dans les valeurs par défaut des paramètres avec "powershell -File" (Windows PowerShell 5.1) : on le calcule ici
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Script) { $Script = Join-Path $scriptDir 'Deploy-RustDesk.ps1' }
if (-not $Output) { $Output = Join-Path $scriptDir 'dist\RustDesk-Deploy.exe' }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw "Compilateur introuvable : $csc (.NET Framework 4 requis)." }
if (-not (Test-Path $Script)) { throw "Script introuvable : $Script" }
if ($Server -and $ConfigString) { throw 'Utilisez -ConfigString OU -Server/-Key, pas les deux.' }
if ($Bundle -and $InstallerFile) { throw 'Utilisez -Bundle (téléchargement) OU -InstallerFile (fichier local), pas les deux.' }
if ($Version -and -not $Bundle) { throw '-Version s''utilise avec -Bundle.' }
if ($InstallerFile -and -not (Test-Path $InstallerFile)) { throw "Installeur introuvable : $InstallerFile" }
if ($TermsFile -and -not (Test-Path -LiteralPath $TermsFile)) { throw "Texte des conditions introuvable : $TermsFile" }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-RustDeskInstaller([string]$Version, [string]$DestDir) {
    $api = if ($Version) { "https://api.github.com/repos/rustdesk/rustdesk/releases/tags/$Version" }
           else          { 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' }
    Write-Host "[*] Recherche de l'installeur ($(if ($Version) { $Version } else { 'dernière version' }))" -ForegroundColor Cyan
    $rel   = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'Build-Installer' }
    $asset = $rel.assets | Where-Object { $_.name -match '^rustdesk-[\d.]+-x86_64\.exe$' } | Select-Object -First 1
    if (-not $asset) { throw "Aucun installeur Windows x86_64 trouvé dans la release $($rel.tag_name)." }

    $dest = Join-Path $DestDir $asset.name
    Write-Host "[*] Téléchargement de $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) Mo)" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing

    if ($asset.PSObject.Properties['digest'] -and $asset.digest -match '^sha256:(?<h>[0-9a-f]{64})$') {
        if ((Get-FileHash $dest -Algorithm SHA256).Hash.ToLower() -ne $Matches.h) { throw 'SHA256 incorrect : téléchargement corrompu ou altéré.' }
        Write-Host '[+] SHA256 conforme à celui publié par GitHub' -ForegroundColor Green
    }
    $dest
}

$src = Join-Path $scriptDir 'installer-src'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("rd-build-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
New-Item -ItemType Directory -Path (Split-Path $Output) -Force | Out-Null

try {
    # Paramètres figés : un argument par ligne
    $defaults = New-Object System.Collections.Generic.List[string]
    $techKeyXml = $null
    if ($TechnicianPublicKey) {
        if (-not (Test-Path $TechnicianPublicKey)) { throw "Clé publique introuvable : $TechnicianPublicKey (lancez Setup-Technician.ps1)" }
        $techKeyXml = (Get-Content $TechnicianPublicKey -Raw -Encoding UTF8).Trim()
        if ($techKeyXml -notmatch '^<RSAKeyValue><Modulus>[A-Za-z0-9+/=]+</Modulus><Exponent>[A-Za-z0-9+/=]+</Exponent></RSAKeyValue>$') {
            throw 'Ce fichier ne contient pas une CLÉ PUBLIQUE RSA valide (jamais la clé privée !).'
        }
    }
    if ($InboxPin) {
        if ($InboxPin -notmatch '^[0-9a-fA-F]{64}$') { throw '-InboxPin doit être une empreinte SHA-256 de 64 caractères hexadécimaux.' }
        if (-not $techKeyXml) { throw '-InboxPin nécessite -TechnicianPublicKey : la fiche envoyée au serveur est chiffrée avec cette clé.' }
        if (-not $InboxUrl) { if ($Server) { $InboxUrl = "${Server}:21120" } else { throw '-InboxPin nécessite -InboxUrl (ou -Server).' } }
        if ($InboxUrl -notmatch '^[A-Za-z0-9.\-]+(:\d{1,5})?$') { throw '-InboxUrl doit être de la forme hôte ou hôte:port.' }
        $InboxPin = $InboxPin.ToLower()
    }
    elseif ($InboxUrl) { throw '-InboxUrl nécessite -InboxPin.' }
    foreach ($pair in @(
        @('-ClientName', $ClientName), @('-ConfigString', $ConfigString), @('-Server', $Server),
        @('-Relay', $Relay), @('-ApiServer', $ApiServer), @('-Key', $Key), @('-TechPublicKey', $techKeyXml),
        @('-InboxUrl', $InboxUrl), @('-InboxPin', $InboxPin))) {
        if ($pair[1]) { $defaults.Add($pair[0]); $defaults.Add($pair[1]) }
    }
    $defaultsFile = Join-Path $tmp 'defaults.txt'
    [IO.File]::WriteAllText($defaultsFile, ($defaults -join "`n"), (New-Object Text.UTF8Encoding $false))

    $manifest = Join-Path $src 'app.manifest'
    if ($NoElevate) {
        $manifest = Join-Path $tmp 'app.manifest'
        (Get-Content (Join-Path $src 'app.manifest') -Raw).Replace('requireAdministrator', 'asInvoker') |
            Set-Content $manifest -Encoding UTF8
    }

    # csc lit Program.cs en UTF-8 uniquement avec BOM : on le garantit pour les accents
    $program = Join-Path $tmp 'Program.cs'
    [IO.File]::WriteAllText($program, [IO.File]::ReadAllText((Join-Path $src 'Program.cs')), (New-Object Text.UTF8Encoding $true))

    # Installeur RustDesk à embarquer (facultatif) : on refuse tout fichier dont la signature n'est pas valide
    if ($Bundle) { $InstallerFile = Get-RustDeskInstaller -Version $Version -DestDir $tmp }
    if ($InstallerFile) {
        $sig = Get-AuthenticodeSignature $InstallerFile
        if ($sig.Status -ne 'Valid') { throw "Signature de l'installeur invalide ($($sig.Status)) : $InstallerFile" }
        $bundledName = Split-Path $InstallerFile -Leaf
        $bundledVer  = (Get-Item $InstallerFile).VersionInfo.FileVersion
        $bundledSigner = $sig.SignerCertificate.Subject
    }

    $cscArgs = @(
        '/nologo', '/target:exe', '/optimize+', '/codepage:65001',
        "/out:$Output", "/win32manifest:$manifest",
        "/resource:$Script,Deploy-RustDesk.ps1",
        "/resource:$defaultsFile,defaults.txt"
    )
    if ($InstallerFile) { $cscArgs += "/resource:$InstallerFile,rustdesk-setup.exe" }
    if ($TermsFile) {
        $termsText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $TermsFile).Path, [Text.Encoding]::UTF8) -replace "`r`n", "`n"
        if (-not $termsText.Trim()) { throw 'Le texte des conditions est vide.' }
        if ($termsText -match '\[(NOM|ADRESSE|E-MAIL|TÉLÉPHONE|TELEPHONE|DURÉE|DUREE|DÉLAI|DELAI|À ADAPTER|A ADAPTER|NAME|ADDRESS|EMAIL|PHONE|RETENTION|DELAY|TO ADAPT)[^\]]*\]') { throw 'Le texte des conditions contient encore des champs à remplir entre crochets ([NOM...], [ADRESSE...]) : complétez-le avant de construire l''exe.' }
        $termsSha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($termsText))) -replace '-', '').ToLower()
        $termsVer = if ($termsText -match '(?im)^\s*version\s*:\s*(?<v>[^\n]{1,40})$') { $Matches['v'].Trim() } else { '(sans version)' }
        $cscArgs += "/resource:$((Resolve-Path -LiteralPath $TermsFile).Path),terms.txt"
    }

    # Tâche de maintenance : embarquée dès que l'exe sait où lire les ordres (serveur + empreinte) et comment les vérifier (clé publique). Elle exige un
    # texte de conditions qui la décrit (« tâche de maintenance ») : on ne place jamais sur un poste un composant que le client n'a pas pu lire.
    if (-not $NoAgent -and $InboxPin -and $techKeyXml) {
        $agentFile = Join-Path $scriptDir 'Pg20-Agent.ps1'
        if (-not (Test-Path -LiteralPath $agentFile)) { throw "Pg20-Agent.ps1 introuvable à côté de ce script : $agentFile (ou utilisez -NoAgent)" }
        if (-not ([IO.File]::ReadAllText($agentFile, [Text.Encoding]::UTF8)).Contains('# __UNINSTALL_FUNCTION__')) { throw 'Pg20-Agent.ps1 : marqueur « # __UNINSTALL_FUNCTION__ » introuvable.' }
        if (-not $TermsFile) { throw 'La tâche de maintenance exige un texte de conditions qui la décrit : ajoutez -TermsFile (ou -NoAgent pour un exe sans elle).' }
        if ($termsText -notmatch '(?i)(t[âa]che de maintenance|maintenance task)') { throw 'Le texte des conditions ne décrit pas la « tâche de maintenance » (point 2) : complétez-le (version « c » du texte) ou utilisez -NoAgent.' }
        $cscArgs += "/resource:$agentFile,Pg20-Agent.ps1"
        $agentEmbedded = $true
    }
    $cscArgs += $program
    $cscOut = & $csc @cscArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Échec de la compilation (code $LASTEXITCODE).`n$cscOut" }
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$f = Get-Item $Output
$size = if ($f.Length -ge 1MB) { "$([math]::Round($f.Length / 1MB, 1)) Mo" } else { "$([math]::Round($f.Length / 1KB)) Ko" }
Write-Host "[+] $($f.FullName) ($size)" -ForegroundColor Green
if ($bundledName) { Write-Host "    Installeur embarqué : $bundledName (version $bundledVer, signé : $bundledSigner) -> aucun téléchargement chez le client" }
else              { Write-Host '    Pas d''installeur embarqué : l''exe téléchargera RustDesk depuis GitHub chez le client.' }
if ($defaults.Count) { Write-Host "    Paramètres figés : $(($defaults | Where-Object { $_ -like '-*' }) -join ' ')" }
if ($termsSha) { Write-Host "    Conditions d'installation : version $termsVer, empreinte SHA-256 $termsSha -> l'exe exigera leur acceptation (gardez ce texte : il sert à retrouver ce qui a été accepté)" }
else { Write-Host '    AUCUN texte de conditions (-TermsFile) : l''exe s''installera sans demander d''acceptation.' -ForegroundColor Yellow }
if ($agentEmbedded) { Write-Host '    Tâche de maintenance : intégrée (désinstallation à distance, uniquement sur ordre signé du technicien ; le poste doit avoir accepté les conditions qui la décrivent)' }
else { Write-Host '    Pas de tâche de maintenance : ces postes se désinstalleront à la main (bouton « Désinstaller… » : commande guidée).' }
Write-Host '    Non signé : SmartScreen affichera "éditeur inconnu" tant que l''exe n''est pas signé avec un certificat de signature de code.'
