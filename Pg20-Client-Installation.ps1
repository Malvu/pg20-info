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
    .\Pg20-Client-Installation.ps1 -ClientName "Dupont SARL"

.EXAMPLE
    # Votre serveur auto-hébergé
    .\Pg20-Client-Installation.ps1 -ClientName "Dupont SARL" -Server rd.mondomaine.fr -Key "AbCdEf...="

.EXAMPLE
    # Avec la chaîne exportée depuis RustDesk (Paramètres > Réseau > Exporter la config serveur)
    .\Pg20-Client-Installation.ps1 -ClientName "Dupont SARL" -ConfigString "0nI9...."

.EXAMPLE
    # Désinstallation
    .\Pg20-Client-Installation.ps1 -Uninstall
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ClientName,                    # si absent : le nom saisi dans la fenêtre des conditions est repris, sinon demandé à l'écran (Entrée = nom du poste)
    [string]$InstallerPath,                 # installeur local (sinon téléchargé depuis GitHub)
    [string]$Version,                       # ex. 1.4.9 ; vide = dernière version stable
    [string]$ConfigString,                  # chaîne "Exporter la config serveur"
    [string]$Server,                        # ex. rd.mondomaine.fr
    [string]$Relay,                         # facultatif, par défaut = $Server
    [string]$ApiServer,                     # facultatif (RustDesk Pro / console web)
    [string]$Key,                           # clé publique du serveur (id_ed25519.pub)
    [string]$Password,                      # généré aléatoirement si absent (-AskPassword pour le demander à l'écran)
    [ValidateRange(12, 64)][int]$PasswordLength = 20,
    [string]$OutDir,                        # dossier du CSV (défaut : dossier du script)
    [switch]$NoSaveCredentials,             # ne pas écrire le CSV
    [switch]$SkipAuthPolicy,                # ne pas forcer "mot de passe permanent uniquement"
    [switch]$SkipPortHardening,             # ne pas couper l'accès direct par IP et la découverte du réseau local, ni ajouter les 2 règles de blocage du pare-feu (par défaut : coupés et bloqués)
    [switch]$ForceReinstall,
    [switch]$CleanReinstall,                # RustDesk déjà présent (ou ses restes) et relié à VOTRE serveur : l'efface d'abord, le poste repart avec une identité neuve (sinon le serveur refuse la fiche)
    [switch]$NoPrompt,                      # aucune question à l'écran (déploiement par script, GPO, RMM)
    [string]$TechPublicKey,                 # clé publique RSA (XML) du technicien : le mot de passe est chiffré dans le CSV
    [string]$InboxUrl,                      # réception des fiches sur votre serveur : hôte[:port], port par défaut 21120
    [string]$InboxPin,                      # empreinte SHA-256 (64 hex) du certificat TLS de ce service : seul ce certificat est accepté
    [switch]$NoInbox,                       # ne pas envoyer la fiche au serveur
    [string]$TermsPath,                     # texte des conditions d'installation (intégré à l'exe par Pg20-Exe-Compiler -TermsFile) : leur acceptation est exigée
    [switch]$AcceptTerms,                   # déploiement par script : accepte les conditions sans fenêtre (la preuve note « accepté par paramètre »)
    [string]$AgentPath,                     # tâche de maintenance (Pg20-Client-Maintenance.ps1, intégrée à l'exe par Pg20-Exe-Compiler) : exécute un ordre de désinstallation signé par le technicien
    [string]$BrandName,                     # marque du technicien (intégrée à l'exe par Pg20-Exe-Compiler -BrandName) : en-tête de la fenêtre d'acceptation, titres
    [string]$LogoPath,                      # logo .png de la marque (intégré à l'exe par Pg20-Exe-Compiler -LogoFile)
    [switch]$NoAgent,                       # ne pas installer la tâche de maintenance
    [switch]$AskPassword,                   # demande le mot de passe permanent à l'écran (par défaut : généré et transmis chiffré au technicien, personne n'a à le saisir)
    [switch]$ShowSteps,                     # affiche chaque étape de l'installation (par défaut l'écran interactif n'affiche que le résumé ; les étapes sont notées dans %TEMP%\Pg20-Info-Install.log)
    [switch]$ExplorerClosed,               # donné par le lanceur : il a déjà fermé la fenêtre de l'Explorateur au double-clic (le script ne la cherche plus : cela compilait du C# au démarrage)
    [string]$LaunchDir,                    # dossier d'où l'exe a été lancé (donné par le lanceur) : la fenêtre de l'Explorateur qui l'affiche est fermée au début de l'installation
    [switch]$NoGui,                        # pas de fenêtre de progression : tout s'affiche dans la console (déploiement par script, dépannage)
    [switch]$Leger,                        # CLIENT LÉGER : session de dépannage ponctuelle SANS installation (RustDesk tourne depuis un dossier temporaire, rien ne reste après la fin) ; figé dans l'exe par Pg20-Exe-Fabriquer -Light
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RdExe       = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
$ServiceName = 'RustDesk'
$ServiceToml = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml'

# Écran interactif (l'exe lancé par un client) : seul le résumé final s'affiche. Les étapes sont gardées en mémoire, notées dans %TEMP%\Pg20-Info-Install.log
# et montrées en cas d'erreur (sinon on ne verrait que l'erreur, sans savoir où l'on en était). Les avertissements [!] s'affichent toujours.
$script:QuietSteps = $false
$script:StepBuffer = New-Object System.Collections.Generic.List[object]
$script:StepLog = Join-Path $env:TEMP 'Pg20-Info-Install.log'
try { if ((Test-Path -LiteralPath $script:StepLog) -and (Get-Item -LiteralPath $script:StepLog).Length -gt 200000) { [IO.File]::Delete($script:StepLog) } } catch { }
function Write-Line([string]$Text, [string]$Color) {
    if (-not $script:QuietSteps) { Write-Host $Text -ForegroundColor $Color; return }
    $script:StepBuffer.Add(@($Text, $Color))
    try { [IO.File]::AppendAllText($script:StepLog, ('{0:yyyy-MM-dd HH:mm:ss}  {1}{2}' -f (Get-Date), $Text, [Environment]::NewLine), (New-Object Text.UTF8Encoding($false))) } catch { }
}
function Write-Step($m)   { Write-Line "[*] $m" 'Cyan'; if ($script:UiOn) { Update-UiFromStep ([string]$m) } }
function Write-Ok($m)     { Write-Line "[+] $m" 'Green' }
function Write-Detail($m) { Write-Line "    $m" 'Gray' }
# Les avertissements sont aussi gardés pour le résumé (test explicite : une liste vide est « fausse » pour PowerShell)
function Write-Warn($m)   { Write-Host "[!] $m" -ForegroundColor Yellow; if ($null -ne $script:UiWarnings) { $script:UiWarnings.Add([string]$m) } }
function Show-BufferedSteps {
    if (-not $script:QuietSteps -or -not $script:StepBuffer.Count) { return }
    Write-Host ''
    Write-Host '--- Détail des étapes effectuées avant l''erreur ---' -ForegroundColor DarkGray
    foreach ($l in $script:StepBuffer) { Write-Host $l[0] -ForegroundColor $l[1] }
    $script:StepBuffer.Clear()
}

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

# Pare-feu Windows : l'installeur de RustDesk crée une règle ENTRANTE qui autorise tous les ports de rustdesk.exe. On y ajoute deux règles qui BLOQUENT (un blocage l'emporte sur une
# autorisation) les seuls ports des fonctions que l'installation désactive : accès direct par IP (TCP 21118) et découverte du réseau local (UDP 21119). Aucun autre trafic n'est touché ;
# les connexions SORTANTES vers le serveur du technicien et leurs réponses passent comme avant. Les noms contiennent « RustDesk » : la désinstallation complète les efface avec les autres règles RustDesk.
$script:FirewallBlockRules = @(
    @{ Name = 'RustDesk (Pg20 Info) : entrant bloqué TCP 21118 (accès direct par IP)'; Protocol = 'TCP'; Port = 21118 },
    @{ Name = 'RustDesk (Pg20 Info) : entrant bloqué UDP 21119 (découverte du réseau local)'; Protocol = 'UDP'; Port = 21119 }
)
# L'installeur de RustDesk laisse un script « rustdesk_install_<empreinte>.cmd » dans le dossier temporaire de la session qui l'a lancé, à chaque installation (RustDesk ne l'efface pas).
# On efface ceux de ce dossier (les anciennes installations y comprises) ; -TempDir sert aux tests. Rend le nombre de scripts effacés.
function Remove-RustDeskInstallScripts([string]$TempDir = '') {
    if (-not $TempDir) { $TempDir = [IO.Path]::GetTempPath() }
    $n = 0
    if (-not (Test-Path -LiteralPath $TempDir)) { return 0 }
    foreach ($pat in 'rustdesk_install_*.cmd', 'rustdesk_uninstall_*.cmd') {
        foreach ($f in @(Get-ChildItem -LiteralPath $TempDir -File -Filter $pat -Force -ErrorAction SilentlyContinue)) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ } catch { }
        }
    }
    $n
}
function Set-PortFirewallRules([string]$Program) {
    $made = 0
    foreach ($r in $script:FirewallBlockRules) {
        $old = @(Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)
        if ($old.Count) { $old | Remove-NetFirewallRule -ErrorAction Stop }          # rejouable : jamais de doublon
        [void](New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Block -Program $Program -Protocol $r.Protocol -LocalPort $r.Port -Profile Any -Enabled True -ErrorAction Stop)
        $made++
    }
    $made
}

# ---------------------------------------------------------------- Fenêtres système (progression, résultat, erreur)
# L'exe lancé par un client n'affiche plus de console : une vraie fenêtre Windows avec une barre de progression, puis le résumé, ou l'erreur avec ses détails.
# La fenêtre vit dans SON PROPRE fil (espace d'exécution STA) : elle ne se fige jamais, même pendant les attentes réseau ou l'installeur de RustDesk. Le script
# principal ne fait que déposer l'état (pourcentage, texte, mode) dans une table partagée ; la fenêtre le lit toutes les 100 ms. Tout est facultatif : si la fenêtre
# ne peut pas s'ouvrir, l'installation continue (affichage dans la console s'il y en a une, boîte de message en dernier recours).
$script:Ui = $null; $script:UiOn = $false; $script:UiPs = $null; $script:UiAsync = $null
$script:UiWarnings = New-Object System.Collections.Generic.List[string]
$script:UiNoMessageBox = $false           # (tests) pas de boîte de message de secours
# Étapes connues : motif du texte de Write-Step, pourcentage atteint, texte affiché. Ordre croissant : entre deux étapes, la barre avance doucement jusqu'à la suivante.
$script:UiSteps = @(
    , @('^Attente de la disparition', 14, 'Effacement de l''ancienne installation…')
    , @('^Recherche de l', 16, 'Recherche de RustDesk…')
    , @('^Téléchargement', 20, 'Téléchargement de RustDesk…')
    , @('^Installation silencieuse', 40, 'Installation de RustDesk…')
    , @('^Vérification du service', 60, 'Démarrage du service RustDesk…')
    , @('^Attente de la disponibilité', 66, 'Attente du service RustDesk…')
    , @('^Application (du serveur|de la configuration)', 72, 'Configuration de l''accès pour le technicien…')
    , @('^Définition du mot de passe', 78, 'Sécurisation de l''accès…')
    , @('^Politique d', 82, 'Sécurisation de l''accès…')
    , @('^Réduction de l', 84, 'Sécurisation de l''accès…')
    , @('^Vérification finale', 86, 'Vérifications finales…')
    , @('^Installation de la tâche', 90, 'Installation de la tâche de maintenance…')
    , @('^Envoi de la fiche', 94, 'Envoi de la fiche au technicien…')
)

function Get-UiCode {
@'
param($ui)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
function Clr([int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($r, $g, $b) }
function Fnt([double]$size, [bool]$bold = $false) { New-Object System.Drawing.Font('Segoe UI', $size, $(if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular })) }
function Lbl([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $font = $null, $color = $null) {
    $l = New-Object System.Windows.Forms.Label
    $l.UseMnemonic = $false; $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, $h)
    if ($font) { $l.Font = $font }
    if ($color) { $l.ForeColor = $color }
    $l
}
$gray = Clr 90 90 90; $green = Clr 14 122 84; $red = Clr 179 38 30; $amber = Clr 138 82 0
$logo = $null
if ($ui.logo -and (Test-Path -LiteralPath $ui.logo)) {
    try { $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($ui.logo)); $logo = [System.Drawing.Image]::FromStream($ms) } catch { $logo = $null }
}
$dy = $(if ($ui.brand -or $ui.client -or $logo) { 64 } else { 0 })
$st = @{ mode = ''; disp = 0.0; wantH = 0; screen = $null }
# Place la fenêtre au CENTRE de la zone de travail de l'écran (hors barre des tâches) où se trouvait le pointeur au départ, et la raccourcit (défilement) si elle ne
# tient pas : écran de portable en 1366 x 768, mise à l'échelle 125 ou 150 %... Appelée à chaque changement de contenu : la fenêtre change de hauteur
# entre la progression, le résumé et l'erreur, et doit rester centrée et entièrement visible.
function Fit-Center {
    if ($ui.workArea) { $p = ([string]$ui.workArea).Split(','); $wa = New-Object System.Drawing.Rectangle([int]$p[0], [int]$p[1], [int]$p[2], [int]$p[3]) }
    else {
        if (-not $st.screen) { $st.screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position) }
        $wa = $st.screen.WorkingArea
    }
    $chromeH = $f.Height - $f.ClientSize.Height
    $maxH = $wa.Height - $chromeH - 12
    $h = [int]$st.wantH
    $w = 560                                                    # avec défilement, la barre verticale prend sa place : la fenêtre s'élargit d'autant (pas de barre horizontale)
    if ($h -gt $maxH) { $h = [Math]::Max(200, $maxH); $body.AutoScroll = $true; $w = 560 + [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth } else { $body.AutoScroll = $false }
    $f.ClientSize = New-Object System.Drawing.Size($w, $h)
    $body.Size = New-Object System.Drawing.Size($w, [Math]::Max(100, $h - $dy))
    $x = $wa.Left + [int](($wa.Width - $f.Width) / 2); $y = $wa.Top + [int](($wa.Height - $f.Height) / 2)
    $f.Location = New-Object System.Drawing.Point([Math]::Max($wa.Left, $x), [Math]::Max($wa.Top, $y))
}

$f = New-Object System.Windows.Forms.Form
$f.Text = $(if ($ui.caption) { [string]$ui.caption } elseif ($ui.brand) { "$($ui.brand) - Installation" } else { 'Installation' })
$f.StartPosition = 'Manual'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ControlBox = $false
$f.Font = Fnt 10; $f.TopMost = $true
$f.ClientSize = New-Object System.Drawing.Size(560, (210 + $dy))
if ($dy -gt 0) {
    $x = 14
    if ($logo) {
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Image = $logo; $pic.SizeMode = 'Zoom'
        $pic.Location = New-Object System.Drawing.Point(14, 8); $pic.Size = New-Object System.Drawing.Size(48, 48)
        $f.Controls.Add($pic); $x = 72
    }
    $f.Controls.Add((Lbl ([string]$ui.brand) $x 6 (546 - $x) 30 (Fnt 15 $true)))
    $f.Controls.Add((Lbl $(if ($ui.client) { "Installation pour : $($ui.client)" } else { '' }) $x 36 (546 - $x) 22 $null $gray))
    $sep = New-Object System.Windows.Forms.Label
    $sep.BorderStyle = 'Fixed3D'; $sep.Text = ''
    $sep.Location = New-Object System.Drawing.Point(14, 62); $sep.Size = New-Object System.Drawing.Size(532, 2)
    $f.Controls.Add($sep)
}
$body = New-Object System.Windows.Forms.Panel
$body.Location = New-Object System.Drawing.Point(0, $dy); $body.Size = New-Object System.Drawing.Size(560, 900)
$f.Controls.Add($body)

$enterProgress = {
    $body.Controls.Clear()
    $t = Lbl $(if ($ui.heading) { [string]$ui.heading } else { 'Installation en cours' }) 14 14 532 28 (Fnt 13 $true)
    $st.step = Lbl ([string]$ui.text) 14 54 532 26 (Fnt 11)
    $b = New-Object System.Windows.Forms.ProgressBar
    $b.Minimum = 0; $b.Maximum = 100; $b.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $b.Location = New-Object System.Drawing.Point(14, 92); $b.Size = New-Object System.Drawing.Size(532, 26)
    $st.bar = $b
    $st.pct = Lbl '0 %' 14 124 532 22 $null $gray
    $st.pct.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $note = Lbl $(if ($ui.note) { [string]$ui.note } else { 'Merci de patienter, cela prend en général une à deux minutes. Ne fermez pas cette fenêtre et n''éteignez pas le PC.' }) 14 156 532 44 $null $gray
    $body.Controls.AddRange(@($t, $st.step, $b, $st.pct, $note))
    $st.wantH = $dy + 210; Fit-Center
    $f.ControlBox = $false
}

# « Ne pas éjecter » : annule l'éjection automatique de la clé USB ; la fenêtre reste ouverte jusqu'à « Fermer »
$keepKey = {
    $ui.keep = $true; $st.ejectUntil = $null
    if ($st.eject) { $st.eject.Visible = $false }
    if ($st.status) { $st.status.Text = ([string][char]0x2714 + ' Validé par le technicien. La clé USB reste branchée : vous pouvez fermer cette fenêtre.') }
}

$enterResult = {
    $body.Controls.Clear(); $y = 12
    $body.Controls.Add((Lbl ([string][char]0x2714 + '  ' + [string]$ui.title) 14 $y 532 32 (Fnt 14 $true) $green)); $y += 46
    foreach ($row in @($ui.rows)) {
        $val = [string]$row[1]
        $lines = [Math]::Max(1, [Math]::Ceiling($val.Length / 44.0))
        $h = 22 * $lines
        $body.Controls.Add((Lbl ([string]$row[0]) 14 $y 190 22 $null $gray))
        $v = New-Object System.Windows.Forms.TextBox
        $v.ReadOnly = $true; $v.BorderStyle = 'None'; $v.BackColor = $f.BackColor; $v.Multiline = $true; $v.WordWrap = $true; $v.TabStop = $false
        $v.Text = $val; $v.Location = New-Object System.Drawing.Point(210, ($y + 1)); $v.Size = New-Object System.Drawing.Size(336, $h)
        $body.Controls.Add($v); $y += $h + 6
    }
    if ($ui.code) {
        $pan = New-Object System.Windows.Forms.Panel
        $pan.BackColor = Clr 255 244 214; $pan.Location = New-Object System.Drawing.Point(14, ($y + 4)); $pan.Size = New-Object System.Drawing.Size(532, 96)
        if ($ui.codeLabel) {          # client léger : l'identifiant (9 ou 10 chiffres) en grand, sur toute la largeur
            $pan.Controls.Add((Lbl ([string]$ui.codeLabel) 14 8 500 22 $null $amber))
            $pan.Controls.Add((Lbl ([string]$ui.code) 14 30 500 40 (Fnt 24 $true)))
            $pan.Controls.Add((Lbl ([string]$ui.codeNote) 14 70 510 22 $null $gray))
        }
        else {
            $pan.Controls.Add((Lbl 'Code de contrôle' 14 8 300 22 $null $amber))
            $pan.Controls.Add((Lbl ([string]$ui.code) 14 30 160 56 (Fnt 30 $true)))          # 160 px : assez pour 4 chiffres en gras, et sans recouvrir la phrase qui commence à 190 px
            $pan.Controls.Add((Lbl 'Le technicien le compare avec celui de son téléphone avant de valider.' 190 38 330 44 $null $gray))
        }
        $body.Controls.Add($pan); $y += 108
    }
    $warn = @($ui.warnings | Where-Object { $_ })
    if ($warn.Count) {
        $wt = 'À noter :' + "`r`n" + (($warn | ForEach-Object { '• ' + $_ }) -join "`r`n")
        $wl = [Math]::Min(140, 22 * (1 + $warn.Count) + 22 * [Math]::Floor($wt.Length / 70))
        $body.Controls.Add((Lbl $wt 14 ($y + 4) 532 $wl $null $amber)); $y += $wl + 8
    }
    if ($ui.info) {
        $il = 22 * [Math]::Max(1, [Math]::Ceiling(([string]$ui.info).Length / 66.0))
        $body.Controls.Add((Lbl ([string]$ui.info) 14 ($y + 4) 532 $il $null $gray)); $y += $il + 8
    }
    $st.status = Lbl '' 14 ($y + 6) 532 44 (Fnt 10 $true)
    $body.Controls.Add($st.status); $y += 52
    $m = New-Object System.Windows.Forms.ProgressBar
    $m.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee; $m.MarqueeAnimationSpeed = 30; $m.Visible = $false
    $m.Location = New-Object System.Drawing.Point(14, $y); $m.Size = New-Object System.Drawing.Size(532, 8); $st.marq = $m
    $body.Controls.Add($m); $y += 22
    $c = New-Object System.Windows.Forms.Button
    $cw = $(if ($ui.closeText) { 210 } else { 100 })
    $c.Text = $(if ($ui.closeText) { [string]$ui.closeText } else { 'Fermer' }); $c.Font = Fnt 10 $true
    $c.Location = New-Object System.Drawing.Point((546 - $cw), $y); $c.Size = New-Object System.Drawing.Size($cw, 36)
    $c.Add_Click({ $f.Close() })
    $body.Controls.Add($c); $f.AcceptButton = $c
    $st.eject = $null; $st.ejectUntil = $null
    if ($ui.canEject) {
        $ej = New-Object System.Windows.Forms.Button
        $ej.Text = 'Ne pas éjecter'; $ej.Font = Fnt 10 $true; $ej.Visible = $false
        $ej.Location = New-Object System.Drawing.Point(14, $y); $ej.Size = New-Object System.Drawing.Size(180, 36)
        $ej.Add_Click({ & $keepKey })
        $body.Controls.Add($ej); $st.eject = $ej
    }
    $st.wantH = $dy + $y + 52; Fit-Center
    $f.ControlBox = $true
    $f.TopMost = [bool]$ui.topMost          # client léger : au premier plan tant que le technicien n'est pas connecté
}

$enterError = {
    $body.Controls.Clear(); $y = 12
    $body.Controls.Add((Lbl ([string][char]0x2716 + '  L''installation n''a pas abouti') 14 $y 532 32 (Fnt 14 $true) $red)); $y += 46
    $ml = 22 * [Math]::Max(2, [Math]::Min(5, [Math]::Ceiling(([string]$ui.message).Length / 60.0)))
    $body.Controls.Add((Lbl ([string]$ui.message) 14 $y 532 $ml)); $y += $ml + 10
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'; $tb.WordWrap = $true; $tb.BackColor = [System.Drawing.Color]::White
    $tb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $tb.Location = New-Object System.Drawing.Point(14, $y); $tb.Size = New-Object System.Drawing.Size(532, 150)
    $tb.Text = ([string]$ui.details -replace "(?<!`r)`n", "`r`n"); $body.Controls.Add($tb); $y += 160
    $cp = New-Object System.Windows.Forms.Button
    $cp.Text = 'Copier les détails'; $cp.Location = New-Object System.Drawing.Point(14, $y); $cp.Size = New-Object System.Drawing.Size(190, 36)
    $cp.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText([string]$ui.details) } catch { } })
    $body.Controls.Add($cp)
    $c = New-Object System.Windows.Forms.Button
    $c.Text = 'Fermer'; $c.Font = Fnt 10 $true
    $c.Location = New-Object System.Drawing.Point(446, $y); $c.Size = New-Object System.Drawing.Size(100, 36)
    $c.Add_Click({ $f.Close() })
    $body.Controls.Add($c)
    $st.wantH = $dy + $y + 52; Fit-Center
    $f.ControlBox = $true
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({
    try {
        if ($ui.close) { $timer.Stop(); $st.mode = 'closing'; $f.Close(); return }
        if ($ui.mode -ne $st.mode) {
            $st.mode = [string]$ui.mode
            if ($st.mode -eq 'progress') { & $enterProgress } elseif ($st.mode -eq 'result') { & $enterResult } elseif ($st.mode -eq 'error') { & $enterError }
        }
        if ($st.mode -eq 'progress') {
            $target = [double]$ui.pct; $creep = [double]$ui.creepTo
            if ($st.disp -lt $target) { $st.disp = [Math]::Min($target, $st.disp + [Math]::Max(0.8, ($target - $st.disp) * 0.25)) }
            elseif ($st.disp -lt $creep) { $st.disp = [Math]::Min($creep, $st.disp + 0.03) }
            $v = [int][Math]::Max(0, [Math]::Min(100, [Math]::Floor($st.disp)))
            if ($st.bar.Value -ne $v) { $st.bar.Value = $v; $st.pct.Text = "$v %" }
            if ($st.step.Text -ne [string]$ui.text) { $st.step.Text = [string]$ui.text }
            $ui.shown = $v
        }
        elseif ($st.mode -eq 'result' -and $st.status) {
            $s = [string]$ui.status
            if ($s -ne $st.lastStatus) {
                $st.lastStatus = $s
                switch ($s) {
                    'waiting'     { $st.status.ForeColor = $amber; $st.status.Text = 'En attente de la validation du technicien…'; $st.marq.Visible = $true }
                    'validated'   { $st.status.ForeColor = $green; $st.status.Text = ([string][char]0x2714 + ' Validé par le technicien. Cette fenêtre va se fermer.'); $st.marq.Visible = $false
                                    if ($st.eject) { $st.eject.Visible = $true; $st.ejectUntil = (Get-Date).AddSeconds([int]$ui.ejectSeconds) } }       # exe sur une clé USB : éjection annoncée, annulable pendant quelques secondes
                    'light'       { $st.status.ForeColor = $green; $st.status.Text = ([string][char]0x2714 + ' Session ouverte : le technicien peut se connecter. Fermez cette fenêtre pour y mettre fin.'); $st.marq.Visible = $false }
                    'connected'   { $st.status.ForeColor = $green; $st.status.Text = ([string][char]0x2714 + ' Le technicien est connecté. Pour mettre fin à la session, cliquez sur « Terminer la session ».'); $st.marq.Visible = $false }
                    'ended'       { $st.status.ForeColor = $amber; $st.status.Text = 'Le technicien s''est déconnecté. Cliquez sur « Terminer la session » pour tout effacer, ou attendez-le s''il doit se reconnecter.'; $st.marq.Visible = $false }
                    'timeout'     { $st.status.ForeColor = $amber; $st.status.Text = 'Le technicien n''a pas encore validé : il le fera depuis son téléphone. Vous pouvez fermer cette fenêtre.'; $st.marq.Visible = $false }
                    'unavailable' { $st.status.ForeColor = $amber; $st.status.Text = 'Suivi de la validation indisponible : le technicien validera depuis son téléphone. Vous pouvez fermer cette fenêtre.'; $st.marq.Visible = $false }
                    default       { $st.status.Text = ''; $st.marq.Visible = $false }
                }
            }
        }
        if ($st.ejectUntil) {
            $left = [int][Math]::Ceiling(($st.ejectUntil - (Get-Date)).TotalSeconds)
            if ($left -le 0) { $st.ejectUntil = $null; $st.mode = 'closing'; $f.Close(); return }
            $msg = ([string][char]0x2714 + ' Validé par le technicien. La clé USB va être éjectée dans ' + $left + ' s : vous pourrez ensuite la retirer.')
            if ($st.status.Text -ne $msg) { $st.status.Text = $msg }
        }
        $ui.ejectShown = [bool]($st.eject -and $st.eject.Visible)
        $ui.geom = ($f.Left.ToString() + ',' + $f.Top + ',' + $f.Width + ',' + $f.Height + ',' + $body.AutoScroll + ',' + $body.HorizontalScroll.Visible)
        if ($ui.press) { $p = [string]$ui.press; $ui.press = $null; if ($p -eq 'close') { $st.mode = 'closing'; $f.Close() } elseif ($p -eq 'keep' -and $st.eject) { & $keepKey } }
        if ($ui.windowCmd) {         # client léger : la fenêtre reste au premier plan tant que le technicien n'est pas connecté, se réduit dès qu'il l'est
            $wc = [string]$ui.windowCmd; $ui.windowCmd = $null
            if ($wc -eq 'minimize') { $f.TopMost = $false; $f.WindowState = [System.Windows.Forms.FormWindowState]::Minimized }
            elseif ($wc -eq 'restore') { $f.WindowState = [System.Windows.Forms.FormWindowState]::Normal; $f.TopMost = [bool]$ui.topMost; $f.Activate() }
        }
        if ($ui.shot) {
            $path = [string]$ui.shot; $ui.shot = $null
            $bmp = New-Object System.Drawing.Bitmap($f.Width, $f.Height)
            $f.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $f.Width, $f.Height))); $bmp.Save($path); $bmp.Dispose(); $ui.shotDone = $true
        }
    }
    catch { $ui.uiError = [string]$_.Exception.Message }
})
# fermer la fenêtre de progression par Alt+F4 ne doit pas la faire disparaître : l'installation continue
$f.Add_FormClosing({ param($s, $e) if (-not $ui.close -and $st.mode -eq 'progress') { $e.Cancel = $true } })
$f.Add_FormClosed({ $ui.closed = $true })
$f.Add_Shown({ $f.Activate(); $ui.ready = $true })
& $enterProgress; $st.mode = 'progress'
$timer.Start()
[System.Windows.Forms.Application]::Run($f)
$ui.closed = $true
'@
}

function Start-UiWindow {
    param([string]$Brand = '', [string]$LogoPath = '', [string]$ClientName = '', [string]$WorkArea = '', [string]$Caption = '', [string]$Heading = '', [string]$Note = '')      # -WorkArea « x,y,largeur,hauteur » : (tests) simule un autre écran
    if ($script:UiOn) { return $true }
    try {
        $ui = [hashtable]::Synchronized(@{
                caption = $Caption; heading = $Heading; note = $Note; codeLabel = ''; codeNote = ''; closeText = ''; topMost = $false; windowCmd = $null
                brand = $Brand; logo = $LogoPath; client = $ClientName; mode = 'progress'; pct = 0.0; creepTo = 0.0; text = 'Préparation…'
                ready = $false; closed = $false; close = $false; press = $null; shot = $null; shotDone = $false; shown = 0; uiError = ''
                status = ''; title = ''; rows = @(); code = ''; warnings = @(); info = ''; message = ''; details = ''; workArea = $WorkArea; geom = ''; canEject = $false; keep = $false; ejectSeconds = 4; ejectShown = $false
            })
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [Threading.ApartmentState]::STA; $rs.ThreadOptions = [Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript((Get-UiCode)).AddArgument($ui)
        $async = $ps.BeginInvoke()
        for ($i = 0; $i -lt 150 -and -not $ui.ready -and -not $async.IsCompleted; $i++) { [Threading.Thread]::Sleep(100) }
        if (-not $ui.ready) {
            $why = ''; try { $why = (@($ps.Streams.Error | ForEach-Object { [string]$_ }) -join ' ; ') } catch { }
            try { $ps.Stop() } catch { }
            throw "la fenêtre ne s'est pas ouverte $why"
        }
        $script:Ui = $ui; $script:UiPs = $ps; $script:UiAsync = $async; $script:UiOn = $true
        $true
    }
    catch { $script:UiOn = $false; Write-Line "    (fenêtre d'installation indisponible : $($_.Exception.Message))" 'Gray'; $false }
}

function Set-UiProgress([double]$Pct, [string]$Text = '', [double]$CreepTo = -1) {
    if (-not $script:UiOn) { return }
    try {
        if ($Text) { $script:Ui.text = $Text }
        $script:Ui.pct = [double]$Pct
        $script:Ui.creepTo = $(if ($CreepTo -ge 0) { [double]$CreepTo } else { [double]$Pct })
    }
    catch { }
}

# Appelé par Write-Step : fait avancer la barre selon l'étape annoncée
function Update-UiFromStep([string]$Text) {
    if (-not $script:UiOn) { return }
    $steps = @($script:UiSteps)
    for ($i = 0; $i -lt $steps.Count; $i++) {
        if ($Text -match $steps[$i][0]) {
            $next = $(if ($i + 1 -lt $steps.Count) { [double]$steps[$i + 1][1] - 1 } else { 99 })
            Set-UiProgress ([double]$steps[$i][1]) ([string]$steps[$i][2]) $next
            return
        }
    }
}

function Show-UiResult {
    param([string]$Title, $Rows, [string]$Code = '', $Warnings = @(), [string]$Info = '', [string]$CodeLabel = '', [string]$CodeNote = '', [string]$CloseText = '')
    if (-not $script:UiOn) { return $false }
    try {
        $u = $script:Ui
        $u.title = $Title; $u.rows = @($Rows); $u.code = $Code; $u.warnings = @($Warnings); $u.info = $Info; $u.status = ''; $u.canEject = [bool]$script:CanEject; $u.codeLabel = $CodeLabel; $u.codeNote = $CodeNote; $u.closeText = $CloseText
        $u.pct = 100.0; $u.creepTo = 100.0
        [Threading.Thread]::Sleep(450)            # laisse la barre atteindre 100 % avant de passer au résumé
        $u.mode = 'result'
        $true
    }
    catch { $false }
}

function Set-UiStatus([string]$Status) { if ($script:UiOn) { try { $script:Ui.status = $Status } catch { } } }

function Wait-UiClosed {
    param([int]$MaxSec = 3600, [scriptblock]$OnTick)         # -OnTick : appelé à chaque tour de la boucle d'attente (client léger : suivi de la connexion du technicien)
    if (-not $script:UiOn) { return }
    $auto = 0; if ($env:PG20_UI_AUTOCLOSE) { [void][int]::TryParse($env:PG20_UI_AUTOCLOSE, [ref]$auto) }      # (tests) fermeture automatique après N secondes
    $t0 = Get-Date
    while (-not $script:Ui.closed -and ((Get-Date) - $t0).TotalSeconds -lt $MaxSec) {
        [Threading.Thread]::Sleep(150)
        if ($OnTick) { try { & $OnTick } catch { } }
        if ($auto -gt 0 -and ((Get-Date) - $t0).TotalSeconds -ge $auto) { foreach ($x in @($(if ($env:PG20_UI_AUTOPRESS) { $env:PG20_UI_AUTOPRESS } else { 'close' }) -split ',')) { $script:Ui.press = $x; [Threading.Thread]::Sleep(1000) }; $auto = 0 }
    }
}

function Stop-UiWindow {
    if (-not $script:UiOn) { return }
    try { $script:Ui.close = $true; for ($i = 0; $i -lt 30 -and -not $script:UiAsync.IsCompleted; $i++) { [Threading.Thread]::Sleep(100) } } catch { }
    $script:UiOn = $false
}

# Erreur : fenêtre avec le message et les détails (ouverte au besoin) ; boîte de message système en dernier recours. Le lanceur est prévenu (fichier témoin).
function Show-UiError {
    param([string]$Message, [string]$Details = '', [string]$Brand = '', [string]$LogoPath = '', [string]$ClientName = '')
    try {
        if (-not $script:UiOn) { [void](Start-UiWindow -Brand $Brand -LogoPath $LogoPath -ClientName $ClientName) }
        if ($script:UiOn) {
            try { if ($PSCommandPath) { [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $PSCommandPath) 'ui-error-shown'), '1') } } catch { }
            $u = $script:Ui; $u.message = $Message; $u.details = $Details; $u.mode = 'error'
            Wait-UiClosed
            return $true
        }
    }
    catch { }
    if (-not $script:UiNoMessageBox) {
        try { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show("$Message`r`n`r`nDétails : $($script:StepLog)", 'Installation', 'OK', 'Error') } catch { }
    }
    $false
}

# Ferme la fenêtre de l'Explorateur de fichiers ouverte sur le dossier d'où l'exe a été lancé (en général la clé USB) : elle encombre l'écran du client
# et peut empêcher d'éjecter la clé. SEULE la fenêtre qui affiche exactement ce dossier est fermée, aucune autre. Sans effet si l'exe a été lancé d'un terminal.
function Close-LaunchExplorerWindow([string]$Dir) {
    if (-not $Dir) { return }
    try {
        $target = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
        # l'Explorateur annonce toujours le chemin LONG : on ramène aussi le dossier de l'exe à sa forme longue (un chemin 8.3 comme C:\Users\NOM~1 sinon ne correspondrait jamais)
        try {
            Add-Type -Namespace Pg20 -Name LongPath -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern int GetLongPathName(string shortPath, System.Text.StringBuilder longPath, int size);' -ErrorAction Stop
        }
        catch { }
        try { $sb = New-Object System.Text.StringBuilder 1024; if ([Pg20.LongPath]::GetLongPathName($target, $sb, 1024) -gt 0) { $target = $sb.ToString().TrimEnd('\') } } catch { }
        $shell = New-Object -ComObject Shell.Application
        $hits = @()
        foreach ($w in @($shell.Windows())) {
            try {
                if ([string]$w.FullName -notmatch '(?i)\\explorer\.exe$') { continue }          # pas Internet Explorer ni une autre application
                $loc = [string]$w.LocationURL
                if ($loc -notmatch '^file:') { continue }                                          # « Ce PC », « Accès rapide »... : pas un dossier
                $path = [Uri]::UnescapeDataString(([Uri]$loc).LocalPath).TrimEnd('\')
                if ($path -ieq $target) { $hits += [int64]$w.HWND; $w.Quit() }
            }
            catch { }
        }
        if ($hits.Count) {
            # Quit() ne suffit pas toujours (processus élevé face à un Explorateur normal) : on demande alors la fermeture à la fenêtre elle-même (WM_CLOSE)
            Start-Sleep -Milliseconds 500
            try { Add-Type -Namespace Pg20 -Name CloseWin -MemberDefinition '[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);' -ErrorAction Stop } catch { }
            foreach ($h in $hits) { try { $p = [IntPtr]$h; if ([Pg20.CloseWin]::IsWindow($p)) { [void][Pg20.CloseWin]::PostMessage($p, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) } } catch { } }
        }
    }
    catch { }
}
# Empreinte NON réversible du matériel de ce poste : SHA-256 d'un identifiant de l'ordinateur (UUID de la carte mère, sinon numéro de série du BIOS, sinon de la carte mère)
# précédé d'un texte propre à Pg20 Info, réduit à 32 caractères. Elle sert au technicien à reconnaître le MÊME ordinateur après une réinstallation, même si son nom a
# changé. Le numéro de série lui-même n'est jamais envoyé ; l'empreinte voyage dans la fiche chiffrée pour le technicien (le serveur ne la lit pas). Vide quand
# l'ordinateur ne donne que des valeurs génériques (« Default string », « To be filled by O.E.M. », UUID tout à zéro ou tout à F...).
function ConvertTo-HardwareFingerprint([string]$Uuid = '', [string]$BiosSerial = '', [string]$BoardSerial = '') {
    $generic = '^(0+|1+|default string|to be filled by o\.?e\.?m\.?|system serial number|system product name|chassis serial number|base board serial number|type2 - board serial number|serial number|none|n/?a|unknown|not specified|not applicable|not available|0123456789|123456789|o\.?e\.?m\.?|\*+|x+|\.+|-+|f{8}-f{4}-f{4}-f{4}-f{12}|0{8}-0{4}-0{4}-0{4}-0{12})$'
    $label = ''; $value = ''
    foreach ($c in @(@('uuid', $Uuid), @('bios', $BiosSerial), @('board', $BoardSerial))) {
        $v = ([string]$c[1]).Trim()
        if ($v.Length -ge 4 -and $v -notmatch ('(?i)' + $generic)) { $label = $c[0]; $value = $v.ToLowerInvariant(); break }
    }
    if (-not $label) { return '' }
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('Pg20-Info/hw/v1|' + $label + '|' + $value))
    ([BitConverter]::ToString($hash) -replace '-', '').ToLower().Substring(0, 32)
}
function Get-HardwareFingerprint {
    $u = ''; $b = ''; $m = ''
    try { $u = [string](Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).UUID } catch { }
    try { $b = [string](Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber } catch { }
    try { $m = [string](Get-CimInstance Win32_BaseBoard -ErrorAction Stop).SerialNumber } catch { }
    ConvertTo-HardwareFingerprint $u $b $m
}

# ---------------------------------------------------------------- Client léger (option -Leger) : session de dépannage ponctuelle, SANS installation
# RustDesk est lancé depuis un dossier temporaire avec un profil Windows factice : RustDesk ignore la variable APPDATA et déduit ses dossiers de USERPROFILE (documenté par ses
# utilisateurs pour une version « portable »), donc rien n'est écrit dans le vrai profil de la personne. Pas de service, pas de tâche planifiée, pas de mot de passe permanent.
# Le serveur et la clé du technicien sont donnés par le nom du fichier (rustdesk-host=...,key=....exe : méthode de RustDesk pour un exe non installé) ET par un fichier de
# configuration du profil factice. L'ID et le mot de passe à usage unique s'affichent dans RustDesk ; la fenêtre du client léger affiche l'ID en grand. À la fin (fenêtre
# fermée) tous les processus lancés et le dossier temporaire sont supprimés. Si RustDesk est déjà installé ou ouvert sur le poste, on refuse de démarrer.
function Get-LightExeName([string]$ServerHost, [string]$Key) {
    $n = "rustdesk-host=$ServerHost,key=$Key.exe"
    if ($ServerHost -notmatch '^[A-Za-z0-9.\-]+$' -or $Key -notmatch '^[A-Za-z0-9+=_\-]+$' -or $n.Length -gt 120) { return 'rustdesk.exe' }       # nom invalide ou trop long : la configuration passe par le fichier seulement
    $n
}
function New-LightSessionFiles([string]$Dir, [string]$SetupExe, [string]$ServerHost, [string]$Key) {
    foreach ($d in 'AppData\Roaming\RustDesk\config', 'AppData\Local', 'Documents') { New-Item -ItemType Directory -Force -Path (Join-Path $Dir $d) | Out-Null }
    $toml = @("rendezvous_server = '${ServerHost}:21116'", 'nat_type = 1', 'serial = 0', '', '[options]',
        "relay-server = '$ServerHost'", "key = '$Key'", "custom-rendezvous-server = '$ServerHost'",
        "approve-mode = 'password'", "verification-method = 'use-temporary-password'", "temporary-password-length = '6'",
        "direct-server = 'N'", "enable-lan-discovery = 'N'", '')          # ni accès direct par IP ni visibilité sur le réseau local (comme pour une installation)
    [IO.File]::WriteAllText((Join-Path $Dir 'AppData\Roaming\RustDesk\config\RustDesk2.toml'), ($toml -join "`n"), (New-Object Text.UTF8Encoding $false))
    $exe = Join-Path $Dir (Get-LightExeName $ServerHost $Key)
    Copy-Item -LiteralPath $SetupExe -Destination $exe -Force
    $exe
}
# Racine des sessions : %LOCALAPPDATA%\Pg20-Info\Depannage (nom LONG). Jamais %TEMP% : il est souvent écrit en nom court (« C:\Users\NOM~1\... »), alors que le chemin d'un processus
# est toujours en nom long : la recherche des processus à arrêter ne trouverait rien et RustDesk resterait ouvert après la fin de la session.
$script:LightRoot = $null           # (tests) racine de remplacement
function Get-LightRoot { if ($script:LightRoot) { $script:LightRoot } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Pg20-Info\Depannage' } }
function New-LightProcessInfo([string]$Exe, [string]$Dir, [string[]]$Arguments = @(), [switch]$Capture) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe; $psi.WorkingDirectory = $Dir; $psi.UseShellExecute = $false
    if ($Arguments.Count) { $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ' }
    $psi.EnvironmentVariables['USERPROFILE'] = $Dir
    $psi.EnvironmentVariables['APPDATA'] = Join-Path $Dir 'AppData\Roaming'
    $psi.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $Dir 'AppData\Local'
    if ($Capture) { $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true }
    $psi
}
function Start-LightRustDesk([string]$Exe, [string]$Dir) { [Diagnostics.Process]::Start((New-LightProcessInfo $Exe $Dir)) }
# L'ID est demandé à RustDesk (--get-id, comme pour l'exe installé) ; il met quelques secondes à apparaître après le premier démarrage
function Get-LightRustDeskId([string]$Exe, [string]$Dir, [int]$TimeoutSec = 90) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        try {
            $p = [Diagnostics.Process]::Start((New-LightProcessInfo $Exe $Dir @('--get-id') -Capture))
            if ($p.WaitForExit(15000)) { $o = $p.StandardOutput.ReadToEnd().Trim(); if ($o -match '^\d{6,12}$') { return $o } }
            else { try { $p.Kill() } catch { } }
        }
        catch { }
        Start-Sleep -Seconds 3
    }
    ''
}
# Identifiants des processus lancés DEPUIS le dossier $Dir. Une seule requête WMI (ExecutablePath est vide pour les processus protégés, sans exception) : parcourir Get-Process
# avec .Path lève une exception par processus protégé, ce qui prenait plus de 20 secondes par passage.
function Get-LightProcessIds([string]$Dir) {
    $prefix = $Dir.TrimEnd('\') + '\'
    try {
        @(Get-CimInstance -ClassName Win32_Process -Filter 'ExecutablePath IS NOT NULL' -ErrorAction Stop | Where-Object { $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [int]$_.ProcessId })
    }
    catch {
        @(Get-Process -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } catch { $false } } | ForEach-Object { [int]$_.Id })
    }
}
function Stop-LightSession([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return }
    for ($pass = 0; $pass -lt 4; $pass++) {
        $ids = @(Get-LightProcessIds $Dir)
        if (-not $ids.Count) { break }
        foreach ($id in $ids) { try { [Diagnostics.Process]::GetProcessById($id).Kill() } catch { } }
        Start-Sleep -Milliseconds 500
    }
    for ($i = 0; $i -lt 12; $i++) { try { [IO.Directory]::Delete($Dir, $true); break } catch { Start-Sleep -Milliseconds 500 } }
}
# RustDesk déjà installé, ou déjà ouvert (n'importe quel profil) : le client léger refuse de démarrer
function Test-RustDeskPresent { [bool]((Get-InstalledRustDesk) -or @(Get-Process -Name rustdesk -ErrorAction SilentlyContinue).Count) }
$script:LightIdTimeout = 90       # secondes d'attente de l'ID (les tests la raccourcissent)

# --- Client léger : fenêtres au premier plan tant que le technicien n'est pas connecté, réduites dès qu'il l'est.
# « Connecté » = RustDesk a ouvert sa « fenêtre de connexion » (processus lancé avec --cm, fenêtre VISIBLE) : un processus --cm déjà présent mais sans fenêtre visible ne compte pas.
# Les fenêtres de RustDesk sont pilotées par l'API Windows (user32) compilée à la demande ; si cette compilation échoue, seule la fenêtre du client léger est gérée.
$script:LightWinState = $null
function Initialize-LightWin {
    if ($script:LightWinState) { return ($script:LightWinState -eq 'ok') }
    try {
        Add-Type -ReferencedAssemblies 'System.Core' -ErrorAction Stop -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
namespace Pg20 {
  public static class LightWin {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public static IntPtr[] VisibleWindows(HashSet<uint> pids) {
      List<IntPtr> res = new List<IntPtr>();
      EnumWindows(delegate (IntPtr h, IntPtr l) {
        uint pid; GetWindowThreadProcessId(h, out pid);
        if (!pids.Contains(pid) || !IsWindowVisible(h) || GetWindow(h, 4) != IntPtr.Zero || GetWindowTextLength(h) == 0) return true;
        RECT r; GetWindowRect(h, out r);
        if (IsIconic(h) || (r.R - r.L > 100 && r.B - r.T > 100)) res.Add(h);
        return true; }, IntPtr.Zero);
      return res.ToArray();
    }
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr h, int index);
    // au premier plan ET toujours au-dessus ; une fenêtre déjà « toujours au-dessus » n'est pas retouchée (l'ordre des fenêtres ne change pas à chaque appel)
    public static void Front(IntPtr h) { if (IsIconic(h)) ShowWindow(h, 9); if ((GetWindowLong(h, -20) & 0x8) == 0) SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040); }
    public static void Minimize(IntPtr h) { SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); ShowWindow(h, 6); }
    // « toujours au-dessus » sans rien d'autre : ne rouvre pas une fenêtre réduite, ne prend pas le focus, ne fait rien si c'est déjà le cas
    public static void Top(IntPtr h) { if ((GetWindowLong(h, -20) & 0x8) == 0) SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }
    [DllImport("user32.dll")] static extern IntPtr GetTopWindow(IntPtr h);
    public static bool Iconic(IntPtr h) { return IsIconic(h); }
    // vrai si la fenêtre a est AU-DESSUS de la fenêtre b dans l'ordre d'affichage
    public static bool IsAbove(IntPtr a, IntPtr b) { for (IntPtr h = GetTopWindow(IntPtr.Zero); h != IntPtr.Zero; h = GetWindow(h, 2)) { if (h == a) return true; if (h == b) return false; } return false; }
    // place la fenêtre h juste DERRIÈRE la fenêtre after (sans focus, sans déplacement, sans changement de taille)
    public static void PlaceBehind(IntPtr h, IntPtr after) { SetWindowPos(h, after, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }
  }
}
'@
        $script:LightWinState = 'ok'
    }
    catch { $script:LightWinState = 'ko' }
    $script:LightWinState -eq 'ok'
}
# processus RustDesk du poste (le garde-fou du démarrage a vérifié qu'aucun autre RustDesk n'était ouvert) : fenêtre de connexion (--cm) / fenêtre principale
function Get-LightWindowTargets {
    $cm = New-Object 'System.Collections.Generic.HashSet[uint32]'; $main = New-Object 'System.Collections.Generic.HashSet[uint32]'
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'rustdesk%'" -ErrorAction Stop)) {
        $cl = [string]$p.CommandLine
        if ($cl -match '(^|\s)--cm(\s|$)') { [void]$cm.Add([uint32]$p.ProcessId) }
        elseif ($cl -notmatch '(^|\s)--(server|tray|service)(\s|$)') { [void]$main.Add([uint32]$p.ProcessId) }
    }
    [pscustomobject]@{ cm = $cm; main = $main }
}
$script:LightLastTargets = $null
function Test-LightConnected {
    try {
        $t = Get-LightWindowTargets
        $script:LightLastTargets = $t
        if (-not $t.cm.Count) { return $false }
        if (-not (Initialize-LightWin)) { return $true }          # fenêtres illisibles : la présence du processus de connexion suffit
        @([Pg20.LightWin]::VisibleWindows($t.cm)).Count -gt 0
    }
    catch { $false }
}
function Set-LightRustDeskWindows([string]$Mode) {              # 'front' : au premier plan (toujours au-dessus) ; 'minimize' : réduite dans la barre des tâches ; 'cm' : la fenêtre de connexion de RustDesk passe « toujours au-dessus » (sans la rouvrir si la personne l'a réduite)
    try {
        if (-not (Initialize-LightWin)) { return }
        $t = Get-LightWindowTargets
        if ($Mode -eq 'cm') { foreach ($h in @([Pg20.LightWin]::VisibleWindows($t.cm))) { [Pg20.LightWin]::Top($h) }; return }
        foreach ($h in @([Pg20.LightWin]::VisibleWindows($t.main))) { if ($Mode -eq 'front') { [Pg20.LightWin]::Front($h) } else { [Pg20.LightWin]::Minimize($h) } }
    }
    catch { }
}
# La fenêtre RustDesk (identifiant + mot de passe) doit rester DEVANT celle du client léger : si les deux sont affichées et que celle du client léger passe au-dessus
# (clic, réouverture depuis la barre des tâches...), elle est replacée juste derrière. Aucune fenêtre réduite n'est rouverte, aucun focus n'est pris.
function Set-LightWindowOrder([object]$Targets = $null, [uint32[]]$OwnPid = @([uint32]$PID)) {
    try {
        if (-not (Initialize-LightWin)) { return }
        if (-not $Targets) { $Targets = Get-LightWindowTargets }
        $own = New-Object 'System.Collections.Generic.HashSet[uint32]'; foreach ($i in $OwnPid) { [void]$own.Add([uint32]$i) }
        $mine = @(@([Pg20.LightWin]::VisibleWindows($own)) | Where-Object { -not [Pg20.LightWin]::Iconic($_) })
        $rd = @(@([Pg20.LightWin]::VisibleWindows($Targets.main)) | Where-Object { -not [Pg20.LightWin]::Iconic($_) })
        foreach ($m in $mine) { foreach ($r in $rd) { if ([Pg20.LightWin]::IsAbove($m, $r)) { [Pg20.LightWin]::PlaceBehind($m, $r) } } }
    }
    catch { }
}
function Invoke-LightSession {
    param([string]$SetupExe, [string]$ServerHost, [string]$ServerKey)
    $sess = $null
    try {
        if (-not $ServerHost -or -not $ServerKey) { throw 'Le serveur du technicien n''est pas indiqué dans cet exe (-Server et -Key).' }
        if (-not $SetupExe -or -not (Test-Path -LiteralPath $SetupExe)) { throw 'RustDesk n''est pas embarqué dans cet exe : le client léger doit être fabriqué en version hors ligne.' }
        if (Test-RustDeskPresent) {
            throw 'RustDesk est déjà installé ou ouvert sur ce poste : ce programme ne le touche pas. Dites-le à votre technicien : il pourra utiliser le RustDesk déjà présent. Sinon, fermez RustDesk puis relancez ce programme.'
        }
        $lightRoot = Get-LightRoot
        # restes d'une ancienne session interrompue (plus aucun RustDesk n'est ouvert : le contrôle ci-dessus l'a vérifié) : effacés
        foreach ($old in @(Get-ChildItem -LiteralPath $lightRoot -Directory -ErrorAction SilentlyContinue)) { Stop-LightSession $old.FullName }
        $sess = Join-Path $lightRoot ('Session-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Set-UiProgress 20 'Préparation de la session…' 38
        Write-Step 'Préparation de la session de dépannage (dossier temporaire, sans installation)'
        $exe = New-LightSessionFiles $sess $SetupExe $ServerHost $ServerKey
        Set-UiProgress 40 'Démarrage de RustDesk…' 62
        Write-Step 'Démarrage de RustDesk sans installation'
        [void](Start-LightRustDesk $exe $sess)
        Set-UiProgress 62 'Récupération de votre identifiant…' 92
        $id = Get-LightRustDeskId $exe $sess $script:LightIdTimeout
        # diagnostic (journal) : RustDesk a-t-il bien écrit sa configuration dans le profil factice, et non dans le vrai profil de la personne ?
        Write-Detail ('Configuration de RustDesk dans le dossier temporaire : ' + $(if (Test-Path -LiteralPath (Join-Path $sess 'AppData\Roaming\RustDesk\config\RustDesk.toml')) { 'oui (profil isolé)' } else { 'NON TROUVÉE : vérifiez que %APPDATA%\RustDesk n''a pas été créé dans le vrai profil' }))
        Write-Ok $(if ($id) { 'Session prête : identifiant relevé' } else { 'Session prête : identifiant à lire dans la fenêtre RustDesk' })
        $idText = $(if ($id) { ($id -replace '(\d{3})(?=\d)', '$1 ') } else { '' })
        $rows = @()
        if ($id) { $rows += , @('Mot de passe', 'à usage unique, affiché dans la fenêtre RustDesk') } else { $rows += , @('Identifiant et mot de passe', 'à lire dans la fenêtre RustDesk qui vient de s''ouvrir') }
        $rows += , @('Installation', 'aucune : RustDesk tourne depuis un dossier temporaire')
        $rows += , @('Fin de la session', 'fermer cette fenêtre : l''accès est coupé et tout est effacé')
        $info = 'Pour que le technicien puisse agir sur des fenêtres d''administrateur, fermez ce programme et relancez-le avec « Exécuter en tant qu''administrateur ».'
        if ($script:UiOn) { $script:Ui.topMost = $true }          # au premier plan tant que le technicien n'est pas connecté
        $shown = Show-UiResult -Title 'La session de dépannage est prête' -Rows $rows -Code $idText -CodeLabel 'Votre identifiant : lisez-le à votre technicien' -CodeNote 'Lisez-lui aussi le mot de passe affiché dans la fenêtre RustDesk.' -Info $info -CloseText 'Terminer la session'
        if ($shown) {
            Set-UiStatus 'light'
            $lt = @{ connected = $false; lastCheck = [datetime]::MinValue; lastFront = Get-Date }
            Set-LightRustDeskWindows 'front'
            # toutes les ~1,5 s : le technicien est-il connecté ? oui = les deux fenêtres (celle-ci et celle de RustDesk) se réduisent ; il se déconnecte = elles reviennent
            $tick = {
                $now = Get-Date
                if (($now - $lt.lastCheck).TotalSeconds -lt 1.5) { return }
                $lt.lastCheck = $now
                $c = Test-LightConnected
                if ($c -and -not $lt.connected) {
                    $lt.connected = $true; Write-Detail 'Connexion du technicien détectée : les fenêtres sont réduites'
                    $script:Ui.windowCmd = 'minimize'; Set-UiStatus 'connected'; Set-LightRustDeskWindows 'minimize'
                    Set-LightRustDeskWindows 'cm'; $lt.lastFront = $now      # la fenêtre de connexion de RustDesk reste AU-DESSUS : si la personne rouvre la fenêtre du client léger, elle passe dessous
                }
                elseif (-not $c -and $lt.connected) {
                    $lt.connected = $false; Write-Detail 'Le technicien s''est déconnecté : les fenêtres reviennent au premier plan'
                    $script:Ui.windowCmd = 'restore'; Set-UiStatus 'ended'; Set-LightRustDeskWindows 'front'; $lt.lastFront = $now
                }
                elseif (-not $c -and -not $lt.connected -and ($now - $lt.lastFront).TotalSeconds -ge 6) { Set-LightRustDeskWindows 'front'; $lt.lastFront = $now }      # la fenêtre RustDesk reste devant
                elseif ($c -and $lt.connected -and ($now - $lt.lastFront).TotalSeconds -ge 6) { Set-LightRustDeskWindows 'cm'; $lt.lastFront = $now }                  # connecté : la fenêtre de connexion reste au-dessus (RustDesk peut la recréer)
                Set-LightWindowOrder $script:LightLastTargets              # la fenêtre RustDesk reste DEVANT celle du client léger
            }
            Wait-UiClosed -MaxSec 28800 -OnTick $tick
        }
        else {
            Write-Host ''
            Write-Host "Votre identifiant : $(if ($idText) { $idText } else { '(à lire dans la fenêtre RustDesk)' })" -ForegroundColor Green
            Write-Host 'Lisez aussi à votre technicien le mot de passe affiché dans la fenêtre RustDesk.'
            [void](Read-Host 'Appuyez sur Entrée pour terminer la session (l''accès est coupé et tout est effacé)')
        }
    }
    finally {
        Stop-LightSession $sess
        try { $lr = Get-LightRoot; if ((Test-Path -LiteralPath $lr) -and -not @(Get-ChildItem -LiteralPath $lr -Force -ErrorAction SilentlyContinue).Count) { [IO.Directory]::Delete($lr); $pi = Split-Path -Parent $lr; if ((Test-Path -LiteralPath $pi) -and -not @(Get-ChildItem -LiteralPath $pi -Force -ErrorAction SilentlyContinue).Count -and -not $script:LightRoot) { [IO.Directory]::Delete($pi) } } } catch { }
    }
}

# Le dossier d'où l'exe est lancé est-il sur un disque AMOVIBLE (clé USB) ? Alors la clé est éjectée automatiquement dès que le technicien a validé la fiche.
function Test-RemovableDir([string]$Dir) {
    try {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Dir))
        if ($root -notmatch '^[A-Za-z]:\\$') { return $false }
        ([IO.DriveInfo]$root).DriveType -eq [IO.DriveType]::Removable
    }
    catch { $false }
}

# Console visible ? (le lanceur n'en ouvre plus : sans fenêtre, une question posée à la console resterait sans réponse possible)
function Test-ConsoleVisible {
    try {
        Add-Type -Namespace Pg20 -Name ConsoleWin -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);' -ErrorAction Stop
    }
    catch { }
    try { $h = [Pg20.ConsoleWin]::GetConsoleWindow(); ($h -ne [IntPtr]::Zero) -and [Pg20.ConsoleWin]::IsWindowVisible($h) } catch { $true }
}

# Témoin pour le lanceur : l'interface est prête (il ferme son écran d'attente)
function Set-ReadyFlag { try { if ($PSCommandPath) { [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $PSCommandPath) 'ready.flag'), '1') } } catch { } }

# Service RustDesk : l'installeur le crée et le démarre lui-même, parfois lentement (antivirus, réinstallation juste après un effacement). On attend qu'il
# existe, puis on le démarre autant de fois qu'il le faut, dans un délai total, au lieu d'échouer au premier refus de Windows. $ScCommand : (tests) remplaçable.
$ScCommand = 'sc.exe'
function Start-RustDeskService {
    param([int]$TimeoutSec = 120, [int]$InstallAfterSec = 45)
    $ErrorActionPreference = 'Continue'
    $start = Get-Date; $deadline = $start.AddSeconds($TimeoutSec); $lastErr = ''; $installTried = $false
    while ($true) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -eq 'Running') { break }
            if ($svc.Status -eq 'Stopped') {
                try { Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction Stop } catch { $lastErr = $_.Exception.Message }
                try { Start-Service -Name $ServiceName -ErrorAction Stop }
                catch { $lastErr = $_.Exception.Message; if ($_.Exception.InnerException) { $lastErr += ' / ' + $_.Exception.InnerException.Message } }
            }
        }
        elseif (-not $installTried -and ((Get-Date) - $start).TotalSeconds -ge $InstallAfterSec) {
            $installTried = $true      # l'installeur n'a pas créé le service : on le demande à RustDesk (une seule fois)
            Invoke-RustDesk '--install-service' | Out-Null
        }
        if ((Get-Date) -ge $deadline) {
            $q = ''; try { $q = ((& $ScCommand query $ServiceName 2>&1) | Out-String).Trim() } catch { }
            $ev = ''      # ce que Windows a noté pour ce service (sans cela, l'erreur seule ne dit pas POURQUOI il refuse de démarrer)
            try {
                $ev = (@(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = $start.AddMinutes(-2) } -MaxEvents 50 -ErrorAction Stop |
                    Where-Object { $_.Message -match 'RustDesk' } | Select-Object -First 3 |
                    ForEach-Object { '{0:HH:mm:ss} (id {1}) {2}' -f $_.TimeCreated, $_.Id, ($_.Message -replace '\s+', ' ') }) -join ' | ')
            } catch { }
            throw "Le service RustDesk ne démarre pas (délai de $TimeoutSec s). Dernière erreur : $lastErr $q$(if ($ev) { " Journal Windows : $ev" })"
        }
        Start-Sleep 3
    }
    try { Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction Stop } catch { }
}

# Après un effacement : attend que Windows ait réellement supprimé l'ancien service (un service « marqué pour suppression » empêche d'en créer un neuf).
function Wait-RustDeskServiceGone {
    param([int]$TimeoutSec = 90)
    $ErrorActionPreference = 'Continue'
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $gone = $false
        try { $o = ((& $ScCommand query $ServiceName 2>&1) | Out-String); $gone = ($LASTEXITCODE -eq 1060) -or ($o -match '\b1060\b') } catch { }
        if ($gone) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        Start-Sleep 2
    }
}

# Le nom saisi dans la fenêtre des conditions sert aussi de nom du client quand l'exe n'en porte pas : pas de seconde question à l'écran.
function Get-ClientNameFromConsent($Consent) {
    if ($Consent -and $Consent.mode -eq 'dialogue') {
        $n = (("$($Consent.name)") -replace '[\x00-\x1f]', '').Trim()
        if ($n.Length -gt 80) { $n = $n.Substring(0, 80).Trim() }
        if ($n) { return $n }
    }
    $null
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

# ---------------------------------------------------------------- Conditions d'installation (avertissement et preuve d'acceptation)
# Le texte est un fichier (Pg20-Exe-Compiler -TermsFile) dont la ligne « Version : ... » l'identifie. Avec la preuve ne voyage que son EMPREINTE
# (SHA-256 du texte, fins de ligne normalisées) : le technicien garde les versions du texte et retrouve celle qui a été acceptée (Pg20-Clients-Carnet.ps1).
function Get-TermsInfo([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) -replace "`r`n", "`n"
    $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($text))) -replace '-', ''
    $ver = ''
    if ($text -match '(?im)^\s*version\s*:\s*(?<v>[^\n]{1,40})$') { $ver = $Matches['v'].Trim() }
    [pscustomobject]@{ text = $text; sha256 = $sha.ToLower(); version = $ver }
}

# La preuve : qui a accepté, quand, quel texte (empreinte), comment (fenêtre ou paramètre), combien de temps la fenêtre est restée ouverte.
# Elle part dans la fiche chiffrée (et dans la ligne chiffrée de la clé USB) ; le serveur y ajoute sa propre heure de réception.
function New-ConsentRecord($Terms, [string]$Name, [string]$Mode, [int]$Seconds) {
    [ordered]@{
        v = 1; version = $Terms.version; sha256 = $Terms.sha256; mode = $Mode; name = $Name
        at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); seconds = $Seconds
        user = $env:USERNAME; host = $env:COMPUTERNAME
    }
}

# Version console (session sans fenêtres, ou fenêtre impossible à ouvrir) : texte affiché, puis nom saisi ET mot « J'ACCEPTE »
function Read-TermsConsole($Terms, [string]$Brand = '', [string]$ClientName = '') {
    $t0 = Get-Date
    if ($Brand) { Write-Host $Brand -ForegroundColor Cyan }
    if ($ClientName) { Write-Host "Installation pour : $ClientName" }
    Write-Host ''
    Write-Host $Terms.text
    Write-Host ''
    $name = (Read-Host 'Nom et prénom de la personne qui accepte (Entrée sans rien saisir = refuser)').Trim()
    if ($name.Length -lt 3) { return [pscustomobject]@{ accepted = $false; name = ''; seconds = 0 } }
    $word = (Read-Host "Tapez J'ACCEPTE pour accepter ces conditions").Trim()
    [pscustomobject]@{ accepted = ($word -ieq "J'ACCEPTE"); name = $name; seconds = [int]((Get-Date) - $t0).TotalSeconds }
}

# Fenêtre d'acceptation : le texte à lire, une case, le nom de la personne qui accepte. « Accepter » reste grisé tant que la case n'est pas cochée
# et que le nom fait moins de 3 caractères ; fermer la fenêtre ou « Refuser » = refus (rien n'est installé). -OnShown : crochet pour les tests.
function Show-TermsDialog($Terms, [scriptblock]$OnShown = $null, [string]$Brand = '', [string]$LogoPath = '', [string]$ClientName = '', [string]$WorkArea = '', [switch]$Light) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $state = @{ accepted = $false; name = ''; seconds = 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()

    # En-tête facultatif : logo + marque du technicien + « Installation pour : <client> » (nom figé dans l'exe). Les autres contrôles descendent de $dy.
    $dy = $(if ($Brand -or $ClientName) { 64 } else { 0 })
    $logo = $null
    if ($LogoPath -and (Test-Path -LiteralPath $LogoPath)) {
        try {
            $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($LogoPath))      # lu en mémoire : le fichier n'est pas verrouillé
            $logo = [System.Drawing.Image]::FromStream($ms)
        }
        catch { $logo = $null }
    }
    if ($logo -and $dy -eq 0) { $dy = 64 }

    # Taille adaptée à l'écran (zone de travail de l'écran où se trouve le pointeur) : sur un petit écran (portable 1366 x 768, mise à l'échelle 125 %...) la fenêtre
    # complète dépasserait ; c'est alors la zone de texte qui raccourcit (elle défile), et la fenêtre est centrée.
    if ($WorkArea) { $q = $WorkArea.Split(','); $wa = New-Object System.Drawing.Rectangle([int]$q[0], [int]$q[1], [int]$q[2], [int]$q[3]) }
    else { $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea }
    $chrome = [System.Windows.Forms.SystemInformation]::CaptionHeight + 2 * [System.Windows.Forms.SystemInformation]::FixedFrameBorderSize.Height + 8
    $need = 610 + $dy + $chrome + 16
    $ex = 0; if ($need -gt $wa.Height) { $ex = -[Math]::Min(350 - 140, $need - $wa.Height) }      # au plus 210 px de moins : la zone de texte garde 140 px
    $boxH = 350 + $ex

    $f = New-Object System.Windows.Forms.Form
    $f.Text = $(if ($Brand) { "$Brand - " } else { '' }) + $(if ($Light) { 'Conditions de la session de dépannage' } else { "Conditions d'installation de l'accès à distance" })
    $f.ClientSize = New-Object System.Drawing.Size(700, (610 + $dy + $ex))
    $f.StartPosition = 'Manual'; $f.TopMost = $true; $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ControlBox = $false
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $f.Location = New-Object System.Drawing.Point(($wa.Left + [Math]::Max(0, [int](($wa.Width - $f.Width) / 2))), ($wa.Top + [Math]::Max(0, [int](($wa.Height - $f.Height) / 2))))

    $head = @()
    if ($dy -gt 0) {
        $x = 14
        if ($logo) {
            $pic = New-Object System.Windows.Forms.PictureBox
            $pic.Image = $logo; $pic.SizeMode = 'Zoom'
            $pic.Location = New-Object System.Drawing.Point(14, 8); $pic.Size = New-Object System.Drawing.Size(48, 48)
            $head += $pic; $x = 72
        }
        $bl = New-Object System.Windows.Forms.Label
        $bl.UseMnemonic = $false
        $bl.Text = $(if ($Brand) { $Brand } else { '' })
        $bl.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
        $bl.Location = New-Object System.Drawing.Point($x, 6); $bl.Size = New-Object System.Drawing.Size((686 - $x), 30)
        $cl = New-Object System.Windows.Forms.Label
        $cl.UseMnemonic = $false
        $cl.Text = $(if ($ClientName) { "Installation pour : $ClientName" } else { '' })
        $cl.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
        $cl.Location = New-Object System.Drawing.Point($x, 36); $cl.Size = New-Object System.Drawing.Size((686 - $x), 22)
        $sep = New-Object System.Windows.Forms.Label
        $sep.BorderStyle = 'Fixed3D'; $sep.Text = ''
        $sep.Location = New-Object System.Drawing.Point(14, 62); $sep.Size = New-Object System.Drawing.Size(672, 2)
        $head += $bl, $cl, $sep
    }

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Lisez ces conditions avant d'installer"
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point(14, (12 + $dy)); $title.Size = New-Object System.Drawing.Size(672, 28)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Vertical'; $box.WordWrap = $true; $box.BackColor = [System.Drawing.Color]::White
    $box.Location = New-Object System.Drawing.Point(14, (46 + $dy)); $box.Size = New-Object System.Drawing.Size(672, $boxH)
    $box.Text = ($Terms.text -replace "`n", "`r`n")

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = "J'ai lu ces conditions et je les accepte."
    $chk.Location = New-Object System.Drawing.Point(14, (408 + $dy + $ex)); $chk.Size = New-Object System.Drawing.Size(672, 26)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Nom et prénom de la personne qui accepte :'
    $lbl.Location = New-Object System.Drawing.Point(14, (444 + $dy + $ex)); $lbl.Size = New-Object System.Drawing.Size(672, 22)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(14, (470 + $dy + $ex)); $tb.Size = New-Object System.Drawing.Size(420, 28)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = $(if ($Light) { 'Accepter et démarrer' } else { 'Accepter et installer' }); $ok.Enabled = $false
    $ok.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $ok.Location = New-Object System.Drawing.Point(14, (520 + $dy + $ex)); $ok.Size = New-Object System.Drawing.Size(250, 46)
    $no = New-Object System.Windows.Forms.Button
    $no.Text = 'Refuser et quitter'
    $no.Location = New-Object System.Drawing.Point(280, (520 + $dy + $ex)); $no.Size = New-Object System.Drawing.Size(200, 46)
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Une copie de ces conditions et de votre acceptation sera enregistrée sur ce PC.'
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $hint.Location = New-Object System.Drawing.Point(14, (574 + $dy + $ex)); $hint.Size = New-Object System.Drawing.Size(672, 22)
    $f.Controls.AddRange(@($head + @($title, $box, $chk, $lbl, $tb, $ok, $no, $hint)))
    $f.CancelButton = $no

    $update = { $ok.Enabled = ($chk.Checked -and $tb.Text.Trim().Length -ge 3) }
    $chk.Add_CheckedChanged($update)
    $tb.Add_TextChanged($update)
    $ok.Add_Click({
        $state.accepted = $true; $state.name = $tb.Text.Trim(); $state.seconds = [int]$sw.Elapsed.TotalSeconds
        $f.Close()
    })
    $no.Add_Click({ $f.Close() })
    $f.Add_Shown({
        $f.Activate(); $box.Select(0, 0)
        if ($OnShown) { & $OnShown $f @{ box = $box; check = $chk; name = $tb; ok = $ok; cancel = $no } }
    })
    [void]$f.ShowDialog()
    $f.Dispose()
    if ($logo) { $logo.Dispose() }
    [pscustomobject]@{ accepted = [bool]$state.accepted; name = [string]$state.name; seconds = [int]$state.seconds }
}

# Copie des conditions et de l'acceptation, laissée sur le PC du client (C:\ProgramData\Pg20-Info) : il garde sa propre preuve.
function Save-ConsentReceipt($Consent, $Terms, [string]$RdId, [string]$ClientName) {
    $dir = Join-Path $env:ProgramData 'Pg20-Info'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir ('Acceptation-{0}-{1:yyyyMMdd-HHmm}.txt' -f $RdId, (Get-Date))
    $head = @(
        "PREUVE D'ACCEPTATION DES CONDITIONS D'INSTALLATION", '',
        "Client              : $ClientName",
        "Poste               : $($Consent.host)",
        "Session Windows     : $($Consent.user)",
        "ID RustDesk         : $RdId",
        "Accepté par         : $($Consent.name)",
        "Date (heure du PC)  : $((Get-Date).ToString('dd.MM.yyyy HH:mm:ss'))",
        "Mode d'acceptation  : $($Consent.mode)",
        "Texte               : version $($Consent.version), empreinte SHA-256 $($Consent.sha256)", '',
        '--------------------------------------------------------------------', ''
    ) -join "`r`n"
    [IO.File]::WriteAllText($path, $head + "`r`n" + ($Terms.text -replace "`n", "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($true)))
    $path
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
    $rel   = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'Pg20-Client-Installation' }
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

# ---------------------------------------------------------------- Désinstallation complète
# Efface TOUT : service, processus, programme, règles de pare-feu « RustDesk » et dossiers de configuration que le désinstalleur de RustDesk laisse
# derrière lui (ID, clés, serveur mémorisés : sans cela, une réinstallation repart avec la même identité). AUTONOME (aucune variable du script) :
# le carnet du technicien en copie le texte tel quel dans la commande du bouton « Désinstaller » de « Pg20 - Se connecter » (Pg20-Clients-Carnet.ps1).
#   -ExpectedId : abandonne SANS rien toucher si ce poste n'a pas cet ID RustDesk (mauvaise fenêtre, mauvais poste).
#   -DryRun     : n'efface rien, annonce seulement ce qui le serait.
# Les autres paramètres ne servent qu'aux tests (identité simulée, dossiers de remplacement ; -SkipProgram : ni service ni programme).
function Uninstall-RustDeskFully {
    param(
        [string]$ExpectedId = '',
        [switch]$DryRun,
        [switch]$SkipProgram,
        [string]$CurrentId = '',
        [string]$ProfileRoot = 'C:\Users',
        [string]$ServiceProfile = 'C:\Windows\ServiceProfiles\LocalService',
        [string]$WindowsTemp = '',                 # (tests) dossier « C:\Windows\Temp » de remplacement
        [string]$LogDir = '',
        [int]$NoticeSeconds = 0,                   # avant d'arrêter le service : laisse le temps de lire que la session RustDesk va se couper
        [switch]$KeepAgent,                        # (appelé par la tâche de maintenance elle-même, qui se supprime ensuite) ne retire pas la tâche de maintenance
        [switch]$Quiet,                            # n'affiche que les avertissements (le détail reste dans le journal)
        [string]$AgentDir = '',                    # (tests) dossier de la tâche de maintenance, par défaut « C:\Program Files\Pg20-Info\Agent »
        [string]$AgentTask = 'Pg20-Info-Maintenance'
    )
    $ErrorActionPreference = 'Continue'
    $result = [pscustomobject]@{ ok = $false; aborted = $false; needReboot = $false; id = ''; wiped = @(); left = @() }
    $lines = New-Object System.Collections.Generic.List[string]
    $say = {
        param([string]$Text, [string]$Color = 'Gray')
        if (-not $Quiet -or $Color -eq 'Yellow') { Write-Host $Text -ForegroundColor $Color }
        $lines.Add(('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Text))
    }
    $tag = $(if ($DryRun) { '[simulation] ' } else { '' })
    $rdExe = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
    $uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $findEntry = { Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'RustDesk' } | Select-Object -First 1 }

    if (-not $SkipProgram -and -not $DryRun) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            & $say "Droits administrateur requis : ouvrez PowerShell en tant qu'administrateur (clic droit sur Démarrer), puis recommencez. Rien n'a été modifié." 'Yellow'
            $result.aborted = $true
            return $result
        }
    }

    # Quel poste est-ce ? (demandé à RustDesk, sinon lu dans sa configuration)
    $id = $CurrentId
    if (-not $id -and -not $SkipProgram -and (Test-Path -LiteralPath $rdExe)) {
        $o = Join-Path $env:TEMP ('rd-id-' + [guid]::NewGuid().ToString('N') + '.txt')
        try {
            $p = Start-Process -FilePath $rdExe -ArgumentList '--get-id' -RedirectStandardOutput $o -PassThru -WindowStyle Hidden
            if (-not $p.WaitForExit(20000)) { try { $p.Kill() } catch { } }
            Start-Sleep -Milliseconds 300
            $t = [string](Get-Content -LiteralPath $o -Raw -ErrorAction SilentlyContinue)
            if ($t.Trim() -match '^\d{6,}$') { $id = $t.Trim() }
        }
        catch { }
        finally { [IO.File]::Delete($o) }
    }
    if (-not $id -and -not $SkipProgram) {
        $toml = Join-Path $ServiceProfile 'AppData\Roaming\RustDesk\config\RustDesk.toml'
        if (Test-Path -LiteralPath $toml) {
            $m = Select-String -LiteralPath $toml -Pattern "^id\s*=\s*'(?<id>[^']+)'" | Select-Object -First 1
            if ($m) { $id = $m.Matches[0].Groups['id'].Value }
        }
    }
    $result.id = $id
    if ($ExpectedId -and -not $SkipProgram) {
        if (-not $id) {
            & $say "L'ID de ce poste est illisible : par sécurité, rien n'a été modifié (la commande vise le poste $ExpectedId)." 'Yellow'
            $result.aborted = $true
            return $result
        }
        if ($id -ne $ExpectedId) {
            & $say "ATTENTION : ce poste a l'ID $id, pas $ExpectedId. Mauvaise session ? Rien n'a été modifié." 'Yellow'
            $result.aborted = $true
            return $result
        }
    }
    & $say ($tag + 'Désinstallation complète de RustDesk' + $(if ($id) { " (ID $id)" } else { '' })) 'Cyan'

    if (-not $SkipProgram) {
        if ($NoticeSeconds -gt 0 -and -not $DryRun -and (Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue)) {
            & $say "Cette session RustDesk va se couper dans $NoticeSeconds secondes : c'est normal, la désinstallation continue sur ce poste (résultat noté dans C:\ProgramData\Pg20-Info)." 'Yellow'
            Start-Sleep -Seconds $NoticeSeconds
        }
        if (Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue) {
            & $say ($tag + 'Arrêt du service RustDesk')
            if (-not $DryRun) { Stop-Service -Name 'RustDesk' -Force -ErrorAction SilentlyContinue }
        }
        $procs = @(Get-Process -Name 'rustdesk' -ErrorAction SilentlyContinue)
        if ($procs.Count) {
            & $say ($tag + "Fermeture de $($procs.Count) processus RustDesk")
            if (-not $DryRun) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue }
        }
        $inst = & $findEntry
        if ($inst) {
            & $say ($tag + "Désinstallation de RustDesk $($inst.DisplayVersion)")
            if (-not $DryRun) {
                $us = [string]$inst.UninstallString
                if ($us -match '(?i)msiexec(\.exe)?\s+/[IX]\s*(\{[0-9A-F\-]{36}\})') { $uFile = 'msiexec.exe'; $uArgs = "/x $($Matches[2]) /qn /norestart" }
                else { $uFile = 'cmd.exe'; $uArgs = '/c "' + $us + '"' }
                $un = Start-Process -FilePath $uFile -ArgumentList $uArgs -PassThru -WindowStyle Hidden
                if (-not $un.WaitForExit(300000)) { & $say 'Le désinstalleur est encore en cours après 5 minutes.' 'Yellow' }
                elseif ($un.ExitCode -eq 3010) { $result.needReboot = $true }
                Start-Sleep -Seconds 3
            }
        }
        else { & $say "RustDesk n'apparaît pas dans les programmes installés : on nettoie ce qu'il a pu laisser." }

        # Restes que le désinstalleur ne retire pas toujours : service, dossier du programme, règles de pare-feu
        if (Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue) {
            & $say ($tag + 'Suppression du service resté enregistré')
            if (-not $DryRun) { & sc.exe delete RustDesk | Out-Null }
        }
        $progDir = Join-Path $env:ProgramFiles 'RustDesk'
        if (Test-Path -LiteralPath $progDir) {
            & $say ($tag + "Suppression du dossier $progDir")
            if (-not $DryRun) { Remove-Item -LiteralPath $progDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        try {
            $fw = @(Get-NetFirewallRule -DisplayName '*RustDesk*' -ErrorAction SilentlyContinue)
            if ($fw.Count) {
                & $say ($tag + "Suppression de $($fw.Count) règle(s) de pare-feu RustDesk")
                if (-not $DryRun) { $fw | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
            }
        }
        catch { }
    }

    # Configuration laissée par RustDesk : service (profil LocalService) et, pour chaque compte, AppData\Roaming\RustDesk et AppData\Local\rustdesk.
    # C'est elle qui garde l'ID, les clés et le serveur : sans l'effacer, une réinstallation retrouve la même identité.
    $dirs = New-Object System.Collections.Generic.List[string]
    $dirs.Add((Join-Path $ServiceProfile 'AppData\Roaming\RustDesk'))
    if (Test-Path -LiteralPath $ProfileRoot) {
        foreach ($prof in @(Get-ChildItem -LiteralPath $ProfileRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($prof.Name -in 'Public', 'Default', 'Default User', 'All Users') { continue }
            $dirs.Add((Join-Path $prof.FullName 'AppData\Roaming\RustDesk'))
            $dirs.Add((Join-Path $prof.FullName 'AppData\Local\rustdesk'))
        }
    }
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d -ErrorAction SilentlyContinue)) { continue }       # en simulation sans droits administrateur, un dossier protégé est ignoré sans bruit
        & $say ($tag + "Suppression de la configuration : $d")
        if ($DryRun) { $result.wiped += $d; continue }
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $d) { $result.left += $d } else { $result.wiped += $d }
    }

    # Scripts que l'installeur de RustDesk laisse dans un dossier temporaire à chaque installation (rustdesk_install_<empreinte>.cmd) : RustDesk ne les efface pas.
    # Dossiers temporaires de chaque compte, du profil du service et de Windows. Un script impossible à effacer n'empêche pas la désinstallation (ce n'est qu'une trace).
    $tempDirs = New-Object System.Collections.Generic.List[string]
    $tempDirs.Add($(if ($WindowsTemp) { $WindowsTemp } else { Join-Path $env:WINDIR 'Temp' }))
    $tempDirs.Add((Join-Path $ServiceProfile 'AppData\Local\Temp'))
    if (Test-Path -LiteralPath $ProfileRoot) {
        foreach ($prof in @(Get-ChildItem -LiteralPath $ProfileRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($prof.Name -in 'Public', 'Default', 'Default User', 'All Users') { continue }
            $tempDirs.Add((Join-Path $prof.FullName 'AppData\Local\Temp'))
        }
    }
    foreach ($td in $tempDirs) {
        if (-not (Test-Path -LiteralPath $td -ErrorAction SilentlyContinue)) { continue }
        foreach ($pat in 'rustdesk_install_*.cmd', 'rustdesk_uninstall_*.cmd') {
            foreach ($sf in @(Get-ChildItem -LiteralPath $td -File -Filter $pat -Force -ErrorAction SilentlyContinue)) {
                & $say ($tag + "Suppression d'un script d'installation laissé par RustDesk : $($sf.FullName)")
                if ($DryRun) { $result.wiped += $sf.FullName; continue }
                Remove-Item -LiteralPath $sf.FullName -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $sf.FullName) { & $say "Script non effacé (verrouillé ?) : $($sf.FullName)" 'Yellow' } else { $result.wiped += $sf.FullName }
            }
        }
    }

    if (-not $SkipProgram -and -not $DryRun) {
        if (Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue) { $result.left += 'le service RustDesk' }
        if (Test-Path -LiteralPath $rdExe) { $result.left += $rdExe }
        if (Get-Process -Name 'rustdesk' -ErrorAction SilentlyContinue) { $result.left += 'un processus rustdesk' }
        if (& $findEntry) { $result.left += "l'entrée « Applications et fonctionnalités »" }
    }
    $result.ok = (@($result.left).Count -eq 0)

    # La tâche de maintenance (Pg20-Client-Maintenance.ps1) n'a plus de raison d'être sans RustDesk : on la retire aussi, avec son dossier
    if ($result.ok -and -not $DryRun -and -not $KeepAgent -and (-not $SkipProgram -or $AgentDir)) {
        $agDir = $(if ($AgentDir) { $AgentDir } else { Join-Path $env:ProgramFiles 'Pg20-Info\Agent' })
        $hasTask = $false
        try { $hasTask = [bool](Get-ScheduledTask -TaskName $AgentTask -ErrorAction SilentlyContinue) } catch { }
        if ($hasTask -or (Test-Path -LiteralPath $agDir)) {
            & $say 'Suppression de la tâche de maintenance Pg20 Info'
            try { Unregister-ScheduledTask -TaskName $AgentTask -Confirm:$false -ErrorAction SilentlyContinue } catch { }
            if (Test-Path -LiteralPath $agDir) {
                Remove-Item -LiteralPath $agDir -Recurse -Force -ErrorAction SilentlyContinue
                $agParent = Split-Path -Parent $agDir
                if ((Test-Path -LiteralPath $agParent) -and -not @(Get-ChildItem -LiteralPath $agParent -Force -ErrorAction SilentlyContinue).Count) { Remove-Item -LiteralPath $agParent -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    if ($DryRun) { & $say "Simulation terminée : rien n'a été modifié." 'Cyan' }
    elseif ($result.ok) { & $say ('Désinstallation terminée : RustDesk et sa configuration sont effacés de ce poste' + $(if ($result.needReboot) { ' (redémarrez le poste pour terminer)' } else { '' }) + '.') 'Green' }
    else { & $say ('Désinstallation INCOMPLÈTE, il reste : ' + (@($result.left) -join ' ; ') + '. Redémarrez le poste puis recommencez.') 'Yellow' }
    if (-not $DryRun) {
        try {
            $logFolder = $(if ($LogDir) { $LogDir } else { Join-Path $env:ProgramData 'Pg20-Info' })
            New-Item -ItemType Directory -Force -Path $logFolder | Out-Null
            [IO.File]::WriteAllLines((Join-Path $logFolder ('desinstallation-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))), $lines, (New-Object Text.UTF8Encoding($true)))
        }
        catch { }
    }
    $result
}

# ---------------------------------------------------------------- Tâche de maintenance (désinstallation sur ordre signé du technicien)
# Pg20-Client-Maintenance.ps1 est copié dans « C:\Program Files\Pg20-Info\Agent » (dossier réservé au système et aux administrateurs : un utilisateur ordinaire ne
# peut pas le modifier) avec sa configuration (serveur, empreinte du certificat, clé publique du technicien), et une tâche planifiée du compte
# système l'exécute au démarrage puis toutes les 3 minutes, sans fenêtre. Il n'exécute qu'un ordre « désinstaller » SIGNÉ par le technicien.
function Get-FunctionSource([string]$ScriptPath, [string]$Name) {
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tok, [ref]$err)
    $fn = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $fn) { throw "Fonction $Name introuvable dans $ScriptPath." }
    $fn.Extent.Text
}

# Renvoie ok/message. En cas d'échec, rien ne reste (ni tâche ni dossier). -TestUserSid / -TestAsCurrentUser : tests hors compte système.
function Install-MaintenanceAgent {
    param(
        [Parameter(Mandatory)][string]$AgentSource,
        [Parameter(Mandatory)][string]$FunctionSource,
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Pin,
        [Parameter(Mandatory)][string]$PublicKeyXml,
        [string]$Dir = '',
        [string]$TaskName = 'Pg20-Info-Maintenance',
        [int]$IntervalMinutes = 3,
        [string]$TestUserSid = '',
        [switch]$TestAsCurrentUser
    )
    if (-not $Dir) { $Dir = Join-Path $env:ProgramFiles 'Pg20-Info\Agent' }
    $marker = '# __UNINSTALL_FUNCTION__'
    try {
        $src = [IO.File]::ReadAllText($AgentSource, [Text.Encoding]::UTF8)
        $at = $src.IndexOf($marker)
        if ($at -lt 0 -or $src.IndexOf($marker, $at + 1) -ge 0) { throw "marqueur $marker absent ou en double dans le script de la tâche" }
        $full = $src.Replace($marker, $FunctionSource)
        $perr = $null; $ptok = $null
        [void][Management.Automation.Language.Parser]::ParseInput($full, [ref]$ptok, [ref]$perr)
        if (@($perr).Count) { throw "script de la tâche invalide : $($perr[0].Message)" }

        # Dossier d'abord verrouillé (système + administrateurs, sans héritage), fichiers ensuite : ils en héritent
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $sids = @('S-1-5-18', 'S-1-5-32-544'); if ($TestUserSid) { $sids += $TestUserSid }
        foreach ($sid in $sids) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        (New-Object IO.DirectoryInfo($Dir)).SetAccessControl($acl)        # ne modifie que les droits d'accès (Set-Acl exige en plus un privilège d'audit)

        $scriptPath = Join-Path $Dir 'Pg20-Client-Maintenance.ps1'
        [IO.File]::WriteAllText($scriptPath, $full, (New-Object Text.UTF8Encoding($true)))
        $cfg = ConvertTo-Json -InputObject ([ordered]@{
                v = 1; server = $Server; pin = $Pin.ToLower(); pubkey = $PublicKeyXml; task = $TaskName
                installedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            }) -Compress
        [IO.File]::WriteAllText((Join-Path $Dir 'agent.json'), $cfg, (New-Object Text.UTF8Encoding($false)))

        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # Compte système : la tâche tourne hors de toute session, aucune fenêtre n'est possible (pas de -WindowStyle, pas de « Bypass » : ces options
        # ressemblent trop à un logiciel malveillant pour certains antivirus). Le script est local et n'a pas de marque « téléchargé » : RemoteSigned suffit.
        $action = New-ScheduledTaskAction -Execute $psExe -WorkingDirectory $Dir `
            -Argument ('-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned {0}-File "{1}"' -f $(if ($TestAsCurrentUser) { '-WindowStyle Hidden ' } else { '' }), $scriptPath)
        $every = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
        $triggers = @($every)
        if (-not $TestAsCurrentUser) {            # un déclencheur « au démarrage » exige les droits administrateur : absent des tests
            $boot = New-ScheduledTaskTrigger -AtStartup
            $boot.Delay = 'PT3M'
            $triggers = @($boot, $every)
        }
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden `
            -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
        $principal = $(if ($TestAsCurrentUser) { New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited }
                       else { New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest })
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force `
            -Description "Pg20 Info : désinstalle RustDesk de ce poste, uniquement sur ordre signé du technicien (conditions d'installation, point 2)." | Out-Null
        if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { throw 'la tâche planifiée est introuvable après sa création' }
        [pscustomobject]@{ ok = $true; message = ''; dir = $Dir; task = $TaskName }
    }
    catch {
        $why = $_.Exception.Message
        try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
        [pscustomobject]@{ ok = $false; message = $why; dir = $Dir; task = $TaskName }
    }
}

# ---------------------------------------------------------------- Réinstallation propre (nouvelle identité RustDesk)
# Un RustDesk réinstallé sur un PC qui l'a déjà gardé son identité (ID, clés) : le serveur ne voit aucune nouvelle inscription et refuse la fiche.
# Avec -CleanReinstall, l'exe efface d'abord l'ancien RustDesk et sa configuration (Uninstall-RustDeskFully) : le poste repart avec une identité
# neuve et s'inscrit comme un nouveau poste. GARDE-FOU : cela n'a lieu que si la configuration de RustDesk désigne NOTRE serveur ; un RustDesk relié
# à un autre serveur (ou à aucun : l'usage personnel du client) n'est jamais effacé.
function Get-RustDeskConfigState {
    param([string]$ServiceProfile = 'C:\Windows\ServiceProfiles\LocalService', [string]$ProfileRoot = 'C:\Users')
    $files = New-Object System.Collections.Generic.List[string]
    $dirs = New-Object System.Collections.Generic.List[string]
    $dirs.Add((Join-Path $ServiceProfile 'AppData\Roaming\RustDesk'))
    if (Test-Path -LiteralPath $ProfileRoot) {
        foreach ($prof in @(Get-ChildItem -LiteralPath $ProfileRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($prof.Name -in 'Public', 'Default', 'Default User', 'All Users') { continue }
            $dirs.Add((Join-Path $prof.FullName 'AppData\Roaming\RustDesk')); $dirs.Add((Join-Path $prof.FullName 'AppData\Local\rustdesk'))
        }
    }
    $servers = New-Object System.Collections.Generic.List[string]
    $leftovers = $false
    # Le PC du technicien (sa clé privée est dans son profil) n'est JAMAIS un client : il est relié au même serveur et ne doit pas être effacé
    $technicianPc = $false
    if (Test-Path -LiteralPath $ProfileRoot) {
        foreach ($prof in @(Get-ChildItem -LiteralPath $ProfileRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $prof.FullName 'AppData\Roaming\Pg20-Info\technician.key') -ErrorAction SilentlyContinue) { $technicianPc = $true }
        }
    }
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d -ErrorAction SilentlyContinue)) { continue }
        $leftovers = $true
        $toml = Join-Path $d 'config\RustDesk2.toml'
        if (Test-Path -LiteralPath $toml) {
            $txt = [string](Get-Content -LiteralPath $toml -Raw -ErrorAction SilentlyContinue)
            foreach ($m in [regex]::Matches($txt, '(?m)^\s*custom-rendezvous-server\s*=\s*[''"]([^''"]*)[''"]')) {
                $v = ($m.Groups[1].Value.Trim() -replace ':\d+$', '')
                if ($v) { $servers.Add($v) }
            }
        }
    }
    [pscustomobject]@{ leftovers = $leftovers; servers = @($servers | Select-Object -Unique); technicianPc = $technicianPc }
}

function Invoke-CleanReinstall {
    param(
        [string]$ServerHost,
        [bool]$ProgramPresent = $false,
        [hashtable]$UninstallParams = @{},
        [string]$ServiceProfile = 'C:\Windows\ServiceProfiles\LocalService',
        [string]$ProfileRoot = 'C:\Users'
    )
    $st = Get-RustDeskConfigState -ServiceProfile $ServiceProfile -ProfileRoot $ProfileRoot
    if (-not $ProgramPresent -and -not $st.leftovers) { return [pscustomobject]@{ action = 'rien'; detail = 'aucun RustDesk sur ce poste' } }
    if ($st.technicianPc) { return [pscustomobject]@{ action = 'ignoré'; detail = 'ce poste est celui du technicien (sa clé privée est présente) : rien n''est effacé' } }
    $mine = ($ServerHost -replace ':\d+$', '')
    if (-not $mine) { return [pscustomobject]@{ action = 'ignoré'; detail = 'serveur du technicien non précisé : rien n''est effacé' } }
    if (@($st.servers).Count -eq 0) { return [pscustomobject]@{ action = 'ignoré'; detail = 'ce RustDesk n''est relié à aucun serveur du technicien (usage personnel ?) : rien n''est effacé' } }
    $others = @($st.servers | Where-Object { $_ -ine $mine })
    if ($others.Count) { return [pscustomobject]@{ action = 'ignoré'; detail = "ce RustDesk est relié à un autre serveur ($($others -join ', ')) : rien n'est effacé" } }
    $u = Uninstall-RustDeskFully @UninstallParams -ServiceProfile $ServiceProfile -ProfileRoot $ProfileRoot
    if ($u.aborted) { return [pscustomobject]@{ action = 'échec'; detail = 'effacement abandonné (droits administrateur ?)' } }
    if (-not $u.ok) { return [pscustomobject]@{ action = 'échec'; detail = 'il reste : ' + (@($u.left) -join ' ; ') } }
    [pscustomobject]@{ action = 'effacé'; detail = 'ancien RustDesk et sa configuration effacés : le poste repart avec une identité neuve' }
}
# En cas d'erreur (arrêt du script), l'écran interactif montre d'abord les étapes gardées en mémoire. Si l'ancien RustDesk avait déjà été effacé (réinstallation
# propre) et que l'installation n'est pas allée au bout, le poste n'est plus relié à votre serveur : on le dit (sinon RustDesk, resté sur ses réglages
# d'origine, donne des erreurs de connexion qui ne disent pas pourquoi).
$script:CleanWiped = $false; $script:InstallComplete = $false; $script:GuiWanted = $false; $script:ClientFrozen = ''; $script:CanEject = $false
trap {
    $err = $_
    $details = ''
    try { $details = (@($script:StepBuffer | ForEach-Object { [string]$_[0] }) -join "`r`n") } catch { }
    Show-BufferedSteps
    $interrupted = ''
    if ($script:CleanWiped -and -not $script:InstallComplete) {
        $interrupted = 'La réinstallation propre a été interrompue après l''effacement : ce poste n''est plus relié à votre serveur (RustDesk est revenu à ses réglages d''origine). Redémarrez le poste puis relancez l''exe : il reprendra là où il s''est arrêté.'
        Write-Warn $interrupted
    }
    if ($script:GuiWanted) {
        $m = [string]$err.Exception.Message
        $d = $details + "`r`n`r`nErreur : $m"
        if ($interrupted) { $d += "`r`n`r`n$interrupted" }
        [void](Show-UiError -Message ($m + $(if ($interrupted) { "`r`n`r`n" + $interrupted } else { '' })) -Details $d -Brand $BrandName -LogoPath $LogoPath -ClientName $script:ClientFrozen)
    }
    break
}

# ---------------------------------------------------------------- Désinstallation
if ($Uninstall) {
    $u = Uninstall-RustDeskFully
    if ($u.ok) { exit 0 } else { exit 1 }
}

# ---------------------------------------------------------------- Contrôle des paramètres
if ($Server -and $ConfigString) { throw 'Utilisez -ConfigString OU -Server/-Key, pas les deux.' }
if ($Password) { $problem = Test-PasswordPolicy $Password; if ($problem) { throw $problem } }

# ---------------------------------------------------------------- Questions (nom du client, mot de passe)
# Posées d'emblée : on répond, puis tout le reste s'exécute sans intervention.
$interactive = -not $NoPrompt -and [Environment]::UserInteractive
$script:GuiWanted = [bool]($interactive -and -not $NoGui)               # fenêtres système (progression, résultat, erreur) ; sinon console comme avant
$script:QuietSteps = [bool]($interactive -and ($script:GuiWanted -or -not $ShowSteps))
$script:ClientFrozen = $ClientName                                         # nom du client figé dans l'exe (« Installation pour : … »), avant toute question
if ($script:GuiWanted) { $ProgressPreference = 'SilentlyContinue' }       # la barre de PowerShell ralentit les téléchargements et ne sert à rien ici
$script:CanEject = [bool]($script:GuiWanted -and $LaunchDir -and (Test-RemovableDir $LaunchDir))     # exe lancé depuis une clé USB : la clé est éjectée toute seule dès que la fiche est validée
if ($LaunchDir) {         # noté dans le journal (sans rien afficher) : permet de comprendre pourquoi la clé s'est éjectée, ou non
    $driveType = 'inconnu'; try { $driveType = [string]([IO.DriveInfo][IO.Path]::GetPathRoot([IO.Path]::GetFullPath($LaunchDir))).DriveType } catch { }
    Write-Detail ("Dossier de l'exe : {0} ; type de disque : {1} ; éjection automatique après validation : {2}" -f $LaunchDir, $driveType, $(if ($script:CanEject) { 'oui' } else { 'non' }))
}

# ---------------------------------------------------------------- Conditions d'installation
# Avec un texte de conditions (-TermsPath, intégré à l'exe par Pg20-Exe-Compiler -TermsFile), RIEN n'est installé tant qu'elles ne sont pas acceptées :
# fenêtre à l'écran, ou -AcceptTerms (déploiement par script : la preuve note « accepté par paramètre »). Refus = code de sortie 20 ; mode silencieux
# sans -AcceptTerms = code 21.
$consent = $null; $terms = $null
if ($TermsPath) {
    if (-not (Test-Path -LiteralPath $TermsPath)) { throw "Texte des conditions introuvable : $TermsPath" }
    $terms = Get-TermsInfo $TermsPath
    if (-not $terms.text.Trim()) { throw 'Le texte des conditions est vide.' }
    if ($AcceptTerms) {
        $consent = New-ConsentRecord $terms '(accepté par paramètre)' 'parametre' 0
    }
    elseif ($interactive) {
        $ans = $null
        Set-ReadyFlag
        try { $ans = Show-TermsDialog $terms -Brand $BrandName -LogoPath $LogoPath -ClientName $ClientName -Light:$Leger }
        catch {
            if (-not (Test-ConsoleVisible)) { exit 30 }          # ni fenêtre ni console visible : le lanceur relance avec une console (-NoGui)
            $ans = Read-TermsConsole $terms -Brand $BrandName -ClientName $ClientName
        }
        if (-not $ans.accepted) {
            Write-Warn "Conditions refusées : rien n'a été installé ni modifié."
            exit 20
        }
        $consent = New-ConsentRecord $terms $ans.name 'dialogue' $ans.seconds
    }
    else {
        Write-Warn "Cette installation exige l'acceptation des conditions : ajoutez -AcceptTerms (avec l'exe : /accept) si le client les a acceptées. Rien n'a été installé."
        exit 21
    }
}

# Client léger : une session de dépannage, sans installation (pas de fiche, pas de tâche de maintenance, pas de mot de passe permanent)
if ($Leger) {
    if (-not $interactive) { Write-Warn 'Le client léger demande une personne devant l''écran : pas de mode silencieux.'; exit 21 }
    if ($script:GuiWanted) {
        [void](Start-UiWindow -Brand $BrandName -LogoPath $LogoPath -ClientName '' -Caption $(if ($BrandName) { "$BrandName - Dépannage" } else { 'Dépannage' }) -Heading 'Préparation de la session de dépannage' -Note 'Cela prend quelques secondes. Ne fermez pas cette fenêtre.')
        Set-ReadyFlag; Set-UiProgress 8 'Préparation…' 18
    }
    if ($LaunchDir -and -not $ExplorerClosed) { Close-LaunchExplorerWindow $LaunchDir }
    Invoke-LightSession -SetupExe $InstallerPath -ServerHost $Server -ServerKey $Key
    Stop-UiWindow
    exit 0
}

if ($interactive) {
    try {
        if (-not $ClientName) { $ClientName = Get-ClientNameFromConsent $consent }
        if (-not $ClientName) {
            Write-Host ''
            $ClientName = (Read-Host "Nom du client (Entrée = $env:COMPUTERNAME)").Trim()
        }
        if (-not $Password -and $AskPassword) {
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
if ($script:QuietSteps) { Write-Host ''; Write-Host 'Installation en cours : patientez quelques minutes et ne fermez pas cette fenêtre.' -ForegroundColor Cyan }
if ($script:GuiWanted -and (Start-UiWindow -Brand $BrandName -LogoPath $LogoPath -ClientName $script:ClientFrozen)) { Set-ReadyFlag; Set-UiProgress 3 'Préparation de l''installation…' 12 }
if ($interactive -and $LaunchDir -and -not $ExplorerClosed) { Close-LaunchExplorerWindow $LaunchDir }      # l'installation démarre : la fenêtre de la clé USB n'a plus à rester ouverte

# ---------------------------------------------------------------- Réinstallation propre (option -CleanReinstall)
$cleaned = $false
if ($CleanReinstall) {
    Set-UiProgress 5 'Vérification de l''installation existante…' 13
    $up = @{}; if ($script:QuietSteps) { $up['Quiet'] = $true }
    $cr = Invoke-CleanReinstall -ServerHost $Server -UninstallParams $up -ProgramPresent ([bool]((Get-InstalledRustDesk) -or (Test-Path -LiteralPath $RdExe)))
    switch ($cr.action) {
        'effacé' {
            $cleaned = $true; $script:CleanWiped = $true
            Write-Host "[+] Réinstallation propre : $($cr.detail)." -ForegroundColor Green
            Write-Step 'Attente de la disparition de l''ancien service RustDesk'
            if (-not (Wait-RustDeskServiceGone 90)) { throw 'Windows n''a pas fini de supprimer l''ancien service RustDesk (service marqué pour suppression). Redémarrez le poste puis relancez l''exe.' }
            Start-Sleep 5
        }
        'ignoré' { Write-Warn "Réinstallation propre ignorée : $($cr.detail)." }
        'échec' { throw "Réinstallation propre impossible : $($cr.detail). Redémarrez le poste puis relancez l'exe." }
    }
}
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
Start-RustDeskService
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

# Exposition réseau : avec votre serveur, un poste ne fait que des connexions SORTANTES. L'accès direct par IP (port 21118) et la découverte du réseau local (UDP 21116,
# qui rend le poste visible des autres appareils du réseau du client) ne servent à rien : on les coupe. Chaque réglage est relu après le redémarrage du service.
$portOptions = [ordered]@{ 'direct-server' = 'N'; 'enable-lan-discovery' = 'N' }
if (-not $SkipPortHardening) {
    Write-Step 'Réduction de l''exposition réseau (pas d''accès direct par IP, poste invisible sur le réseau local)'
    foreach ($k in $portOptions.Keys) { Invoke-RustDesk '--option', $k, $portOptions[$k] | Out-Null }
    # deuxième barrière : deux règles du pare-feu Windows qui bloquent ces deux ports (un échec n'arrête pas l'installation : les réglages ci-dessus restent appliqués)
    try { $nRules = Set-PortFirewallRules $RdExe; Write-Detail ("Pare-feu Windows : $nRules règle(s) ajoutée(s) (entrant bloqué : TCP 21118, UDP 21119)") }
    catch { Write-Warn "Règles du pare-feu Windows non ajoutées ($($_.Exception.Message)) : le poste reste protégé par les réglages RustDesk (accès direct et découverte du réseau local désactivés)." }
}

try { Restart-Service $ServiceName -ErrorAction Stop }
catch { Write-Detail "Redémarrage du service refusé ($($_.Exception.Message)) : nouvelle tentative"; Start-Sleep 5; Start-RustDeskService 90 }
Start-Sleep 5
$rdId = Get-RustDeskId   # l'ID peut changer si le serveur a changé

# ---------------------------------------------------------------- Vérification
Write-Step 'Vérification finale'
$ver = (Get-InstalledRustDesk).DisplayVersion
$svc = Get-Service $ServiceName
if ($svc.Status -ne 'Running') { Write-Warn "Service : $($svc.Status)" } else { Write-Ok 'Service : Running' }
foreach ($opt in @('custom-rendezvous-server', 'approve-mode', 'verification-method') + $(if (-not $SkipPortHardening) { @($portOptions.Keys) })) {
    $v = Invoke-RustDesk '--option', $opt
    Write-Detail ("{0,-26} = {1}" -f $opt, $(if ($v) { $v } else { '(par défaut)' }))
    # un réglage d'exposition relu autrement que voulu : dit clairement (journal), sans bloquer l'installation ; Pg20-Diagnostic-Ports.ps1 mesure le résultat réel
    if (-not $SkipPortHardening -and $portOptions.Contains($opt) -and $v -and ([string]$v).Trim() -ne $portOptions[$opt]) { Write-Warn ("Réglage « $opt » non pris en compte (lu : $v) : le poste reste plus visible sur le réseau que prévu.") }
}
# traces de l'installeur de RustDesk dans le dossier temporaire de cette session (un échec n'arrête rien)
try { $nScripts = Remove-RustDeskInstallScripts; if ($nScripts) { Write-Detail "Dossier temporaire : $nScripts script(s) d'installation de RustDesk effacé(s)" } } catch { }

# ---------------------------------------------------------------- Tâche de maintenance (désinstallation sur ordre signé)
# Seulement si les conditions (qui la décrivent, point 2) ont été acceptées, et si le poste sait où lire les ordres (serveur + empreinte) et comment les
# vérifier (clé publique du technicien). Un échec n'arrête rien : le technicien saura (champ « agent » de la fiche) qu'il doit désinstaller ce poste à la main.
$agentInstalled = $false
if (-not $NoAgent -and -not $NoInbox -and $consent -and $TechPublicKey -and $InboxUrl -and $InboxPin -match '^[0-9a-fA-F]{64}$') {
    $selfPath = $(if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path })
    if (-not $AgentPath -and $selfPath) { $beside = Join-Path (Split-Path -Parent $selfPath) 'Pg20-Client-Maintenance.ps1'; if (Test-Path -LiteralPath $beside) { $AgentPath = $beside } }
    if ($AgentPath -and (Test-Path -LiteralPath $AgentPath)) {
        Write-Step 'Installation de la tâche de maintenance (désinstallation sur ordre signé du technicien)'
        try {
            $ag = Install-MaintenanceAgent -AgentSource $AgentPath -FunctionSource (Get-FunctionSource $selfPath 'Uninstall-RustDeskFully') `
                -Server $InboxUrl -Pin $InboxPin -PublicKeyXml $TechPublicKey
            if ($ag.ok) { $agentInstalled = $true; Write-Ok 'Tâche de maintenance installée (démarrage + toutes les 3 minutes, sans fenêtre)' }
            else { Write-Warn "Tâche de maintenance non installée : $($ag.message.TrimEnd(".")). Ce poste devra être désinstallé à la main." }
        }
        catch { Write-Warn "Tâche de maintenance non installée : $($_.Exception.Message). Ce poste devra être désinstallé à la main." }
    }
}

# ---------------------------------------------------------------- Envoi de la fiche au serveur du technicien
$hwFingerprint = ''
try { $hwFingerprint = Get-HardwareFingerprint } catch { }
Write-Detail ('Empreinte du matériel : ' + $(if ($hwFingerprint) { 'calculée (non réversible : jamais le numéro de série)' } else { 'indisponible (numéros de série génériques)' }))
$inboxSent = $false; $controlCode = ''; $follow = ''
if ($TechPublicKey -and $InboxUrl -and $InboxPin -and -not $NoInbox) {
    Write-Step 'Envoi de la fiche (chiffrée) à votre serveur'
    try {
        if ($InboxPin -notmatch '^[0-9a-fA-F]{64}$') { throw 'empreinte du certificat (-InboxPin) invalide' }
        $record = [ordered]@{
            v = 1; id = $rdId; name = $ClientName; host = $env:COMPUTERNAME; password = $Password
            ver = $ver; ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            agent = $agentInstalled
        }
        if ($consent) { $record['consent'] = $consent }          # la preuve d'acceptation voyage dans la fiche chiffrée
        if ($hwFingerprint) { $record['hw'] = $hwFingerprint }   # empreinte du matériel (non réversible) : reconnaître le même ordinateur après une réinstallation
        $sent = Send-InboxRecord -Endpoint $InboxUrl -Pin $InboxPin -Id $rdId -Label $ClientName -Blob (New-Envelope $record $TechPublicKey)
        if ($sent.ok) { $inboxSent = $true; $controlCode = [string]$sent.code; $follow = [string]$sent.follow; Write-Ok 'Fiche reçue par votre serveur' }
        else { Write-Warn "Fiche non envoyée : $($sent.message)." }
    }
    catch { Write-Warn "Fiche non envoyée : $($_.Exception.Message)." }
    if (-not $inboxSent) { $controlCode = ''; $follow = '' }
}

# ---------------------------------------------------------------- Copie des conditions laissée chez le client
$receiptPath = ''
if ($consent -and $terms) {
    try { $receiptPath = Save-ConsentReceipt $consent $terms $rdId $ClientName }
    catch { Write-Warn "Copie des conditions non enregistrée sur ce PC : $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- Résultat
$script:InstallComplete = $true
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
    if ($consent -or $agentInstalled -or $hwFingerprint) {
        # La preuve d'acceptation (et le fait que la tâche de maintenance est installée) suit la fiche sur la clé USB, dans un fichier à part (le format de
        # rustdesk-deployments.csv ne change pas) : chiffrée pour le technicien, ou en clair si l'exe n'a pas sa clé publique (comme le mot de passe dans ce cas).
        $cs = Join-Path $OutDir 'rustdesk-consents.csv'
        $cEnc = ''; $cJson = ''
        $side = [ordered]@{ v = 1; id = $rdId; agent = $agentInstalled }
        if ($consent) { $side['consent'] = $consent }
        if ($hwFingerprint) { $side['hw'] = $hwFingerprint }
        if ($TechPublicKey) { $cEnc = New-Envelope $side $TechPublicKey }
        else { $cJson = ConvertTo-Json -InputObject $side -Compress }
        [pscustomobject]@{ Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); ID = $rdId; ConsentEnc = $cEnc; ConsentJson = $cJson } |
            Export-Csv -Path $cs -Append -NoTypeInformation -Encoding UTF8
    }
    # Mot de passe en clair : accès limité aux administrateurs. Chiffré : aucune restriction nécessaire (et l'outil du technicien peut le lire sans élévation).
    if ($new -and -not $TechPublicKey) { icacls $csv /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null }
}

$encrypted = [bool]$TechPublicKey -and -not $NoSaveCredentials
$delivered = $encrypted -or $inboxSent        # le technicien recevra le mot de passe (chiffré) : inutile de l'afficher ici
$pwShown = if ($delivered) { '(transmis au technicien, chiffré : rien à noter)' }
           elseif ($generated) { "$Password  (généré)" }
           else { '(celui que vous avez défini)' }
$infoText = if ($inboxSent) { 'Rien à noter : la fiche est arrivée sur le serveur du technicien, qui la validera depuis son téléphone avec le code de contrôle ci-dessus.' }
            elseif ($encrypted) { 'Rien à noter : branchez la clé sur votre PC et ouvrez Pg20-Clients, le client sera importé automatiquement.' }
            else { 'Transférez ces informations dans votre gestionnaire de mots de passe, puis supprimez le CSV s''il est sur une clé USB partagée.' }

# Résumé : fenêtre système (code de contrôle en grand, avertissements) ; à défaut, la console comme avant
$shownInWindow = $false
if ($script:GuiWanted) {
    if (-not $script:UiOn) { [void](Start-UiWindow -Brand $BrandName -LogoPath $LogoPath -ClientName $script:ClientFrozen) }
    if ($script:UiOn) {
        $rows = @()
        $rows += , @('Client', "$ClientName ($env:COMPUTERNAME)")
        $rows += , @('ID RustDesk', [string]$rdId)
        $rows += , @('Mot de passe permanent', $pwShown)
        if ($inboxSent) { $rows += , @('Fiche envoyée au technicien', 'oui') }
        if ($consent) { $rows += , @('Conditions acceptées', ('{0} ({1})' -f $consent.name, $consent.mode)) }
        if ($agentInstalled) { $rows += , @('Tâche de maintenance', 'installée (désinstallation à distance, uniquement sur ordre signé du technicien)') }
        if (-not $NoSaveCredentials) { $rows += , @('Enregistré dans', ([string]$csv + $(if (-not $encrypted) { ' (accès limité aux administrateurs)' } else { '' }))) }
        if ($receiptPath) { $rows += , @('Copie des conditions', [string]$receiptPath) }
        $shownInWindow = Show-UiResult -Title $(if ($BrandName) { "$BrandName : RustDesk est prêt" } else { 'RustDesk est prêt' }) -Rows $rows -Code ([string]$controlCode) -Warnings @($script:UiWarnings) -Info $infoText
    }
}
if (-not $shownInWindow) {
    Write-Host ''
    Write-Host $(if ($BrandName) { "================ $BrandName : RustDesk prêt ================" } else { '================ RustDesk prêt ================' }) -ForegroundColor Green
    Write-Host "  Client   : $ClientName ($env:COMPUTERNAME)"
    Write-Host "  ID       : $rdId"
    Write-Host "  Mot de passe permanent : $pwShown"
    if ($inboxSent) { Write-Host '  Fiche envoyée au serveur du technicien : oui' }
    if ($controlCode) { Write-Host "  Code de contrôle : $controlCode   (le technicien le compare avec celui de son téléphone)" -ForegroundColor Yellow }
    if ($consent) { Write-Host ("  Conditions acceptées : {0} ({1}){2}" -f $consent.name, $consent.mode, $(if ($receiptPath) { " ; copie : $receiptPath" } else { '' })) }
    if ($agentInstalled) { Write-Host '  Tâche de maintenance : installée (désinstallation à distance, uniquement sur ordre signé du technicien)' }
    if (-not $NoSaveCredentials) { Write-Host "  Enregistré dans : $csv$(if (-not $encrypted) { ' (accès limité aux administrateurs)' })" }
    Write-Host '================================================' -ForegroundColor Green
    Write-Warn $infoText
}

# ---------------------------------------------------------------- Attente de la validation du technicien
# La fenêtre reste ouverte jusqu'à ce que le technicien valide la fiche depuis son téléphone, puis se ferme toute seule (code de sortie 10, que le
# lanceur reconnaît). Pas d'attente en mode silencieux. Fermer la fenêtre avant n'a aucune conséquence : tout est déjà installé et envoyé.
if ($inboxSent -and $follow -and $interactive -and $shownInWindow) {
    Set-UiStatus 'waiting'
    $outcome = 'timeout'; $w0 = Get-Date
    while (((Get-Date) - $w0).TotalSeconds -lt 600 -and -not $script:Ui.closed) {
        $outcome = try { Wait-InboxValidation -Endpoint $InboxUrl -Pin $InboxPin -Follow $follow -MaxSec 5 } catch { 'error' }
        if ($outcome -ne 'timeout') { break }
    }
    if ($script:Ui.closed) { exit 0 }                       # fermée par la personne : tout est déjà installé et envoyé
    switch ($outcome) {
        'validated' {
            if ($script:CanEject) {
                # exe lancé depuis une clé USB : la fenêtre annonce l'éjection, se ferme après quelques secondes (ou à « Fermer ») et la clé est éjectée, sauf « Ne pas éjecter » ;
                # code 11 = éjection demandée (le lanceur l'exécute à sa fin, quand la clé n'est plus occupée)
                Set-UiStatus 'validated'
                Wait-UiClosed
                $keepUsb = [bool]$script:Ui.keep
                Stop-UiWindow
                exit $(if ($keepUsb) { 10 } else { 11 })
            }
            Set-UiStatus 'validated'; [Threading.Thread]::Sleep(3000); Stop-UiWindow; exit 10
        }
        'timeout'   { Set-UiStatus 'timeout' }
        default     { Set-UiStatus 'unavailable' }
    }
    Wait-UiClosed
}
elseif ($shownInWindow) { Wait-UiClosed }
elseif ($inboxSent -and $follow -and $interactive) {
    Write-Host ''
    Write-Host "En attente de la validation du technicien... (vous pouvez aussi fermer cette fenêtre : l'installation est terminée)" -ForegroundColor Cyan
    $outcome = try { Wait-InboxValidation -Endpoint $InboxUrl -Pin $InboxPin -Follow $follow } catch { 'error' }
    switch ($outcome) {
        'validated' { Write-Host 'Validé par le technicien. Cette fenêtre va se fermer.' -ForegroundColor Green; Start-Sleep -Seconds 3; exit 10 }
        'timeout'   { Write-Warn "Le technicien n'a pas encore validé : il le fera depuis son téléphone. Vous pouvez fermer cette fenêtre." }
        default     { Write-Warn 'Suivi de la validation indisponible : le technicien validera depuis son téléphone. Vous pouvez fermer cette fenêtre.' }
    }
}
