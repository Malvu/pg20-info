<#
.SYNOPSIS
    Pg20 Info : vos clients en un clic. Import automatique depuis la clé USB, validation des nouveaux postes, connexion RustDesk.

.DESCRIPTION
    - Importe seul les fiches des clients (nom, ID, mot de passe) depuis la clé USB branchée : plus rien à retaper.
    - Interroge votre serveur : tout poste qui s'enregistre et que vous n'avez pas installé vous-même est signalé "A VALIDER".
    - Ouvre la session RustDesk d'un client d'un seul geste (lien rustdesk:// avec l'ID et le mot de passe).
    Les mots de passe sont protégés par DPAPI : lisibles uniquement par votre compte Windows sur ce PC.

.EXAMPLE
    .\Pg20-Clients.ps1                       # menu interactif
.EXAMPLE
    .\Pg20-Clients.ps1 -Connect "Dupont"     # ouvre directement la session du client
.EXAMPLE
    .\Pg20-Clients.ps1 -Watch                # surveille le serveur et notifie chaque nouveau poste
#>
[CmdletBinding()]
param(
    [switch]$Import,          # importe les clés USB branchées, puis quitte
    [switch]$Sync,            # interroge le serveur, puis quitte
    [switch]$List,            # affiche la liste, puis quitte
    [string]$Connect,         # numéro, ID ou début du nom du client à ouvrir
    [switch]$DryRun,          # avec -Connect : affiche le lien sans l'ouvrir
    [switch]$Watch,           # surveille le serveur et notifie les nouveaux postes
    [int]$Interval = 20,      # secondes entre deux interrogations avec -Watch
    [switch]$TestBalloon,     # affiche une notification Windows de test, puis quitte (vérifie la surveillance en tâche de fond)
    [switch]$Quick,           # petite fenêtre « Se connecter à un client » (recherche + double-clic), sans navigateur : pour l'icône du bureau
    [int]$AutoPick,           # (tests) avec -Quick : choisit automatiquement le N-ième client et clique sur « Se connecter »
    [switch]$AutoDelete,      # (tests) avec -Quick -AutoPick : SUPPRIME le client choisi (sans confirmation) au lieu de s'y connecter
    [switch]$AutoUninstall,   # (tests) avec -Quick -AutoPick : envoie (ou annule) l'ordre de désinstallation du client choisi, sans boîtes de dialogue
    [string]$ShotPath,        # (tests) avec -Quick : enregistre une image de la fenêtre à cet emplacement
    [string]$TestNote,        # (tests) avec -Quick : texte de la zone de message (vérifier qu'un message long n'est pas coupé)
    [string]$ImportFrom,      # dossier ou fichier CSV à importer (au lieu des clés USB)
    [string]$Forget,          # numéro, ID ou nom d'un client à OUBLIER : son mot de passe est effacé de ce PC
    [switch]$All,             # inclut les postes masqués
    [switch]$Console,         # ancien menu en mode texte au lieu de la page web
    [switch]$NoBrowser,       # (tests) ne pas ouvrir le navigateur
    [string]$Token,           # (tests) jeton de la page web imposé
    [int]$Port                # (tests) port de la page web imposé
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Pg20-Common.ps1')

# ---------------------------------------------------------------- Stockage
function Get-StorePath { Join-Path (Get-Pg20Dir) 'clients.json' }

function Read-Store {
    $p = Get-StorePath
    if (-not (Test-Path $p)) { return @() }
    $raw = Get-Content $p -Raw -Encoding UTF8
    if (-not $raw.Trim()) { return @() }
    # PowerShell 5.1 renvoie le tableau JSON d'un seul bloc : on le déroule pour obtenir un client par élément
    $items = $raw | ConvertFrom-Json
    @($items | ForEach-Object { $_ })
}

function Save-Store { ConvertTo-Json -InputObject @($script:Store) -Depth 4 | Set-Content (Get-StorePath) -Encoding UTF8 }

# Plusieurs instances peuvent tourner en même temps (page web ouverte + surveillance en tâche de fond). Chaque opération recharge donc la
# liste depuis le disque, travaille et l'enregistre sous un verrou commun : aucune instance ne réécrit une liste périmée par-dessus
# l'autre (une fiche déjà effacée du serveur serait perdue). Renvoie ce que produit le bloc.
function Use-Store([scriptblock]$Body) {
    $mutex = New-Object System.Threading.Mutex($false, 'Pg20ClientsStoreLock')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(60000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'la liste des clients est occupée par un autre processus (verrou non obtenu en 60 s)' }
        $script:Store = @(Read-Store)
        & $Body
    }
    finally { if ($held) { try { $mutex.ReleaseMutex() } catch { } }; $mutex.Dispose() }
}

# Surveillance en tâche de fond : sans fenêtre, les messages vont aussi dans %APPDATA%\Pg20-Info\watch.log (jamais de mot de passe)
function Write-Watch([string]$Text, [string]$Color = 'Gray') {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Text
    Write-Host $line -ForegroundColor $Color
    try {
        $log = Join-Path (Get-Pg20Dir) 'watch.log'
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 200KB) { Move-Item $log ($log + '.old') -Force }
        Add-Content -Path $log -Value $line -Encoding UTF8
    } catch { }
}

function New-Client([string]$Id) {
    [pscustomobject]@{ id = $Id; name = '(poste inconnu)'; host = ''; installed = ''; firstSeen = ''; ip = ''; status = 'A valider'; unknown = $true; pwd = '' }
}

function Find-Client([string]$Id) { $script:Store | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }

function Set-Prop($Obj, [string]$Name, $Value) { Add-Member -InputObject $Obj -NotePropertyName $Name -NotePropertyValue $Value -Force }
function Get-Prop($Obj, [string]$Name) { if ($Obj.PSObject.Properties[$Name]) { $Obj.PSObject.Properties[$Name].Value } else { $null } }
function Clear-Props($Obj, [string[]]$Names) { foreach ($n in $Names) { if ($Obj.PSObject.Properties[$n]) { $Obj.PSObject.Properties.Remove($n) } } }

# Valide un poste. Si une fiche reçue du serveur attend d'écraser les données d'un client déjà connu (réinstallation, nouveau mot de passe),
# c'est ici qu'elle est appliquée : jamais avant, pour qu'une fausse fiche ne puisse pas remplacer un mot de passe sans votre accord.
function Confirm-Client($Rec) {
    $inc = Get-Prop $Rec 'incoming'
    if ($inc) {
        $Rec.name = $inc.name; $Rec.host = $inc.host; $Rec.installed = $inc.installed; $Rec.pwd = $inc.pwd
        if ($inc.PSObject.Properties['consent'] -and $inc.consent) { Set-Prop $Rec 'consent' $inc.consent }
        if ($inc.PSObject.Properties['agent']) { Set-Prop $Rec 'agent' ([bool]$inc.agent) }
        Clear-Props $Rec @('incoming')
    }
    Clear-Props $Rec @('code', 'viaServer')
    $Rec.unknown = $false; $Rec.status = 'Valide'
    Set-Prop $Rec 'validatedAt' ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
    Save-ConsentProofAuto $Rec
    Save-Store
}

# « Oublier » : le mot de passe et le nom sont effacés de ce PC. La fiche reste masquée (le serveur connaît toujours cet ID : sans elle,
# le poste réapparaîtrait « A VALIDER » à chaque synchronisation) et un nouvel import de la clé USB ne la ressuscite pas.
function Forget-Client($Rec) {
    $Rec.name = '(client oublié)'; $Rec.host = ''; $Rec.installed = ''; $Rec.pwd = ''; $Rec.unknown = $false; $Rec.status = 'Ignore'
    Add-Member -InputObject $Rec -NotePropertyName forgotten -NotePropertyValue $true -Force
    Save-Store
}

# ---------------------------------------------------------------- Suppression complète d'un client
# « Supprimer » : le client n'a plus jamais existé. Retiré de ce PC (nom, poste, mot de passe), des lignes de la clé USB branchée et du
# serveur (demande déposée sur le flux, exécutée par un service de la VM en moins d'une minute, après copie de la base).
# Seule trace conservée, dans deleted.json : le NUMÉRO d'ID et l'heure de suppression. Elle sert uniquement à ce qu'une ANCIENNE ligne d'une
# autre copie de la clé, ou le serveur pas encore à jour, ne ressuscite pas le client. Une nouvelle installation (fiche, ou ligne de clé plus
# récente) ou un poste qui se réinscrit après la suppression l'efface et le fait réapparaître normalement.
function ConvertTo-Utc([string]$Iso) {
    [datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal))
}
function Get-DeletedPath { Join-Path (Get-Pg20Dir) 'deleted.json' }
function Read-Deleted {
    $p = Get-DeletedPath
    if (-not (Test-Path $p)) { return @() }
    $raw = Get-Content $p -Raw -Encoding UTF8
    if (-not $raw.Trim()) { return @() }
    @($raw | ConvertFrom-Json | ForEach-Object { $_ })
}
function Save-Deleted($List) { ConvertTo-Json -InputObject @($List) -Depth 3 | Set-Content (Get-DeletedPath) -Encoding UTF8 }
function Find-Deleted([string]$Id) { Read-Deleted | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }
function Clear-Deleted([string]$Id) { Save-Deleted @(Read-Deleted | Where-Object { $_.id -ne $Id }) }
function Add-Deleted([string]$Id) {
    $l = @(Read-Deleted | Where-Object { $_.id -ne $Id }) + [pscustomobject]@{ id = $Id; deletedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    Save-Deleted $l
}

# Retire de la clé USB branchée les lignes de ce client (nom + mot de passe chiffré). Le reste du fichier est conservé tel quel.
function Remove-UsbRows([string]$Id) {
    $removed = 0; $errors = @()
    foreach ($csv in @(Find-DeploymentCsv)) {
        try {
            $rows = @(Import-Csv -Path $csv -Encoding UTF8)
            $keep = @($rows | Where-Object { ([string]($_.ID -replace '\D', '')) -ne $Id })
            if ($keep.Count -eq $rows.Count) { continue }
            if ($keep.Count) { $keep | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8 }
            else { Set-Content -Path $csv -Value '"Date","Client","Poste","ID","Password","PasswordEnc","Version","Serveur"' -Encoding UTF8 }
            $removed += ($rows.Count - $keep.Count)
        }
        catch { $errors += "$csv : $($_.Exception.Message)" }
    }
    [pscustomobject]@{ removed = $removed; errors = $errors }
}

# Demande au serveur de retirer ce poste de sa liste (POST /peers/forget). Échec = rien n'est supprimé nulle part.
function Send-ServerForget([string]$Id) {
    $cfg = Get-FeedConfig
    if (-not $cfg) { return [pscustomobject]@{ ok = $false; message = 'accès au serveur non configuré' } }
    try {
        $token = Unprotect-Dpapi $cfg.token
        Invoke-RestMethod -Method Post -Uri ($cfg.url + '/peers/forget') -Headers @{ Authorization = "Bearer $token" } `
            -ContentType 'application/json' -Body (ConvertTo-Json -InputObject @{ id = $Id } -Compress) -TimeoutSec 8 | Out-Null
        [pscustomobject]@{ ok = $true; message = '' }
    }
    catch { [pscustomobject]@{ ok = $false; message = "serveur injoignable ou demande refusée ($($_.Exception.Message)). Êtes-vous sur le réseau local ou sur le WireGuard ?" } }
}

# Prévient le serveur que cette fiche est validée depuis CE PC (même appel que le bouton Valider du téléphone) : l'exe d'installation qui
# attend chez le client peut alors se fermer. Au mieux : une fiche sans heure de réception (client importé de la clé USB) ou un serveur
# injoignable ne gênent jamais la validation locale. La validation déposée sur le serveur est ensuite effacée à la synchronisation suivante.
function Send-ServerValidated($Rec) {
    $stamp = [string](Get-Prop $Rec 'recvAt')
    if (-not $stamp) { return }
    $cfg = Get-FeedConfig
    if (-not $cfg) { return }
    try {
        $token = Unprotect-Dpapi $cfg.token
        Invoke-RestMethod -Method Post -Uri ($cfg.url + '/records/validate') -Headers @{ Authorization = "Bearer $token" } `
            -ContentType 'application/json' -Body (ConvertTo-Json -InputObject @{ id = [string]$Rec.id; received_at = $stamp } -Compress) -TimeoutSec 4 | Out-Null
    }
    catch { }
}

# ---------------------------------------------------------------- Conditions acceptées par le client (preuve)
# La preuve voyage dans la fiche chiffrée (ou dans rustdesk-consents.csv sur la clé USB) : on n'en garde que des champs connus, de longueur bornée.
function Limit-Text($Value, [int]$Max) {
    $t = (([string]$Value) -replace '[\x00-\x1f]', '').Trim()
    if ($t.Length -gt $Max) { $t.Substring(0, $Max) } else { $t }
}

function ConvertTo-Consent($C, [string]$ServerAt = '') {
    if (-not $C) { return $null }
    try {
        $sha = (Limit-Text $C.sha256 64).ToLower()
        $mode = Limit-Text $C.mode 12
        if ($sha -notmatch '^[0-9a-f]{64}$' -or $mode -notin 'dialogue', 'parametre') { return $null }
        $secs = 0; [void][int]::TryParse([string]$C.seconds, [ref]$secs)
        [pscustomobject]@{
            version = (Limit-Text $C.version 40); sha256 = $sha; mode = $mode; name = (Limit-Text $C.name 80)
            at = (Limit-Text $C.at 32); seconds = $secs; user = (Limit-Text $C.user 64); host = (Limit-Text $C.host 63); serverAt = (Limit-Text $ServerAt 40)
        }
    }
    catch { $null }
}

function Get-ConsentSummary($Rec) {
    $c = Get-Prop $Rec 'consent'
    if (-not $c) { return '' }
    if ($c.mode -eq 'parametre') { return "Conditions déclarées acceptées par paramètre (texte v$($c.version))" }
    $when = $(if ($c.at) { Format-Local ([string]$c.at) } else { '' })
    "Conditions acceptées le $when par $($c.name) (texte v$($c.version))"
}

# Cherche, dans le dossier « conditions » à côté de ce script, le texte dont l'empreinte est celle de la preuve
function Find-TermsText([string]$Sha) {
    $dir = Join-Path $PSScriptRoot 'conditions'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.txt' -File)) {
        $norm = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) -replace "`r`n", "`n"
        $h = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($norm))) -replace '-', '').ToLower()
        if ($h -eq $Sha) { return [pscustomobject]@{ file = $f.Name; text = $norm } }
    }
    $null
}

# Exportation AUTOMATIQUE de la preuve : dès qu'un client dont la fiche porte une preuve est VALIDÉ (téléphone ou PC), ou importé de la clé USB,
# elle est écrite dans Documents\Pg20-Info-Preuves : rien à faire, et elle survit à la suppression du client. Une seule fois par preuve
# (proofExportedAt) : un fichier effacé exprès n'est pas recréé. Un échec d'écriture est noté dans watch.log et ne gêne jamais la validation.
function Save-ConsentProofAuto($Rec, [string]$Dir = '') {
    $c = Get-Prop $Rec 'consent'
    if (-not $c -or (Get-Prop $Rec 'proofExportedAt') -eq [string]$c.at) { return }
    try {
        $p = Export-ConsentProof $Rec $Dir -Auto
        Set-Prop $Rec 'proofExportedAt' ([string]$c.at)
        Write-Watch "PREUVE D'ACCEPTATION enregistrée ($($Rec.name)) : $p" 'Green'
    }
    catch { Write-Watch "Preuve d'acceptation NON enregistrée ($($Rec.name)) : $($_.Exception.Message)" 'Yellow' }
}

# Écrit la preuve d'acceptation d'un client dans Documents\Pg20-Info-Preuves (avec le texte accepté s'il est dans le dossier « conditions »)
function Export-ConsentProof($Rec, [string]$Dir = '', [switch]$Auto) {
    $c = Get-Prop $Rec 'consent'
    if (-not $c) { throw 'Aucune acceptation de conditions enregistrée pour ce client.' }
    if (-not $Dir) { $Dir = $env:PG20_PROOF_DIR }                       # (tests) dossier imposé
    if (-not $Dir) { $Dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Pg20-Info-Preuves' }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $safe = (([string]$Rec.name) -replace '[^\w\- ]', '_').Trim(); if (-not $safe) { $safe = 'client' }
    if ($Auto) {
        # nom stable (ID + date de l'acceptation) : indépendant d'un renommage du client, et jamais écrit deux fois
        $when = Get-Date
        try { $when = ([datetime]::Parse([string]$c.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)).ToLocalTime() } catch { }
        $path = Join-Path $Dir ('Preuve-{0}-{1:yyyyMMdd-HHmmss}.txt' -f $Rec.id, $when)
        if (Test-Path -LiteralPath $path) { return $path }
    }
    else { $path = Join-Path $Dir ('Preuve-{0}-{1}-{2:yyyyMMdd-HHmm}.txt' -f $safe, $Rec.id, (Get-Date)) }
    $found = Find-TermsText ([string]$c.sha256)
    $how = $(if ($c.mode -eq 'dialogue') { "fenêtre d'acceptation (case cochée et nom saisi)" } else { 'paramètre -AcceptTerms (déclaré par le technicien, pas saisi par le client)' })
    $srv = $(if ($c.serverAt) { Format-Local ([string]$c.serverAt) } else { '(non disponible : fiche reçue par la clé USB)' })
    $vat = Get-Prop $Rec 'validatedAt'
    $val = $(if ($vat) { Format-Local ([string]$vat) } else { "(client importé depuis la clé USB : validé d'office)" })
    $txt = $(if ($found) { 'oui (' + $found.file + ')' } else { 'NON : placez le fichier de cette version dans le dossier « conditions » à côté de Pg20-Clients.ps1' })
    $lines = @(
        "PREUVE D'ACCEPTATION DES CONDITIONS D'INSTALLATION", '',
        "Client                     : $($Rec.name)",
        "ID RustDesk                : $(Format-RdId $Rec.id)",
        "Poste                      : $($c.host)   (session Windows : $($c.user))",
        "Accepté par                : $($c.name)",
        "Mode d'acceptation         : $how",
        "Date (horloge du PC)       : $(Format-Local ([string]$c.at))",
        "Date (réception serveur)   : $srv",
        "Durée de la fenêtre        : $($c.seconds) s",
        "Validé par le technicien   : $val",
        "Texte accepté              : version $($c.version)",
        "Empreinte SHA-256 du texte : $($c.sha256)",
        "Texte retrouvé             : $txt", '',
        "Cette preuve est un journal tenu par l'outil du technicien : elle ne remplace pas un accord écrit signé.",
        '', '--------------------------------------------------------------------', ''
    )
    $body = ($lines -join "`r`n")
    if ($found) { $body += "`r`n" + ($found.text -replace "`n", "`r`n") + "`r`n" }
    [IO.File]::WriteAllText($path, $body, (New-Object Text.UTF8Encoding($true)))
    $path
}

# À appeler dans Use-Store. Le serveur est prévenu EN PREMIER : s'il est injoignable, rien n'est supprimé (pas de client à moitié effacé).
function Remove-Client($Rec) {
    $id = [string]$Rec.id; $name = [string]$Rec.name
    $srv = Send-ServerForget $id
    if (-not $srv.ok) { return [pscustomobject]@{ ok = $false; message = "Rien n'a été supprimé : $($srv.message)"; usbRows = 0 } }
    $ord = Get-Prop $Rec 'uninstallOrder'
    if ($ord) { [void](Revoke-UninstallOrder $id ([string]$ord.nonce)) }      # un ordre de désinstallation encore en attente n'a plus de client : annulé (ou déjà exécuté : nettoyé)
    $usb = Remove-UsbRows $id
    $script:Store = @($script:Store | Where-Object { $_.id -ne $id })
    Save-Store
    Add-Deleted $id
    $parts = @('retiré de ce PC', 'demande envoyée au serveur (effective en moins d''une minute)')
    if ($usb.removed) { $parts += "retiré de la clé USB ($($usb.removed) ligne(s))" }
    if ($usb.errors.Count) { $parts += "clé USB NON modifiée : $($usb.errors -join '; ')" }
    [pscustomobject]@{ ok = $true; message = "$name : " + ($parts -join ' ; ') + '.'; usbRows = $usb.removed }
}

# ---------------------------------------------------------------- Désinstallation automatique (ordre signé)
# Les postes installés avec la tâche de maintenance (champ « agent » de leur fiche, Pg20-Agent.ps1) vont chercher, toutes les 30 minutes, un ordre
# de désinstallation sur le serveur. Cet ordre est SIGNÉ ici, avec la clé privée de ce PC : le serveur le transporte sans pouvoir en fabriquer ni
# en modifier un, et le poste le refuse si la signature, l'ID ou les dates ne correspondent pas. Quand le poste a exécuté l'ordre, il le signale :
# Receive-OrderResults retire alors le client de la liste (ce PC, clé USB, serveur), sans rien d'autre à faire.
function Send-UninstallOrder($Rec) {
    $id = [string]$Rec.id
    $cfg = Get-FeedConfig
    if (-not $cfg) { return [pscustomobject]@{ ok = $false; message = 'accès au serveur non configuré'; order = $null } }
    $key = Get-TechPrivateKeyXml
    if (-not $key) { return [pscustomobject]@{ ok = $false; message = (Get-MissingKeyMessage); order = $null } }
    try {
        $o = New-UninstallOrder $id $key 30
        $token = Unprotect-Dpapi $cfg.token
        Invoke-RestMethod -Method Post -Uri ($cfg.url + '/orders') -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' `
            -Body (ConvertTo-Json -InputObject @{ order = $o.order; sig = $o.sig } -Depth 4 -Compress) -TimeoutSec 8 | Out-Null
    }
    catch { return [pscustomobject]@{ ok = $false; message = "ordre non déposé sur le serveur ($($_.Exception.Message)). Êtes-vous sur le réseau local ou sur le WireGuard ?"; order = $null } }
    $info = [pscustomobject]@{ nonce = [string]$o.order.nonce; iat = [string]$o.order.iat; exp = [string]$o.order.exp; sentAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    Set-Prop $Rec 'uninstallOrder' $info
    Save-Store
    [pscustomobject]@{ ok = $true; message = ''; order = $info }
}

# Retire l'ordre du serveur (annulé, exécuté ou périmé). Renvoie $true si le serveur a répondu.
function Revoke-UninstallOrder([string]$Id, [string]$Nonce) {
    $cfg = Get-FeedConfig
    if (-not $cfg -or $Id -notmatch '^\d{6,12}$' -or $Nonce -notmatch '^[0-9a-f]{32}$') { return $false }
    try {
        $token = Unprotect-Dpapi $cfg.token
        Invoke-RestMethod -Method Post -Uri ($cfg.url + '/orders/ack') -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' `
            -Body (ConvertTo-Json -InputObject @{ id = $Id; nonce = $Nonce } -Compress) -TimeoutSec 6 | Out-Null
        $true
    }
    catch { $false }
}

# Annulation demandée par le technicien : l'ordre est retiré du serveur ; en cas d'échec il est conservé (le poste pourrait encore l'exécuter)
function Cancel-UninstallOrder($Rec) {
    $ord = Get-Prop $Rec 'uninstallOrder'
    if (-not $ord) { return [pscustomobject]@{ ok = $true; message = 'Aucune désinstallation n''était demandée.' } }
    if (-not (Revoke-UninstallOrder ([string]$Rec.id) ([string]$ord.nonce))) {
        return [pscustomobject]@{ ok = $false; message = "Annulation impossible : serveur injoignable (l'ordre reste en place). Êtes-vous sur le réseau local ou sur le WireGuard ?" }
    }
    Clear-Props $Rec @('uninstallOrder')
    Save-Store
    [pscustomobject]@{ ok = $true; message = "Désinstallation annulée : $($Rec.name) ne sera pas désinstallé (sauf si le poste l'avait déjà exécutée)." }
}

# Lit l'état des ordres déposés : un poste qui a exécuté son ordre est retiré de la liste ; un ordre jamais exécuté à son échéance est oublié.
# À appeler dans Use-Store. Un ordre qui ne correspond à aucun client de CE PC n'est jamais touché.
function Receive-OrderResults($Cfg, [string]$Token) {
    $res = [pscustomobject]@{ uninstalled = @(); expired = @(); message = '' }
    try { $feed = Invoke-RestMethod -Uri ($Cfg.url + '/orders') -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 8 }
    catch { return $res }                           # serveur sans cette fonction (ancienne version) : rien à relever
    $now = (Get-Date).ToUniversalTime()
    foreach ($o in @($feed.orders | Where-Object { $_ })) {
        $rec = Find-Client ([string]$o.id)
        $ord = $(if ($rec) { Get-Prop $rec 'uninstallOrder' })
        if (-not $ord -or [string]$ord.nonce -ne [string]$o.nonce) { continue }
        if ($o.done) {
            $name = [string]$rec.name; $cid = [string]$rec.id
            $r = Remove-Client $rec
            if ($r.ok) { $res.uninstalled += [pscustomobject]@{ id = $cid; name = $name } }
            else { $res.message = "$name s'est désinstallé mais n'a pas pu être retiré de la liste : $($r.message)" }
            continue
        }
        $exp = $null; try { $exp = ConvertTo-Utc ([string]$o.exp) } catch { }
        if ($exp -and $exp -lt $now) {
            [void](Revoke-UninstallOrder ([string]$rec.id) ([string]$ord.nonce))
            Clear-Props $rec @('uninstallOrder'); Save-Store
            $res.expired += [pscustomobject]@{ id = [string]$rec.id; name = [string]$rec.name }
        }
    }
    $res
}

# ---------------------------------------------------------------- Import depuis la clé USB
function Find-DeploymentCsv {
    if ($ImportFrom) {
        if (Test-Path $ImportFrom -PathType Leaf) { return @($ImportFrom) }
        $p = Join-Path $ImportFrom 'rustdesk-deployments.csv'
        if (Test-Path $p) { return @($p) } else { return @() }
    }
    $found = @()
    foreach ($d in (Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 })) {
        $p = Join-Path ($d.DeviceID + '\') 'Pg20-Info\rustdesk-deployments.csv'
        if (Test-Path $p) { $found += $p }
    }
    $found
}

function Import-Deployments {
    $added = 0; $updated = 0; $csvs = @(Find-DeploymentCsv); $clearAfter = @()
    foreach ($csv in $csvs) {
        # Preuves d'acceptation déposées par l'exe à côté de la clé (fichier à part : le format de rustdesk-deployments.csv ne change pas)
        # Cette ligne dit aussi si la tâche de maintenance est installée (agent) ; les anciennes lignes ne contiennent que la preuve elle-même.
        $cmap = @{}; $amap = @{}
        $cf = Join-Path (Split-Path -Parent $csv) 'rustdesk-consents.csv'
        if (Test-Path -LiteralPath $cf) {
            foreach ($cr in @(Import-Csv -Path $cf -Encoding UTF8)) {
                $cid = [string]($cr.ID -replace '\D', '')
                if (-not $cid) { continue }
                try {
                    $o = $null
                    if ($cr.ConsentEnc) { $o = Unprotect-Envelope $cr.ConsentEnc; if ([string]$o.id -ne $cid) { $o = $null } }
                    elseif ($cr.ConsentJson) { $o = $cr.ConsentJson | ConvertFrom-Json }
                    if (-not $o) { continue }
                    if ($o.PSObject.Properties['consent'] -or $o.PSObject.Properties['agent']) {                     # enveloppe {v, id, agent, consent}
                        $cn = ConvertTo-Consent $o.consent ''
                        if ($o.PSObject.Properties['agent']) { $amap[$cid] = [bool]$o.agent }
                    }
                    else { $cn = ConvertTo-Consent $o '' }                                                           # ancien format : la preuve seule
                    if ($cn) { $cmap[$cid] = $cn }
                }
                catch { }
            }
        }
        foreach ($r in (Import-Csv -Path $csv -Encoding UTF8)) {
            $id = [string]($r.ID -replace '\D', '')
            if (-not $id) { continue }
            $del = Find-Deleted $id
            if ($del) {
                # Client supprimé : une ligne de clé plus ANCIENNE que la suppression (autre copie de la clé) ne le ressuscite pas ;
                # une ligne plus récente est une nouvelle installation : elle efface la trace de suppression et s'importe normalement.
                $rowUtc = $null
                try { $rowUtc = [datetime]::ParseExact([string]$r.Date, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal).ToUniversalTime() } catch { }
                if (-not $rowUtc -or $rowUtc -le (ConvertTo-Utc ([string]$del.deletedAt))) { continue }
                $clearAfter += $id          # effacée à la FIN : l'ordre des lignes de la clé ne compte pas (les plus anciennes restent ignorées)
            }
            $rec = Find-Client $id
            if ($rec -and $rec.PSObject.Properties['forgotten'] -and $rec.forgotten) { continue }      # client oublié : l'import ne le ressuscite pas
            $pw = ''
            if ($r.PasswordEnc) {
                try { $pw = Unprotect-FromTech $r.PasswordEnc }
                catch { Write-Host "  ! mot de passe de '$($r.Client)' illisible : $($_.Exception.Message)" -ForegroundColor Yellow }
            }
            elseif ($r.Password) { $pw = $r.Password }
            if ($rec) {
                # Le serveur a reçu pour cet ID une fiche différente de cette ligne de la clé (réinstallation sans clé, nouveau mot de passe) :
                # une ancienne ligne de la clé ne l'écrase pas, vous décidez dans la page (« Valider »).
                $held = Get-Prop $rec 'incoming'; if (-not $held -and (Get-Prop $rec 'viaServer')) { $held = $rec }
                if ($held -and $pw -and ((Unprotect-Dpapi $held.pwd) -ne $pw)) { continue }
            }
            if ($rec) { $updated++ } else { $rec = New-Client $id; $script:Store = @($script:Store) + $rec; $added++ }
            $rec.name = $r.Client; $rec.host = $r.Poste; $rec.installed = $r.Date; $rec.unknown = $false
            if ($cmap.ContainsKey($id)) { Set-Prop $rec 'consent' $cmap[$id] }
            if ($amap.ContainsKey($id)) { Set-Prop $rec 'agent' $amap[$id] }
            if ($rec.status -ne 'Ignore') { $rec.status = 'Valide' }      # installé par vous : validé d'office
            if ($rec.status -eq 'Valide') { Save-ConsentProofAuto $rec }
            if ($pw) { $rec.pwd = Protect-Dpapi $pw }
            Clear-Props $rec @('incoming', 'code', 'viaServer')           # la clé USB fait foi : une fiche du serveur en attente pour cet ID devient inutile
        }
    }
    if ($added -or $updated) { Save-Store }
    foreach ($cid in @($clearAfter | Select-Object -Unique)) { Clear-Deleted $cid }
    [pscustomobject]@{ files = $csvs.Count; added = $added; updated = $updated }
}

# ---------------------------------------------------------------- Interrogation du serveur
# Fiches d'installation envoyées par les exes directement au serveur (sans clé USB) : relevées, ouvertes avec votre clé privée,
# rangées « A valider » avec leur code de contrôle, puis effacées du serveur (seulement après enregistrement sur ce PC).
function Receive-Records($Cfg, [string]$Token) {
    $res = [pscustomobject]@{ received = @(); validated = @(); rejected = 0; message = '' }
    try { $feed = Invoke-RestMethod -Uri ($Cfg.url + '/records') -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 8 }
    catch { return $res }                           # serveur sans cette fonction (ancienne version) : rien à relever
    $recs = @($feed.records | Where-Object { $_ })
    $vals = @($feed.validations | Where-Object { $_ })
    if (-not $recs.Count -and -not $vals.Count) { return $res }
    if (-not (Get-TechPrivateKeyXml)) { $res.message = 'fiches en attente sur le serveur mais clé privée introuvable sur ce PC'; return $res }

    $ack = @()
    foreach ($r in $recs) {
        $id = [string]$r.id
        $ack += @{ id = $id; received_at = [string]$r.received_at }
        # Le code de contrôle est choisi par le serveur et affiché par l'exe chez le client (4 chiffres) ; vide avec un ancien serveur
        $code = [string]$r.code; if ($code -notmatch '^\d{4}$') { $code = '' }
        try {
            $f = Unprotect-Envelope ([string]$r.blob)
            $name = (([string]$f.name) -replace '[\x00-\x1f]', '').Trim()
            $pw   = [string]$f.password
            if ([int]$f.v -ne 1 -or [string]$f.id -ne $id -or $name.Length -lt 1 -or $name.Length -gt 80 -or $pw.Length -lt 12 -or $pw.Length -gt 128 -or $pw -match '[\s\x00-\x1f]') {
                throw 'fiche invalide (contenu)'
            }
            $hostName = (([string]$f.host) -replace '[\x00-\x1f]', '').Trim(); if ($hostName.Length -gt 63) { $hostName = $hostName.Substring(0, 63) }
            $when = Format-Local ([string]$f.ts)
            $consent = ConvertTo-Consent $f.consent ([string]$r.received_at)      # preuve d'acceptation (heure du serveur ajoutée) ; $null si l'exe n'en avait pas
            $agentFlag = [bool]($f.PSObject.Properties['agent'] -and $f.agent)    # le poste a la tâche de maintenance : désinstallation à distance possible

            if (Find-Deleted $id) { Clear-Deleted $id }          # une fiche reçue est une nouvelle installation : le client supprimé réapparaît
            $rec = Find-Client $id
            $forgotten = $rec -and (Get-Prop $rec 'forgotten')
            $same = $rec -and -not $forgotten -and $rec.pwd -and ((Unprotect-Dpapi $rec.pwd) -eq $pw) -and $rec.name -eq $name
            if ($same) { if ($consent -and -not (Get-Prop $rec 'consent')) { Set-Prop $rec 'consent' $consent }; Set-Prop $rec 'agent' $agentFlag; continue }                 # déjà connue à l'identique (fiche aussi relevée sur la clé USB) : rien à faire
            if (-not $rec) { $rec = New-Client $id; $script:Store = @($script:Store) + $rec }
            if ($forgotten) { Clear-Props $rec @('forgotten'); $rec.status = 'A valider' }
            if (-not $rec.pwd -or $forgotten -or ($rec.unknown -and $rec.status -eq 'A valider')) {
                # Poste encore sans données (inconnu, ou oublié) : la fiche le renseigne tout de suite, il reste « A valider »
                $rec.name = $name; $rec.host = $hostName; $rec.installed = $when; $rec.unknown = $false; $rec.status = 'A valider'; $rec.pwd = Protect-Dpapi $pw
                Clear-Props $rec @('incoming')
                if ($consent) { Set-Prop $rec 'consent' $consent }
                Set-Prop $rec 'agent' $agentFlag
                Set-Prop $rec 'viaServer' $true; Set-Prop $rec 'code' $code
            }
            else {
                # Client déjà connu avec d'autres données : la fiche attend votre validation (elle n'écrase rien d'avance)
                Set-Prop $rec 'incoming' ([pscustomobject]@{ name = $name; host = $hostName; installed = $when; pwd = (Protect-Dpapi $pw); consent = $consent; agent = $agentFlag })
                Set-Prop $rec 'code' $code; Set-Prop $rec 'viaServer' $true
                $rec.status = 'A valider'
            }
            # Une fiche = une NOUVELLE installation : un ordre de désinstallation resté en attente pour cet ID ne doit pas toucher cette installation
            $pendOrd = Get-Prop $rec 'uninstallOrder'
            if ($pendOrd) { [void](Revoke-UninstallOrder $id ([string]$pendOrd.nonce)); Clear-Props $rec @('uninstallOrder') }
            Set-Prop $rec 'recvAt' ([string]$r.received_at)      # identifie la fiche : une validation du téléphone ne s'applique qu'à elle
            $res.received += [pscustomobject]@{ id = $id; name = $name; code = $code }
        }
        catch {
            $res.rejected++                          # fabriquée, altérée ou chiffrée pour une autre clé : écartée (et effacée du serveur)
            Write-Host "  ! fiche reçue pour l'ID $id écartée : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    # Validations faites depuis le téléphone (bouton « Valider » de la notification) : appliquées seulement à la fiche précise
    # qu'elles désignent (même ID ET même date de réception). Sans correspondance, elles restent sur le serveur (purgées après 14 jours).
    $valAck = @()
    foreach ($v in $vals) {
        $rec = Find-Client ([string]$v.id)
        if ($rec -and (Get-Prop $rec 'recvAt') -eq [string]$v.received_at) {
            if ($rec.status -eq 'A valider') {
                $nm = $rec.name
                Confirm-Client $rec
                $res.validated += [pscustomobject]@{ id = $rec.id; name = $nm }
            }
            $valAck += @{ id = [string]$v.id; received_at = [string]$v.received_at }
        }
    }
    Save-Store                                       # d'abord enregistrer ici, ensuite seulement effacer côté serveur
    try {
        Invoke-RestMethod -Method Post -Uri ($Cfg.url + '/records/ack') -Headers @{ Authorization = "Bearer $Token" } `
            -ContentType 'application/json' -Body (ConvertTo-Json -InputObject @{ items = $ack; validated = $valAck } -Depth 4 -Compress) -TimeoutSec 8 | Out-Null
    }
    catch { $res.message = 'fiches enregistrées, mais non effacées du serveur (elles seront relues sans conséquence)' }
    $res
}

function Invoke-FeedSync {
    $cfg = Get-FeedConfig
    if (-not $cfg) { return [pscustomobject]@{ ok = $false; message = 'accès au serveur non configuré (voir Setup-Technician.ps1 -FeedUrl ... -FeedToken ...)'; added = @(); count = 0; received = @() } }
    try {
        $token = Unprotect-Dpapi $cfg.token
        $feed = Invoke-RestMethod -Uri ($cfg.url + '/peers') -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 8
    }
    catch {
        return [pscustomobject]@{ ok = $false; message = "serveur injoignable : $($_.Exception.Message). Êtes-vous sur le réseau local ou sur le WireGuard ?"; added = @(); count = 0; received = @() }
    }
    $added = @()
    foreach ($p in @($feed.peers)) {
        $id = [string]$p.id
        $rec = Find-Client $id
        if (-not $rec) {
            $del = Find-Deleted $id
            if ($del) {
                # Client supprimé : tant que le serveur n'a pas fini de le retirer (10 min au plus), son ancienne inscription est ignorée.
                # Un poste inscrit APRÈS la suppression (RustDesk encore installé chez lui), ou encore listé après 10 min, réapparaît « A valider ».
                $first = $null; try { $first = ConvertTo-Utc ([string]$p.first_seen) } catch { }
                $delUtc = ConvertTo-Utc ([string]$del.deletedAt)
                if ($first -and $first -le $delUtc -and ((Get-Date).ToUniversalTime() - $delUtc).TotalMinutes -lt 10) { continue }
                Clear-Deleted $id
            }
        }
        if (-not $rec) { $rec = New-Client $id; $script:Store = @($script:Store) + $rec; $added += $rec }
        $rec.firstSeen = [string]$p.first_seen; $rec.ip = [string]$p.ip
    }
    Save-Store
    $rr = Receive-Records $cfg $token
    $orr = Receive-OrderResults $cfg $token
    $msg = "$($feed.count) poste(s) enregistré(s) sur le serveur"
    if ($rr.received.Count) { $msg += " · $($rr.received.Count) fiche(s) reçue(s)" }
    if ($rr.validated.Count) { $msg += " · $($rr.validated.Count) validée(s) depuis le téléphone" }
    if ($rr.rejected) { $msg += " · $($rr.rejected) fiche(s) écartée(s)" }
    if ($rr.message) { $msg += " · $($rr.message)" }
    if ($orr.uninstalled.Count) { $msg += " · $($orr.uninstalled.Count) poste(s) désinstallé(s) à distance" }
    if ($orr.message) { $msg += " · $($orr.message)" }
    [pscustomobject]@{ ok = $true; message = $msg; added = $added; count = $feed.count; received = @($rr.received); validated = @($rr.validated); rejected = [int]$rr.rejected
                       uninstalled = @($orr.uninstalled); expiredOrders = @($orr.expired) }
}

# ---------------------------------------------------------------- Affichage
function Format-Local([string]$Iso) {
    if (-not $Iso) { return '' }
    try { [datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { $Iso }
}

function Get-View {
    @($script:Store | Where-Object { $script:ShowAll -or $_.status -ne 'Ignore' } |
        Sort-Object @{ Expression = { if ($_.status -eq 'A valider') { 0 } else { 1 } } }, @{ Expression = { $_.name } })
}

function Show-List([string[]]$NewIds = @()) {
    $view = @(Get-View)      # @() : avec un seul client, PowerShell renverrait un objet sans propriété Count
    Write-Host ''
    Write-Host ('{0,3}  {1,-26} {2,-12} {3,-10} {4,-16} {5}' -f 'N°', 'Client', 'ID', 'Statut', 'Installé le', 'Vu par le serveur') -ForegroundColor Cyan
    if (-not $view.Count) { Write-Host '  (aucun client : branchez la clé USB puis tapez i)' }
    for ($i = 0; $i -lt $view.Count; $i++) {
        $c = $view[$i]
        $statut = switch ($c.status) { 'Valide' { 'valide' } 'A valider' { 'A VALIDER' } default { 'masqué' } }
        $vu = if ($c.firstSeen) { Format-Local $c.firstSeen } else { 'pas encore' }
        $nom = $c.name + $(if ($NewIds -contains $c.id) { ' (nouveau)' } else { '' }) + $(if (Get-Prop $c 'code') { " [code $(Get-Prop $c 'code')]" } else { '' })
        $color = if ($c.status -eq 'A valider') { 'Yellow' } elseif ($c.status -eq 'Ignore') { 'DarkGray' } else { 'White' }
        Write-Host ('{0,3}  {1,-26} {2,-12} {3,-10} {4,-16} {5}' -f ($i + 1), $nom, (Format-RdId $c.id), $statut, $c.installed, $vu) -ForegroundColor $color
    }
}

function Show-Balloon([string]$Title, [string]$Text) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        if (-not $script:ni) { $script:ni = New-Object System.Windows.Forms.NotifyIcon; $script:ni.Icon = [System.Drawing.SystemIcons]::Information; $script:ni.Visible = $true }
        $script:ni.ShowBalloonTip(10000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { }
}

# ---------------------------------------------------------------- Actions
function Resolve-Client([string]$Key, $View) {
    if ($Key -match '^\d{1,3}$' -and [int]$Key -ge 1 -and [int]$Key -le $View.Count) { return $View[[int]$Key - 1] }
    $digits = $Key -replace '\D', ''
    if ($digits.Length -ge 6) { $m = @($View | Where-Object { $_.id -eq $digits }); if ($m.Count) { return $m[0] } }
    $m = @($View | Where-Object { $_.name -like "*$Key*" })
    if ($m.Count -eq 1) { return $m[0] }
    if ($m.Count -gt 1) { throw "Plusieurs clients correspondent à « $Key » : précisez ou utilisez le numéro." }
    throw "Aucun client ne correspond à « $Key »."
}

function Open-Client($Rec) {
    $uri = 'rustdesk://connection/new/' + $Rec.id
    $pw = Unprotect-Dpapi $Rec.pwd
    if ($pw) { $uri += '?password=' + [uri]::EscapeDataString($pw) }
    if ($DryRun) { Write-Host ('  [simulation] ' + ($uri -replace 'password=.*', 'password=********')); return }
    Write-Host "  Ouverture de RustDesk vers $($Rec.name) ($(Format-RdId $Rec.id))..." -ForegroundColor Green
    if (-not $pw) { Write-Host '  (aucun mot de passe enregistré pour ce client : RustDesk le demandera)' -ForegroundColor Yellow }
    Start-Process $uri
}

function Copy-ClientPassword($Rec) {
    $pw = Unprotect-Dpapi $Rec.pwd
    if (-not $pw) { Write-Host '  Aucun mot de passe enregistré pour ce client.' -ForegroundColor Yellow; return }
    Set-Clipboard -Value $pw
    $hash = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($pw))) -replace '-', ''
    $cmd = '$c = Get-Clipboard -Raw; Start-Sleep 30; $c = Get-Clipboard -Raw; if ($c) { $h = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($c.TrimEnd("`r","`n")))) -replace "-",""; if ($h -eq "' + $hash + '") { Set-Clipboard -Value " " } }'
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', $cmd
    Write-Host '  Mot de passe copié : il sera effacé du presse-papiers dans 30 secondes.' -ForegroundColor Green
}

function Show-SyncResult($R) {
    if ($R.ok) { Write-Host "  Serveur : $($R.message)." -ForegroundColor DarkGray }
    else { Write-Host "  Serveur : $($R.message)" -ForegroundColor Yellow }
    foreach ($n in @($R.added)) { Write-Host "  >> NOUVEAU POSTE inconnu sur le serveur : ID $(Format-RdId $n.id) (vu depuis $($n.ip))" -ForegroundColor Yellow }
    foreach ($n in @($R.received)) { Write-Host "  >> FICHE REÇUE : $($n.name) (ID $(Format-RdId $n.id)), code de contrôle $($n.code) : à valider" -ForegroundColor Yellow }
    foreach ($n in @($R.validated)) { Write-Host "  >> VALIDÉ depuis le téléphone : $($n.name) (ID $(Format-RdId $n.id))" -ForegroundColor Green }
    foreach ($n in @($R.uninstalled)) { Write-Host "  >> DÉSINSTALLÉ à distance : $($n.name) (ID $(Format-RdId $n.id)) : retiré de la liste" -ForegroundColor Green }
    foreach ($n in @($R.expiredOrders)) { Write-Host "  >> ORDRE PÉRIMÉ : $($n.name) (ID $(Format-RdId $n.id)) n'a pas exécuté la désinstallation en 30 jours (poste éteint ?)" -ForegroundColor Yellow }
}

# ---------------------------------------------------------------- Interface web locale
# Mini-serveur HTTP sur 127.0.0.1 UNIQUEMENT (joignable depuis ce PC seulement), protégé par un jeton aléatoire.
# La page n'a jamais accès aux mots de passe : c'est cet outil qui ouvre RustDesk ou copie le mot de passe.
function New-WebToken {
    $b = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($b); $rng.Dispose()
    ([BitConverter]::ToString($b) -replace '-', '').ToLower()
}

function Send-Bytes($Ctx, [byte[]]$Bytes, [int]$Code, [string]$Type) {
    $r = $Ctx.Response
    $r.StatusCode = $Code; $r.ContentType = $Type
    $r.AddHeader('Cache-Control', 'no-store')
    $r.AddHeader('X-Content-Type-Options', 'nosniff')
    $r.AddHeader('X-Frame-Options', 'DENY')
    $r.AddHeader('Content-Security-Policy', "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'")
    $r.ContentLength64 = $Bytes.Length
    if ($Bytes.Length) { $r.OutputStream.Write($Bytes, 0, $Bytes.Length) }
    $r.OutputStream.Close()
}
function Send-Json($Ctx, $Obj, [int]$Code = 200) { Send-Bytes $Ctx ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Obj -Depth 6 -Compress))) $Code 'application/json; charset=utf-8' }
function Send-Text($Ctx, [string]$Text, [int]$Code = 200, [string]$Type = 'text/plain; charset=utf-8') { Send-Bytes $Ctx ([Text.Encoding]::UTF8.GetBytes($Text)) $Code $Type }

# Liste envoyée à la page : jamais de mot de passe, seulement « hasPassword »
function Get-WebClients([bool]$IncludeHidden, [string[]]$NewIds) {
    @($script:Store |
        Where-Object { -not ($_.PSObject.Properties['forgotten'] -and $_.forgotten) } |
        Where-Object { $IncludeHidden -or $_.status -ne 'Ignore' } |
        Sort-Object @{ Expression = { if ($_.status -eq 'A valider') { 0 } else { 1 } } }, @{ Expression = { $_.name } } |
        ForEach-Object {
            [pscustomobject]@{
                id = $_.id; idText = (Format-RdId $_.id); name = $_.name; host = $_.host; installed = $_.installed
                firstSeen = (Format-Local $_.firstSeen); status = $_.status; unknown = [bool]$_.unknown
                hasPassword = [bool]$_.pwd; isNew = ($NewIds -contains $_.id)
                code = [string](Get-Prop $_ 'code'); viaServer = [bool](Get-Prop $_ 'viaServer')
                consent = (Get-ConsentSummary $_); hasConsent = [bool](Get-Prop $_ 'consent')
                agent = [bool](Get-Prop $_ 'agent'); uninstallSince = $(if (Get-Prop $_ 'uninstallOrder') { Format-Local ([string](Get-Prop $_ 'uninstallOrder').sentAt) } else { '' })
                incoming = $(if (Get-Prop $_ 'incoming') { [pscustomobject]@{ name = (Get-Prop $_ 'incoming').name; host = (Get-Prop $_ 'incoming').host; installed = (Get-Prop $_ 'incoming').installed } } else { $null })
            }
        })
}

# Traite une requête ; renvoie $true quand l'utilisateur demande à quitter
function Handle-WebRequest($Ctx, [string]$WebToken, [string]$HostHeader) {
    $req = $Ctx.Request; $path = $req.Url.AbsolutePath
    if ($req.Headers['Host'] -ne $HostHeader) { Send-Text $Ctx 'Hôte refusé.' 400; return $false }     # protège contre le « DNS rebinding »
    if ($path -eq '/favicon.ico') { Send-Bytes $Ctx ([byte[]]@()) 204 'image/x-icon'; return $false }
    if ($req.HttpMethod -eq 'GET' -and $path -eq '/') {
        if ($req.QueryString['t'] -cne $WebToken) { Send-Text $Ctx 'Accès refusé : ouvrez la page avec le lien affiché par Pg20-Clients.' 403; return $false }
        Send-Text $Ctx $script:WebHtml.Replace('__TOKEN__', $WebToken) 200 'text/html; charset=utf-8'
        return $false
    }
    # En-tête personnalisé obligatoire : un autre site web ne peut pas l'envoyer (il faudrait une autorisation CORS que nous ne donnons jamais)
    if ($req.Headers['X-Token'] -cne $WebToken) { Send-Json $Ctx @{ ok = $false; error = 'Jeton invalide : rouvrez la page depuis Pg20-Clients.' } 403; return $false }

    $body = $null
    if ($req.HttpMethod -eq 'POST') {
        if ($req.ContentLength64 -gt 8192) { Send-Json $Ctx @{ ok = $false; error = 'Requête trop grande.' } 413; return $false }
        $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8); $raw = $sr.ReadToEnd(); $sr.Dispose()
        if ($raw) { try { $body = $raw | ConvertFrom-Json } catch { Send-Json $Ctx @{ ok = $false; error = 'Requête illisible.' } 400; return $false } }
    }

    $route = "$($req.HttpMethod) $path"
    switch ($route) {
        'GET /api/state' {
            Send-Json $Ctx @{ ok = $true; clients = @(Get-WebClients ($req.QueryString['hidden'] -eq '1') $script:NewIds); server = $script:ServerInfo; usb = $script:UsbInfo }
            return $false
        }
        'POST /api/import' {
            $i = Import-Deployments
            $script:UsbInfo = @{ files = $i.files; message = "$($i.files) fichier(s) lu(s)" }
            $msg = if (-not $i.files) { 'Aucune clé USB avec des fiches clients détectée.' } else { "Clé USB : $($i.added) nouveau(x) client(s), $($i.updated) déjà connu(s)." }
            Send-Json $Ctx @{ ok = $true; message = $msg }
            return $false
        }
        'POST /api/sync' {
            $s = Invoke-FeedSync
            $script:ServerInfo = @{ ok = [bool]$s.ok; message = [string]$s.message; count = [int]$s.count }
            $script:NewIds = @($script:NewIds) + @($s.added | ForEach-Object { $_.id }) + @($s.received | ForEach-Object { $_.id })
            Send-Json $Ctx @{ ok = $true; message = [string]$s.message }
            return $false
        }
        'POST /api/quit' { Send-Json $Ctx @{ ok = $true; message = 'Au revoir.' }; return $true }
        { $_ -in 'POST /api/connect', 'POST /api/copy', 'POST /api/validate', 'POST /api/rename', 'POST /api/hide', 'POST /api/forget', 'POST /api/delete', 'POST /api/proof', 'POST /api/cancel-uninstall' } {
            $id = [string]$body.id
            if ($id -notmatch '^\d{6,12}$') { Send-Json $Ctx @{ ok = $false; error = 'ID invalide.' } 400; return $false }
            $rec = Find-Client $id
            if (-not $rec) { Send-Json $Ctx @{ ok = $false; error = 'Client introuvable.' } 404; return $false }
            switch ($path) {
                '/api/connect'  { Open-Client $rec; $msg = if ($DryRun) { 'Simulation : RustDesk n''a pas été ouvert.' } else { 'Ouverture de RustDesk…' } }
                '/api/copy'     {
                    if (-not $rec.pwd) { Send-Json $Ctx @{ ok = $false; error = 'Aucun mot de passe enregistré pour ce client.' } 400; return $false }
                    Copy-ClientPassword $rec; $msg = 'Mot de passe copié : effacé du presse-papiers dans 30 secondes.'
                }
                '/api/validate' { Confirm-Client $rec; Send-ServerValidated $rec; $msg = 'Poste validé.' }
                '/api/rename'   {
                    $name = (([string]$body.name) -replace '[\x00-\x1f]', '').Trim()
                    if ($name.Length -lt 1 -or $name.Length -gt 80) { Send-Json $Ctx @{ ok = $false; error = 'Nom invalide (1 à 80 caractères).' } 400; return $false }
                    $rec.name = $name; $rec.unknown = $false; Save-Store; $msg = 'Nom enregistré.'
                }
                '/api/hide'     {
                    if ($body.hidden) { $rec.status = 'Ignore'; $msg = 'Client masqué.' }
                    else { $rec.status = $(if ($rec.unknown) { 'A valider' } else { 'Valide' }); $msg = 'Client affiché.' }
                    Save-Store
                }
                '/api/forget'   { Forget-Client $rec; $msg = 'Client oublié : mot de passe effacé.' }
                '/api/proof'    {
                    try { $pp = Export-ConsentProof $rec } catch { Send-Json $Ctx @{ ok = $false; error = [string]$_.Exception.Message } 400; return $false }
                    if (-not $DryRun) { Start-Process explorer.exe -ArgumentList ('/select,"' + $pp + '"') }
                    $msg = "Preuve enregistrée : $pp"
                }
                '/api/cancel-uninstall' {
                    $cr = Cancel-UninstallOrder $rec
                    if (-not $cr.ok) { Send-Json $Ctx @{ ok = $false; error = [string]$cr.message } 502; return $false }
                    $msg = [string]$cr.message
                }
                '/api/delete'   {
                    $res = Remove-Client $rec
                    if (-not $res.ok) { Send-Json $Ctx @{ ok = $false; error = [string]$res.message } 502; return $false }
                    $msg = [string]$res.message
                }
            }
            Send-Json $Ctx @{ ok = $true; message = $msg }
            return $false
        }
        default { Send-Json $Ctx @{ ok = $false; error = 'Route inconnue.' } 404; return $false }
    }
}

function Start-WebUi {
    $htmlFile = Join-Path $PSScriptRoot 'Pg20-Clients-ui.html'
    if (-not (Test-Path $htmlFile)) { throw "Page introuvable : $htmlFile" }
    $script:WebHtml = Get-Content $htmlFile -Raw -Encoding UTF8
    $script:ServerInfo = @{ ok = $false; message = 'Serveur pas encore interrogé.'; count = 0 }
    $script:UsbInfo = @{ files = 0; message = '' }
    $script:NewIds = @()
    $tok = if ($Token) { $Token } else { New-WebToken }

    $listener = New-Object System.Net.HttpListener
    $bound = $null
    $candidates = if ($Port) { @($Port) } else { 1..40 | ForEach-Object { Get-Random -Minimum 49200 -Maximum 65000 } }
    foreach ($p in $candidates) {
        $listener.Prefixes.Clear(); $listener.Prefixes.Add("http://127.0.0.1:$p/")
        try { $listener.Start(); $bound = $p; break } catch { }
    }
    if (-not $bound) { throw 'Impossible de démarrer le serveur local (aucun port libre).' }
    $url = "http://127.0.0.1:$bound/?t=$tok"
    $hostHeader = "127.0.0.1:$bound"

    Write-Host ''
    Write-Host '=== Pg20 Info : clients ===' -ForegroundColor Green
    Write-Host "  L'interface s'ouvre dans votre navigateur : $url"
    Write-Host '  Laissez cette fenêtre ouverte. Pour arrêter : bouton « Quitter » dans la page, ou fermez cette fenêtre.' -ForegroundColor DarkGray
    if (-not $NoBrowser) { Start-Process $url }

    $last = Get-Date; $quit = $false
    try {
        while (-not $quit) {
            $task = $listener.GetContextAsync()
            while (-not $task.Wait(1000)) {
                if (((Get-Date) - $last).TotalMinutes -ge 45) { $quit = $true; Write-Host '  Inactif depuis 45 minutes : arrêt.' -ForegroundColor DarkGray; break }
            }
            if ($quit) { break }
            $ctx = $task.Result; $last = Get-Date
            try { $quit = [bool](Use-Store { Handle-WebRequest $ctx $tok $hostHeader }) }
            catch {
                try { Send-Json $ctx @{ ok = $false; error = $_.Exception.Message } 500 } catch { }
            }
        }
    }
    finally { $listener.Stop(); $listener.Close() }
}

# ---------------------------------------------------------------- Programme
$script:Store = @(Read-Store)
$script:ShowAll = $All.IsPresent

# ---------------------------------------------------------------- Désinstaller RustDesk chez un client
# Deux cas, selon le champ « agent » de la fiche du client :
#  - avec la tâche de maintenance (postes installés avec une version récente de l'exe) : le bouton « Désinstaller » dépose un ordre SIGNÉ sur le serveur ;
#    le poste le lit dans la demi-heure qui suit son allumage et se désinstalle seul, sans rien afficher ; le client disparaît ensuite de la liste tout
#    seul (Receive-OrderResults). Rien à faire pour le client.
#  - sans elle (anciens postes) : seule une session RustDesk permet d'agir. Le bouton prépare alors UNE commande autonome, la place dans le
#    presse-papiers, ouvre la session et guide l'opération. La commande vérifie l'ID du poste avant de toucher à quoi que ce soit
#    (Uninstall-RustDeskFully -ExpectedId, dans Deploy-RustDesk.ps1).
function Get-UninstallScript($Rec, [switch]$DryRun) {
    $id = [string]$Rec.id
    if ($id -notmatch '^\d{6,12}$') { throw 'ID de client invalide.' }
    $deploy = Join-Path $PSScriptRoot 'Deploy-RustDesk.ps1'
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($deploy, [ref]$tok, [ref]$err)
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Uninstall-RustDeskFully' }, $true)
    if (-not $fn) { throw 'Fonction de désinstallation introuvable dans Deploy-RustDesk.ps1.' }
    $call = "Uninstall-RustDeskFully -ExpectedId '$id'" + $(if ($DryRun) { ' -DryRun' } else { ' -NoticeSeconds 10' }) + ' | Out-Null'
    $fn.Extent.Text + "`r`n" + $call + "`r`n"
}

# Commande courte à coller dans un PowerShell ADMINISTRATEUR du client : le script (compressé, en base64) est décompressé puis exécuté sur place
function New-UninstallCommand($Rec, [switch]$DryRun) {
    $script = Get-UninstallScript $Rec -DryRun:$DryRun
    $ms = New-Object IO.MemoryStream
    $gz = New-Object IO.Compression.GzipStream($ms, [IO.Compression.CompressionMode]::Compress)
    $bytes = [Text.Encoding]::UTF8.GetBytes($script)
    $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    "iex ([IO.StreamReader]::new([IO.Compression.GzipStream]::new([IO.MemoryStream]::new([Convert]::FromBase64String('$b64')),[IO.Compression.CompressionMode]::Decompress),[Text.Encoding]::UTF8).ReadToEnd())"
}

# Confirmation par saisie : « Continuer » ne s'active que lorsque le texte saisi est EXACTEMENT celui attendu (le nom du client)
function Show-TypedConfirm($Owner, [string]$Title, [string]$Message, [string]$Expected, [scriptblock]$OnShown = $null) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $state = @{ ok = $false }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.ClientSize = New-Object System.Drawing.Size(540, 340)
    $f.StartPosition = $(if ($Owner) { 'CenterParent' } else { 'CenterScreen' })
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $msg = New-Object System.Windows.Forms.Label
    $msg.Text = $Message; $msg.UseMnemonic = $false
    $msg.Location = New-Object System.Drawing.Point(16, 14); $msg.Size = New-Object System.Drawing.Size(508, 190)
    $ask = New-Object System.Windows.Forms.Label
    $ask.Text = 'Pour confirmer, tapez exactement le nom du client :'
    $ask.Location = New-Object System.Drawing.Point(16, 212); $ask.Size = New-Object System.Drawing.Size(508, 22)
    $exp = New-Object System.Windows.Forms.Label
    $exp.Text = $Expected; $exp.UseMnemonic = $false; $exp.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $exp.Location = New-Object System.Drawing.Point(16, 236); $exp.Size = New-Object System.Drawing.Size(508, 22)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(16, 262); $tb.Size = New-Object System.Drawing.Size(508, 28)
    $go = New-Object System.Windows.Forms.Button
    $go.Text = 'Continuer'; $go.Enabled = $false; $go.ForeColor = [System.Drawing.Color]::FromArgb(179, 38, 30)
    $go.Location = New-Object System.Drawing.Point(16, 296); $go.Size = New-Object System.Drawing.Size(150, 36)
    $no = New-Object System.Windows.Forms.Button
    $no.Text = 'Annuler'; $no.Location = New-Object System.Drawing.Point(174, 296); $no.Size = New-Object System.Drawing.Size(110, 36)
    $f.Controls.AddRange(@($msg, $ask, $exp, $tb, $go, $no))
    $f.CancelButton = $no
    $tb.Add_TextChanged({ $go.Enabled = ($tb.Text.Trim().Length -gt 0 -and $tb.Text.Trim() -ieq $Expected.Trim()) })
    $go.Add_Click({ $state.ok = $true; $f.Close() })
    $no.Add_Click({ $f.Close() })
    $f.Add_Shown({
        $f.Activate(); $tb.Focus() | Out-Null
        if ($OnShown) { & $OnShown $f @{ text = $tb; ok = $go; cancel = $no } }
    })
    if ($Owner) { [void]$f.ShowDialog($Owner) } else { [void]$f.ShowDialog() }
    $f.Dispose()
    [bool]$state.ok
}

# Guide de l'opération pendant que la session RustDesk est ouverte. Renvoie 'remove' (« c'est terminé : retirer le client de la liste ») ou 'later'.
function Show-UninstallSteps($Owner, $Rec, [string]$Command, [scriptblock]$OnShown = $null) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $state = @{ result = 'later' }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "Désinstaller RustDesk chez $($Rec.name)"
    $f.ClientSize = New-Object System.Drawing.Size(620, 470)
    $f.StartPosition = $(if ($Owner) { 'CenterParent' } else { 'CenterScreen' })
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $text = New-Object System.Windows.Forms.Label
    $text.Text = "RustDesk s'ouvre sur « $($Rec.name) » (ID $(Format-RdId $Rec.id)). La commande de désinstallation est dans le presse-papiers.`n`n" +
        "Dans la session RustDesk :`n" +
        "  1. Clic droit sur le bouton Démarrer, puis « Windows PowerShell (administrateur) » (ou « Terminal (administrateur) »). Acceptez la demande de l'écran si elle apparaît.`n" +
        "  2. Collez la commande (clic droit dans la fenêtre, ou Ctrl+V), puis Entrée.`n" +
        "  3. La session RustDesk se coupe au bout de 10 secondes : c'est normal, la désinstallation continue sur le poste (le résultat reste noté dans C:\ProgramData\Pg20-Info chez le client). Si un message d'arrêt s'affiche avant (droits, mauvais poste), rien n'a été modifié.`n`n" +
        "La commande vérifie l'ID du poste ($($Rec.id)) avant de toucher à quoi que ce soit : sur un autre poste, elle ne fait rien.`n`n" +
        "Pour vérifier, quelques minutes plus tard : une connexion à ce poste doit échouer.`n`n" +
        "Quand c'est fait, retirez le client de la liste (ce PC, la clé USB et le serveur) avec le bouton du bas. Pas avant : si RustDesk reste installé chez le client, il se réenregistre et revient « À valider »."
    $text.UseMnemonic = $false
    $text.Location = New-Object System.Drawing.Point(16, 14); $text.Size = New-Object System.Drawing.Size(588, 360)

    $copy = New-Object System.Windows.Forms.Button
    $copy.Text = 'Copier la commande à nouveau'; $copy.Location = New-Object System.Drawing.Point(16, 384); $copy.Size = New-Object System.Drawing.Size(240, 36)
    $done = New-Object System.Windows.Forms.Button
    $done.Text = "C'est terminé : retirer le client de la liste…"; $done.ForeColor = [System.Drawing.Color]::FromArgb(179, 38, 30)
    $done.Location = New-Object System.Drawing.Point(16, 426); $done.Size = New-Object System.Drawing.Size(380, 36)
    $later = New-Object System.Windows.Forms.Button
    $later.Text = 'Plus tard'; $later.Location = New-Object System.Drawing.Point(404, 426); $later.Size = New-Object System.Drawing.Size(200, 36)
    $f.Controls.AddRange(@($text, $copy, $done, $later))
    $f.CancelButton = $later
    $copy.Add_Click({ Set-Clipboard -Value $Command; $copy.Text = 'Commande copiée' })
    $done.Add_Click({ $state.result = 'remove'; $f.Close() })
    $later.Add_Click({ $f.Close() })
    $f.Add_Shown({
        $f.Activate()
        if ($OnShown) { & $OnShown $f @{ copy = $copy; done = $done; later = $later } }
    })
    if ($Owner) { [void]$f.ShowDialog($Owner) } else { [void]$f.ShowDialog() }
    $f.Dispose()
    [string]$state.result
}

# Petite fenêtre « Se connecter à un client » : liste des clients VALIDÉS, recherche au clavier, Entrée ou double-clic ouvre RustDesk
# avec l'ID et le mot de passe déjà remplis. Les fiches « à valider » ne s'y trouvent pas (elles se traitent dans la page ou sur le téléphone).
function Show-QuickPicker {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $script:QuickAll = @(Use-Store { @($script:Store | Where-Object { $_.status -eq 'Valide' -and $_.pwd -and -not (Get-Prop $_ 'forgotten') } | Sort-Object { $_.name }) })
    $pending = @(Use-Store { @($script:Store | Where-Object { $_.status -eq 'A valider' -and -not (Get-Prop $_ 'forgotten') }) }).Count

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Pg20 Info : se connecter à un client'
    $f.ClientSize = New-Object System.Drawing.Size(620, 450)
    $f.StartPosition = 'CenterScreen'; $f.TopMost = $true; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Tapez pour chercher, puis Entrée ou double-clic pour vous connecter.'
    $hint.Location = New-Object System.Drawing.Point(14, 12); $hint.Size = New-Object System.Drawing.Size(592, 22)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(14, 40); $tb.Size = New-Object System.Drawing.Size(592, 28)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false; $lv.GridLines = $false
    $lv.Location = New-Object System.Drawing.Point(14, 76); $lv.Size = New-Object System.Drawing.Size(592, 258)
    [void]$lv.Columns.Add('Client', 330); [void]$lv.Columns.Add('ID', 110); [void]$lv.Columns.Add('Poste', 130)

    $note = New-Object System.Windows.Forms.Label
    $note.Location = New-Object System.Drawing.Point(14, 340); $note.Size = New-Object System.Drawing.Size(592, 54)      # 3 lignes : le message de suppression est long
    $note.UseMnemonic = $false
    $note.ForeColor = [System.Drawing.Color]::FromArgb(138, 82, 0)
    $note.Text = $(if ($pending) { "$pending fiche(s) à valider : ouvrez la page complète ou validez depuis le téléphone." } elseif (-not $script:QuickAll.Count) { 'Aucun client validé pour le moment.' } else { '' })

    $go = New-Object System.Windows.Forms.Button
    $go.Text = 'Se connecter'; $go.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $go.Location = New-Object System.Drawing.Point(14, 396); $go.Size = New-Object System.Drawing.Size(140, 40)
    $unin = New-Object System.Windows.Forms.Button
    $unin.Text = 'Désinstaller…'; $unin.ForeColor = [System.Drawing.Color]::FromArgb(138, 82, 0)
    $unin.Location = New-Object System.Drawing.Point(162, 396); $unin.Size = New-Object System.Drawing.Size(120, 40)
    $del = New-Object System.Windows.Forms.Button
    $del.Text = 'Supprimer…'; $del.ForeColor = [System.Drawing.Color]::FromArgb(179, 38, 30)
    $del.Location = New-Object System.Drawing.Point(290, 396); $del.Size = New-Object System.Drawing.Size(100, 40)
    $page = New-Object System.Windows.Forms.Button
    $page.Text = 'Page complète…'; $page.Location = New-Object System.Drawing.Point(398, 396); $page.Size = New-Object System.Drawing.Size(130, 40)
    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Fermer'; $close.Location = New-Object System.Drawing.Point(536, 396); $close.Size = New-Object System.Drawing.Size(70, 40)
    $f.AcceptButton = $go; $f.CancelButton = $close
    $f.Controls.AddRange(@($hint, $tb, $lv, $note, $go, $unin, $del, $page, $close))

    $fill = {
        $q = ($tb.Text -replace '\s', '').ToLower()
        $lv.BeginUpdate(); $lv.Items.Clear()
        foreach ($c in $script:QuickAll) {
            $hay = ($c.name + $c.id + $c.host) -replace '\s', ''
            if ($q -and $hay.ToLower().IndexOf($q) -lt 0) { continue }
            $it = New-Object System.Windows.Forms.ListViewItem(([string]$c.name) + $(if (Get-Prop $c 'uninstallOrder') { '  (désinstallation demandée)' } else { '' }))
            [void]$it.SubItems.Add((Format-RdId $c.id)); [void]$it.SubItems.Add([string]$c.host)
            $it.Tag = $c
            [void]$lv.Items.Add($it)
        }
        if ($lv.Items.Count) { $lv.Items[0].Selected = $true }
        $lv.EndUpdate()
    }
    $connect = {
        if ($lv.SelectedItems.Count) { Open-Client $lv.SelectedItems[0].Tag; $f.Close() }
    }
    # Suppression complète : PC + clé USB + serveur (voir Remove-Client). Le serveur est prévenu d'abord : injoignable = rien n'est supprimé.
    $remove = {
        if (-not $lv.SelectedItems.Count) { return }
        $rec = $lv.SelectedItems[0].Tag
        if (-not $AutoDelete) {
            $q = "Supprimer « $($rec.name) » (ID $(Format-RdId $rec.id)) ?`n`nIl sera retiré de ce PC (mot de passe effacé), de la clé USB si elle est branchée, et du serveur.`nSi RustDesk est encore installé chez le client, il se réenregistrera et réapparaîtra « À valider ».`n`nLes preuves d'acceptation déjà exportées (Documents\Pg20-Info-Preuves) sont conservées.`n`nAction définitive."
            if ([System.Windows.Forms.MessageBox]::Show($f, $q, 'Supprimer le client', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
        }
        $res = Use-Store { Remove-Client $rec }
        if ($res.ok) {
            $script:QuickAll = @($script:QuickAll | Where-Object { $_.id -ne $rec.id })
            $note.ForeColor = [System.Drawing.Color]::FromArgb(14, 122, 84); $note.Text = $res.message
            & $fill
        }
        elseif (-not $AutoDelete) { [void][System.Windows.Forms.MessageBox]::Show($f, [string]$res.message, 'Suppression impossible', 'OK', 'Error') }
        else { Write-Host ("ECHEC suppression : " + $res.message) }
    }
    $del.Add_Click($remove)
    # Désinstaller RustDesk chez le client. Trois cas :
    #  - une désinstallation est déjà demandée : on propose de l'ANNULER ;
    #  - le poste a la tâche de maintenance : confirmation par saisie du nom, puis ordre signé déposé sur le serveur (le poste se désinstalle seul,
    #    le client disparaît tout seul de la liste) ;
    #  - sinon (ancien poste) : confirmation par saisie du nom, commande prête dans le presse-papiers, session ouverte, guide, puis retrait du client.
    $uninstall = {
        if (-not $lv.SelectedItems.Count) { return }
        $rec = $lv.SelectedItems[0].Tag
        $okColor = [System.Drawing.Color]::FromArgb(14, 122, 84)
        $pend = Get-Prop $rec 'uninstallOrder'
        if ($pend) {
            $q = "Une désinstallation de « $($rec.name) » est déjà demandée (le $(Format-Local ([string]$pend.sentAt))).`n`nLe poste l'exécutera seul dès qu'il sera allumé et connecté à internet, puis disparaîtra de la liste.`n`nAnnuler cette demande ?"
            if ($AutoUninstall -or [System.Windows.Forms.MessageBox]::Show($f, $q, 'Désinstallation déjà demandée', 'YesNo', 'Question', 'Button2') -eq 'Yes') {
                $cr = Use-Store { $r = Find-Client $rec.id; if ($r) { Cancel-UninstallOrder $r } else { [pscustomobject]@{ ok = $false; message = 'Client introuvable.' } } }
                if ($cr.ok) { Clear-Props $rec @('uninstallOrder'); $note.ForeColor = $okColor; $note.Text = $cr.message; & $fill }
                elseif (-not $AutoUninstall) { [void][System.Windows.Forms.MessageBox]::Show($f, [string]$cr.message, 'Annulation impossible', 'OK', 'Error') }
                else { Write-Host ("ECHEC annulation : " + $cr.message) }
            }
            return
        }
        if (Get-Prop $rec 'agent') {
            $q = "Désinstaller RustDesk chez « $($rec.name) » (ID $(Format-RdId $rec.id)) ?`n`n" +
                 "• Vous ne pourrez plus vous connecter à ce poste.`n" +
                 "• Il se désinstallera tout seul dans les 30 minutes qui suivent son allumage, sans rien afficher : le client n'a rien à faire.`n" +
                 "• Il sera ensuite retiré de cette liste automatiquement.`n" +
                 "• Annulable tant que le poste n'a pas exécuté l'ordre."
            if (-not $AutoUninstall -and -not (Show-TypedConfirm $f 'Désinstaller RustDesk chez ce client' $q ([string]$rec.name))) { return }
            $sr = Use-Store { $r = Find-Client $rec.id; if ($r) { Send-UninstallOrder $r } else { [pscustomobject]@{ ok = $false; message = 'Client introuvable.'; order = $null } } }
            if ($sr.ok) {
                Set-Prop $rec 'uninstallOrder' $sr.order
                $note.ForeColor = $okColor
                $note.Text = "Ordre envoyé : $($rec.name) se désinstallera seul dans les 30 minutes qui suivent son allumage, puis disparaîtra de la liste."
                & $fill
                if (-not $AutoUninstall) {
                    [void][System.Windows.Forms.MessageBox]::Show($f, "Ordre envoyé.`n`n« $($rec.name) » se désinstallera tout seul dans les 30 minutes qui suivent son allumage (connecté à internet). Vous n'avez rien d'autre à faire : il sera retiré de la liste automatiquement (laissez la surveillance Pg20 active, ou ouvrez la page de temps en temps).`n`nVous pouvez annuler avec ce même bouton tant que ce n'est pas fait.", 'Désinstallation demandée', 'OK', 'Information')
                }
            }
            elseif (-not $AutoUninstall) { [void][System.Windows.Forms.MessageBox]::Show($f, [string]$sr.message, 'Ordre non envoyé', 'OK', 'Error') }
            else { Write-Host ("ECHEC ordre : " + $sr.message) }
            return
        }
        if ($AutoUninstall) { Write-Host 'MANUEL : ce poste n''a pas la tâche de maintenance.'; return }
        $q = "Désinstaller RustDesk chez « $($rec.name) » (ID $(Format-RdId $rec.id)) ?`n`n" +
             "• Vous ne pourrez plus vous connecter à ce poste.`n" +
             "• RustDesk, sa configuration et son identité seront effacés chez le client.`n" +
             "• Ce poste n'a pas la tâche de maintenance (installation plus ancienne) : cela se fait dans une session RustDesk ouverte sur ce poste, avec une commande que je prépare pour vous.`n`n" +
             "Cette opération ne se défait pas."
        if (-not (Show-TypedConfirm $f 'Désinstaller RustDesk chez ce client' $q ([string]$rec.name))) { return }
        $cmd = New-UninstallCommand $rec
        Set-Clipboard -Value $cmd
        $f.TopMost = $false                    # la fenêtre RustDesk qui s'ouvre ne doit pas être masquée par celle-ci
        Open-Client $rec
        if ((Show-UninstallSteps $f $rec $cmd) -eq 'remove') { & $remove }
    }
    $unin.Add_Click($uninstall)
    $tb.Add_TextChanged($fill)
    $tb.Add_KeyDown({ param($s, $e)
        if ($e.KeyCode -eq 'Down' -and $lv.Items.Count) { $i = [Math]::Min(($(if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Index } else { -1 })) + 1, $lv.Items.Count - 1); $lv.Items[$i].Selected = $true; $lv.EnsureVisible($i); $e.Handled = $true }
        elseif ($e.KeyCode -eq 'Up' -and $lv.Items.Count) { $i = [Math]::Max(($(if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Index } else { 1 })) - 1, 0); $lv.Items[$i].Selected = $true; $lv.EnsureVisible($i); $e.Handled = $true }
    })
    $lv.Add_DoubleClick($connect)
    $go.Add_Click($connect)
    $page.Add_Click({ Start-Process (Join-Path $PSScriptRoot 'Pg20-Clients.cmd'); $f.Close() })
    $close.Add_Click({ $f.Close() })
    & $fill
    $f.Add_Shown({
        $f.Activate(); $tb.Focus() | Out-Null
        if ($TestNote) { $note.ForeColor = [System.Drawing.Color]::FromArgb(14, 122, 84); $note.Text = $TestNote }
        if ($AutoPick -gt 0) {                                         # mode test : choix automatique, image, clic
            if ($lv.Items.Count -ge $AutoPick) { $lv.Items[$AutoPick - 1].Selected = $true }
            if ($ShotPath) {
                $bmp = New-Object System.Drawing.Bitmap($f.Width, $f.Height)
                $f.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $f.Width, $f.Height))); $bmp.Save($ShotPath); $bmp.Dispose()
            }
            if ($AutoDelete) { & $remove } elseif ($AutoUninstall) { & $uninstall } else { $go.PerformClick() }
            if (-not $f.IsDisposed) { $f.Close() }
        }
    })
    [void]$f.ShowDialog()
}

if ($Quick) { Show-QuickPicker; return }

if ($TestBalloon) {
    Show-Balloon 'Pg20 Info : test' 'Si vous voyez ce message, les notifications de la surveillance fonctionnent.'
    Start-Sleep -Seconds 8
    if ($script:ni) { $script:ni.Dispose() }
    return
}

if ($Watch) {
    # Une seule surveillance à la fois (la tâche de fond et un lancement à la main ne se doublent pas)
    $guard = New-Object System.Threading.Mutex($false, 'Pg20ClientsWatchRunning')
    $own = $false
    try { $own = $guard.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $own = $true }
    if (-not $own) { Write-Host 'Une surveillance tourne déjà : rien à faire.'; return }
    Write-Watch "Surveillance démarrée (toutes les $Interval s)." 'Cyan'
    $lastProblem = ''
    try {
        while ($true) {
            try {
                # Chaque tour : recharge la liste, lit la clé USB, interroge le serveur, enregistre ; une erreur ne tue pas la boucle
                $r = Use-Store { $null = Import-Deployments; Invoke-FeedSync }
                foreach ($n in @($r.added)) {
                    Write-Watch ("NOUVEAU POSTE : ID {0} (vu depuis {1})" -f (Format-RdId $n.id), $n.ip) 'Yellow'
                    Show-Balloon 'Pg20 Info : nouveau poste RustDesk' ("ID " + (Format-RdId $n.id) + " vient de s'enregistrer sur votre serveur.")
                }
                foreach ($n in @($r.received)) {
                    Write-Watch ("FICHE REÇUE : {0} (ID {1}), code {2}" -f $n.name, (Format-RdId $n.id), $n.code) 'Yellow'
                    Show-Balloon 'Pg20 Info : fiche reçue' ("$($n.name) vient de s'installer (code de contrôle $($n.code)). Validez depuis le téléphone ou ouvrez Pg20-Clients.")
                }
                foreach ($n in @($r.validated)) { Write-Watch ("VALIDÉ depuis le téléphone : {0} (ID {1})" -f $n.name, (Format-RdId $n.id)) 'Green' }
                foreach ($n in @($r.uninstalled)) {
                    Write-Watch ("DÉSINSTALLÉ à distance : {0} (ID {1}), retiré de la liste" -f $n.name, (Format-RdId $n.id)) 'Green'
                    Show-Balloon 'Pg20 Info : désinstallation terminée' ("$($n.name) s'est désinstallé tout seul : le client a été retiré de la liste.")
                }
                foreach ($n in @($r.expiredOrders)) { Write-Watch ("ORDRE PÉRIMÉ : {0} (ID {1}) n'a pas exécuté la désinstallation en 30 jours" -f $n.name, (Format-RdId $n.id)) 'Yellow' }
                if ($r.rejected) { Write-Watch "$($r.rejected) fiche(s) écartée(s) : illisible(s) ou fabriquée(s), effacée(s) du serveur." 'Red' }
                # Un problème (serveur injoignable...) n'est consigné qu'une fois, puis quand il disparaît : pas de répétition toutes les 20 s
                $problem = if ($r.ok) { '' } else { [string]$r.message }
                if ($problem -ne $lastProblem) { Write-Watch $(if ($problem) { $problem } else { 'Serveur de nouveau joignable.' }) 'DarkYellow'; $lastProblem = $problem }
            }
            catch {
                $problem = "Erreur : $($_.Exception.Message)"
                if ($problem -ne $lastProblem) { Write-Watch $problem 'Red'; $lastProblem = $problem }
            }
            Start-Sleep -Seconds $Interval
        }
    }
    finally { if ($script:ni) { $script:ni.Dispose() }; if ($own) { try { $guard.ReleaseMutex() } catch { } } }
    return
}

if ($Import -or $Sync -or $List -or $Connect -or $Forget) {
    Use-Store {
        if ($Import) { $i = Import-Deployments; Write-Host "  Import : $($i.added) ajouté(s), $($i.updated) mis à jour ($($i.files) fichier(s) lu(s))." }
        if ($Forget) {
            $v = @(Get-View); $rec = Resolve-Client $Forget $v; $nom = $rec.name
            Forget-Client $rec
            Write-Host "  $nom (ID $(Format-RdId $rec.id)) : oublié. Mot de passe effacé de ce PC ; l'ID reste masqué."
        }
        if ($Sync) { Show-SyncResult (Invoke-FeedSync) }
        if ($List) { Show-List }
        if ($Connect) { $v = @(Get-View); Open-Client (Resolve-Client $Connect $v) }
    }
    return
}

# --- Page web (par défaut) ou menu texte (-Console) ---
if (-not $Console) { Start-WebUi; return }

# --- Mode interactif en texte ---
Write-Host ''
Write-Host '=== Pg20 Info : clients ===' -ForegroundColor Green
$imp = Import-Deployments
if ($imp.files) { Write-Host "  Clé USB : $($imp.added) nouveau(x) client(s) importé(s), $($imp.updated) déjà connu(s)." -ForegroundColor Green }
else { Write-Host '  Aucune clé USB avec fiches clients détectée (branchez-la puis tapez i).' -ForegroundColor DarkGray }
$syncResult = Invoke-FeedSync
Show-SyncResult $syncResult
$newIds = @($syncResult.added | ForEach-Object { $_.id })

while ($true) {
    $script:Store = @(Read-Store)      # une surveillance en tâche de fond peut avoir modifié la liste entre-temps
    Show-List $newIds
    Write-Host ''
    Write-Host 'Numéro = se connecter | v N valider | c N copier le mot de passe | n N renommer | x N masquer | d N oublier (efface le mot de passe) | i importer la clé | s actualiser | a tout voir | q quitter' -ForegroundColor DarkCyan
    $in = (Read-Host 'Choix').Trim()
    if (-not $in -or $in -match '^[qQ]$') { break }
    try {
        $view = @(Get-View)
        if ($in -match '^[iI]$') { $i = Import-Deployments; Write-Host "  Import : $($i.added) ajouté(s), $($i.updated) mis à jour ($($i.files) fichier(s))."; continue }
        if ($in -match '^[sS]$') { $s = Invoke-FeedSync; Show-SyncResult $s; $newIds = @($s.added | ForEach-Object { $_.id }); continue }
        if ($in -match '^[aA]$') { $script:ShowAll = -not $script:ShowAll; continue }
        if ($in -match '^([vcnxdVCNXD])\s*(\d+)$') {
            $act = $Matches[1].ToLower(); $rec = Resolve-Client $Matches[2] $view
            switch ($act) {
                'v' { Confirm-Client $rec; Send-ServerValidated $rec; Write-Host "  $($rec.name) : validé." -ForegroundColor Green }
                'c' { Copy-ClientPassword $rec }
                'n' { $nom = (Read-Host "  Nouveau nom pour l'ID $(Format-RdId $rec.id)").Trim(); if ($nom) { $rec.name = $nom; $rec.unknown = $false; Save-Store } }
                'x' { $rec.status = 'Ignore'; Save-Store; Write-Host "  $($rec.name) : masqué (tapez a pour le revoir)." }
                'd' {
                    $ok = Read-Host "  Oublier $($rec.name) (ID $(Format-RdId $rec.id)) ? Son mot de passe sera effacé de ce PC. (o/N)"
                    if ($ok -match '^[oOyY]') { $nom = $rec.name; Forget-Client $rec; Write-Host "  $nom : oublié. Mot de passe effacé ; l'ID reste masqué (le serveur le connaît toujours)." -ForegroundColor Green }
                    else { Write-Host '  Annulé.' }
                }
            }
            continue
        }
        $rec = Resolve-Client $in $view
        if ($rec.status -eq 'A valider') {
            $ok = Read-Host "  $($rec.name) (ID $(Format-RdId $rec.id)) n'est pas validé. Se connecter quand même ? (o/N)"
            if ($ok -notmatch '^[oOyY]') { continue }
        }
        Open-Client $rec
    }
    catch { Write-Host "  ! $($_.Exception.Message)" -ForegroundColor Yellow }
}
