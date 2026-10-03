<#
.SYNOPSIS
    Prépare votre PC de technicien : clé de chiffrement des mots de passe + accès à la liste des postes du serveur.

.DESCRIPTION
    - Crée une paire de clés RSA. La clé PRIVÉE reste sur ce PC (protégée par votre compte Windows, DPAPI).
      La clé PUBLIQUE (technician.pub.xml) est intégrée aux exes : elle chiffre les mots de passe des clients.
    - Mémorise l'adresse et le jeton de la liste des postes (service de la VM pg20-info), protégé par DPAPI.

.EXAMPLE
    .\Setup-Technician.ps1                          # crée la clé si elle n'existe pas
.EXAMPLE
    .\Setup-Technician.ps1 -ExportBackup            # affiche la clé privée : à ranger dans votre gestionnaire de mots de passe
.EXAMPLE
    .\Setup-Technician.ps1 -VerifyBackup            # vérifie que la sauvegarde collée est complète et correspond bien à votre clé
.EXAMPLE
    .\Setup-Technician.ps1 -RestoreFromBackup       # recrée la clé privée depuis votre sauvegarde (nouveau PC, Windows réinstallé)
.EXAMPLE
    .\Setup-Technician.ps1 -FeedUrl http://<IP_VM>:8099 -FeedToken (Read-Host -AsSecureString "Jeton")
.EXAMPLE
    .\Setup-Technician.ps1 -ShowFeedToken           # affiche le jeton (à copier dans les secrets de Home Assistant)
#>
[CmdletBinding()]
param(
    [string]$FeedUrl,
    [securestring]$FeedToken,
    [string]$PublicKeyOut,                  # par défaut : technician.pub.xml à côté du script
    [switch]$ExportBackup,
    [switch]$VerifyBackup,
    [switch]$RestoreFromBackup,
    [switch]$ShowFeedToken
)
$ErrorActionPreference = 'Stop'
# $PSScriptRoot est vide dans les valeurs par défaut des paramètres avec "powershell -File" (Windows PowerShell 5.1) : on le calcule ici
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $PublicKeyOut) { $PublicKeyOut = Join-Path $scriptDir 'technician.pub.xml' }
. (Join-Path $scriptDir 'Pg20-Common.ps1')
$dir = Get-Pg20Dir
$keyFile = Join-Path $dir 'technician.key'

function Save-PublicKey([string]$PrivateXml) {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false
    try { $rsa.FromXmlString($PrivateXml); $pub = $rsa.ToXmlString($false) } finally { $rsa.Dispose() }
    [IO.File]::WriteAllText($PublicKeyOut, $pub, (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText((Join-Path $dir 'technician.pub.xml'), $pub, (New-Object Text.UTF8Encoding $false))
}

if ($ShowFeedToken) {
    $cfg = Get-FeedConfig
    if (-not $cfg -or -not $cfg.token) { throw 'Aucun jeton enregistré.' }
    Write-Host (Unprotect-Dpapi $cfg.token)
    return
}

if ($ExportBackup) {
    $xml = Get-TechPrivateKeyXml
    if (-not $xml) { throw (Get-MissingKeyMessage) }
    Write-Host ''
    Write-Host 'COPIEZ le texte ci-dessous (une seule ligne) dans une note sécurisée de votre gestionnaire de mots de passe :' -ForegroundColor Yellow
    Write-Host ''
    Write-Host $xml
    Write-Host ''
    Write-Host 'Sans cette sauvegarde, si ce PC ou Windows est perdu, les mots de passe chiffrés de vos clients seront IRRÉCUPÉRABLES.' -ForegroundColor Yellow
    return
}

if ($VerifyBackup) {
    # Contrôle fonctionnel : on chiffre avec la clé publique de ce PC, puis on déchiffre avec la sauvegarde collée.
    $current = Get-TechPrivateKeyXml
    if (-not $current) { throw (Get-MissingKeyMessage) }
    $pasted = (Read-Host 'Collez la sauvegarde de la clé privée (une seule ligne)').Trim()
    $ok = $false
    $a = New-Object System.Security.Cryptography.RSACryptoServiceProvider; $a.PersistKeyInCsp = $false
    $b = New-Object System.Security.Cryptography.RSACryptoServiceProvider; $b.PersistKeyInCsp = $false
    try {
        $b.FromXmlString($current)
        $enc = $b.Encrypt([Text.Encoding]::UTF8.GetBytes('verification-pg20'), $true)
        $a.FromXmlString($pasted)
        $ok = ([Text.Encoding]::UTF8.GetString($a.Decrypt($enc, $true)) -eq 'verification-pg20')
    }
    catch { $ok = $false }
    finally { $a.Dispose(); $b.Dispose() }
    if ($ok) { Write-Host '[+] Sauvegarde VALIDE : elle déchiffre bien les mots de passe de vos clients.' -ForegroundColor Green }
    else { Write-Host '[x] Sauvegarde INVALIDE, incomplète ou d''une autre clé : refaites -ExportBackup et recopiez TOUTE la ligne.' -ForegroundColor Red; exit 1 }
    return
}

if ($RestoreFromBackup) {
    $xml = (Read-Host 'Collez la clé privée sauvegardée (une ligne commençant par <RSAKeyValue>)').Trim()
    if ($xml -notmatch '^<RSAKeyValue>.*<D>.*</RSAKeyValue>$') { throw 'Ce texte ne ressemble pas à une clé privée RSA.' }
    Save-PublicKey $xml
    Protect-Dpapi $xml | Set-Content $keyFile -Encoding ASCII
    Write-Host '[+] Clé privée restaurée.' -ForegroundColor Green
    return
}

if (Test-Path $keyFile) {
    Write-Host "[=] Clé de chiffrement déjà présente : $keyFile" -ForegroundColor Cyan
    if (-not (Test-Path $PublicKeyOut)) { Save-PublicKey (Get-TechPrivateKeyXml) }
}
else {
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 2048
    $rsa.PersistKeyInCsp = $false
    try { $priv = $rsa.ToXmlString($true) } finally { $rsa.Dispose() }
    Save-PublicKey $priv
    Protect-Dpapi $priv | Set-Content $keyFile -Encoding ASCII
    Write-Host '[+] Clé de chiffrement créée (la partie privée reste sur ce PC).' -ForegroundColor Green
}
Write-Host "    Clé publique pour les exes : $PublicKeyOut"

if ($FeedUrl -or $FeedToken) {
    if (-not ($FeedUrl -and $FeedToken)) { throw 'Indiquez -FeedUrl ET -FeedToken.' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($FeedToken)
    try { $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    [pscustomobject]@{ url = $FeedUrl.TrimEnd('/'); token = (Protect-Dpapi $plainToken) } |
        ConvertTo-Json | Set-Content (Join-Path $dir 'feed.json') -Encoding UTF8
    Write-Host "[+] Accès à la liste des postes enregistré : $($FeedUrl.TrimEnd('/'))" -ForegroundColor Green
}

Write-Host ''
Write-Host 'IMPORTANT : sauvegardez la clé privée  ->  .\Setup-Technician.ps1 -ExportBackup' -ForegroundColor Yellow
