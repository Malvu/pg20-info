<#
.SYNOPSIS
    Installe le client Pg20 Info SANS aucune question sur CE poste : stratégie de groupe (GPO), outil de gestion à distance (RMM) ou lancement à la main.

.DESCRIPTION
    À lancer en administrateur ou sous le compte SYSTEM (c'est le cas d'un script de démarrage GPO ou d'une tâche RMM). Le script :
      1. retrouve l'exe client fabriqué par Pg20-Exe-Fabriquer.ps1 (-Exe, ou l'unique .exe à côté de ce script) ; il attend le réseau si l'exe est sur un partage ;
      2. se souvient de ce qu'il a déjà fait (dossier %ProgramData%\Pg20-Info\Deploiement) : un poste déjà installé avec CET exe n'est pas réinstallé, ce qui permet de le
         laisser dans un script de démarrage GPO sans réinstaller à chaque démarrage ;
      3. copie l'exe en local, le lance avec /silent /accept, attend la fin (délai maximal), puis efface la copie ;
      4. écrit un journal (Deploiement.log) et rend un code de sortie clair.
    /accept = l'acceptation des conditions est donnée PAR PARAMÈTRE : la preuve d'acceptation du poste le mentionne (« accepté par paramètre »). Le client doit avoir accepté le
    texte des conditions AVANT (devis, contrat, courriel) : gardez cette trace. Voir DEPLOIEMENT-SCRIPT.txt.

    Codes de sortie : 0 = installé (ou déjà installé avec cet exe) ; 1 = l'exe a échoué ; 2 = pas administrateur ; 3 = exe introuvable ;
    4 = plusieurs exe possibles (précisez -Exe) ; 5 = délai dépassé ; 20 = conditions refusées ; 21 = conditions non acceptées.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Pg20-Deploiement-Poste.ps1 -Exe "\\SERVEUR\Pg20$\Pg20-Info-Support-Dupont-SA-Offline.exe"
.EXAMPLE
    .\Pg20-Deploiement-Poste.ps1 -Exe C:\Temp\Pg20-Info-Support-Dupont-SA-Offline.exe -Force -ExtraArgs /clean
#>
[CmdletBinding()]
param(
    [string]$Exe = '',                          # exe client ; par défaut : l'unique .exe à côté de ce script
    [switch]$Force,                             # réinstalle même si ce poste est déjà installé avec cet exe
    [string[]]$ExtraArgs = @(),                 # options de l'exe en plus de /silent /accept (ex. /clean : réinstallation propre)
    [int]$TimeoutSeconds = 1800,                # durée maximale de l'installation
    [int]$WaitNetworkSeconds = 120,             # attente d'un exe sur un partage réseau (le réseau n'est pas toujours prêt au démarrage)
    [string]$LogDir = '',                       # par défaut : %ProgramData%\Pg20-Info\Deploiement
    [string]$ServiceName = 'RustDesk',          # service dont l'état prouve que le poste est installé
    [switch]$NoAdminCheck                       # (tests) ne pas exiger les droits d'administrateur
)
$ErrorActionPreference = 'Stop'

if (-not $LogDir) { $LogDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Pg20-Info\Deploiement' }
$logFile = Join-Path $LogDir 'Deploiement.log'
$stateFile = Join-Path $LogDir 'etat.json'
function Write-Log([string]$Text) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Text
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { [void](New-Item -ItemType Directory -Force -Path $LogDir) }
        if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 1MB) { Move-Item -LiteralPath $logFile ($logFile + '.old') -Force }       # journal limité à ~2 Mo
        [IO.File]::AppendAllText($logFile, $line + "`r`n", (New-Object Text.UTF8Encoding($true)))
    }
    catch { }
    Write-Host $line
}
function Exit-With([int]$Code, [string]$Text) { Write-Log "$Text (code $Code)"; exit $Code }

Write-Log "--- Pg20-Deploiement-Poste sur $env:COMPUTERNAME (utilisateur : $env:USERNAME)"

if (-not $NoAdminCheck) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Exit-With 2 'Ce script doit être lancé en administrateur (ou par un script de démarrage GPO / un outil de gestion à distance).' }
}

# ---- l'exe : -Exe, sinon l'unique .exe à côté du script ; attente du réseau pour un partage
$source = $Exe
if (-not $source) {
    $here = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.exe' -File -ErrorAction SilentlyContinue)
    if ($here.Count -gt 1) { Exit-With 4 ("Plusieurs exe à côté du script (" + (($here | ForEach-Object Name) -join ', ') + ') : indiquez lequel avec -Exe.') }
    if ($here.Count -eq 1) { $source = $here[0].FullName }
}
if (-not $source) { Exit-With 3 'Aucun exe client : indiquez -Exe, ou placez l''exe à côté de ce script.' }
$t0 = Get-Date
while (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    if (((Get-Date) - $t0).TotalSeconds -ge $WaitNetworkSeconds) { Exit-With 3 "Exe introuvable : $source" }
    Start-Sleep -Seconds ([Math]::Min(10, [Math]::Max(1, $WaitNetworkSeconds)))
}
$sha = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLower()
Write-Log "Exe : $source (SHA-256 $($sha.Substring(0, 16))…)"

# ---- ce poste est-il déjà installé avec CET exe ?
$state = $null
if (Test-Path -LiteralPath $stateFile) { try { $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null } }
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $Force -and $state -and $state.exeSha256 -eq $sha -and $svc -and $svc.Status -eq 'Running') {
    Exit-With 0 "Déjà installé avec cet exe le $($state.date) : rien à faire (-Force pour réinstaller)"
}
if ($state -and $state.exeSha256 -ne $sha) { Write-Log 'Un autre exe (nouvelle version) avait été installé sur ce poste : installation de celui-ci.' }
elseif ($state -and $state.exeSha256 -eq $sha -and -not $Force) { Write-Log "Le service $ServiceName n'est pas en marche : réinstallation." }

# ---- copie locale, lancement, attente
$run = Join-Path $LogDir ('run-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Force -Path $run)
$local = Join-Path $run ([IO.Path]::GetFileName($source))
$code = 1
try {
    Copy-Item -LiteralPath $source -Destination $local -Force
    $argList = @('/silent', '/accept') + @($ExtraArgs | Where-Object { $_ })
    Write-Log ('Lancement : ' + [IO.Path]::GetFileName($local) + ' ' + ($argList -join ' '))
    $p = Start-Process -FilePath $local -ArgumentList $argList -WorkingDirectory $run -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { }
        Exit-With 5 "Délai de $TimeoutSeconds s dépassé : installation arrêtée"
    }
    $code = [int]$p.ExitCode
}
finally {
    try { [IO.Directory]::Delete($run, $true) } catch { Write-Log "Copie locale non effacée : $run" }
}

if ($code -eq 0) {
    try { [IO.File]::WriteAllText($stateFile, (ConvertTo-Json -InputObject ([ordered]@{ exeSha256 = $sha; exe = [IO.Path]::GetFileName($source); date = (Get-Date).ToString('yyyy-MM-dd HH:mm') }) -Compress), (New-Object Text.UTF8Encoding($false))) }
    catch { Write-Log "État non enregistré : $($_.Exception.Message)" }
    Exit-With 0 'Installation terminée : la fiche de ce poste attend la validation du technicien'
}
$why = switch ($code) { 20 { 'conditions refusées' } 21 { 'conditions non acceptées (/accept)' } default { 'échec de l''installation : voir Pg20-Info-Setup.log dans le dossier temporaire du compte qui a lancé le script (C:\Windows\Temp pour SYSTEM)' } }
Exit-With $code "Installation non terminée : $why"
