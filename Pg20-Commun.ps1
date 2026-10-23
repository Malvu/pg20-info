# Fonctions communes aux outils du technicien Info Pg20.
# Chargé par Pg20-Technicien-Configurer.ps1 et Pg20-Clients-Carnet.ps1 :  . "$PSScriptRoot\Pg20-Commun.ps1"
# Les secrets (clé privée, jeton, mots de passe) sont protégés par DPAPI : lisibles uniquement par votre compte Windows, sur ce PC.

function Get-Pg20Dir {
    $d = Join-Path $env:APPDATA 'Pg20-Info'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    $d
}

function Protect-Dpapi([string]$Plain) {
    (ConvertTo-SecureString $Plain -AsPlainText -Force) | ConvertFrom-SecureString
}

function Unprotect-Dpapi([string]$Protected) {
    if (-not $Protected) { return '' }
    $sec  = ConvertTo-SecureString $Protected
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Message d'erreur précis quand la clé privée est introuvable : la clé est liée au COMPTE Windows et à son dossier AppData
function Get-MissingKeyMessage {
    $p = Join-Path (Get-Pg20Dir) 'technician.key'
    $elev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    "Clé privée introuvable.`n  Compte  : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)$(if ($elev) { '  (fenêtre ouverte EN ADMINISTRATEUR)' })`n  Cherchée dans : $p`n" +
    "  La clé est liée au compte Windows qui a lancé Pg20-Technicien-Configurer.ps1 : ouvrez PowerShell avec CE compte, sans « Exécuter en tant qu'administrateur » (Win+R, tapez powershell, Entrée),`n" +
    "  ou, si la clé a été perdue, restaurez-la : .\Pg20-Technicien-Configurer.ps1 -RestoreFromBackup"
}

function Get-TechPrivateKeyXml {
    $p = Join-Path (Get-Pg20Dir) 'technician.key'
    if (Test-Path $p) { Unprotect-Dpapi ((Get-Content $p -Raw).Trim()) }
}

# Déchiffre un mot de passe chiffré par l'exe d'installation (RSA-OAEP, clé publique de ce technicien)
function Unprotect-FromTech([string]$Base64) {
    $xml = Get-TechPrivateKeyXml
    if (-not $xml) { throw (Get-MissingKeyMessage) }
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false
    try {
        $rsa.FromXmlString($xml)
        [Text.Encoding]::UTF8.GetString($rsa.Decrypt([Convert]::FromBase64String($Base64), $true))
    }
    finally { $rsa.Dispose() }
}

# Ouvre une fiche reçue du serveur (voir New-Envelope dans Pg20-Client-Installation.ps1) : RSA-OAEP | IV (16) | AES-256-CBC | HMAC-SHA256 (32).
# Le HMAC est vérifié AVANT tout déchiffrement : une fiche fabriquée ou altérée est refusée (exception « fiche invalide »).
function Unprotect-Envelope([string]$Base64) {
    $xml = Get-TechPrivateKeyXml
    if (-not $xml) { throw (Get-MissingKeyMessage) }
    $all = [Convert]::FromBase64String($Base64)
    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false
    try {
        $rsa.FromXmlString($xml)
        $n = $rsa.KeySize / 8
        if ($all.Length -lt ($n + 16 + 16 + 32)) { throw 'fiche invalide (trop courte)' }
        $wrapped = New-Object byte[] $n;  [Array]::Copy($all, 0, $wrapped, 0, $n)
        try { $keys = $rsa.Decrypt($wrapped, $true) } catch { throw 'fiche invalide (clé non déchiffrable)' }
    }
    finally { $rsa.Dispose() }
    if ($keys.Length -ne 64) { throw 'fiche invalide (clés)' }
    $encKey = New-Object byte[] 32; $macKey = New-Object byte[] 32
    [Array]::Copy($keys, 0, $encKey, 0, 32); [Array]::Copy($keys, 32, $macKey, 0, 32)

    $iv  = New-Object byte[] 16;  [Array]::Copy($all, $n, $iv, 0, 16)
    $ctLen = $all.Length - $n - 16 - 32
    $ct  = New-Object byte[] $ctLen; [Array]::Copy($all, $n + 16, $ct, 0, $ctLen)
    $tag = New-Object byte[] 32;  [Array]::Copy($all, $all.Length - 32, $tag, 0, 32)

    $ms = New-Object IO.MemoryStream
    $ms.Write($iv, 0, 16); $ms.Write($ct, 0, $ct.Length); $ms.Write([Text.Encoding]::ASCII.GetBytes('pg20v1'), 0, 6)
    $hmac = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (, $macKey)
    $calc = $hmac.ComputeHash($ms.ToArray()); $hmac.Dispose()
    $diff = 0; for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($calc[$i] -bxor $tag[$i]) }
    if ($diff -ne 0) { throw 'fiche invalide (signature incorrecte)' }

    $aes = [Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.Mode = [Security.Cryptography.CipherMode]::CBC; $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $encKey; $aes.IV = $iv
    try { $plain = $aes.CreateDecryptor().TransformFinalBlock($ct, 0, $ct.Length) } catch { throw 'fiche invalide (contenu)' } finally { $aes.Dispose() }
    [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
}

# ---------------------------------------------------------------- Ordres de désinstallation signés
# Un ordre dit « désinstalle RustDesk du poste <ID> » ; il est signé (RSA-SHA256) avec la clé privée du technicien, que seul ce PC possède. Les postes
# équipés de la tâche de maintenance (Pg20-Client-Maintenance.ps1) ne l'exécutent qu'après avoir vérifié la signature avec la clé publique reçue à l'installation :
# le serveur qui transporte l'ordre ne peut donc ni en fabriquer un, ni en modifier un. Le préfixe « pg20-order-v1| » du texte signé sépare cet usage
# de la clé de tout autre. Ce texte doit rester identique, caractère pour caractère, à Get-OrderMessage dans Pg20-Client-Maintenance.ps1.
function Get-OrderMessage($Order) {
    'pg20-order-v1|{0}|{1}|{2}|{3}|{4}' -f $Order.id, $Order.action, $Order.nonce, $Order.iat, $Order.exp
}

function New-UninstallOrder([string]$Id, [string]$PrivateKeyXml, [int]$ValidDays = 30, $Now = $null) {
    if ($Id -notmatch '^[0-9]{6,12}$') { throw 'ID de client invalide.' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $utc = $(if ($Now) { ([datetime]$Now).ToUniversalTime() } else { [datetime]::UtcNow })
    $nonceBytes = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($nonceBytes); $rng.Dispose()
    $order = [ordered]@{
        v = 1; action = 'uninstall'; id = $Id
        nonce = ([BitConverter]::ToString($nonceBytes) -replace '-', '').ToLower()
        iat = $utc.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
        exp = $utc.AddDays($ValidDays).ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
    }
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.PersistKeyInCsp = $false
    try {
        $rsa.FromXmlString($PrivateKeyXml)
        $sig = [Convert]::ToBase64String($rsa.SignData([Text.Encoding]::UTF8.GetBytes((Get-OrderMessage ([pscustomobject]$order))), 'SHA256'))
    }
    finally { $rsa.Dispose() }
    [pscustomobject]@{ order = $order; sig = $sig }
}

# ---------------------------------------------------------------- Chiffrement du flux local (correctif du 2026-10-10, point 2 de l'audit)
# Le flux (peers-feed.py) peut désormais chiffrer ses échanges. PowerShell 5.1 ne connaît PAS -SkipCertificateCheck : pour
# accepter un certificat auto-signé SANS accepter n'importe quoi, on compare l'EMPREINTE SHA-256 du certificat présenté à
# celle qui est figée ici. La vérification ne concerne QUE l'hôte du flux : tout autre certificat est validé normalement.
#   - si feed.json contient "https://..." sans empreinte connue, on REFUSE la connexion et on explique quoi faire (jamais
#     d'acceptation silencieuse : ce serait pire que le HTTP clair, puisqu'on croirait être protégé) ;
#   - si l'adresse reste en http://, rien ne change.
#
# IMPORTANT (défaut constaté au banc d'essai du 2026-10-10) : un BLOC DE SCRIPT PowerShell ne peut PAS servir de rappel de
# validation de certificat. .NET invoque ce rappel depuis un thread réseau, qui n'a AUCUNE instance PowerShell : le bloc
# échoue (« Il n'y a pas d'instance d'exécution disponible pour exécuter des scripts sur ce thread ») et TOUTE connexion
# HTTPS est alors refusée, même avec la bonne empreinte. On compile donc un petit type C# : du code .NET ordinaire, qui
# s'exécute sans difficulté sur ce thread.
if (-not ('Pg20Tls' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

public static class Pg20Tls
{
    // Hôte du flux et empreinte SHA-256 attendue (hexadécimal minuscule). Vide = aucune vérification figée.
    public static string Hote = "";
    public static string Empreinte = "";

    public static bool Valider(object expediteur, X509Certificate certificat, X509Chain chaine, SslPolicyErrors erreurs)
    {
        try
        {
            if (certificat == null) { return false; }
            // ATTENTION — défaut constaté au banc d'essai du 2026-10-10 : .NET passe ici un HttpWebRequest (ni un Uri, ni
            // une chaîne). Ne pas traiter ce cas faisait échouer la comparaison d'hôte : on retombait alors sur la
            // validation de chaîne, qui refuse un certificat auto-signé, et TOUTE connexion HTTPS était refusée.
            string hote = "";
            HttpWebRequest requete = expediteur as HttpWebRequest;
            if (requete != null && requete.RequestUri != null) { hote = requete.RequestUri.Host; }
            else if (expediteur is Uri) { hote = ((Uri)expediteur).Host; }
            else if (expediteur is string)
            {
                string brut = (string)expediteur;
                Uri u;
                if (Uri.TryCreate(brut, UriKind.Absolute, out u)) { hote = u.Host; }
                else { hote = brut; }
            }
            int deuxPoints = hote.IndexOf(':');
            if (deuxPoints > 0) { hote = hote.Substring(0, deuxPoints); }   // « hote:port » éventuel
            if (hote.Length > 0 && Hote.Length > 0 && string.Equals(hote, Hote, StringComparison.OrdinalIgnoreCase))
            {
                if (Empreinte == null || Empreinte.Length == 0) { return false; }   // HTTPS sans empreinte connue : refus
                using (SHA256 sha = SHA256.Create())
                {
                    byte[] h = sha.ComputeHash(certificat.GetRawCertData());
                    return BitConverter.ToString(h).Replace("-", "").ToLowerInvariant() == Empreinte;
                }
            }
        }
        catch { return false; }
        return erreurs == SslPolicyErrors.None;    // autre hôte : validation normale
    }
}
'@ -ErrorAction Stop
}

$script:FeedTlsPrepare = $false

function Set-FeedTls([string]$Url, [string]$Pin) {
    $hote = ''
    try { $hote = ([Uri]$Url).Host } catch { $hote = '' }
    if (-not $hote) { return }
    [Pg20Tls]::Hote = $hote
    [Pg20Tls]::Empreinte = ($Pin -replace '[^0-9a-fA-F]', '').ToLower()
    if ($script:FeedTlsPrepare) { return }
    $script:FeedTlsPrepare = $true
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    # La décision est confiée à du code .NET (voir le commentaire ci-dessus) : il s'exécute sans PowerShell.
    # NB : PowerShell présente « [Pg20Tls]::Valider » comme un PSMethod, non convertible en délégué. On construit donc le
    # délégué explicitement, à partir de la méthode .NET sous-jacente (piège constaté au banc d'essai du 2026-10-10).
    $methode = [Pg20Tls].GetMethod('Valider', [Reflection.BindingFlags]'Public,Static')
    $delegue = [Delegate]::CreateDelegate([Net.Security.RemoteCertificateValidationCallback], $methode)
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $delegue
}

# Renseigne le chiffrement à partir de l'adresse du flux, et refuse clairement un HTTPS sans empreinte.
function Confirm-FeedTls($Cfg) {
    if (-not $Cfg -or -not $Cfg.url) { return }
    $pin = [string]$env:PG20_TLS_PIN
    if (-not $pin -and $Cfg.PSObject.Properties['tlsPin']) { $pin = [string]$Cfg.tlsPin }
    Set-FeedTls ([string]$Cfg.url) $pin
    if (([string]$Cfg.url) -match '^https://' -and -not [Pg20Tls]::Empreinte) {
        Write-Warning ("Le flux est configuré en HTTPS mais son empreinte de certificat est inconnue : la connexion sera refusée. " +
                       "Obtenez l'empreinte avec « openssl x509 -in /etc/pg20/inbox.crt -outform DER | sha256sum » sur la VM, " +
                       "puis ajoutez-la dans " + (Join-Path (Get-Pg20Dir) 'feed.json') + ' sous la forme { "url": "...", "tlsPin": "<empreinte>" }' +
                       ", ou passez-la par la variable d'environnement PG20_TLS_PIN.")
    }
}

function Get-FeedConfig {
    $p = Join-Path (Get-Pg20Dir) 'feed.json'
    if (Test-Path $p) {
        $cfg = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        Confirm-FeedTls $cfg            # prépare le chiffrement (sans effet si l'adresse reste en http://)
        $cfg
    }
}

# Même présentation que RustDesk : chiffres groupés par trois en partant de la DROITE (12345678 -> 12 345 678)
function Format-RdId([string]$Id) { $Id -replace '\B(?=(\d{3})+(?!\d))', ' ' }
