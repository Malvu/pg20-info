<#
.SYNOPSIS
    Pg20 Info : rassemble en UN fichier ce qu'il faut pour juger un essai (recette) sur un PC. LECTURE SEULE : rien n'est installé, créé ni modifié,
    sauf le fichier de rapport.

.DESCRIPTION
    À lancer sur le PC d'essai APRÈS l'installation (de préférence en administrateur : certaines lectures en ont besoin) :
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Pg20-Diagnostic-Recette.ps1
    ou double-clic sur Pg20-Diagnostic-Recette.cmd. Le rapport Recette-<date>.txt s'écrit à côté du script (sur la clé USB, ou dans le dossier TEMP si la
    clé est protégée en écriture) ; il contient : Windows, écran (taille, mise à l'échelle), antivirus, RustDesk (version, service, serveur désigné),
    tâche de maintenance (état, dernier passage, intervalle), dernières lignes des journaux du lanceur et du script, preuves d'acceptation présentes.
    Il contient le NOM du PC et de la session Windows (utile pour s'y retrouver), JAMAIS un mot de passe ni une clé : les lignes de configuration
    RustDesk ne sont lues que pour le nom du serveur.
#>
[CmdletBinding()]
param(
    [int]$LogLines = 60,       # nombre de dernières lignes de chaque journal
    [string]$OutDir            # dossier du rapport (défaut : celui du script, sinon TEMP)
)
$ErrorActionPreference = 'Continue'
$script:out = New-Object System.Collections.Generic.List[string]
function Add-Out([string]$Text = '') { $script:out.Add($Text); Write-Host $Text }
function Section([string]$Title) { Add-Out ''; Add-Out ('== ' + $Title) }
function Try-Get([scriptblock]$Block) { try { & $Block } catch { $null } }
Add-Type -Namespace Pg20 -Name Lp -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern uint GetLongPathName(string s, System.Text.StringBuilder l, uint n);' -ErrorAction SilentlyContinue
function Get-LongPath([string]$Path) { try { $sb = New-Object System.Text.StringBuilder 1024; if ([Pg20.Lp]::GetLongPathName($Path, $sb, 1024) -gt 0) { return $sb.ToString() } } catch { }; $Path }
function Show-Tail([string]$Path, [int]$N) {
    if (-not (Test-Path -LiteralPath $Path)) { Add-Out "  (absent : $Path)"; return }
    $it = Get-Item -LiteralPath $Path
    Add-Out ("  {0}  ({1:yyyy-MM-dd HH:mm:ss}, {2} octets) ; {3} dernières lignes :" -f $Path, $it.LastWriteTime, $it.Length, $N)
    try { Get-Content -LiteralPath $Path -Tail $N -Encoding UTF8 -ErrorAction Stop | ForEach-Object { Add-Out ('    ' + $_) } }
    catch { Add-Out "  (illisible : $($_.Exception.Message))" }
}

Add-Out ('Pg20 Info : rapport de recette, ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Out ('Session : ' + $(if ($isAdmin) { 'administrateur' } else { 'utilisateur standard (certaines lectures sont limitées : relancez en administrateur)' }))

# ------------------------------------------------------------------ Windows, écran
Section 'Windows et écran'
$os = Try-Get { Get-CimInstance Win32_OperatingSystem }
$disp = Try-Get { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).DisplayVersion }
if ($os) { Add-Out ("  Système : {0}, build {1}{2}, {3}" -f ($os.Caption -replace 'Microsoft ', ''), $os.BuildNumber, $(if ($disp) { ", version $disp" }), $os.OSArchitecture) }
Add-Out ("  PC / session : {0} / {1}" -f $env:COMPUTERNAME, $env:USERNAME)
$vc = @(Try-Get { Get-CimInstance Win32_VideoController } | Where-Object { $_.CurrentHorizontalResolution })
foreach ($v in $vc) { Add-Out ("  Écran (carte {0}) : {1} x {2} pixels" -f $v.Name, $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution) }
$dpi = Try-Get { (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -ErrorAction Stop).AppliedDPI }
if (-not $dpi) { $dpi = Try-Get { (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction Stop).LogPixels } }
if ($dpi) { Add-Out ("  Mise à l'échelle : {0} % ({1} ppp)" -f [int]([double]$dpi / 96 * 100), $dpi) } else { Add-Out "  Mise à l'échelle : 100 % (valeur par défaut, non lue)" }
Add-Out ('  Langue de l''interface : ' + (Try-Get { (Get-UICulture).Name }))

# ------------------------------------------------------------------ Disques
Section 'Disques : type vu par Windows (la clé USB doit être « AMOVIBLE » pour s''éjecter toute seule)'
$dtypes = @{ 0 = 'inconnu'; 1 = 'sans racine'; 2 = 'AMOVIBLE'; 3 = 'FIXE'; 4 = 'réseau'; 5 = 'CD/DVD'; 6 = 'disque RAM' }
foreach ($d in @(Try-Get { Get-CimInstance Win32_LogicalDisk })) {
    $bus = Try-Get { (Get-Partition -DriveLetter $d.DeviceID.Substring(0, 1) -ErrorAction Stop | Get-Disk -ErrorAction Stop).BusType }
    Add-Out ('  {0}  type : {1}{2}  étiquette : {3}  système de fichiers : {4}' -f $d.DeviceID, $dtypes[[int]$d.DriveType], $(if ($bus) { ", bus : $bus" } else { '' }), $d.VolumeName, $d.FileSystem)
}
# ------------------------------------------------------------------ Antivirus
Section 'Antivirus déclarés à Windows'
$av = @(Try-Get { Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop })
if ($av.Count) { foreach ($a in $av) { Add-Out ('  ' + $a.displayName) } } else { Add-Out '  (aucun lisible : poste sans Centre de sécurité, ou lecture refusée)' }
$mp = Try-Get { Get-MpComputerStatus -ErrorAction Stop }
if ($mp) { Add-Out ("  Microsoft Defender : protection en temps réel {0}" -f $(if ($mp.RealTimeProtectionEnabled) { 'activée' } else { 'désactivée' })) }
$threat = @(Try-Get { Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.Resources -match 'Pg20|RustDesk' } | Select-Object -First 5 })
if ($threat.Count) { foreach ($t in $threat) { Add-Out ("  DÉTECTION Defender : {0:yyyy-MM-dd HH:mm} {1}" -f $t.InitialDetectionTime, ($t.Resources -join ' ')) } } else { Add-Out '  Aucune détection Defender liée à Pg20 / RustDesk.' }

# ------------------------------------------------------------------ RustDesk
Section 'RustDesk'
$keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$inst = Try-Get { Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'RustDesk' } | Select-Object -First 1 }
if ($inst) { Add-Out ('  Installé : version ' + $inst.DisplayVersion) } else { Add-Out '  Non installé (aucune entrée « RustDesk » dans les programmes).' }
$svc = Try-Get { Get-Service -Name 'RustDesk' -ErrorAction Stop }
if ($svc) { Add-Out ('  Service : {0} (démarrage : {1})' -f $svc.Status, $svc.StartType) } else { Add-Out '  Service RustDesk : absent' }
foreach ($cfg in @('C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml', (Join-Path $env:APPDATA 'RustDesk\config\RustDesk2.toml'))) {
    if (Try-Get { Test-Path -LiteralPath $cfg -ErrorAction Stop }) {
        $line = $null; $denied = $false
        try { $line = Select-String -LiteralPath $cfg -Pattern '^\s*(custom-rendezvous-server|rendezvous_server)\s*=' -ErrorAction Stop | Select-Object -First 1 } catch { $denied = $true }
        Add-Out ('  Configuration {0} : serveur = {1}' -f $cfg, $(if ($line) { ($line.Line -replace '^\s*[\w-]+\s*=\s*', '').Trim().Trim("'", '"') } elseif ($denied) { '(illisible : relancez en administrateur)' } else { '(non indiqué)' }))
    }
}

# ------------------------------------------------------------------ Tâche de maintenance
Section 'Tâche de maintenance (Pg20-Info-Maintenance)'
$task = Try-Get { Get-ScheduledTask -TaskName 'Pg20-Info-Maintenance' -ErrorAction Stop }
if ($task) {
    $ti = Try-Get { Get-ScheduledTaskInfo -TaskName 'Pg20-Info-Maintenance' -ErrorAction Stop }
    Add-Out ('  État : ' + $task.State + ' ; compte : ' + $task.Principal.UserId + ' ; cachée : ' + $task.Settings.Hidden)
    foreach ($tr in @($task.Triggers)) { Add-Out ('  Déclencheur : ' + $tr.CimClass.CimClassName + $(if ($tr.Repetition -and $tr.Repetition.Interval) { ', répété toutes les ' + $tr.Repetition.Interval } else { '' })) }
    if ($ti) { Add-Out ('  Dernier passage : {0:yyyy-MM-dd HH:mm:ss} ; résultat : {1} ; prochain : {2:yyyy-MM-dd HH:mm:ss}' -f $ti.LastRunTime, $ti.LastTaskResult, $ti.NextRunTime) }
    $boot = Try-Get { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
    if ($boot) { Add-Out ('  Dernier démarrage du PC : {0:yyyy-MM-dd HH:mm:ss}  (le « dernier passage » doit être postérieur : la tâche tourne bien au démarrage)' -f $boot) }
}
elseif (-not $isAdmin) { Add-Out '  Tâche NON VISIBLE sans droits administrateur (une tâche créée par SYSTEM reste cachée à un compte standard) : relancez ce rapport en administrateur (clic droit, Exécuter en tant qu''administrateur).' }
else { Add-Out '  Tâche absente (pas installée, ou déjà exécutée puis retirée après une désinstallation).' }
$agentLog = Join-Path ${env:ProgramFiles} 'Pg20-Info\Agent\agent.log'
if (Test-Path -LiteralPath $agentLog) { Show-Tail $agentLog 15 } else { Add-Out '  Journal de la tâche : absent (normal si la tâche n''est pas installée ou après désinstallation).' }

# ------------------------------------------------------------------ Journaux de l'installation
Section 'Journaux du lanceur et du script (dossier TEMP)'
$temps = New-Object System.Collections.Generic.List[string]; $temps.Add((Get-LongPath $env:TEMP))
foreach ($d in @(Try-Get { Get-ChildItem 'C:\Users' -Directory -ErrorAction Stop })) { $t = Join-Path $d.FullName 'AppData\Local\Temp'; if ((Test-Path -LiteralPath $t) -and -not ($temps -contains (Get-LongPath $t))) { $temps.Add((Get-LongPath $t)) } }
$seen = 0
foreach ($t in $temps) {
    foreach ($name in 'Pg20-Info-Setup.log', 'Pg20-Info-Install.log') {
        $p = Join-Path $t $name
        if (Test-Path -LiteralPath $p) { $seen++; Add-Out ''; Show-Tail $p $LogLines }
    }
}
if (-not $seen) { Add-Out '  Aucun journal : l''exe n''a pas pu démarrer (SmartScreen, antivirus...) ou le TEMP de la session qui l''a lancé n''est pas lisible d''ici.' }

# ------------------------------------------------------------------ Traces laissées
Section 'Traces laissées sur le PC'
$pd = 'C:\ProgramData\Pg20-Info'
if (Test-Path -LiteralPath $pd) { Get-ChildItem -LiteralPath $pd -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object { Add-Out ('  {0:yyyy-MM-dd HH:mm}  {1}' -f $_.LastWriteTime, $_.Name) } }
else { Add-Out "  $pd absent." }

# ------------------------------------------------------------------ Écriture du rapport
$dirOut = $OutDir; if (-not $dirOut) { $dirOut = $PSScriptRoot }; if (-not $dirOut) { $dirOut = (Get-Location).Path }
$file = Join-Path $dirOut ('Recette-{0:yyyyMMdd-HHmm}.txt' -f (Get-Date))
try { [IO.File]::WriteAllLines($file, $script:out, (New-Object Text.UTF8Encoding($true))) }
catch { $file = Join-Path $env:TEMP ('Recette-{0:yyyyMMdd-HHmm}.txt' -f (Get-Date)); [IO.File]::WriteAllLines($file, $script:out, (New-Object Text.UTF8Encoding($true))) }
Write-Host ''
Write-Host "Rapport écrit : $file" -ForegroundColor Green
