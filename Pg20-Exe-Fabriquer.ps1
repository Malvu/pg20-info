<#
.SYNOPSIS
    Produit l'exe d'installation d'UN client : votre marque, le nom du client, vos réglages, un registre de ce qui a été fabriqué.

.DESCRIPTION
    Lit build.config.json (serveur, clés, marque, logo, texte des conditions) et appelle Pg20-Exe-Compiler.ps1 avec ce qu'il faut. Résultat :
      dist\clients\<client>\<Marque>-Support-<client>[-Offline].exe
    L'exe porte votre marque (propriétés du fichier, fenêtre de l'UAC, titre de la console, en-tête de la fenêtre d'acceptation avec votre logo)
    et le nom du client est déjà dedans : il n'est plus demandé à l'écran, et la fenêtre d'acceptation dit « Installation pour : <client> ».
    Chaque exe fabriqué est noté dans dist\clients\clients.csv (date, client, fichier, empreintes de l'exe et du texte, version du texte...).
    Par défaut l'exe fait une « réinstallation propre » : si RustDesk est déjà sur le poste ET relié à VOTRE serveur, il est effacé avant l'installation, pour que le poste
    reparte avec une identité neuve (sinon le serveur refuse la fiche d'un poste qu'il connaît déjà). Un RustDesk relié à un autre serveur (ou à aucun), ou le PC du technicien,
    n'est jamais touché. -KeepIdentity désactive ce comportement.
    Rien n'est exécuté : l'exe est seulement construit puis contrôlé (propriétés, logo, texte, nom du client).

.EXAMPLE
    .\Pg20-Exe-Fabriquer.ps1 -Client "Dupont SARL"
.EXAMPLE
    .\Pg20-Exe-Fabriquer.ps1 -Client "Cabinet Martin" -Online      # exe qui télécharge RustDesk au lieu de l'embarquer
.EXAMPLE
    .\Pg20-Exe-Fabriquer.ps1 -List                                  # les exes déjà fabriqués
#>
[CmdletBinding()]
param(
    [string]$Client,                 # nom du client tel qu'il doit apparaître (1 à 80 caractères, sans guillemet ni barre oblique inverse)
    [switch]$Generic,                # exe GÉNÉRIQUE (sans nom de client : il est demandé à l'écran), à votre marque : celui de la clé USB
    [switch]$Online,                 # exe « en ligne » (télécharge RustDesk) au lieu de l'exe hors ligne
    [switch]$Light,                  # exe CLIENT LÉGER (« <Marque>-Depannage.exe ») : session de dépannage ponctuelle SANS installation, ID lu au téléphone ; RustDesk embarqué, pas de fiche, pas de tâche de maintenance
    [string]$TermsFile,              # texte des conditions de ce client (par défaut : le plus récent conditions-AAAA-MM-JJ*.txt)
    [switch]$NoAgent,                # sans la tâche de maintenance
    [switch]$KeepIdentity,           # NE fige PAS la réinstallation propre (par défaut, un RustDesk déjà relié à votre serveur est effacé avant l'installation : identité neuve)
    [string]$Config,                 # fichier de réglages (défaut : build.config.json à côté de ce script)
    [string]$OutDir,                 # dossier de sortie (défaut : celui du fichier de réglages, sinon dist\clients)
    [switch]$DryRun,                 # contrôle tout et annonce ce qui serait fait, sans construire
    [switch]$List                    # affiche le registre des exes fabriqués, puis quitte
)
$ErrorActionPreference = 'Stop'
$CleanReinstall = -not $KeepIdentity       # par défaut : un poste déjà connu du serveur repart avec une identité neuve (sinon le serveur refuse sa fiche)
if ($Light) { if ($Client -or $Online) { throw '-Light s''utilise seul (exe générique, hors ligne).' }; $Generic = $true; $NoAgent = $true; $CleanReinstall = $false }
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
function Resolve-Rel([string]$Path) { if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $scriptDir $Path } }

# ------------------------------------------------------------------ réglages
if (-not $Config) { $Config = Join-Path $scriptDir 'build.config.json' }
if (-not (Test-Path -LiteralPath $Config)) { throw "Fichier de réglages introuvable : $Config (modèle : build.config.example.json)" }
$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($k in $(if ($Light) { @('server', 'key') } else { @('server', 'key', 'inboxPin', 'technicianPublicKey') })) { if (-not $cfg.$k) { throw "build.config.json : « $k » manque." } }
if (-not $Light -and [string]$cfg.inboxPin -notmatch '^[0-9a-fA-F]{64}$') { throw 'build.config.json : inboxPin doit être une empreinte SHA-256 de 64 caractères hexadécimaux.' }
if (-not $OutDir) { $OutDir = $(if ($cfg.outDir) { [string]$cfg.outDir } else { 'dist\clients' }) }
$OutDir = Resolve-Rel $OutDir
$manifest = Join-Path $OutDir 'clients.csv'

if ($List) {
    if (-not (Test-Path -LiteralPath $manifest)) { 'Aucun exe fabriqué pour le moment.'; return }
    Import-Csv -LiteralPath $manifest -Encoding UTF8 | Format-Table Date, Client, Fichier, Mode, Texte, Tache -AutoSize
    return
}

# ------------------------------------------------------------------ le client
if ($Generic -and $Client) { throw 'Utilisez -Client OU -Generic, pas les deux.' }
if (-not $Client -and -not $Generic) { throw 'Indiquez le client : -Client "Nom du client" (ou -Generic pour l''exe sans nom de client).' }
$Client = ($Client -replace '\s+', ' ').Trim()
if (-not $Generic) {
    if ($Client.Length -lt 1 -or $Client.Length -gt 80) { throw 'Nom du client : 1 à 80 caractères.' }
    if ($Client -match '["\\\x00-\x1f]') { throw 'Nom du client : ni guillemet, ni barre oblique inverse, ni caractère de contrôle.' }
}

# Nom de fichier : lettres et chiffres seulement (accents retirés), jamais de nom de dossier ni de caractère spécial
function ConvertTo-Slug([string]$Text, [int]$Max) {
    $n = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $n.ToCharArray()) { if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) } }
    $s = ($sb.ToString() -replace '[^A-Za-z0-9]+', '-').Trim('-')
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max).Trim('-') }
    $s
}
$slug = $(if ($Light) { '_leger' } elseif ($Generic) { '_generique' } else { ConvertTo-Slug $Client 40 })
if (-not $slug) { throw "Nom du client « $Client » : aucune lettre ni chiffre utilisable pour le nom du fichier." }

# ------------------------------------------------------------------ la marque
$brand = $cfg.brand
$brandName = $(if ($brand -and $brand.name) { [string]$brand.name } else { '' })
$company = $(if ($brand -and $brand.company) { [string]$brand.company } else { $brandName })
$logo = ''; $icon = ''
if ($brand -and $brand.logo) { $l = Resolve-Rel ([string]$brand.logo); if (Test-Path -LiteralPath $l) { $logo = $l } else { Write-Warning "Logo introuvable ($l) : l'exe sera construit sans logo." } }
if ($brand -and $brand.icon) { $i = Resolve-Rel ([string]$brand.icon); if (Test-Path -LiteralPath $i) { $icon = $i } else { Write-Warning "Icône introuvable ($i) : elle sera tirée du logo, ou absente." } }
$brandSlug = $(if ($brandName) { ConvertTo-Slug $brandName 24 } else { 'Support' })
$prefix = $(if ($brandName) { "$brandSlug-Support" } else { 'Support' })

# ------------------------------------------------------------------ le texte des conditions
if (-not $TermsFile) {
    $tf = [string]$cfg.termsFile
    if ($tf -and $tf -ne 'latest') { $TermsFile = Resolve-Rel $tf }
    else {
        $cand = @(Get-ChildItem -LiteralPath (Join-Path $scriptDir 'conditions') -Filter 'conditions-*.txt' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match $(if ($Light) { '^conditions-leger-\d{4}-\d{2}-\d{2}[a-z]?\.txt$' } else { '^conditions-\d{4}-\d{2}-\d{2}[a-z]?\.txt$' }) } | Sort-Object Name -Descending)
        if (-not $cand.Count) { throw 'Aucun texte de conditions daté dans le dossier conditions (conditions-AAAA-MM-JJ.txt) : copiez le modèle et complétez-le.' }
        $TermsFile = $cand[0].FullName
    }
}
if (-not (Test-Path -LiteralPath $TermsFile)) { throw "Texte des conditions introuvable : $TermsFile" }
$termsText = [IO.File]::ReadAllText($TermsFile, [Text.Encoding]::UTF8) -replace "`r`n", "`n"
$termsSha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($termsText))) -replace '-', '').ToLower()
$termsVer = $(if ($termsText -match '(?im)^\s*version\s*:\s*(?<v>[^\n]{1,40})$') { $Matches['v'].Trim() } else { '(sans version)' })

# ------------------------------------------------------------------ l'exe
$installer = ''
if (-not $Online) {
    if (-not $cfg.installerFile) { throw 'build.config.json : installerFile manque (exe hors ligne). Utilisez -Online, ou indiquez l''installeur RustDesk à embarquer.' }
    $installer = Resolve-Rel ([string]$cfg.installerFile)
    if (-not (Test-Path -LiteralPath $installer)) { throw "Installeur RustDesk introuvable : $installer" }
}
$mode = $(if ($Light) { 'léger' } elseif ($Online) { 'en ligne' } else { 'hors ligne' })
$clientDir = Join-Path $OutDir $slug
$exeName = $(if ($Light) { "$brandSlug-Depannage.exe" } else { $(if ($Generic) { $prefix } else { "$prefix-$slug" }) + $(if ($Online) { '' } else { '-Offline' }) + '.exe' })
$exePath = Join-Path $clientDir $exeName

"Client : $(if ($Generic) { '(générique : le nom est demandé à l''écran)' } else { $Client })  ->  $exeName ($mode)"
"Marque : $(if ($brandName) { $brandName } else { '(aucune)' }) ; logo : $(if ($logo) { 'oui' } else { 'non' }) ; conditions : version $termsVer (SHA-256 $($termsSha.Substring(0, 12))…)"
if ($DryRun) { 'Simulation : rien n''a été construit.'; return }

New-Item -ItemType Directory -Force -Path $clientDir | Out-Null
if (Test-Path -LiteralPath $exePath) {                      # un exe précédent du même client est mis de côté, jamais écrasé sans trace
    $old = Join-Path $clientDir 'ancien'; New-Item -ItemType Directory -Force -Path $old | Out-Null
    Move-Item -LiteralPath $exePath (Join-Path $old ($exeName -replace '\.exe$', ('.' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.exe'))) -Force
}

$buildArgs = @('-Server', [string]$cfg.server, '-Key', [string]$cfg.key, '-TermsFile', $TermsFile, '-Output', $exePath)
if ($Light) { $buildArgs += '-Light' }
else { $buildArgs += @('-TechnicianPublicKey', (Resolve-Rel ([string]$cfg.technicianPublicKey)), '-InboxPin', [string]$cfg.inboxPin) }
if (-not $Generic) { $buildArgs += @('-ClientName', $Client) }
if ($cfg.inboxUrl -and -not $Light) { $buildArgs += @('-InboxUrl', [string]$cfg.inboxUrl) }
if ($installer) { $buildArgs += @('-InstallerFile', $installer) }
if ($NoAgent) { $buildArgs += '-NoAgent' }
if ($CleanReinstall) { $buildArgs += '-CleanReinstall' }
if ($brandName) { $buildArgs += @('-BrandName', $brandName) }
if ($company -and $company -ne $brandName) { $buildArgs += @('-CompanyName', $company) }
if ($logo) { $buildArgs += @('-LogoFile', $logo) }
if ($icon) { $buildArgs += @('-IconFile', $icon) }
if ($cfg.exeVersion) { $buildArgs += @('-ExeVersion', [string]$cfg.exeVersion) }
if ($env:PG20_BUILD_NOELEVATE -eq '1') { $buildArgs += '-NoElevate' }       # (tests) compiler sans demander les droits administrateur

$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'Pg20-Exe-Compiler.ps1') @buildArgs 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exePath)) { throw "La construction a échoué.`n$out" }

# ------------------------------------------------------------------ contrôles (sans exécuter l'exe)
$problems = @()
$fvi = (Get-Item -LiteralPath $exePath).VersionInfo
if ($brandName) {
    if ($fvi.ProductName -ne $brandName) { $problems += "propriété « Produit » = '$($fvi.ProductName)'" }
    if ($fvi.CompanyName -ne $company) { $problems += "propriété « Société » = '$($fvi.CompanyName)'" }
}
$asm = [Reflection.Assembly]::LoadFile($exePath)
$names = $asm.GetManifestResourceNames()
foreach ($r in 'Pg20-Client-Installation.ps1', 'defaults.txt', 'terms.txt') { if ($names -notcontains $r) { $problems += "ressource $r absente" } }
if ($logo -and $names -notcontains 'logo.png') { $problems += 'logo absent de l''exe' }
if (-not $NoAgent -and $names -notcontains 'Pg20-Client-Maintenance.ps1') { $problems += 'tâche de maintenance absente de l''exe' }
$rd = New-Object IO.StreamReader($asm.GetManifestResourceStream('defaults.txt'), [Text.Encoding]::UTF8); $defaults = $rd.ReadToEnd(); $rd.Dispose()
$dl = @($defaults -split "`r?`n" | Where-Object { $_ })
$ix = [Array]::IndexOf($dl, '-ClientName')
if ($CleanReinstall -and $dl -notcontains '-CleanReinstall') { $problems += '-CleanReinstall absent de l''exe' }
if ($Light) {
    if ($dl -notcontains '-Leger') { $problems += '-Leger absent de l''exe' }
    foreach ($bad in '-CleanReinstall', '-TechPublicKey', '-InboxPin', '-InboxUrl') { if ($dl -contains $bad) { $problems += "$bad ne doit pas figurer dans le client léger" } }
    if ($names -notcontains 'rustdesk-setup.exe') { $problems += 'RustDesk (rustdesk-setup.exe) n''est pas embarqué' }
    if ($names -contains 'Pg20-Client-Maintenance.ps1') { $problems += 'la tâche de maintenance ne doit pas être dans le client léger' }
}
if ($Generic) { if ($ix -ge 0) { $problems += 'un nom de client est figé dans l''exe générique' } }
elseif ($ix -lt 0 -or $dl[$ix + 1] -ne $Client) { $problems += 'nom du client absent ou différent dans l''exe' }
if ($brandName) { $ib = [Array]::IndexOf($dl, '-BrandName'); if ($ib -lt 0 -or $dl[$ib + 1] -ne $brandName) { $problems += 'marque absente ou différente dans l''exe' } }
$ts = New-Object IO.StreamReader($asm.GetManifestResourceStream('terms.txt'), [Text.Encoding]::UTF8); $embedded = ($ts.ReadToEnd() -replace "`r`n", "`n"); $ts.Dispose()
$embeddedSha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($embedded))) -replace '-', '').ToLower()
if ($embeddedSha -ne $termsSha) { $problems += 'texte des conditions de l''exe différent du fichier' }
if ($problems.Count) { throw ("Exe construit mais contrôle en échec : " + ($problems -join ' ; ') + "`n$exePath") }

# ------------------------------------------------------------------ registre
$exeSha = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLower()
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$row = [pscustomobject]@{
    Date = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Client = $(if ($Light) { '(client léger)' } elseif ($Generic) { '(générique)' } else { $Client }); Fichier = (Join-Path $slug $exeName); Mode = $mode; ExeSHA256 = $exeSha
    Marque = $brandName; Texte = $termsVer; TexteSHA256 = $termsSha; Tache = $(if ($NoAgent) { 'non' } else { 'oui' }); Logo = $(if ($logo) { 'oui' } else { 'non' }); Propre = $(if ($CleanReinstall) { 'oui' } else { 'non' })
}
if (Test-Path -LiteralPath $manifest) {
    # Registre d'avant la colonne « Propre » : Export-Csv -Append écarterait le champ en trop. On complète les anciennes lignes (ces exes n'avaient pas l'option).
    $rows = @(Import-Csv -LiteralPath $manifest -Encoding UTF8)
    if ($rows.Count -and -not $rows[0].PSObject.Properties['Propre']) {
        foreach ($r in $rows) { Add-Member -InputObject $r -NotePropertyName Propre -NotePropertyValue 'non' }
        $rows | Export-Csv -LiteralPath $manifest -NoTypeInformation -Encoding UTF8
    }
}
$row | Export-Csv -LiteralPath $manifest -Append -NoTypeInformation -Encoding UTF8

$size = (Get-Item -LiteralPath $exePath).Length
"[+] $exePath ($([math]::Round($size / 1MB, 1)) Mo)"
"    SHA-256 $exeSha"
"    Propriétés : $($fvi.FileDescription) ; société $($fvi.CompanyName) ; version $($fvi.FileVersion)"
"    Conditions : version $termsVer ; tâche de maintenance : $(if ($NoAgent) { 'non' } else { 'oui' }) ; noté dans $manifest"
"    Contrôlé sans l'exécuter : marque, nom du client, texte, ressources. À essayer sur un poste de test avant de le remettre au client."
