<#
.SYNOPSIS
    Prépare votre PC de technicien : clé de chiffrement des mots de passe + accès à la liste des postes du serveur.

.DESCRIPTION
    - Crée une paire de clés RSA. La clé PRIVÉE reste sur ce PC (protégée par votre compte Windows, DPAPI).
      La clé PUBLIQUE (technician.pub.xml) est intégrée aux exes : elle chiffre les mots de passe des clients.
    - Mémorise l'adresse et le jeton de la liste des postes (service de la VM pg20-info), protégé par DPAPI.

.EXAMPLE
    .\Pg20-Technicien-Configurer.ps1                          # crée la clé si elle n'existe pas
.EXAMPLE
    .\Pg20-Technicien-Configurer.ps1 -ExportBackup            # affiche la clé privée : à ranger dans votre gestionnaire de mots de passe
.EXAMPLE
    .\Pg20-Technicien-Configurer.ps1 -ExportBackup -Clipboard # la clé privée va DIRECTEMENT dans le presse-papiers (rien ne s'affiche, rien n'est tapé) : à coller dans votre gestionnaire
.EXAMPLE
    .\Pg20-Technicien-Configurer.ps1 -VerifyBackup            # vérifie que la sauvegarde collée est complète et correspond bien à votre clé
.EXAMPLE
    .\Pg20-Technicien-Configurer.ps1 -VerifyBackup -Clipboard # idem, en lisant la sauvegarde que vous venez de copier depuis votre gestionnaire
.EXAMPLE
    .\Pg20-Technicien-Configurer.ps1 -RestoreFromBackup       # recrée la clé privée depuis votre sauvegarde (nouveau PC, Windows réinstallé)
.EXAMPLE
    .\Pg20-Technicien-Configurer.ps1 -FeedUrl http://<IP_VM>:8099 -FeedToken (Read-Host -AsSecureString "Jeton")
.EXAMPLE
    .\Pg20-Technicien-Configurer.ps1 -ShowFeedToken           # affiche le jeton (à copier dans les secrets de Home Assistant)
#>
[CmdletBinding()]
param(
    [string]$FeedUrl,
    [securestring]$FeedToken,
    [string]$PublicKeyOut,                  # par défaut : technician.pub.xml à côté du script
    [switch]$ExportBackup,
    [switch]$Clipboard,                     # avec -ExportBackup : copie la clé dans le presse-papiers au lieu de l'afficher ; avec -VerifyBackup : lit la sauvegarde dans le presse-papiers
    [switch]$VerifyBackup,
    [switch]$RestoreFromBackup,
    [switch]$ShowFeedToken
)
$ErrorActionPreference = 'Stop'
# $PSScriptRoot est vide dans les valeurs par défaut des paramètres avec "powershell -File" (Windows PowerShell 5.1) : on le calcule ici
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $PublicKeyOut) { $PublicKeyOut = Join-Path $scriptDir 'technician.pub.xml' }
. (Join-Path $scriptDir 'Pg20-Commun.ps1')
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
    if ($Clipboard) {
        # La clé privée ne s'affiche pas (elle resterait dans l'historique du terminal, des captures d'écran...) : elle est copiée, vous la collez dans une note sécurisée
        # de votre gestionnaire de mots de passe, puis le presse-papiers est vidé (seulement s'il contient encore la clé).
        Set-Clipboard -Value $xml
        Write-Host ''
        Write-Host '[+] La clé privée est dans le presse-papiers (elle ne s''affiche pas).' -ForegroundColor Green
        Write-Host '    Collez-la MAINTENANT (Ctrl+V) dans une note sécurisée de votre gestionnaire de mots de passe, puis revenez ici.' -ForegroundColor Yellow
        [void](Read-Host '    Appuyez sur Entrée quand c''est enregistré : le presse-papiers sera alors vidé')
        try { if ((Get-Clipboard -Raw).Trim() -eq $xml) { Set-Clipboard -Value ' '; Write-Host '[+] Presse-papiers vidé.' -ForegroundColor Green } } catch { }
        Write-Host ''
        Write-Host 'Sans cette sauvegarde, si ce PC ou Windows est perdu, les mots de passe chiffrés de vos clients seront IRRÉCUPÉRABLES.' -ForegroundColor Yellow
        Write-Host 'Vérifiez-la maintenant :  .\Pg20-Technicien-Configurer.ps1 -VerifyBackup -Clipboard   (après avoir recopié la note depuis votre gestionnaire)' -ForegroundColor Yellow
        return
    }
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
    if ($Clipboard) {
        # Le presse-papiers ne contient pas encore la clé (on vient de taper la commande, qui a occupé le presse-papiers) : on attend que la personne la copie
        if (-not (([string](Get-Clipboard -Raw)) -match '<RSAKeyValue>') -and (-not [Console]::IsInputRedirected -or $env:PG20_TEST_PROMPT)) {
            Write-Host ''
            Write-Host 'Copiez maintenant la sauvegarde de la clé : ouvrez le fichier (ou la note de votre gestionnaire), sélectionnez TOUT le texte, puis Ctrl+C.' -ForegroundColor Yellow
            [void](Read-Host 'Appuyez sur Entrée quand c''est copié')
        }
        $pasted = ([string](Get-Clipboard -Raw)).Trim()
    }
    else { $pasted = (Read-Host 'Collez la sauvegarde de la clé privée (une seule ligne)').Trim() }
    $pasted = ($pasted -replace '[\uFEFF\u200B]', '').Trim()            # un copier-coller depuis un fichier texte peut apporter un caractère invisible (BOM) au début
    $ok = $false; $why = ''
    # Un fichier texte peut contenir un titre, des retours à la ligne... : on isole la clé elle-même
    $m = [regex]::Match($pasted, '(?s)<RSAKeyValue>.*?</RSAKeyValue>')
    $a = New-Object System.Security.Cryptography.RSACryptoServiceProvider; $a.PersistKeyInCsp = $false
    $b = New-Object System.Security.Cryptography.RSACryptoServiceProvider; $b.PersistKeyInCsp = $false
    try {
        if (-not $pasted) { $why = 'le presse-papiers est vide (il est vidé après chaque vérification : recopiez le contenu du fichier, puis relancez)' }
        elseif (-not $m.Success) { $why = ('le texte copié ne contient pas de clé (il doit contenir <RSAKeyValue> ... </RSAKeyValue>) ; longueur copiée : {0} caractères' -f $pasted.Length) }
        else {
            $pasted = $m.Value
            if ($pasted -notmatch '<D>') { $why = 'cette clé ne contient que la partie PUBLIQUE : ce n''est pas la sauvegarde de la clé privée' }
            else { try { $a.FromXmlString($pasted) } catch { $why = 'clé illisible ou tronquée : recopiez TOUT le texte, sans rien ajouter ni retirer' } }
            if (-not $why) {
                $b.FromXmlString($current)
                $enc = $b.Encrypt([Text.Encoding]::UTF8.GetBytes('verification-pg20'), $true)
                try { $ok = ([Text.Encoding]::UTF8.GetString($a.Decrypt($enc, $true)) -eq 'verification-pg20') } catch { $ok = $false }
                if (-not $ok) { $why = 'c''est une clé privée valide, mais ce n''est PAS celle de ce PC : elle ne déchiffre pas ce que la clé publique de ce PC a chiffré (autre clé, ou ancienne clé)' }
            }
        }
    }
    catch { $ok = $false; if (-not $why) { $why = 'clé illisible : ' + $_.Exception.Message } }
    finally { $a.Dispose(); $b.Dispose() }
    if ($Clipboard) { try { if (([string](Get-Clipboard -Raw)).Trim() -ne '') { Set-Clipboard -Value ' ' } } catch { } }       # la sauvegarde copiée ne reste pas dans le presse-papiers
    if ($ok) { Write-Host '[+] Sauvegarde VALIDE : elle déchiffre bien les mots de passe de vos clients.' -ForegroundColor Green }
    else {
        Write-Host ('[x] Sauvegarde INVALIDE : ' + $why + '.') -ForegroundColor Red
        if ($Clipboard) { Write-Host '    (le presse-papiers a été vidé : recopiez le texte avant de relancer)' -ForegroundColor DarkGray }
        exit 1
    }
    return
}

if ($RestoreFromBackup) {
    $xml = ((Read-Host 'Collez la clé privée sauvegardée (une ligne commençant par <RSAKeyValue>)') -replace '[\uFEFF\u200B]', '').Trim()
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
Write-Host 'IMPORTANT : sauvegardez la clé privée  ->  .\Pg20-Technicien-Configurer.ps1 -ExportBackup' -ForegroundColor Yellow
