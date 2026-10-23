<#
.SYNOPSIS
    Info Pg20 : vos clients en un clic. Import automatique depuis la clé USB, validation des nouveaux postes, connexion RustDesk.

.DESCRIPTION
    - Importe seul les fiches des clients (nom, ID, mot de passe) depuis la clé USB branchée : plus rien à retaper.
    - Interroge votre serveur : tout poste qui s'enregistre et que vous n'avez pas installé vous-même est signalé "A VALIDER".
    - Ouvre la session RustDesk d'un client d'un seul geste (lien rustdesk:// avec l'ID et le mot de passe).
    Les mots de passe sont protégés par DPAPI : lisibles uniquement par votre compte Windows sur ce PC.

.EXAMPLE
    .\Pg20-Clients-Carnet.ps1                       # menu interactif
.EXAMPLE
    .\Pg20-Clients-Carnet.ps1 -Connect "Dupont"     # ouvre directement la session du client
.EXAMPLE
    .\Pg20-Clients-Carnet.ps1 -Watch                # surveille le serveur et notifie chaque nouveau poste
#>
[CmdletBinding()]
param(
    [switch]$Import,          # importe les clés USB branchées, puis quitte
    [switch]$CleanUnknown,    # postes connus du SERVEUR absents de tout carnet : les affiche et propose de les en retirer (ajout du 2026-10-10)
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
    [switch]$RestoreFromServer, # RECONSTRUIT le carnet depuis l'ARCHIVE chiffrée du serveur (PC perdu ou neuf) : nécessite la clé privée sauvegardée (Pg20-Technicien-Configurer.ps1 -RestoreFromBackup)
    [switch]$Yes,             # avec -RestoreFromServer : ne pas demander de confirmation
    [int]$PurgeDays = 180,    # purge automatique des postes masqués (voir plus bas) : utilisée SEULEMENT si vous demandez explicitement -PurgeDays N (0 = jamais ; minimum 30)
    [switch]$All,             # inclut les postes masqués
    [switch]$Console,         # ancien menu en mode texte au lieu de la page web
    [switch]$NoBrowser,       # (tests) ne pas ouvrir le navigateur
    [string]$Token,           # (tests) jeton de la page web imposé
    [int]$Port                # (tests) port de la page web imposé
)
$ErrorActionPreference = 'Stop'
# ---------------------------------------------------------------- Délais de conservation (décidés le 2026-10-10)
# Ces deux délais viennent des conditions signées par le client (version 2026-10-09, point 6), pas d'un choix de code :
#   - un poste REMPLACÉ par une réinstallation : « mise de côté puis effacée automatiquement, au plus tard 180 jours plus tard ».
#     On efface à 30 jours : plus tôt que le plafond promis, et assez tard pour se rattraper si le remplacement a été détecté à tort
#     (le poste est simplement masqué jusqu'à cette date, et « Afficher à nouveau » le rétablit sans rien effacer).
#   - un client qui RÉSILIE : la fiche et sa copie sur le serveur sont « effacées dans un délai de 30 jours » (point 6), et le
#     technicien s'engage à y procéder dans 30 jours (point 7). On efface donc à 30 jours, automatiquement.
# La preuve d'acceptation, elle, n'est jamais concernée : elle est archivée à part et conservée 1 an après la fin de la collaboration.
# (Les délais eux-mêmes sont écrits DANS les deux fonctions de purge — Invoke-PurgeReplaced et Invoke-PurgeResilie — avec un repli à
#  30 jours : ainsi chaque fonction reste juste même si elle est appelée hors de ce script. Avant ce repli, une constante absente
#  faisait sortir la fonction sans rien effacer, en silence : défaut trouvé au banc d'essai du 2026-10-10.)
# Garde-fou du 2026-10-10 : un intervalle nul ou négatif faisait tourner la surveillance en boucle serrée (Start-Sleep 0), surchargeant le
# poste et le serveur sans aucune pause. L'intervalle est borné entre 5 s et 1 heure.
if ($Interval -lt 5) { $Interval = 5 }
if ($Interval -gt 3600) { $Interval = 3600 }
. (Join-Path $PSScriptRoot 'Pg20-Commun.ps1')

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

# Écriture ATOMIQUE (correctif du 2026-10-10) : l'ancien Set-Content tronquait clients.json avant d'écrire. Une coupure, un disque plein
# ou un antivirus au mauvais moment laissait un JSON tronqué, que Read-Store ne pouvait plus relire : le carnet entier (tous les mots de
# passe) devenait inaccessible. On écrit maintenant à côté puis on remplace d'un bloc, et la version précédente est gardée en .bak.
function Save-Store {
    $p = Get-StorePath; $tmp = $p + '.tmp'
    $json = ConvertTo-Json -InputObject @($script:Store) -Depth 6
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($true)))
    $ok = $false
    if (Test-Path -LiteralPath $p) {
        try { [IO.File]::Replace($tmp, $p, ($p + '.bak'), $true); $ok = $true } catch { }
        if (-not $ok) {
            # Replace a échoué (fichier tenu par un autre programme, antivirus...) : l'ancienne version est gardée telle quelle, puis on remplace.
            try { Copy-Item -LiteralPath $p -Destination ($p + '.bak') -Force -ErrorAction Stop } catch { }
            try { [IO.File]::Delete($p); Move-Item -LiteralPath $tmp -Destination $p -Force -ErrorAction Stop; $ok = $true } catch { }
        }
    }
    else { try { Move-Item -LiteralPath $tmp -Destination $p -Force -ErrorAction Stop; $ok = $true } catch { } }
    if (-not $ok) {
        # Dernier recours : écrire directement (comme avant le correctif) plutôt que de perdre la modification en silence.
        try { [IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding($true))); $ok = $true } catch { }
    }
    if (-not $ok) {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
        throw ("Impossible d'enregistrer la liste des clients dans $p : vérifiez qu'un autre programme ne tient pas le fichier (antivirus, sauvegarde) et réessayez.")
    }
}

# Plusieurs instances peuvent tourner en même temps (page web ouverte + surveillance en tâche de fond). Chaque opération recharge donc la
# liste depuis le disque, travaille et l'enregistre sous un verrou commun : aucune instance ne réécrit une liste périmée par-dessus
# l'autre (une fiche déjà effacée du serveur serait perdue). Renvoie ce que produit le bloc.
function Use-Store([scriptblock]$Body) {
    # Verrou GLOBAL (préfixe « Global\ ») : sans ce préfixe, un mutex nommé n'existe QUE dans la session Windows qui l'a créé.
    # Deux sessions du même compte (bureau + RDP, ou deux sessions déconnectées) n'avaient donc AUCUNE exclusion mutuelle et
    # pouvaient réécrire le carnet l'une par-dessus l'autre (défaut relevé par l'audit de fragilité du 2026-10-10).
    # Repli : si la création du verrou global échoue (droits restreints), on garde l'ancien nom — mieux vaut un verrou par
    # session que pas de verrou du tout.
    $mutex = $null
    foreach ($nom in @('Global\Pg20ClientsStoreLock', 'Pg20ClientsStoreLock')) {
        try { $mutex = New-Object System.Threading.Mutex($false, $nom); break } catch { $mutex = $null }
    }
    if (-not $mutex) { throw 'impossible de créer le verrou de la liste des clients (droits insuffisants ?)' }
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
        if ($inc.PSObject.Properties['hw'] -and $inc.hw) { Set-Prop $Rec 'hw' ([string]$inc.hw) }
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
# Même précaution que Save-Store (correctif du 2026-10-10) : écriture à côté puis remplacement d'un bloc,
# avec les mêmes replis (Replace, remplacement simple, écriture directe) et une erreur claire plutôt qu'un échec muet.
function Save-Deleted($List) {
    $p = Get-DeletedPath; $tmp = $p + '.tmp'
    $json = ConvertTo-Json -InputObject @($List) -Depth 3
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($true)))
    $ok = $false
    if (Test-Path -LiteralPath $p) {
        try { [IO.File]::Replace($tmp, $p, ($p + '.bak'), $true); $ok = $true } catch { }
        if (-not $ok) {
            try { Copy-Item -LiteralPath $p -Destination ($p + '.bak') -Force -ErrorAction Stop } catch { }
            try { [IO.File]::Delete($p); Move-Item -LiteralPath $tmp -Destination $p -Force -ErrorAction Stop; $ok = $true } catch { }
        }
    }
    else { try { Move-Item -LiteralPath $tmp -Destination $p -Force -ErrorAction Stop; $ok = $true } catch { } }
    if (-not $ok) { try { [IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding($true))); $ok = $true } catch { } }
    if (-not $ok) {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
        throw ("Impossible d'enregistrer $p : vérifiez qu'un autre programme ne tient pas le fichier, puis réessayez.")
    }
}
function Find-Deleted([string]$Id) { Read-Deleted | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }
function Clear-Deleted([string]$Id) { Save-Deleted @(Read-Deleted | Where-Object { $_.id -ne $Id }) }
function Add-Deleted([string]$Id) {
    $l = @(Read-Deleted | Where-Object { $_.id -ne $Id }) + [pscustomobject]@{ id = $Id; deletedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    Save-Deleted $l
}

# ---------------------------------------------------------------- Postes ignorés (ajout du 2026-10-10)
# Un poste du serveur qui n'est pas dans le carnet devient une fiche « A valider ». C'est voulu (c'est ainsi qu'on repère une installation
# faite sans l'exe), mais cela fait réapparaître à chaque synchronisation VOTRE propre PC, enregistré sur votre serveur RustDesk : sa fiche
# est recréée indéfiniment, même après un « Supprimer ». Cette liste locale (ignores.json, dans %APPDATA%\Pg20-Info) dit : « cet ID-là, ne
# m'en parle plus ». Elle ne touche NI le serveur NI les fiches existantes : elle empêche seulement la recréation.
function Get-IgnoresPath { Join-Path (Get-Pg20Dir) 'ignores.json' }
function Read-Ignores {
    $p = Get-IgnoresPath
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    $raw = Get-Content $p -Raw -Encoding UTF8
    if (-not $raw.Trim()) { return @() }
    @($raw | ConvertFrom-Json | ForEach-Object { $_ })
}
function Save-Ignores($List) {
    $p = Get-IgnoresPath; $tmp = $p + '.tmp'
    $json = ConvertTo-Json -InputObject @($List) -Depth 3
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($true)))
    try { if (Test-Path -LiteralPath $p) { [IO.File]::Replace($tmp, $p, ($p + '.bak'), $true) } else { Move-Item -LiteralPath $tmp -Destination $p -Force } }
    catch { [IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding($true))) }
}
function Test-Ignored([string]$Id) { [bool](@(Read-Ignores) | Where-Object { [string]$_.id -eq [string]$Id } | Select-Object -First 1) }
function Add-Ignored([string]$Id, [string]$Motif = '') {
    $l = @(Read-Ignores | Where-Object { [string]$_.id -ne [string]$Id }) +
         [pscustomobject]@{ id = [string]$Id; addedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); why = [string]$Motif }
    Save-Ignores $l
}
function Remove-Ignored([string]$Id) { Save-Ignores @(Read-Ignores | Where-Object { [string]$_.id -ne [string]$Id }) }

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
        $readEnd = -1; if ($C.PSObject.Properties['readEnd']) { [void][int]::TryParse([string]$C.readEnd, [ref]$readEnd) }
        $mail = ''; if ($C.PSObject.Properties['email']) { $mail = (Limit-Text $C.email 120) }
        [pscustomobject]@{
            version = (Limit-Text $C.version 40); sha256 = $sha; mode = $mode; name = (Limit-Text $C.name 80); email = $mail; readEnd = $readEnd
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
    $mail = $(if ($c.PSObject.Properties['email'] -and $c.email) { " - $($c.email)" } else { '' })
    "Conditions acceptées le $when par $($c.name)$mail (texte v$($c.version))"
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
    if (-not $Dir -and $env:PG20_PROOF_DIR) { $Dir = $env:PG20_PROOF_DIR }      # (tests) dossier de preuves jetable : jamais le vrai dossier du technicien
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
    $txt = $(if ($found) { 'oui (' + $found.file + ')' } else { 'NON : placez le fichier de cette version dans le dossier « conditions » à côté de Pg20-Clients-Carnet.ps1' })
    $lines = @(
        "PREUVE D'ACCEPTATION DES CONDITIONS D'INSTALLATION", '',
        "Client                     : $($Rec.name)",
        "ID RustDesk                : $(Format-RdId $Rec.id)",
        "Poste                      : $($c.host)   (session Windows : $($c.user))",
        "Accepté par                : $($c.name)",
        "Adresse e-mail du client   : $(if ($c.PSObject.Properties['email'] -and $c.email) { $c.email } else { '(non saisie)' })",
        "Mode d'acceptation         : $how",
        "Date (horloge du PC)       : $(Format-Local ([string]$c.at))",
        "Date (réception serveur)   : $srv",
        "Durée de la fenêtre        : $($c.seconds) s",
        "Texte lu jusqu'à la fin    : $(if ($c.PSObject.Properties['readEnd'] -and [int]$c.readEnd -ge 0) { 'oui, après ' + $c.readEnd + ' s' } else { 'non contrôlé (ancienne version de la fenêtre, ou acceptation par paramètre)' })",
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
    # Correctif du 2026-10-10 : la pierre tombale (deleted.json) est posée AVANT que la fiche ne disparaisse du carnet. Dans l'ordre précédent
    # (carnet d'abord, tombe ensuite), un échec d'écriture de la tombe laissait le client absent du carnet mais sans protection : une ANCIENNE
    # ligne de la clé USB le faisait alors réapparaître comme « A VALIDER », alors qu'il venait d'être supprimé partout.
    Add-Deleted $id
    $usb = Remove-UsbRows $id
    $script:Store = @($script:Store | Where-Object { $_.id -ne $id })
    Save-Store
    $parts = @('retiré de ce PC', 'demande envoyée au serveur (effective en moins d''une minute)')
    if ($usb.removed) { $parts += "retiré de la clé USB ($($usb.removed) ligne(s))" }
    if ($usb.errors.Count) { $parts += "clé USB NON modifiée : $($usb.errors -join '; ')" }
    [pscustomobject]@{ ok = $true; message = "$name : " + ($parts -join ' ; ') + '.'; usbRows = $usb.removed }
}

# ---------------------------------------------------------------- Désinstallation automatique (ordre signé)
# Les postes installés avec la tâche de maintenance (champ « agent » de leur fiche, Pg20-Client-Maintenance.ps1) vont chercher, toutes les 3 minutes, un ordre
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
        $cmap = @{}; $amap = @{}; $hmap = @{}
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
                    if ($o.PSObject.Properties['consent'] -or $o.PSObject.Properties['agent'] -or $o.PSObject.Properties['hw']) {                     # enveloppe {v, id, agent, consent}
                        $cn = ConvertTo-Consent $o.consent ''
                        if ($o.PSObject.Properties['agent']) { $amap[$cid] = [bool]$o.agent }
                        if ($o.PSObject.Properties['hw'] -and ([string]$o.hw) -match '^[0-9a-f]{32}$') { $hmap[$cid] = [string]$o.hw }
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
            # Contrôle de date (correctif du 2026-10-10) : une ANCIENNE ligne de la clé (autre copie du support) écrasait sans condition la fiche
            # déjà enregistrée, mot de passe compris, et la validait d'office. La fiche serveur ayant été acquittée à la réception, le mot de passe
            # perdu ne pouvait plus être retrouvé : le technicien ne pouvait plus se connecter chez ce client. Une ligne plus ancienne passe
            # maintenant en attente de VOTRE décision dans la page (« A valider »), au lieu d'écraser la fiche.
            if ($rec -and -not (Get-Prop $rec 'incoming') -and -not (Get-Prop $rec 'viaServer') -and $pw -and $rec.pwd) {
                $newUtc = $null; $curUtc = $null
                try { $newUtc = [datetime]::ParseExact([string]$r.Date, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal).ToUniversalTime() } catch { }
                try { $curUtc = ConvertTo-Utc ([string]$rec.installed) } catch { }
                if ($newUtc -and $curUtc -and $newUtc -lt $curUtc) {
                    $curPwd = ''
                    try { $curPwd = Unprotect-Dpapi $rec.pwd } catch { }
                    if ($curPwd -ne $pw) {
                        $rec.status = 'A valider'
                        Set-Prop $rec 'incoming' ([pscustomobject]@{ name = [string]$r.Client; host = [string]$r.Poste; installed = [string]$r.Date; pwd = (Protect-Dpapi $pw) })
                        Write-Host ("  ! '$($r.Client)' (ID $(Format-RdId $id)) : ligne de la clé PLUS ANCIENNE que la fiche enregistrée ({0} contre {1}) : mise en attente, rien n'a été écrasé. Validez-la dans la page si c'est bien la bonne." -f [string]$r.Date, [string]$rec.installed) -ForegroundColor Yellow
                        continue
                    }
                }
            }
            if ($rec) { $updated++ } else { $rec = New-Client $id; $script:Store = @($script:Store) + $rec; $added++ }
            $rec.name = $r.Client; $rec.host = $r.Poste; $rec.installed = $r.Date; $rec.unknown = $false
            if ($cmap.ContainsKey($id)) { Set-Prop $rec 'consent' $cmap[$id] }
            if ($amap.ContainsKey($id)) { Set-Prop $rec 'agent' $amap[$id] }
            if ($hmap.ContainsKey($id)) { Set-Prop $rec 'hw' $hmap[$id] }
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

# ---------------------------------------------------------------- Poste réinstallé : l'ancien client est-il remplacé ?
# Un poste réinstallé avec une identité neuve (réinstallation propre de l'exe, Windows réinstallé) arrive avec un NOUVEL ID. Les anciens clients du même
# poste sont alors PROPOSÉS au remplacement : jamais retirés sans votre clic, proposition recalculée à chaque fois (elle ne dépend pas de la façon dont
# la fiche est arrivée, ni d'une validation depuis le téléphone). Deux raisons, dans les deux cas le même nom de poste est exigé :
#   « nom »    : même nom de client ;
#   « compte » : même compte Windows (celui qui a accepté les conditions) ET même adresse Internet vue par le serveur. Le nom du client est celui
#                tapé dans la fenêtre des conditions : il peut changer d'une installation à l'autre, d'où ce second critère.
# Seuls les clients PLUS ANCIENS que le nouveau sont proposés (jamais de proposition croisée) ; « Garder les deux » les écarte (champ keepBoth).
function Get-ReplaceReason($New, $Old) {
    $w1 = ([string](Get-Prop $New 'hw')).Trim(); $w2 = ([string](Get-Prop $Old 'hw')).Trim()
    if ($w1 -and $w1 -ceq $w2) { return 'materiel' }       # même ORDINATEUR (empreinte du matériel identique) : remplacé, quels que soient les noms
    $h1 = ([string]$New.host).Trim(); $h2 = ([string]$Old.host).Trim()
    if (-not $h1 -or $h1 -ine $h2) { return '' }
    $n1 = ([string]$New.name).Trim(); $n2 = ([string]$Old.name).Trim()
    if ($n1 -and $n1 -ieq $n2) { return 'nom' }
    $c1 = Get-Prop $New 'consent'; $c2 = Get-Prop $Old 'consent'
    $u1 = $(if ($c1) { ([string]$c1.user).Trim() } else { '' }); $u2 = $(if ($c2) { ([string]$c2.user).Trim() } else { '' })
    $i1 = ([string](Get-Prop $New 'ip')).Trim(); $i2 = ([string](Get-Prop $Old 'ip')).Trim()
    if ($u1 -and $u1 -ieq $u2 -and $i1 -and $i1 -eq $i2) { return 'compte' }
    ''
}
function Get-ReplaceReasonText([string]$Reason, $New) {
    if ($Reason -eq 'materiel') { return 'même ordinateur (empreinte du matériel identique)' }
    if ($Reason -eq 'nom') { return 'même nom de client et même nom de poste' }
    $c = Get-Prop $New 'consent'
    'même poste « ' + ([string]$New.host).Trim() + ' », même compte Windows « ' + $(if ($c) { ([string]$c.user).Trim() } else { '' }) + ' » et même adresse Internet'
}
function Find-ReplacedClients($Rec) {
    if ([bool]$Rec.unknown -or -not ([string]$Rec.installed)) { return @() }
    $keep = @(Get-Prop $Rec 'keepBoth' | Where-Object { $_ } | ForEach-Object { [string]$_ })
    @($script:Store | Where-Object {
            $_.id -ne $Rec.id -and -not (Get-Prop $_ 'forgotten') -and -not [bool]$_.unknown -and $_.pwd -and
            ([string]$_.installed) -and ([string]$_.installed) -lt ([string]$Rec.installed) -and $keep -notcontains [string]$_.id -and
            (Get-ReplaceReason $Rec $_)
        } | Sort-Object { [string]$_.installed } -Descending | Select-Object -First 8)
}
function Get-ReplacedClients($Rec) { Find-ReplacedClients $Rec }
function Get-WebReplaces($New) {
    @(Find-ReplacedClients $New | ForEach-Object {
            [pscustomobject]@{ id = [string]$_.id; idText = (Format-RdId $_.id); name = [string]$_.name; host = [string]$_.host; installed = [string]$_.installed
                               status = [string]$_.status; reason = (Get-ReplaceReasonText (Get-ReplaceReason $New $_) $New) }
        })
}
function Format-ReplacesHint($Ids) {
    if (@($Ids).Count) { ' ; semble remplacer l''ancien poste (ID ' + ((@($Ids) | ForEach-Object { Format-RdId $_ }) -join ', ') + ')' } else { '' }
}
# Nettoyage automatique de la liste « Se connecter » : un ancien poste remplacé par une réinstallation VALIDÉE du même poste (mêmes règles que « Remplacer
# l'ancien » : même nom de poste et même nom de client, ou même compte Windows et même adresse Internet ; seulement plus ancien) est MASQUÉ, jamais supprimé :
# son mot de passe reste enregistré et on le rétablit d'un clic (page : « Afficher les masqués », menu ⋯ « Afficher à nouveau » ; « Garder les deux » le rétablit
# aussi). Ne touche ni le serveur ni la clé USB. Ignore un ancien déjà masqué, rétabli à la main (autoHideOff) ou dont une désinstallation est demandée.
function Invoke-AutoHideReplaced {
    $hidden = @()
    foreach ($nw in @($script:Store | Where-Object { $_.status -eq 'Valide' -and $_.pwd -and -not (Get-Prop $_ 'forgotten') } | Sort-Object { [string]$_.installed })) {
        foreach ($old in @(Find-ReplacedClients $nw)) {
            if ($old.status -ne 'Valide' -or (Get-Prop $old 'autoHideOff') -or (Get-Prop $old 'uninstallOrder')) { continue }
            $old.status = 'Ignore'
            Set-Prop $old 'autoHidden' ([pscustomobject]@{ by = [string]$nw.id; byName = [string]$nw.name; at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') })
            $hidden += [pscustomobject]@{ id = [string]$old.id; name = [string]$old.name; by = [string]$nw.id; byName = [string]$nw.name }
        }
    }
    if ($hidden.Count) { Save-Store }
    $hidden
}

# Purge des postes MASQUÉS depuis longtemps. ATTENTION (correctif du 2026-10-10) : cette fonction SUPPRIME POUR DE BON (carnet, clé USB branchée,
# serveur). Elle n'est donc plus appelée automatiquement par la surveillance : elle exige une demande EXPLICITE (-PurgeDays N sur la ligne de
# commande). Avant ce correctif, elle tournait à chaque synchronisation avec 180 jours par défaut et supprimait aussi les postes que vous aviez
# masqués VOUS-MÊME, alors que la page annonce qu'ils restent enregistrés avec leur mot de passe. Le jour du masquage est noté (hiddenAt) ; les
# postes déjà masqués repartent d'un délai complet. Jamais purgés : les postes « oubliés », ceux dont une désinstallation est en cours, ceux qui ne
# sont pas masqués. La PREUVE d'acceptation est enregistrée avant la suppression (Documents\Pg20-Info-Preuves) et survit. 5 postes par passage au plus.
function Invoke-AutoPurgeHidden([int]$Days = 180, [datetime]$Now = [datetime]::UtcNow, [switch]$AlsoManuallyHidden) {
    $purged = @()
    if ($Days -le 0) { return $purged }
    if ($Days -lt 30) { $Days = 30 }
    $dirty = $false
    foreach ($rec in @($script:Store)) {
        if ($rec.status -ne 'Ignore') { if (Get-Prop $rec 'hiddenAt') { Clear-Props $rec @('hiddenAt'); $dirty = $true }; continue }
        if ((Get-Prop $rec 'forgotten') -or (Get-Prop $rec 'uninstallOrder')) { continue }
        if (-not (Get-Prop $rec 'hiddenAt')) {
            $ah = Get-Prop $rec 'autoHidden'
            $since = $(if ($ah -and $ah.at) { [string]$ah.at } else { $Now.ToString('yyyy-MM-ddTHH:mm:ssZ') })
            Set-Prop $rec 'hiddenAt' $since; $dirty = $true
        }
    }
    if ($dirty) { Save-Store }
    foreach ($rec in @($script:Store | Where-Object { $_.status -eq 'Ignore' -and -not (Get-Prop $_ 'forgotten') -and -not (Get-Prop $_ 'uninstallOrder') -and (Get-Prop $_ 'hiddenAt') })) {
        if ($purged.Count -ge 5) { break }
        $age = $null; try { $age = ($Now - (ConvertTo-Utc ([string](Get-Prop $rec 'hiddenAt')))).TotalDays } catch { }
        if ($null -eq $age -or $age -lt $Days) { continue }
        # Un poste masqué À LA MAIN (pas par le nettoyage automatique des remplacements) n'est purgé que si vous l'avez demandé explicitement.
        if (-not (Get-Prop $rec 'autoHidden') -and -not $AlsoManuallyHidden) { continue }
        $name = [string]$rec.name; $id = [string]$rec.id
        try { if (Get-Prop $rec 'consent') { [void](Save-ConsentProofAuto $rec) } } catch { }
        $r = Remove-Client $rec
        if (-not $r.ok) { break }                 # serveur injoignable : rien n'est supprimé, on réessaie au prochain passage
        $purged += [pscustomobject]@{ id = $id; name = $name; days = [int][math]::Floor($age) }
    }
    $purged
}

# ---------------------------------------------------------------- Purge AUTOMATIQUE (ajout du 2026-10-10, decision du technicien)
# Deux suppressions qui se font toutes seules, parce qu'elles decoulent du contrat et non d'un choix de rangement :
#   1. un poste REMPLACE par une reinstallation validee : masque par Invoke-AutoHideReplaced, puis EFFACE apres 30 jours
#      (les conditions promettent « au plus tard 180 jours » : 30 est plus tot, et laisse une marge de rattrapage) ;
#   2. un client RESILIE (fonction Stop-ClientService) : sa fiche est EFFACEE 30 jours apres la resiliation, comme promis.
# Ces deux fonctions sont appelees par la synchronisation et par la surveillance. Elles n'effacent que ce qui est PROUVE trop vieux
# (une date enregistree au moment du masquage ou de la resiliation), jamais « au juge », et au plus 5 fiches par passage.
# Rien n'est efface si le serveur est injoignable : Remove-Client refuse alors de supprimer, et on reessaie au passage suivant.

# Efface les postes REMPLACES, masques depuis plus de 30 jours. Renvoie la liste des postes effaces.
function Invoke-PurgeReplaced([int]$Days = 0, [datetime]$Now = [datetime]::UtcNow) {
    $purged = @()
    # 30 jours = delai promis par les conditions (point 6). La valeur est ecrite ICI, pas dans une constante du script :
    # une constante absente ferait sortir la fonction sans rien effacer, en silence (piege constate au banc d'essai).
    if ($Days -le 0) { $Days = 30 }
    if (-not $script:PurgeParPassage) { $script:PurgeParPassage = 5 }
    $liste = @($script:Store | Where-Object { $_.status -eq 'Ignore' -and (Get-Prop $_ 'autoHidden') -and -not (Get-Prop $_ 'forgotten') -and -not (Get-Prop $_ 'uninstallOrder') })
    foreach ($rec in $liste) {
        if ($purged.Count -ge [int]$script:PurgeParPassage) { break }
        $ah = Get-Prop $rec 'autoHidden'
        $age = $null
        try { if ($ah -and $ah.at) { $age = ($Now - (ConvertTo-Utc ([string]$ah.at))).TotalDays } } catch { }
        if ($null -eq $age -or $age -lt $Days) { continue }
        $name = [string]$rec.name; $id = [string]$rec.id; $par = [string]$ah.byName
        # preuve d'acceptation : enregistree AVANT la suppression (elle survit, c'est la piece contractuelle)
        try { [void](Save-ConsentProofAuto $rec) } catch { }
        $r = Remove-Client $rec
        if (-not $r.ok) { break }                  # serveur injoignable : rien n'est supprime, on reessaie plus tard
        $purged += [pscustomobject]@{ id = $id; name = $name; days = [int][math]::Floor($age); byName = $par }
    }
    $purged
}

# Efface les fiches des clients RESILIES, 30 jours apres la resiliation (conditions, point 6).
function Invoke-PurgeResilie([int]$Days = 0, [datetime]$Now = [datetime]::UtcNow) {
    $purged = @()
    if ($Days -le 0) { $Days = 30 }                 # 30 jours : délai du contrat (point 6), écrit ici et non dans une constante externe
    if (-not $script:PurgeParPassage) { $script:PurgeParPassage = 5 }
    foreach ($rec in @($script:Store | Where-Object { $_.status -eq 'Ignore' -and (Get-Prop $_ 'resilie') -and -not (Get-Prop $_ 'forgotten') })) {
        if ($purged.Count -ge [int]$script:PurgeParPassage) { break }
        $ra = Get-Prop $rec 'resilie'
        $age = $null
        try { if ($ra -and $ra.at) { $age = ($Now - (ConvertTo-Utc ([string]$ra.at))).TotalDays } } catch { }
        if ($null -eq $age -or $age -lt $Days) { continue }
        $name = [string]$rec.name; $id = [string]$rec.id
        try { [void](Save-ConsentProofAuto $rec) } catch { }
        $r = Remove-Client $rec
        if (-not $r.ok) { break }
        $purged += [pscustomobject]@{ id = $id; name = $name; days = [int][math]::Floor($age) }
    }
    $purged
}

# ---------------------------------------------------------------- Resiliation d'un client (ajout du 2026-10-10, demande du technicien)
# Ce que le contrat promet a la fin de la collaboration (conditions 2026-10-09, points 6, 7 et 9) : le technicien ENVOIE l'ordre de
# desinstallation (le poste se retire seul) et EFFACE la fiche dans les 30 jours. Cette fonction fait exactement cela, et rien d'autre :
#   1. envoie l'ordre de desinstallation signe (le poste se desinstalle seul, en 3 minutes s'il est allume) ;
#   2. archive la preuve d'acceptation (conservee 1 an apres la fin de la collaboration, elle N'EST PAS effacee) ;
#   3. programme l'effacement de la fiche a 30 jours (Invoke-PurgeResilie s'en charge ensuite, automatiquement).
# Si l'ordre ne peut pas etre envoye (serveur injoignable), RIEN n'est modifie : on reessaie plus tard.
function Stop-ClientService($Rec) {
    $id = [string]$Rec.id
    # Cette fonction s'utilise en usage NORMAL (bouton « Résilier… ») : sa protection n'est pas une variable d'environnement
    # (elle rendrait le bouton inutilisable) mais la CONFIRMATION affichée dans la fenêtre, qui annonce les trois conséquences.
    if (-not $id) { return [pscustomobject]@{ ok = $false; message = 'fiche sans identifiant : rien n''a ete fait.'; order = $null; purgeAt = $null } }
    $deja = Get-Prop $Rec 'resilie'
    if ($deja) { return [pscustomobject]@{ ok = $false; message = ('ce client etait deja marque resilie (effacement prevu le ' + (Format-LocalDate ([string]$deja.purgeAt)) + ').'); order = $null; purgeAt = $null } }
    $o = Send-UninstallOrder $Rec
    if (-not $o.ok) { return [pscustomobject]@{ ok = $false; message = ([string]$o.message + ' Rien n''a ete modifie : la fiche est intacte, reessayez quand le serveur repond.'); order = $null; purgeAt = $null } }
    # preuve d'acceptation : archivee AVANT tout le reste (elle doit survivre a l'effacement de la fiche)
    try { [void](Save-ConsentProofAuto $Rec) } catch { }
    $at = (Get-Date).ToUniversalTime()
    $atIso = $at.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $delai = 30                                      # délai promis par les conditions (point 6) : écrit ici, jamais dans une constante externe
    $purgeIso = $at.AddDays($delai).ToString('yyyy-MM-ddTHH:mm:ssZ')
    Set-Prop $Rec 'resilie' ([pscustomobject]@{ at = $atIso; purgeAt = $purgeIso; orderNonce = [string]$o.order.nonce })
    $Rec.status = 'Ignore'
    # le masquage est memorise : le poste reste consultable dans « Afficher les masques » jusqu'a l'effacement
    if (-not (Get-Prop $Rec 'hiddenAt')) { Set-Prop $Rec 'hiddenAt' $atIso }
    Save-Store
    Write-Watch ("RESILIATION : « $($Rec.name) » (ID $id) — ordre de desinstallation envoye, fiche a effacer le " + $at.AddDays($delai).ToLocalTime().ToString('dd.MM.yyyy')) 'Yellow'
    [pscustomobject]@{ ok = $true; message = 'ordre envoye'; order = $o.order; purgeAt = $purgeIso }
}

# ---------------------------------------------------------------- Postes que le SERVEUR connaît sans qu'ils soient dans le carnet (ajout du 2026-10-10)
# Un poste s'inscrit sur le serveur RustDesk dès qu'il s'y connecte (poste de test, ancien poste oublié, PC du technicien, poste d'un client
# désinstallé à la main...). La synchronisation en crée une fiche « A valider » — c'est voulu — mais quand on ne veut PAS de ce poste, sa fiche
# revient indéfiniment. Ces deux fonctions permettent de VOIR ces postes et de les retirer DU SERVEUR (pas de vos fiches), ce qui les fait
# disparaître pour de bon. Liste locale des ignorés : voir Test-Ignored / Add-Ignored plus haut.
function Find-UnknownPeers {
    <# Renvoie les postes du serveur qui ne sont ni dans le carnet, ni dans la liste des ignorés.
       Lecture seule : aucune modification, ni ici ni sur le serveur. #>
    $cfg = Get-FeedConfig
    if (-not $cfg) { return [pscustomobject]@{ ok = $false; message = 'accès au serveur non configuré (voir Pg20-Technicien-Configurer.ps1 -FeedUrl ... -FeedToken ...)'; unknown = @(); total = 0 } }
    try {
        $token = Unprotect-Dpapi $cfg.token
        $feed = Invoke-RestMethod -Uri ($cfg.url + '/peers') -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 8
    }
    catch { return [pscustomobject]@{ ok = $false; message = "serveur injoignable : $($_.Exception.Message)"; unknown = @(); total = 0 } }
    $tous = @($feed.peers | Where-Object { $_ })
    $liste = @()
    foreach ($p in $tous) {
        $id = [string]$p.id
        if (-not $id) { continue }
        if (Find-Client $id) { continue }            # dans le carnet : ce n'est pas un inconnu
        if (Test-Ignored $id) { continue }           # volontairement ignoré : il n'est plus proposé
        $liste += [pscustomobject]@{ id = $id; firstSeen = [string]$p.first_seen; ip = [string]$p.ip }
    }
    [pscustomobject]@{ ok = $true; message = ''; unknown = @($liste); total = $tous.Count }
}

function Remove-UnknownPeers {
    <# Retire du SERVEUR les postes désignés (Find-UnknownPeers). Ne touche NI le carnet NI la clé USB.
       Chaque retrait est une demande /peers/forget : le serveur copie sa base puis supprime le poste (quelques secondes).
       Un échec n'interrompt pas les suivants : le bilan dit lesquels sont partis. #>
    param([Parameter(Mandatory = $true)][string[]]$Ids)
    $partis = @(); $echecs = @()
    foreach ($id in @($Ids | Select-Object -Unique)) {
        if ($id -notmatch '^\d{6,12}$') { $echecs += [pscustomobject]@{ id = $id; pourquoi = 'identifiant invalide' }; continue }
        if (Find-Client $id) { $echecs += [pscustomobject]@{ id = $id; pourquoi = 'présent dans le carnet : refusé' }; continue }
        $r = Send-ServerForget $id
        if ($r.ok) { $partis += $id } else { $echecs += [pscustomobject]@{ id = $id; pourquoi = [string]$r.message } }
    }
    [pscustomobject]@{ ok = ($echecs.Count -eq 0); removed = @($partis); failed = @($echecs) }
}

function Show-UnknownPeers {
    <# Affiche les postes connus du SERVEUR qui ne sont dans aucun carnet, puis propose (une seule question) de les en retirer.
       Sert à faire le ménage : postes de test, anciens postes désinstallés à la main, PC du technicien... #>
    $r = Find-UnknownPeers
    if (-not $r.ok) { Write-Host "  $($r.message)" -ForegroundColor Yellow; return }
    if (-not $r.unknown.Count) {
        Write-Host ('  Aucun poste inconnu : les ' + $r.total + ' poste(s) du serveur sont tous dans le carnet ou dans la liste des ignorés.') -ForegroundColor Green
        return
    }
    Write-Host ('  ' + $r.unknown.Count + ' poste(s) connu(s) du serveur mais absent(s) du carnet (sur ' + $r.total + ') :') -ForegroundColor Cyan
    foreach ($u in $r.unknown) {
        Write-Host ('    ID {0,-14} première connexion le {1}  (adresse {2})' -f (Format-RdId $u.id), (Format-Local $u.firstSeen), $(if ($u.ip) { $u.ip } else { 'inconnue' }))
    }
    Write-Host '  Ils ne figurent pas dans la liste parce qu''ils portent le statut « Ignore » ou parce qu''ils ont été supprimés de ce carnet.'
    $ok = Read-Host '  Les retirer DU SERVEUR (ils disparaîtront pour de bon) ? (o/N)'
    if ($ok -notmatch '^[oOyY]') { Write-Host '  Rien n''a été modifié.' ; return }
    $res = Remove-UnknownPeers -Ids @($r.unknown | ForEach-Object { $_.id })
    foreach ($id in $res.removed) { Write-Host ('  retiré du serveur : ID ' + (Format-RdId $id)) -ForegroundColor Green }
    foreach ($e in $res.failed) { Write-Host ('  NON retiré : ID ' + (Format-RdId $e.id) + ' (' + $e.pourquoi + ')') -ForegroundColor Yellow }
    if ($res.removed.Count) { Write-Watch ('NETTOYAGE serveur : ' + $res.removed.Count + ' poste(s) inconnu(s) retiré(s) du serveur') }
}
# Adresse Internet d'un client : celle vue par le serveur lors de la dernière inscription du poste (mise à jour à chaque synchronisation). Un changement
# (portable déplacé, autre réseau) est mémorisé (ipPrev, ipChangedAt) et signalé : fenêtre « Se connecter » (7 jours), page (30 jours), journal.
function Get-IpChangeAge($Rec) {
    $t = [string](Get-Prop $Rec 'ipChangedAt')
    if (-not $t) { return $null }
    try { ((Get-Date).ToUniversalTime() - (ConvertTo-Utc $t)).TotalDays } catch { $null }
}
function Get-RecentIpPrev($Rec, [double]$Days = 30) {
    $age = Get-IpChangeAge $Rec
    if ($null -ne $age -and $age -le $Days) { [string](Get-Prop $Rec 'ipPrev') } else { '' }
}
function Format-PickerIp($Rec) {
    $ip = ([string](Get-Prop $Rec 'ip')).Trim()
    if (-not $ip) { return '' }
    if (Get-RecentIpPrev $Rec 7) { "$ip (nouvelle)" } else { $ip }
}# Nom affiché dans la fenêtre « Se connecter » : signale un ancien poste qui semble remplacé par une réinstallation plus récente
function Format-PickerName($Rec) {
    ([string]$Rec.name) + $(if (Get-Prop $Rec 'uninstallOrder') { '  (désinstallation demandée)' } else { '' }) +
        $(if ($script:ReplacedBy -and $script:ReplacedBy.ContainsKey([string]$Rec.id)) { '  (remplacé par ' + $script:ReplacedBy[[string]$Rec.id] + ' ?)' } else { '' })
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

    # $cleOk : la clé privée du technicien est-elle lisible ? Si elle ne l'est pas (DPAPI illisible, profil recréé, carnet
    # restauré sur un autre PC), AUCUNE fiche n'est acquittée : elle restent sur le serveur au lieu d'être detruites, et le
    # message le dit. Sans cette précaution, une panne locale faisait classer des fiches légitimes en « écartées » ET les
    # supprimait du serveur : perte définitive, sans trace (défaut relevé par l'audit de fragilité du 2026-10-10).
    $cleOk = $true
    try { $null = Get-TechPrivateKeyXml } catch { $cleOk = $false }
    $ack = @()
    foreach ($r in $recs) {
        $id = [string]$r.id
        $code = [string]$r.code; if ($code -notmatch '^\d{4}$') { $code = '' }
        # Exceptions locales (clé, DPAPI, disque, mémoire) : la fiche N'EST PAS acquittée, elle revient au prochain passage.
        try { $f = Unprotect-Envelope ([string]$r.blob) }
        catch {
            Write-Host "  ! fiche reçue pour l'ID $id CONSERVÉE sur le serveur : $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Watch ("fiche conservée sur le serveur (non acquittée) : ID $id — $($_.Exception.Message)") 'Yellow'
            $res.message = 'une ou plusieurs fiches n''ont pas pu être ouvertes : elles restent sur le serveur'
            continue
        }
        # Fiche réellement illisible ou fabriquée : celle-là est écartée (et acquittée en fin de fonction).
        try {
            $name = (([string]$f.name) -replace '[\x00-\x1f]', '').Trim()
            $pw   = [string]$f.password
            if ([int]$f.v -ne 1 -or [string]$f.id -ne $id -or $name.Length -lt 1 -or $name.Length -gt 80 -or $pw.Length -lt 12 -or $pw.Length -gt 128 -or $pw -match '[\s\x00-\x1f]') {
                throw 'fiche invalide (contenu)'
            }
            $hostName = (([string]$f.host) -replace '[\x00-\x1f]', '').Trim(); if ($hostName.Length -gt 63) { $hostName = $hostName.Substring(0, 63) }
            $when = Format-Local ([string]$f.ts)
            $consent = ConvertTo-Consent $f.consent ([string]$r.received_at)      # preuve d'acceptation (heure du serveur ajoutée) ; $null si l'exe n'en avait pas
            $hwFp = [string]$f.hw; if ($hwFp -notmatch '^[0-9a-f]{32}$') { $hwFp = '' }        # empreinte du matériel (absente des anciennes fiches)
            $agentFlag = [bool]($f.PSObject.Properties['agent'] -and $f.agent)    # le poste a la tâche de maintenance : désinstallation à distance possible
            $replIds = @()                                                         # anciens postes que cette fiche semble remplacer (même nom de client et de poste)

            if (Find-Deleted $id) { Clear-Deleted $id }          # une fiche reçue est une nouvelle installation : le client supprimé réapparaît
            $rec = Find-Client $id
            $forgotten = $rec -and (Get-Prop $rec 'forgotten')
            $same = $rec -and -not $forgotten -and $rec.pwd -and ((Unprotect-Dpapi $rec.pwd) -eq $pw) -and $rec.name -eq $name
            if ($same) { if ($consent -and -not (Get-Prop $rec 'consent')) { Set-Prop $rec 'consent' $consent }; Set-Prop $rec 'agent' $agentFlag; if ($hwFp) { Set-Prop $rec 'hw' $hwFp }; continue }                 # déjà connue à l'identique (fiche aussi relevée sur la clé USB) : rien à faire
            if (-not $rec) { $rec = New-Client $id; $script:Store = @($script:Store) + $rec }
            if ($forgotten) { Clear-Props $rec @('forgotten'); $rec.status = 'A valider' }
            if (-not $rec.pwd -or $forgotten -or ($rec.unknown -and $rec.status -eq 'A valider')) {
                # Poste encore sans données (inconnu, ou oublié) : la fiche le renseigne tout de suite, il reste « A valider »
                $rec.name = $name; $rec.host = $hostName; $rec.installed = $when; $rec.unknown = $false; $rec.status = 'A valider'; $rec.pwd = Protect-Dpapi $pw
                Clear-Props $rec @('incoming')
                if ($consent) { Set-Prop $rec 'consent' $consent }
                Set-Prop $rec 'agent' $agentFlag; if ($hwFp) { Set-Prop $rec 'hw' $hwFp }
                Set-Prop $rec 'viaServer' $true; Set-Prop $rec 'code' $code
                $replIds = @(Find-ReplacedClients $rec | ForEach-Object { [string]$_.id })
            }
            else {
                # Client déjà connu avec d'autres données : la fiche attend votre validation (elle n'écrase rien d'avance)
                Set-Prop $rec 'incoming' ([pscustomobject]@{ name = $name; host = $hostName; installed = $when; pwd = (Protect-Dpapi $pw); consent = $consent; agent = $agentFlag; hw = $hwFp })
                Set-Prop $rec 'code' $code; Set-Prop $rec 'viaServer' $true
                $rec.status = 'A valider'
            }
            # Une fiche = une NOUVELLE installation : un ordre de désinstallation resté en attente pour cet ID ne doit pas toucher cette installation
            $pendOrd = Get-Prop $rec 'uninstallOrder'
            if ($pendOrd) { [void](Revoke-UninstallOrder $id ([string]$pendOrd.nonce)); Clear-Props $rec @('uninstallOrder') }
            Set-Prop $rec 'recvAt' ([string]$r.received_at)      # identifie la fiche : une validation du téléphone ne s'applique qu'à elle
            $res.received += [pscustomobject]@{ id = $id; name = $name; code = $code; replaces = @($replIds) }
            # C'est ICI, et seulement ici, que la fiche est déclarée « acquittable » : elle a passé toutes les vérifications et
            # son enregistrement par Save-Store (appelé avant l'acquittement) a réussi.
            $ack += @{ id = $id; received_at = [string]$r.received_at }
        }
        catch {
            # Fiche réellement invalide (contenu incohérent) : écartée, et acquittée pour ne pas revenir sans fin.
            $res.rejected++
            Write-Host "  ! fiche reçue pour l'ID $id écartée : $($_.Exception.Message)" -ForegroundColor Yellow
            $ack += @{ id = $id; received_at = [string]$r.received_at }
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
    # Dernière barrière : si la clé privée n'est pas lisible, on n'acquitte RIEN. Les fiches restent sur le serveur (elles
    # reviendront, sans être perdues) au lieu d'être effacées alors qu'elles n'ont pas pu être enregistrées ici.
    if (-not $cleOk) {
        $ack = @(); $valAck = @()
        $res.message = 'clé privée du technicien illisible : aucune fiche n''a été effacée du serveur (elles seront relues)'
        Write-Watch 'clé privée illisible : fiches laissées sur le serveur, rien n''a été effacé' 'Yellow'
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
    if (-not $cfg) { return [pscustomobject]@{ ok = $false; message = 'accès au serveur non configuré (voir Pg20-Technicien-Configurer.ps1 -FeedUrl ... -FeedToken ...)'; added = @(); count = 0; received = @(); validated = @(); rejected = 0; uninstalled = @(); expiredOrders = @(); ipChanges = @(); autoHidden = @(); purged = @() } }
    try {
        $token = Unprotect-Dpapi $cfg.token
        $feed = Invoke-RestMethod -Uri ($cfg.url + '/peers') -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 8
    }
    catch {
        return [pscustomobject]@{ ok = $false; message = "serveur injoignable : $($_.Exception.Message). Êtes-vous sur le réseau local ou sur le WireGuard ?"; added = @(); count = 0; received = @(); validated = @(); rejected = 0; uninstalled = @(); expiredOrders = @(); ipChanges = @(); autoHidden = @(); purged = @() }
    }
    $added = @(); $ipChanges = @()
    foreach ($p in @($feed.peers)) {
        $id = [string]$p.id
        # Poste volontairement ignoré (ajout du 2026-10-10) : on ne recrée pas de fiche. Sans cela, le PC du technicien — enregistré sur son
        # propre serveur — réapparaissait à chaque synchronisation, même après « Supprimer ».
        if (Test-Ignored $id) { continue }
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
        $newIp = ([string]$p.ip).Trim(); $oldIp = ([string](Get-Prop $rec 'ip')).Trim()
        if ($oldIp -and $newIp -and $oldIp -ne $newIp) {
            # le poste s'est (ré)inscrit depuis une autre adresse Internet (portable déplacé, autre réseau) : mémorisé et signalé
            Set-Prop $rec 'ipPrev' $oldIp; Set-Prop $rec 'ipChangedAt' ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
            $ipChanges += [pscustomobject]@{ id = $id; name = [string]$rec.name; from = $oldIp; to = $newIp }
        }
        $rec.firstSeen = [string]$p.first_seen; $rec.ip = $newIp
    }
    Save-Store
    $rr = Receive-Records $cfg $token
    $orr = Receive-OrderResults $cfg $token
    $ah = @(Invoke-AutoHideReplaced)                       # nettoyage de la liste « Se connecter » (après les validations du téléphone)
    # Purge EXPLICITE (facultative) : -PurgeDays N sur la ligne de commande. Elle emporte aussi les postes masqués À LA MAIN, d'où sa
    # restriction. Les DEUX purges automatiques décidées le 2026-10-10 (postes remplacés et clients résiliés) viennent ensuite : elles
    # découlent du contrat signé et ne demandent aucune commande.
    $pg = @()
    if ($PSBoundParameters.ContainsKey('PurgeDays') -and $PurgeDays -gt 0) {
        $pg = @(Invoke-AutoPurgeHidden $PurgeDays)
        foreach ($x in $pg) { Write-Watch ("PURGE : " + $x.name + " (ID " + $x.id + ") supprimé définitivement : masqué depuis " + $x.days + " jour(s) — demande explicite -PurgeDays " + $PurgeDays) 'Yellow' }
    }
    # Purges automatiques : un poste remplacé (masqué) est effacé après 30 jours ; un client résilié, 30 jours après la résiliation.
    $pr = @(Invoke-PurgeReplaced)
    foreach ($x in $pr) { Write-Watch ("PURGE AUTO : « " + $x.name + " » (ID " + $x.id + ") effacé — poste remplacé par « " + $x.byName + " », masqué depuis " + $x.days + " jour(s)") 'Yellow' }
    $pres = @(Invoke-PurgeResilie)
    foreach ($x in $pres) { Write-Watch ("PURGE AUTO : « " + $x.name + " » (ID " + $x.id + ") effacé — client résilié depuis " + $x.days + " jour(s) (délai contractuel de 30 jours)") 'Yellow' }
    $msg = "$($feed.count) poste(s) enregistré(s) sur le serveur"
    if ($rr.received.Count) { $msg += " · $($rr.received.Count) fiche(s) reçue(s)" }
    if ($rr.validated.Count) { $msg += " · $($rr.validated.Count) validée(s) depuis le téléphone" }
    if ($rr.rejected) { $msg += " · $($rr.rejected) fiche(s) écartée(s)" }
    if ($rr.message) { $msg += " · $($rr.message)" }
    if ($orr.uninstalled.Count) { $msg += " · $($orr.uninstalled.Count) poste(s) désinstallé(s) à distance" }
    if ($orr.message) { $msg += " · $($orr.message)" }
    [pscustomobject]@{ ok = $true; message = $msg; added = $added; count = $feed.count; received = @($rr.received); validated = @($rr.validated); rejected = [int]$rr.rejected
                       uninstalled = @($orr.uninstalled); expiredOrders = @($orr.expired); ipChanges = @($ipChanges); autoHidden = @($ah); purged = @($pg)
                       purgedReplaced = @($pr); purgedResilie = @($pres) }
}

# ---------------------------------------------------------------- État « en ligne » des postes (ajout du 2026-10-16, demande du technicien)
# Le serveur RustDesk libre n'a pas d'API, mais il répond, comme à l'application RustDesk (ses petits points verts), à la question « ces postes sont-ils en
# ligne ? » (message OnlineRequest, TCP 21115 = port du serveur 21116 moins 1 ; ni clé ni identification ; refusée depuis la machine du serveur elle-même).
# « EN LIGNE » = le poste s'est inscrit auprès du serveur il y a moins de 30 secondes : RustDesk est lancé chez le client ET relié au serveur. Cela ne dit PAS
# que quelqu'un est devant l'écran, ni que le client est d'accord pour une intervention. Lecture seule : rien n'est écrit ni sur le serveur ni sur ce PC.
# Trame (sources rustdesk-server et hbb_common) : en-tête de 1 à 4 octets (longueur << 2, plus « nombre d'octets - 1 » dans les 2 bits bas, petit-boutiste) puis un
# RendezvousMessage protobuf. Requête : online_request = champ 23 (octets BA 01) contenant OnlineRequest.peers = champ 2 répété (12, longueur, identifiant).
# Réponse : online_response = champ 24 contenant OnlineResponse.states = champ 1 : un bit par poste, DANS L'ORDRE de la requête, bit de poids fort d'abord.
function Get-HbbsEndpoint {
    # (tests) PG20_HBBS_HOST et PG20_HBBS_PORT imposent le serveur ; sinon, la machine du flux des postes (la VM, qui porte aussi le serveur RustDesk)
    $h = [string]$env:PG20_HBBS_HOST; $p = 21115
    if ($env:PG20_HBBS_PORT -match '^\d{1,5}$') { $p = [int]$env:PG20_HBBS_PORT }
    if (-not $h) { $cfg = Get-FeedConfig; if ($cfg -and $cfg.url) { try { $h = ([uri]([string]$cfg.url)).Host } catch { $h = '' } } }
    if (-not $h) { return $null }
    [pscustomobject]@{ host = $h; port = $p }
}

function Add-Varint([System.Collections.Generic.List[byte]]$L, [uint32]$V) {
    while ($V -ge 0x80) { $L.Add([byte](($V -band 0x7F) -bor 0x80)); $V = $V -shr 7 }
    $L.Add([byte]$V)
}

function Read-Varint([byte[]]$B, [ref]$Pos) {
    $v = [long]0; $sh = 0
    while ($true) {
        if ($Pos.Value -ge $B.Length) { throw 'réponse tronquée' }
        $x = $B[$Pos.Value]; $Pos.Value = $Pos.Value + 1
        $v = $v -bor (([long]($x -band 0x7F)) -shl $sh)
        if (($x -band 0x80) -eq 0) { break }
        $sh += 7
        if ($sh -gt 35) { throw 'nombre trop long' }
    }
    return $v
}

# Contenu du premier champ « longueur » de numéro $Field d'un message protobuf, ou $null s'il est absent
function Find-ProtoField([byte[]]$B, [int]$Field) {
    $pos = 0
    while ($pos -lt $B.Length) {
        $tag = Read-Varint $B ([ref]$pos)
        $no = [int]($tag -shr 3); $wt = [int]($tag -band 7)
        if ($wt -eq 0) { [void](Read-Varint $B ([ref]$pos)) }
        elseif ($wt -eq 1) { $pos += 8 }
        elseif ($wt -eq 5) { $pos += 4 }
        elseif ($wt -eq 2) {
            $len = [int](Read-Varint $B ([ref]$pos))
            if ($len -lt 0 -or ($pos + $len) -gt $B.Length) { throw 'champ tronqué' }
            if ($no -eq $Field) { if ($len -eq 0) { return , ([byte[]]@()) }; return , ([byte[]]($B[$pos..($pos + $len - 1)])) }
            $pos += $len
        }
        else { throw 'type de champ inconnu' }
    }
    return $null
}

function Read-ExactBytes($Stream, [int]$Count) {
    $buf = New-Object byte[] $Count; $o = 0
    while ($o -lt $Count) { $n = $Stream.Read($buf, $o, $Count - $o); if ($n -le 0) { throw 'connexion fermée' }; $o += $n }
    return , $buf
}

# Une question au serveur pour au plus 200 postes ; renvoie les octets d'état, ou $null si le serveur ne répond pas comme prévu
function Get-OnlineChunk([string[]]$Lot, [string]$HostName, [int]$Port, [int]$TimeoutMs) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $null }
        $client.EndConnect($ar)
        $flux = $client.GetStream(); $flux.ReadTimeout = $TimeoutMs; $flux.WriteTimeout = $TimeoutMs
        $interne = New-Object System.Collections.Generic.List[byte]
        foreach ($id in $Lot) { $b = [Text.Encoding]::ASCII.GetBytes($id); $interne.Add(0x12); Add-Varint $interne ([uint32]$b.Length); $interne.AddRange($b) }
        $msg = New-Object System.Collections.Generic.List[byte]
        $msg.Add(0xBA); $msg.Add(0x01); Add-Varint $msg ([uint32]$interne.Count); $msg.AddRange($interne)
        $n = $msg.Count
        $trame = New-Object System.Collections.Generic.List[byte]
        if ($n -le 0x3F) { $trame.Add([byte]($n -shl 2)) }
        else { $v = ($n -shl 2) -bor 1; $trame.Add([byte]($v -band 0xFF)); $trame.Add([byte](($v -shr 8) -band 0xFF)) }   # 200 postes : au plus 2 600 octets
        $trame.AddRange($msg)
        $flux.Write($trame.ToArray(), 0, $trame.Count)
        $b0 = (Read-ExactBytes $flux 1)[0]
        $tete = ($b0 -band 3) + 1
        $val = [long]$b0
        if ($tete -gt 1) { $suite = Read-ExactBytes $flux ($tete - 1); for ($i = 0; $i -lt $suite.Length; $i++) { $val = $val -bor ([long]$suite[$i] -shl (8 * ($i + 1))) } }
        $len = [int]($val -shr 2)
        if ($len -lt 1 -or $len -gt 4096) { return $null }
        $rep = Read-ExactBytes $flux $len
        $externe = Find-ProtoField $rep 24
        if ($null -eq $externe) { return $null }
        $etats = Find-ProtoField $externe 1
        $besoin = [int][Math]::Ceiling($Lot.Count / 8)
        if ($null -eq $etats -or $etats.Length -eq 0) { return , ([byte[]](New-Object byte[] $besoin)) }      # aucun bit posé : personne n'est en ligne
        if ($etats.Length -lt $besoin) { return $null }
        return , $etats
    }
    catch { return $null }
    finally { $client.Close() }
}

# Table « identifiant -> $true / $false » ; $null si le serveur est injoignable ou ne répond pas comme prévu. Les identifiants qui ne sont pas des
# nombres de 6 à 12 chiffres sont ignorés (leur état reste inconnu). Aucune écriture : lecture seule.
function Get-OnlineStates {
    param([string[]]$Ids, [int]$TimeoutMs = 1500)
    $liste = @($Ids | Where-Object { $_ -match '^\d{6,12}$' } | Select-Object -Unique)
    if (-not $liste.Count) { return @{} }
    $ep = Get-HbbsEndpoint
    if (-not $ep) { return $null }
    $res = @{}
    for ($debut = 0; $debut -lt $liste.Count; $debut += 200) {
        $lot = @($liste[$debut..([Math]::Min($debut + 199, $liste.Count - 1))])
        $etats = Get-OnlineChunk $lot ([string]$ep.host) ([int]$ep.port) $TimeoutMs
        if ($null -eq $etats) { return $null }
        for ($i = 0; $i -lt $lot.Count; $i++) {
            $res[[string]$lot[$i]] = (([int]$etats[[int][Math]::Floor($i / 8)] -band (0x80 -shr ($i % 8))) -ne 0)
        }
    }
    return $res
}

# Même chose avec une mémoire de 10 secondes (la page du carnet se rafraîchit souvent : un serveur muet ne doit pas la ralentir à chaque fois)
$script:OnlineCache = $null
function Get-OnlineStatesCached([string[]]$Ids, [int]$MaxAgeSec = 10) {
    $cle = (@($Ids | Sort-Object) -join ',')
    $c = $script:OnlineCache
    if ($c -and $c.key -eq $cle -and ((Get-Date) - $c.at).TotalSeconds -lt $MaxAgeSec) { return $c.states }
    $st = Get-OnlineStates $Ids
    $script:OnlineCache = [pscustomobject]@{ key = $cle; at = (Get-Date); states = $st }
    return $st
}

# Dernière fois où chaque poste a été vu en ligne (2026-10-23, « a été connecté le ... ») : le serveur la note toutes les 15 s (GET /presence du flux, voir
# peers-presence.py). Renvoie $null si le serveur ne la fournit pas (ancien serveur, injoignable, pas encore installée) : l'affichage reste alors celui
# d'avant. Sinon { since = début des relevés ; last = id -> date de la dernière fois en ligne ('' = jamais vu en ligne depuis since) }. Lecture seule.
$script:PresenceCache = $null
function Get-Presence([int]$MaxAgeSec = 30, [int]$TimeoutSec = 3) {
    $c = $script:PresenceCache
    if ($c -and ((Get-Date) - $c.at).TotalSeconds -lt $MaxAgeSec) { return $c.data }
    $data = $null
    try {
        $cfg = Get-FeedConfig
        if ($cfg) {
            $token = Unprotect-Dpapi $cfg.token
            $r = Invoke-RestMethod -Uri ($cfg.url.TrimEnd('/') + '/presence') -Headers @{ Authorization = "Bearer $token" } -TimeoutSec $TimeoutSec
            $token = $null
            if ($r -and $null -ne $r.presence) {
                $map = @{}
                foreach ($p in $r.presence.PSObject.Properties) { $map[[string]$p.Name] = [string]$p.Value.last_online }
                $data = [pscustomobject]@{ since = [string]$r.since; last = $map }
            }
        }
    }
    catch { $data = $null }
    $script:PresenceCache = [pscustomobject]@{ at = (Get-Date); data = $data }
    return $data
}

# Texte et couleur de l'état d'un poste dans la fenêtre « Se connecter » ; hors ligne : on ajoute la date de la dernière connexion quand le serveur la donne
function Get-OnlineLabel([string]$Id, $States, $Presence = $null) {
    if ($null -eq $States -or -not $States.ContainsKey($Id)) { return [pscustomobject]@{ text = '? inconnu'; color = [System.Drawing.Color]::FromArgb(140, 140, 140) } }
    if ($States[$Id]) { return [pscustomobject]@{ text = '● en ligne'; color = [System.Drawing.Color]::FromArgb(14, 122, 84) } }
    $txt = '○ hors ligne'
    if ($Presence -and $Presence.last.ContainsKey($Id)) {
        $d = [string]$Presence.last[$Id]
        $txt += $(if ($d) { ', connecté le ' + (Format-Local $d).Substring(0, 10) } else { ', pas encore vu' })
    }
    return [pscustomobject]@{ text = $txt; color = [System.Drawing.Color]::FromArgb(120, 120, 120) }
}

# ---------------------------------------------------------------- Restauration depuis l'archive du serveur
# Le serveur garde, pour chaque client, les dernières fiches reçues, TELLES QUELLES (chiffrées avec votre clé publique : il ne peut pas les lire). Si ce PC est
# perdu : retrouvez votre clé privée (sauvegarde), puis lancez  Pg20-Clients-Carnet.ps1 -RestoreFromServer  : chaque client est rouvert avec votre clé privée et
# remis dans le carnet comme VALIDÉ, avec son mot de passe, sa preuve d'acceptation et la tâche de maintenance. N'est PAS restauré : un client déjà dans le carnet
# (rien n'est écrasé), un client supprimé depuis (la suppression efface aussi son archive), une fiche illisible ou fabriquée (écartée). À appeler dans Use-Store.
function Restore-FromArchive([switch]$Ask) {
    $res = [pscustomobject]@{ ok = $false; message = ''; restored = @(); skipped = 0; rejected = 0; found = 0 }
    $cfg = Get-FeedConfig
    if (-not $cfg) { $res.message = 'accès au serveur non configuré (voir Pg20-Technicien-Configurer.ps1 -FeedUrl ... -FeedToken ...)'; return $res }
    if (-not (Get-TechPrivateKeyXml)) { $res.message = (Get-MissingKeyMessage); return $res }
    $all = @()
    try {
        $token = Unprotect-Dpapi $cfg.token; $off = 0
        while ($true) {
            $page = Invoke-RestMethod -Uri ($cfg.url + "/archive?offset=$off&limit=200") -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 15
            $recs = @($page.records | Where-Object { $_ })
            $all += $recs; $off += $recs.Count
            # Correctif du 2026-10-10 : un « count » absent ou illisible valait 0 et faisait sortir de la boucle après la première page : la
            # restauration était alors TRONQUÉE EN SILENCE (le technicien croyait avoir tout récupéré). On refuse une réponse sans count.
            $total = $null
            try { $total = [int]$page.count } catch { $total = $null }
            if (-not $recs.Count) { break }
            if ($null -eq $total) { $res.message = 'réponse du serveur sans nombre total (count) : restauration INTERROMPUE par prudence, relancez quand le serveur répond normalement'; break }
            if ($off -ge $total) { break }
        }
    }
    catch { $res.message = "archive du serveur illisible : $($_.Exception.Message). Êtes-vous sur le réseau local ou sur le WireGuard ?"; return $res }
    $res.found = $all.Count
    # une seule fiche par client : la plus récente
    $latest = @($all | Group-Object { [string]$_.id } | ForEach-Object { $_.Group | Sort-Object { [string]$_.received_at } | Select-Object -Last 1 })
    $todo = @()
    foreach ($r in $latest) {
        $id = [string]$r.id
        $rec = Find-Client $id
        if (($rec -and -not (Get-Prop $rec 'forgotten')) -or (Find-Deleted $id)) { $res.skipped++; continue }
        try {
            $f = Unprotect-Envelope ([string]$r.blob)
            $name = (([string]$f.name) -replace '[\x00-\x1f]', '').Trim(); $pw = [string]$f.password
            if ([int]$f.v -ne 1 -or [string]$f.id -ne $id -or $name.Length -lt 1 -or $name.Length -gt 80 -or $pw.Length -lt 12 -or $pw.Length -gt 128 -or $pw -match '[\s\x00-\x1f]') { throw 'contenu invalide' }
            $hostName = (([string]$f.host) -replace '[\x00-\x1f]', '').Trim(); if ($hostName.Length -gt 63) { $hostName = $hostName.Substring(0, 63) }
            $todo += [pscustomobject]@{ id = $id; name = $name; host = $hostName; pw = $pw; when = (Format-Local ([string]$f.ts)); recv = [string]$r.received_at
                                        consent = (ConvertTo-Consent $f.consent ([string]$r.received_at)); agent = [bool]($f.PSObject.Properties['agent'] -and $f.agent)
                                        hw = $(if (([string]$f.hw) -match '^[0-9a-f]{32}$') { [string]$f.hw } else { '' }) }
        }
        catch { $res.rejected++ }          # fabriquée, altérée ou chiffrée pour une autre clé : écartée
    }
    if (-not $todo.Count) { $res.ok = $true; $res.message = "rien à restaurer ($($res.found) fiche(s) archivée(s) ; $($res.skipped) client(s) déjà présent(s) ou supprimé(s) ; $($res.rejected) écartée(s))"; return $res }
    if ($Ask) {
        Write-Host ''
        Write-Host "  $($todo.Count) client(s) à restaurer depuis l'archive du serveur :" -ForegroundColor Cyan
        foreach ($t in ($todo | Sort-Object name)) { Write-Host ("    {0}  (ID {1}, installé le {2})" -f $t.name, (Format-RdId $t.id), $t.when) }
        $ans = (Read-Host "  Les ajouter au carnet comme clients VALIDÉS ? (oui/non)").Trim()
        if ($ans -notmatch '^(o|oui|y|yes)$') { $res.message = "restauration annulée : rien n'a été modifié"; $res.ok = $true; return $res }
    }
    foreach ($t in $todo) {
        $rec = Find-Client $t.id
        if (-not $rec) { $rec = New-Client $t.id; $script:Store = @($script:Store) + $rec }
        Clear-Props $rec @('forgotten', 'incoming', 'code', 'viaServer')
        $rec.name = $t.name; $rec.host = $t.host; $rec.installed = $t.when; $rec.pwd = Protect-Dpapi $t.pw; $rec.unknown = $false; $rec.status = 'Valide'
        if ($t.consent) { Set-Prop $rec 'consent' $t.consent }
        Set-Prop $rec 'agent' $t.agent; Set-Prop $rec 'recvAt' $t.recv; if ($t.hw) { Set-Prop $rec 'hw' $t.hw }
        Set-Prop $rec 'restoredAt' ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
        $res.restored += [pscustomobject]@{ id = $t.id; name = $t.name }
    }
    Save-Store
    foreach ($t in $todo) { $rec = Find-Client $t.id; try { if ($rec -and (Get-Prop $rec 'consent')) { [void](Save-ConsentProofAuto $rec) } } catch { } }
    $res.ok = $true
    $res.message = "$($res.restored.Count) client(s) restauré(s) ; $($res.skipped) déjà présent(s) ou supprimé(s) ; $($res.rejected) écarté(s)"
    $res
}

# ---------------------------------------------------------------- Affichage
function Format-Local([string]$Iso) {
    if (-not $Iso) { return '' }
    try { [datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { $Iso }
}
# Date seule, pour les messages ou l'heure n'apporte rien (par exemple la date d'effacement d'une fiche resiliee) :
# « 2026-10-31 (11:00) ». La ou l'heure compte (journal, ordres), Format-Local reste utilise.
function Format-LocalDate([string]$Iso) {
    if (-not $Iso) { return '' }
    try { $d = [datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime(); $d.ToString('yyyy-MM-dd') + ' (' + $d.ToString('HH:mm') + ')' } catch { $Iso }
}

function Get-View {
    @($script:Store | Where-Object { $script:ShowAll -or $_.status -ne 'Ignore' } |
        Sort-Object @{ Expression = { if ($_.status -eq 'A valider') { 0 } else { 1 } } }, @{ Expression = { $_.name } })
}

function Show-List([string[]]$NewIds = @()) {
    $view = @(Get-View)      # @() : avec un seul client, PowerShell renverrait un objet sans propriété Count
    Write-Host ''
    Write-Host ('{0,3}  {1,-26} {2,-12} {3,-10} {4,-16} {5}' -f 'N°', 'Client', 'ID', 'Statut', 'Installé le', 'Première connexion') -ForegroundColor Cyan
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
    foreach ($n in @($R.received)) { Write-Host "  >> FICHE REÇUE : $($n.name) (ID $(Format-RdId $n.id)), code de contrôle $($n.code) : à valider$(Format-ReplacesHint $n.replaces)" -ForegroundColor Yellow }
    foreach ($n in @($R.validated)) { Write-Host "  >> VALIDÉ depuis le téléphone : $($n.name) (ID $(Format-RdId $n.id))" -ForegroundColor Green }
    foreach ($n in @($R.ipChanges | Where-Object { $_ })) { Write-Host "  >> ADRESSE INTERNET CHANGÉE : $($n.name) (ID $(Format-RdId $n.id)) : $($n.from) -> $($n.to)" -ForegroundColor DarkYellow }
    foreach ($n in @($R.autoHidden | Where-Object { $_ })) { Write-Host "  >> NETTOYAGE : « $($n.name) » (ID $(Format-RdId $n.id)) masqué : remplacé par « $($n.byName) » (ID $(Format-RdId $n.by))" -ForegroundColor DarkGray }
    foreach ($n in @($R.purged | Where-Object { $_ })) { Write-Host "  >> PURGE : « $($n.name) » (ID $(Format-RdId $n.id)) masqué depuis $($n.days) jours : supprimé pour de bon (la preuve d'acceptation est gardée)" -ForegroundColor DarkGray }
    foreach ($n in @($R.uninstalled)) { Write-Host "  >> DÉSINSTALLÉ à distance : $($n.name) (ID $(Format-RdId $n.id)) : retiré de la liste" -ForegroundColor Green }
    foreach ($n in @($R.expiredOrders)) { Write-Host "  >> ORDRE PÉRIMÉ : $($n.name) (ID $(Format-RdId $n.id)) n'a pas exécuté la désinstallation en 30 jours (poste éteint ?)" -ForegroundColor Yellow }
}

# ---------------------------------------------------------------- Interface web locale
# Mini-serveur HTTP sur 127.0.0.1 UNIQUEMENT (joignable depuis ce PC seulement), protégé par un jeton aléatoire.
# La page n'a jamais accès aux mots de passe : c'est cet outil qui ouvre RustDesk ou copie le mot de passe.
# TLS ICI ? NON, ET C'EST VOLONTAIRE (analyse du 2026-10-10, audit A6 « transport en clair ») : les échanges ne quittent
# jamais la boucle locale (127.0.0.1), donc personne ne peut les intercepter sur le réseau. La protection réelle est
# ailleurs, et elle est en place : (1) écoute limitée à 127.0.0.1 ; (2) jeton aléatoire de 192 bits exigé à chaque
# requête ; (3) vérification de l'en-tête « Host » contre le DNS rebinding (voir Handle-WebRequest) ; (4) en-têtes
# Cache-Control, X-Content-Type-Options, X-Frame-Options et Content-Security-Policy (voir Send-Bytes). Un certificat
# auto-signé sur la boucle locale n'ajouterait rien : celui qui pourrait lire ce trafic est déjà sur la machine, donc
# il peut lire la mémoire du processus et le fichier du carnet. La seule vraie amélioration possible sur ce point
# concernerait le FLUX LOCAL (port 8099, peers-feed.py), qui traverse le réseau — voir le RECAP.
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
    $on = Get-OnlineStatesCached @($script:Store | ForEach-Object { [string]$_.id })        # état « en ligne » (2026-10-16) : $null = serveur muet
    $pr = Get-Presence                                                                      # dernière connexion (2026-10-23) : $null = le serveur ne la fournit pas
    @($script:Store |
        Where-Object { -not ($_.PSObject.Properties['forgotten'] -and $_.forgotten) } |
        Where-Object { $IncludeHidden -or $_.status -ne 'Ignore' } |
        Sort-Object @{ Expression = { if ($_.status -eq 'A valider') { 0 } else { 1 } } }, @{ Expression = { $_.name } } |
        ForEach-Object {
            [pscustomobject]@{
                id = $_.id; idText = (Format-RdId $_.id); name = $_.name; host = $_.host; installed = $_.installed
                firstSeen = (Format-Local $_.firstSeen); status = $_.status; unknown = [bool]$_.unknown
                hasPassword = [bool]$_.pwd; isNew = ($NewIds -contains $_.id)
                online = $(if ($null -eq $on -or -not $on.ContainsKey([string]$_.id)) { $null } else { [bool]$on[[string]$_.id] })
                lastOnline = $(if ($pr -and $pr.last.ContainsKey([string]$_.id)) { Format-Local ([string]$pr.last[[string]$_.id]) } else { '' })
                presenceSince = $(if ($pr -and $pr.since) { (Format-Local $pr.since).Substring(0, 10) } else { '' })
                code =[string](Get-Prop $_ 'code'); viaServer = [bool](Get-Prop $_ 'viaServer')
                consent = (Get-ConsentSummary $_); hasConsent = [bool](Get-Prop $_ 'consent')
                replaces = @(Get-WebReplaces $_)
                ip = [string](Get-Prop $_ 'ip'); ipPrev = (Get-RecentIpPrev $_ 30); ipChanged = $(if (Get-RecentIpPrev $_ 30) { Format-Local ([string](Get-Prop $_ 'ipChangedAt')) } else { '' })
                autoHidden = $(if (Get-Prop $_ 'autoHidden') { $ahx = Get-Prop $_ 'autoHidden'; [pscustomobject]@{ by = [string]$ahx.by; byName = [string]$ahx.byName; at = (Format-Local ([string]$ahx.at)) } } else { $null })
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
        { $_ -in 'POST /api/connect', 'POST /api/copy', 'POST /api/validate', 'POST /api/rename', 'POST /api/hide', 'POST /api/forget', 'POST /api/delete', 'POST /api/proof', 'POST /api/cancel-uninstall', 'POST /api/replace', 'POST /api/keep-both' } {
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
                    else {
                        $rec.status = $(if ($rec.unknown) { 'A valider' } else { 'Valide' }); $msg = 'Client affiché.'
                        if (Get-Prop $rec 'autoHidden') { Clear-Props $rec @('autoHidden'); Set-Prop $rec 'autoHideOff' $true }       # rétabli à la main : le nettoyage automatique ne le remasque plus
                    }
                    Save-Store
                }
                '/api/forget'   { Forget-Client $rec; $msg = 'Client oublié : mot de passe effacé.' }
                '/api/proof'    {
                    try { $pp = Export-ConsentProof $rec } catch { Send-Json $Ctx @{ ok = $false; error = [string]$_.Exception.Message } 400; return $false }
                    if (-not $DryRun) { Start-Process explorer.exe -ArgumentList ('/select,"' + $pp + '"') }
                    $msg = "Preuve enregistrée : $pp"
                }
                '/api/replace' {
                    # Retire les anciens clients que cette fiche remplace (même nom de client et de poste, ID différent) : serveur d'abord, comme « Supprimer »
                    $old = @(Get-ReplacedClients $rec)
                    if (-not $old.Count) { Send-Json $Ctx @{ ok = $false; error = 'Aucun ancien poste à remplacer (déjà retiré ?).' } 404; return $false }
                    $msgs = @()
                    foreach ($o in $old) {
                        $rr = Remove-Client $o
                        if (-not $rr.ok) { Send-Json $Ctx @{ ok = $false; error = [string]$rr.message } 502; return $false }
                        $msgs += [string]$rr.message
                    }
                    $msg = 'Ancien poste remplacé : ' + ($msgs -join ' ')
                }
                '/api/keep-both' {
                    # écarte pour de bon les anciens postes actuellement proposés (ils ne seront plus reproposés pour ce poste)
                    foreach ($o in @(Find-ReplacedClients $rec)) { if (Get-Prop $o 'autoHidden') { $o.status = 'Valide'; Clear-Props $o @('autoHidden') }; Set-Prop $o 'autoHideOff' $true }       # déjà masqués : rétablis ; et plus jamais masqués par le nettoyage (ni par un autre poste)
                    $ids = @(Find-ReplacedClients $rec | ForEach-Object { [string]$_.id }); $cur = @(Get-Prop $rec 'keepBoth' | Where-Object { $_ })
                    Set-Prop $rec 'keepBoth' @($cur + $ids | Select-Object -Unique); Save-Store; $msg = 'Les deux postes sont conservés.'
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
    $htmlFile = Join-Path $PSScriptRoot 'Pg20-Clients-Carnet-ui.html'
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
    Write-Host '=== Info Pg20 : clients ===' -ForegroundColor Green
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
                # Correctif du 2026-10-10 : le message d'exception brut partait dans le navigateur. Il peut contenir un chemin local, un nom
                # d'utilisateur, voire un secret présent dans une commande (le mot de passe d'un client est passé dans l'URL gestionnaire
                # rustdesk://). Le détail reste dans le journal du technicien (watch.log, jamais de mot de passe) ; la page reçoit un message fixe.
                Write-Watch ('Page web : erreur sur une demande (' + $_.Exception.Message + ')') 'Yellow'
                try { Send-Json $ctx @{ ok = $false; error = 'Erreur interne : l''action n''a pas abouti. Regardez le journal de Pg20 (watch.log).' } 500 } catch { }
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
#    le poste le lit dans les 3 minutes (allumé et connecté ; sinon peu après son démarrage) et se désinstalle seul, sans rien afficher ; le client disparaît ensuite de la liste tout
#    seul (Receive-OrderResults). Rien à faire pour le client.
#  - sans elle (anciens postes) : seule une session RustDesk permet d'agir. Le bouton prépare alors UNE commande autonome, la place dans le
#    presse-papiers, ouvre la session et guide l'opération. La commande vérifie l'ID du poste avant de toucher à quoi que ce soit
#    (Uninstall-RustDeskFully -ExpectedId, dans Pg20-Client-Installation.ps1).
function Get-UninstallScript($Rec, [switch]$DryRun) {
    $id = [string]$Rec.id
    if ($id -notmatch '^\d{6,12}$') { throw 'ID de client invalide.' }
    $deploy = Join-Path $PSScriptRoot 'Pg20-Client-Installation.ps1'
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($deploy, [ref]$tok, [ref]$err)
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Uninstall-RustDeskFully' }, $true)
    if (-not $fn) { throw 'Fonction de désinstallation introuvable dans Pg20-Client-Installation.ps1.' }
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
    $autoHiddenCount = @(Use-Store { @($script:Store | Where-Object { Get-Prop $_ 'autoHidden' }) }).Count
    # Anciens postes qui semblent remplacés par une réinstallation plus récente du même poste : signalés dans la liste, jamais retirés tout seuls
    $script:ReplacedBy = @{}
    $null = Use-Store { foreach ($nw in @($script:Store | Where-Object { $_.status -eq 'Valide' -and $_.pwd -and -not (Get-Prop $_ 'forgotten') } | Sort-Object { [string]$_.installed })) { foreach ($old in @(Find-ReplacedClients $nw)) { $script:ReplacedBy[[string]$old.id] = [string]$nw.name } } }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Info Pg20 : se connecter à un client'
    $f.ClientSize = New-Object System.Drawing.Size(780, 446)
    $f.StartPosition = 'CenterScreen'; $f.TopMost = $true; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Tapez pour chercher, puis Entrée ou double-clic pour vous connecter.'
    $hint.Location = New-Object System.Drawing.Point(14, 12); $hint.Size = New-Object System.Drawing.Size(752, 22)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(14, 40); $tb.Size = New-Object System.Drawing.Size(752, 28)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $false; $lv.GridLines = $false
    $lv.Location = New-Object System.Drawing.Point(14, 76); $lv.Size = New-Object System.Drawing.Size(752, 258)
    [void]$lv.Columns.Add('Client', 190); [void]$lv.Columns.Add('État', 240); [void]$lv.Columns.Add('ID', 90); [void]$lv.Columns.Add('Poste', 95); [void]$lv.Columns.Add('Adresse Internet', 115)

    $note = New-Object System.Windows.Forms.Label
    $note.Location = New-Object System.Drawing.Point(14, 326); $note.Size = New-Object System.Drawing.Size(752, 62)      # 3 lignes : le message de suppression est long
    $note.UseMnemonic = $false
    $note.ForeColor = [System.Drawing.Color]::FromArgb(138, 82, 0)
    # Message d'etat, du plus urgent au moins urgent. Ajout du 2026-10-10 : les clients RESILIES encore presents sont annonces avec
    # leur date d'effacement (30 jours, delai du contrat) : on voit d'un coup d'oeil ce qui va disparaitre tout seul, et quand.
    $resilies = @(Use-Store { @($script:Store | Where-Object { (Get-Prop $_ 'resilie') -and -not (Get-Prop $_ 'forgotten') }) })
    $noteLignes = @()
    if ($resilies.Count) {
        $prochain = ($resilies | Sort-Object { [string](Get-Prop $_ 'resilie').purgeAt } | Select-Object -First 1)
        $noteLignes += [string]$resilies.Count + ' client(s) résilié(s) : fiche effacée automatiquement le ' + (Format-LocalDate ([string](Get-Prop $prochain 'resilie').purgeAt)) + ' (délai contractuel de 30 jours).'
    }
    if ($pending) { $noteLignes += "$pending fiche(s) à valider : ouvrez la page complète ou validez depuis le téléphone." }
    if ($script:ReplacedBy.Count) { $noteLignes += "$($script:ReplacedBy.Count) ancien(s) poste(s) semble(nt) remplacé(s) par une réinstallation plus récente : effacement automatique 30 jours après le masquage (« Supprimer… » pour le faire tout de suite)." }
    elseif ($autoHiddenCount) { $noteLignes += "$autoHiddenCount ancien(s) poste(s) remplacé(s) par une réinstallation masqué(s) automatiquement (page complète : « Afficher les masqués »)." }
    if (-not $script:QuickAll.Count -and -not $noteLignes.Count) { $noteLignes += 'Aucun client validé pour le moment.' }
    $note.Text = ($noteLignes -join "`n")

    $go = New-Object System.Windows.Forms.Button
    $go.Text = 'Se connecter'; $go.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $go.Location = New-Object System.Drawing.Point(14, 392); $go.Size = New-Object System.Drawing.Size(150, 40)
    $unin = New-Object System.Windows.Forms.Button
    $unin.Text = 'Désinstaller…'; $unin.ForeColor = [System.Drawing.Color]::FromArgb(138, 82, 0)
    $unin.Location = New-Object System.Drawing.Point(174, 392); $unin.Size = New-Object System.Drawing.Size(125, 40)
    # « Resilier… » (ajout du 2026-10-10, demande du technicien) : fin de collaboration, telle que le contrat la decrit.
    # Desinstallation + preuve archivee + fiche effacee automatiquement 30 jours plus tard. C'est le bouton le plus « lourd » :
    # il est place entre « Desinstaller… » et « Supprimer… », et demande toujours confirmation.
    $resi = New-Object System.Windows.Forms.Button
    $resi.Text = 'Résilier…'; $resi.ForeColor = [System.Drawing.Color]::FromArgb(138, 82, 0)
    $resi.Location = New-Object System.Drawing.Point(309, 392); $resi.Size = New-Object System.Drawing.Size(100, 40)
    $del = New-Object System.Windows.Forms.Button
    $del.Text = 'Supprimer…'; $del.ForeColor = [System.Drawing.Color]::FromArgb(179, 38, 30)
    $del.Location = New-Object System.Drawing.Point(419, 392); $del.Size = New-Object System.Drawing.Size(110, 40)
    $page = New-Object System.Windows.Forms.Button
    $page.Text = 'Page complète…'; $page.Location = New-Object System.Drawing.Point(544, 392); $page.Size = New-Object System.Drawing.Size(140, 40)
    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Fermer'; $close.Location = New-Object System.Drawing.Point(694, 392); $close.Size = New-Object System.Drawing.Size(72, 40)
    $f.AcceptButton = $go; $f.CancelButton = $close
    $f.Controls.AddRange(@($hint, $tb, $lv, $note, $go, $unin, $resi, $del, $page, $close))

    # État « en ligne » (2026-10-16) : lu une fois à l'ouverture, puis toutes les 20 s. $null = serveur muet : la colonne dit « ? inconnu », rien d'autre ne change.
    $script:Online = Get-OnlineStates @($script:QuickAll | ForEach-Object { [string]$_.id })
    $script:PresenceNow = Get-Presence 0 2        # dernière connexion (2026-10-23) ; $null = le serveur ne la fournit pas : la colonne reste comme avant
    $fill = {
        $q = ($tb.Text -replace '\s', '').ToLower()
        $lv.BeginUpdate(); $lv.Items.Clear()
        foreach ($c in $script:QuickAll) {
            $hay = ($c.name + $c.id + $c.host + (Get-Prop $c 'ip')) -replace '\s', ''
            if ($q -and $hay.ToLower().IndexOf($q) -lt 0) { continue }
            $it = New-Object System.Windows.Forms.ListViewItem((Format-PickerName $c))
            $it.UseItemStyleForSubItems = $false
            $etat = Get-OnlineLabel ([string]$c.id) $script:Online $script:PresenceNow
            [void]$it.SubItems.Add($etat.text); $it.SubItems[1].ForeColor = $etat.color
            [void]$it.SubItems.Add((Format-RdId $c.id)); [void]$it.SubItems.Add([string]$c.host); [void]$it.SubItems.Add((Format-PickerIp $c))
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
    $removeBody = {
            if (-not $lv.SelectedItems.Count) { return }
            $rec = $lv.SelectedItems[0].Tag
            if (-not $AutoDelete) {
                $q = $(if ($script:ReplacedBy.ContainsKey([string]$rec.id)) { "Ce poste semble avoir été remplacé par « $($script:ReplacedBy[[string]$rec.id]) » (même poste, nouvelle installation).`n`n" } else { '' }) + "Supprimer « $($rec.name) » (ID $(Format-RdId $rec.id)) ?`n`nIl sera retiré de ce PC (mot de passe effacé), de la clé USB si elle est branchée, et du serveur.`nSi RustDesk est encore installé chez le client, il se réenregistrera et réapparaîtra « À valider ».`n`nLes preuves d'acceptation déjà exportées (Documents\Pg20-Info-Preuves) sont conservées.`n`nAction définitive."
                if ([System.Windows.Forms.MessageBox]::Show($f, $q, 'Supprimer le client', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
            }
            $res = Use-Store { Remove-Client $rec }
            if ($res.ok) {
                $script:QuickAll = @($script:QuickAll | Where-Object { $_.id -ne $rec.id })
                $note.ForeColor = [System.Drawing.Color]::FromArgb(14, 122, 84); $note.Text = $res.message
                & $fill
                # Ajout du 2026-10-10 : proposer d'ignorer ce poste pour de bon. Utile surtout pour le PC du technicien, enregistré sur son
                # propre serveur : sans cela, la synchronisation recrée sa fiche à chaque passage, même après suppression.
                if (-not $AutoDelete) {
                    $q2 = "Ne plus jamais me proposer « $($rec.name) » (ID $(Format-RdId $rec.id)) ?`n`nSon identifiant sera noté dans une liste locale (ignores.json) : la synchronisation ne recréera plus de fiche pour ce poste.`n`nNi le serveur ni vos autres fiches ne sont touchés. Pour revenir en arrière, supprimez cette ligne du fichier."
                    if ([System.Windows.Forms.MessageBox]::Show($f, $q2, 'Ignorer ce poste', 'YesNo', 'Question', 'Button2') -eq 'Yes') {
                        Add-Ignored ([string]$rec.id) 'ignoré depuis « Se connecter »'
                        $note.Text = $res.message + ' Ce poste ne sera plus proposé (liste des ignorés).'
                    }
                }
            }
            elseif (-not $AutoDelete) { [void][System.Windows.Forms.MessageBox]::Show($f, [string]$res.message, 'Suppression impossible', 'OK', 'Error') }
            else { Write-Host ("ECHEC suppression : " + $res.message) }
    }
    # Correctif du 2026-10-10 : une exception ici (verrou non obtenu, cle DPAPI illisible, fichier verrouille) tuait la fenetre sans message.
    $remove = {
    try { & $removeBody }
    catch { [void][System.Windows.Forms.MessageBox]::Show($f, ('Suppression impossible : ' + $_.Exception.Message), 'Erreur', 'OK', 'Error'); Write-Host ('ECHEC suppression : ' + $_.Exception.Message) }
    }
    $del.Add_Click($remove)
    # Désinstaller RustDesk chez le client. Trois cas :
    #  - une désinstallation est déjà demandée : on propose de l'ANNULER ;
    #  - le poste a la tâche de maintenance : confirmation par saisie du nom, puis ordre signé déposé sur le serveur (le poste se désinstalle seul,
    #    le client disparaît tout seul de la liste) ;
    #  - sinon (ancien poste) : confirmation par saisie du nom, commande prête dans le presse-papiers, session ouverte, guide, puis retrait du client.
    $uninstallBody = {
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
                     "• Il se désinstallera tout seul dans les 3 minutes s'il est allumé et connecté (sinon, peu après son prochain démarrage), sans rien afficher : le client n'a rien à faire.`n" +
                     "• Il sera ensuite retiré de cette liste automatiquement.`n" +
                     "• Annulable tant que le poste n'a pas exécuté l'ordre."
                if (-not $AutoUninstall -and -not (Show-TypedConfirm $f 'Désinstaller RustDesk chez ce client' $q ([string]$rec.name))) { return }
                $sr = Use-Store { $r = Find-Client $rec.id; if ($r) { Send-UninstallOrder $r } else { [pscustomobject]@{ ok = $false; message = 'Client introuvable.'; order = $null } } }
                if ($sr.ok) {
                    Set-Prop $rec 'uninstallOrder' $sr.order
                    $note.ForeColor = $okColor
                    $note.Text = "Ordre envoyé : $($rec.name) se désinstallera seul dans les 3 minutes s'il est allumé et connecté, puis disparaîtra de la liste."
                    & $fill
                    if (-not $AutoUninstall) {
                        [void][System.Windows.Forms.MessageBox]::Show($f, "Ordre envoyé.`n`n« $($rec.name) » se désinstallera tout seul dans les 3 minutes s'il est allumé et connecté à internet (sinon, peu après son prochain démarrage). Vous n'avez rien d'autre à faire : il sera retiré de la liste automatiquement (laissez la surveillance Pg20 active, ou ouvrez la page de temps en temps).`n`nVous pouvez annuler avec ce même bouton tant que ce n'est pas fait.", 'Désinstallation demandée', 'OK', 'Information')
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
    # Correctif du 2026-10-10 : meme protection que « Supprimer » (la fenetre ne doit pas mourir en silence).
    $uninstall = {
    try { & $uninstallBody }
    catch { [void][System.Windows.Forms.MessageBox]::Show($f, ('Desinstallation impossible : ' + $_.Exception.Message), 'Erreur', 'OK', 'Error'); Write-Host ('ECHEC desinstallation : ' + $_.Exception.Message) }
    }
    $unin.Add_Click($uninstall)
    # ---------------------------------------------------------------- Resilier (fin de collaboration) — ajout du 2026-10-10
    # Ce que le contrat promet a la fin de la collaboration (conditions 2026-10-09, points 6, 7 et 9) : le technicien envoie l'ordre de
    # desinstallation (le poste se retire seul) et efface la fiche dans les 30 jours. Un seul geste, donc, et trois consequences
    # clairement annoncees AVANT d'agir : l'ordre part, la preuve d'acceptation est archivee, la fiche s'efface dans 30 jours.
    $resilierBody = {
        if (-not $lv.SelectedItems.Count) { return }
        $rec = $lv.SelectedItems[0].Tag
        if (Get-Prop $rec 'resilie') {
            $q0 = "La résiliation de « $($rec.name) » est déjà enregistrée : sa fiche sera effacée automatiquement le " + (Format-LocalDate ([string](Get-Prop $rec 'resilie').purgeAt)) + ".`n`nRien d'autre à faire."
            [void][System.Windows.Forms.MessageBox]::Show($f, $q0, 'Déjà résilié', 'OK', 'Information'); return
        }
        $q = "Résilier le service pour « $($rec.name) » (ID $(Format-RdId $rec.id)) ?`n`n" +
             "Ce que cela fait, exactement :`n" +
             "  • l'ordre de désinstallation est envoyé au poste : RustDesk se retire tout seul en 3 minutes s'il est allumé et connecté (sinon à son prochain démarrage) ;`n" +
             "  • la preuve d'acceptation des conditions est archivée (Documents\Pg20-Info-Preuves) et conservée 1 an ;`n" +
             "  • la fiche est effacée automatiquement dans 30 jours — le délai promis dans vos conditions.`n`n" +
             "D'ici là, elle reste visible dans « Afficher les masqués ». Si le client revient, on peut annuler avant l'effacement.`n`n" +
             "Cette opération ne se défait pas."
        if ([System.Windows.Forms.MessageBox]::Show($f, $q, 'Résilier le service', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
        $res = Use-Store { $r = Find-Client $rec.id; if ($r) { Stop-ClientService $r } else { [pscustomobject]@{ ok = $false; message = 'Client introuvable.'; purgeAt = $null } } }
        if ($res.ok) {
            $note.ForeColor = [System.Drawing.Color]::FromArgb(14, 122, 84)
            $note.Text = "Résiliation enregistrée : « $($rec.name) » va se désinstaller seul, et sa fiche sera effacée le " + (Format-LocalDate ([string]$res.purgeAt)) + " (30 jours)."
            & $fill
            [void][System.Windows.Forms.MessageBox]::Show($f, "C'est fait.`n`n« $($rec.name) » se désinstallera tout seul dans les 3 minutes s'il est allumé et connecté à internet (sinon, peu après son prochain démarrage). Sa fiche sera effacée automatiquement le " + (Format-LocalDate ([string]$res.purgeAt)) + " — laissez la surveillance Pg20 active, ou ouvrez la page de temps en temps.`n`nLa preuve d'acceptation est archivée et conservée 1 an.", 'Résiliation enregistrée', 'OK', 'Information')
        }
        else {
            $note.ForeColor = [System.Drawing.Color]::FromArgb(179, 38, 30); $note.Text = [string]$res.message
            [void][System.Windows.Forms.MessageBox]::Show($f, [string]$res.message, 'Résiliation impossible', 'OK', 'Error')
        }
    }
    $resi.Add_Click($resilierBody)
    $tb.Add_TextChanged($fill)
    $tb.Add_KeyDown({ param($s, $e)
        if ($e.KeyCode -eq 'Down' -and $lv.Items.Count) { $i = [Math]::Min(($(if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Index } else { -1 })) + 1, $lv.Items.Count - 1); $lv.Items[$i].Selected = $true; $lv.EnsureVisible($i); $e.Handled = $true }
        elseif ($e.KeyCode -eq 'Up' -and $lv.Items.Count) { $i = [Math]::Max(($(if ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Index } else { 1 })) - 1, 0); $lv.Items[$i].Selected = $true; $lv.EnsureVisible($i); $e.Handled = $true }
    })
    $lv.Add_DoubleClick($connect)
    $go.Add_Click($connect)
    $page.Add_Click({
        # même lancement que le raccourci « Pg20 - Page clients » : sans fenêtre de console (conhost --headless) ; à défaut, l'ancien .cmd
        $conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
        if (Test-Path -LiteralPath $conhost) { Start-Process -FilePath $conhost -WindowStyle Hidden -ArgumentList ('--headless powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'Pg20-Clients-Carnet.ps1') + '"') }
        else { Start-Process (Join-Path $PSScriptRoot 'Pg20-Clients-Carnet.cmd') }
        $f.Close()
    })
    $close.Add_Click({ $f.Close() })
    & $fill
    $timerEnLigne = New-Object System.Windows.Forms.Timer
    $timerEnLigne.Interval = 20000
    $timerEnLigne.Add_Tick({
        try {
            $script:Online = Get-OnlineStates @($script:QuickAll | ForEach-Object { [string]$_.id }) 1200
            $script:PresenceNow = Get-Presence 15 1
            foreach ($it in $lv.Items) { $e = Get-OnlineLabel ([string]$it.Tag.id) $script:Online $script:PresenceNow; $it.SubItems[1].Text = $e.text; $it.SubItems[1].ForeColor = $e.color }
        } catch { }
    })
    $timerEnLigne.Start()
    $f.Add_FormClosed({ $timerEnLigne.Stop(); $timerEnLigne.Dispose() })
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

# Garde-fou du 2026-10-10 : -AutoDelete et -AutoUninstall suppriment ou désinstallent SANS confirmation. Ils servent aux essais automatiques
# du projet ; lancés par erreur (raccourci, argument parasite), ils feraient une suppression réelle. Ils exigent donc PG20_TESTMODE=1.
if (($AutoDelete -or $AutoUninstall) -and $env:PG20_TESTMODE -ne '1') {
    throw "-AutoDelete et -AutoUninstall sont réservés aux essais : posez d'abord `$env:PG20_TESTMODE = '1' (ils agissent sans confirmation)."
}
if ($Quick) { Show-QuickPicker; return }

if ($TestBalloon) {
    Show-Balloon 'Info Pg20 : test' 'Si vous voyez ce message, les notifications de la surveillance fonctionnent.'
    Start-Sleep -Seconds 8
    if ($script:ni) { $script:ni.Dispose() }
    return
}

if ($Watch) {
    # Une seule surveillance à la fois (la tâche de fond et un lancement à la main ne se doublent pas). Verrou GLOBAL pour que
    # deux SESSIONS Windows (bureau + RDP, par exemple) ne puissent pas lancer chacune la leur : deux surveillances feraient
    # doublon (notifications en double, écritures concurrentes sur le carnet).
    $guard = $null
    foreach ($nom in @('Global\Pg20ClientsWatchRunning', 'Pg20ClientsWatchRunning')) {
        try { $guard = New-Object System.Threading.Mutex($false, $nom); break } catch { $guard = $null }
    }
    if (-not $guard) { Write-Host 'Impossible de créer le verrou de surveillance (droits insuffisants ?).'; return }
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
                    Show-Balloon 'Info Pg20 : nouveau poste RustDesk' ("ID " + (Format-RdId $n.id) + " vient de s'enregistrer sur votre serveur.")
                }
                foreach ($n in @($r.received)) {
                    Write-Watch ("FICHE REÇUE : {0} (ID {1}), code {2}{3}" -f $n.name, (Format-RdId $n.id), $n.code, (Format-ReplacesHint $n.replaces)) 'Yellow'
                    Show-Balloon 'Info Pg20 : fiche reçue' ("$($n.name) vient de s'installer (code de contrôle $($n.code)). Validez depuis le téléphone ou ouvrez Pg20-Clients.$(if (@($n.replaces).Count) { " Il semble remplacer l'ancien poste (ID $((@($n.replaces) | ForEach-Object { Format-RdId $_ }) -join ', ')) : à retirer dans Pg20-Clients." })")
                }
                foreach ($n in @($r.validated)) { Write-Watch ("VALIDÉ depuis le téléphone : {0} (ID {1})" -f $n.name, (Format-RdId $n.id)) 'Green' }
                foreach ($n in @($r.uninstalled)) {
                    Write-Watch ("DÉSINSTALLÉ à distance : {0} (ID {1}), retiré de la liste" -f $n.name, (Format-RdId $n.id)) 'Green'
                    Show-Balloon 'Info Pg20 : désinstallation terminée' ("$($n.name) s'est désinstallé tout seul : le client a été retiré de la liste.")
                }
                foreach ($n in @($r.ipChanges | Where-Object { $_ })) { Write-Watch ("ADRESSE INTERNET CHANGÉE : {0} (ID {1}) : {2} -> {3}" -f $n.name, (Format-RdId $n.id), $n.from, $n.to) 'DarkYellow' }
                foreach ($n in @($r.autoHidden | Where-Object { $_ })) { Write-Watch ("NETTOYAGE : « {0} » (ID {1}) masqué de la liste : remplacé par « {2} » (ID {3})" -f $n.name, (Format-RdId $n.id), $n.byName, (Format-RdId $n.by)) 'DarkGray' }
                foreach ($n in @($r.purged | Where-Object { $_ })) { Write-Watch ("PURGE : « {0} » (ID {1}) masqué depuis {2} jours : supprimé pour de bon (preuve d'acceptation gardée)" -f $n.name, (Format-RdId $n.id), $n.days) 'DarkGray' }
                # Purges automatiques du 2026-10-10 : postes remplacés (30 jours) et clients résiliés (30 jours, délai du contrat)
                foreach ($n in @($r.purgedReplaced | Where-Object { $_ })) { Write-Watch ("PURGE AUTO : « {0} » (ID {1}) effacé — poste remplacé, masqué depuis {2} jours (preuve d'acceptation gardée)" -f $n.name, (Format-RdId $n.id), $n.days) 'DarkGray' }
                foreach ($n in @($r.purgedResilie | Where-Object { $_ })) { Write-Watch ("PURGE AUTO : « {0} » (ID {1}) effacé — client résilié depuis {2} jours (délai contractuel de 30 jours, preuve d'acceptation gardée)" -f $n.name, (Format-RdId $n.id), $n.days) 'DarkGray' }
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

if ($Import -or $Sync -or $List -or $Connect -or $Forget -or $RestoreFromServer) {
    Use-Store {
        if ($RestoreFromServer) {
            $rr = Restore-FromArchive -Ask:(-not $Yes)
            Write-Host "  Restauration : $($rr.message)" -ForegroundColor $(if ($rr.ok) { 'Green' } else { 'Yellow' })
            foreach ($n in @($rr.restored)) { Write-Host "  >> RESTAURÉ : $($n.name) (ID $(Format-RdId $n.id))" -ForegroundColor Green }
            if ($rr.restored.Count) { Write-Host '  Lancez maintenant la synchronisation (-Sync) pour retrouver les adresses Internet, puis ouvrez le carnet.' -ForegroundColor DarkGray }
        }
        if ($Import) { $i = Import-Deployments; Write-Host "  Import : $($i.added) ajouté(s), $($i.updated) mis à jour ($($i.files) fichier(s) lu(s))." }
        if ($CleanUnknown) { Show-UnknownPeers }
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
Write-Host '=== Info Pg20 : clients ===' -ForegroundColor Green
$imp = Import-Deployments
if ($imp.files) { Write-Host "  Clé USB : $($imp.added) nouveau(x) client(s) importé(s), $($imp.updated) déjà connu(s)." -ForegroundColor Green }
else { Write-Host '  Aucune clé USB avec fiches clients détectée (branchez-la puis tapez i).' -ForegroundColor DarkGray }
$syncResult = Invoke-FeedSync
Show-SyncResult $syncResult
$newIds = @($syncResult.added | ForEach-Object { $_.id })

while ($true) {
    # Correctif du 2026-10-10 : la lecture ET l'affichage se font SOUS le verrou commun (Use-Store relit la liste du disque, puis nous laissons
    # le bloc écrire). Avant, la console relisait la liste à son tour et réécrivait tout le fichier sans verrou : une fiche validée entre-temps
    # par la surveillance (ou par la page) était écrasée, mot de passe compris.
    $actor = @{ action = ''; client = $null; label = ''; ok = $false }
    Use-Store {
        Show-List $newIds
        Write-Host ''
        Write-Host 'Numéro = se connecter | v N valider | c N copier le mot de passe | n N renommer | x N masquer | d N oublier (efface le mot de passe) | i importer la clé | s actualiser | a tout voir | u postes inconnus sur le serveur | q quitter' -ForegroundColor DarkCyan
        $in = (Read-Host 'Choix').Trim()
        if (-not $in -or $in -match '^[qQ]$') { return }
        $view = @(Get-View)
        if ($in -match '^[iI]$') { $actor.action = 'import'; return }
        if ($in -match '^[sS]$') { $actor.action = 'sync'; return }
        if ($in -match '^[uU]$') { $actor.action = 'unknown'; return }
        if ($in -match '^[aA]$') { $script:ShowAll = -not $script:ShowAll; return }
        if ($in -match '^([vcnxdVCNXD])\s*(\d+)$') {
            $act = $Matches[1].ToLower(); $rec = Resolve-Client $Matches[2] $view
            $actor.client = $rec; $actor.label = $rec.name
            switch ($act) {
                'v' { Confirm-Client $rec; $actor.action = 'validate'; $actor.ok = $true }
                'c' { $actor.action = 'copy' }
                'n' {
                    $nom = (Read-Host "  Nouveau nom pour l'ID $(Format-RdId $rec.id)").Trim()
                    if ($nom) { $rec.name = $nom; $rec.unknown = $false; Save-Store; $actor.action = 'renamed' }
                }
                'x' { $rec.status = 'Ignore'; Save-Store; $actor.action = 'masked' }
                'd' {
                    $ok = Read-Host "  Oublier $($rec.name) (ID $(Format-RdId $rec.id)) ? Son mot de passe sera effacé de ce PC. (o/N)"
                    if ($ok -match '^[oOyY]') { $nom = $rec.name; Forget-Client $rec; $actor.action = 'forgotten'; $actor.label = $nom }
                    else { $actor.action = 'cancelled' }
                }
            }
            return
        }
        $rec = Resolve-Client $in $view
        if ($rec.status -eq 'A valider') {
            $ok = Read-Host "  $($rec.name) (ID $(Format-RdId $rec.id)) n'est pas validé. Se connecter quand même ? (o/N)"
            if ($ok -notmatch '^[oOyY]') { $actor.action = 'connect-cancelled'; return }
        }
        $actor.client = $rec; $actor.action = 'connect'
    }
    # Actions faites HORS du verrou : elles touchent le réseau ou ouvrent une fenêtre, sans bloquer la surveillance.
    try {
        switch ($actor.action) {
            'import' { $i = Import-Deployments; Write-Host "  Import : $($i.added) ajouté(s), $($i.updated) mis à jour ($($i.files) fichier(s))." }
            'unknown' { Show-UnknownPeers }
            'sync' { $s = Invoke-FeedSync; Show-SyncResult $s; $newIds = @($s.added | ForEach-Object { $_.id }) }
            'validate' { Send-ServerValidated $actor.client; Write-Host "  $($actor.label) : validé." -ForegroundColor Green }
            'copy' { Copy-ClientPassword $actor.client }
            'renamed' { Write-Host "  $($actor.label) : renommé." -ForegroundColor Green }
            'masked' { Write-Host "  $($actor.label) : masqué (tapez a pour le revoir)." }
            'forgotten' { Write-Host "  $($actor.label) : oublié. Mot de passe effacé ; l'ID reste masqué (le serveur le connaît toujours)." -ForegroundColor Green }
            'cancelled' { Write-Host '  Annulé.' }
            'connect' { Open-Client $actor.client }
        }
    }
    catch { Write-Host "  ! $($_.Exception.Message)" -ForegroundColor Yellow }
}
