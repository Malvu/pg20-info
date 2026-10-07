<#
.SYNOPSIS
    Installe (ou retire) la surveillance en tâche de fond de Pg20-Clients : elle relève toute seule les fiches d'installation
    envoyées à votre serveur, sans ouvrir la page, et affiche une notification Windows.

.DESCRIPTION
    Crée la tâche planifiée « Pg20-Clients-Surveillance » : lancée à l'ouverture de votre session Windows, SANS fenêtre
    (conhost --headless), avec VOS droits (pas d'administrateur), une seule instance, relancée automatiquement en cas d'arrêt.
    Elle exécute  Pg20-Clients-Carnet.ps1 -Watch  : toutes les 20 s elle lit la clé USB si elle est branchée, relève les fiches du serveur,
    applique les validations faites depuis le téléphone, et note ses événements dans %APPDATA%\Pg20-Info\watch.log.
    Elle ne tourne que lorsque ce PC est allumé et joint le serveur (réseau local ou WireGuard) : sinon les fiches attendent
    sur le serveur, chiffrées, jusqu'à 14 jours.

.EXAMPLE
    .\Pg20-Clients-Surveillance-Installer.ps1            # installe et démarre
.EXAMPLE
    .\Pg20-Clients-Surveillance-Installer.ps1 -Remove    # arrête et retire la tâche
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$NoStart,
    [int]$Interval = 20
)
$ErrorActionPreference = 'Stop'
$taskName = 'Pg20-Clients-Surveillance'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$target = Join-Path $scriptDir 'Pg20-Clients-Carnet.ps1'

function Stop-Watchers {
    # Arrête les surveillances en cours (processus powershell lancés avec Pg20-Clients-Carnet.ps1 -Watch)
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -match 'Pg20-Clients\.ps1' -and $_.CommandLine -match '\s-Watch(\s|$)' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; "  processus $($_.ProcessId) arrêté" }
}

if ($Remove) {
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($t) { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; Write-Host "[+] Tâche « $taskName » retirée." -ForegroundColor Green }
    else { Write-Host "Tâche « $taskName » absente : rien à retirer." }
    Stop-Watchers
    return
}

if (-not (Test-Path $target)) { throw "Script introuvable : $target" }
$conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
if (-not (Test-Path $conhost)) { throw 'conhost.exe introuvable (Windows 10 version 1809 ou plus récent requis).' }

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$arg = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $target + '" -Watch -Interval ' + $Interval
$action = New-ScheduledTaskAction -Execute $conhost -Argument $arg -WorkingDirectory $scriptDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force `
    -Description 'Pg20 Info : relève les fiches d''installation envoyées au serveur RustDesk et applique les validations du téléphone (Pg20-Clients-Carnet.ps1 -Watch).' | Out-Null
Write-Host "[+] Tâche « $taskName » créée pour $user (à l'ouverture de session, sans fenêtre, sans droits administrateur)." -ForegroundColor Green

if (-not $NoStart) {
    Stop-Watchers | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 4
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -match 'Pg20-Clients\.ps1' -and $_.CommandLine -match '\s-Watch(\s|$)' })
    if ($running.Count) { Write-Host "[+] Surveillance démarrée (processus $($running[0].ProcessId)). Journal : $(Join-Path $env:APPDATA 'Pg20-Info\watch.log')" -ForegroundColor Green }
    else { Write-Host '[!] La tâche est créée mais aucun processus de surveillance n''est visible : consultez watch.log ou relancez la tâche.' -ForegroundColor Yellow }
}
