<#
.SYNOPSIS
    Crée (ou retire) deux icônes sur le bureau pour se connecter aux clients en un clic, sans fenêtre noire.

.DESCRIPTION
    - « Pg20 - Se connecter » : petite fenêtre avec la liste de vos clients validés, une recherche, Entrée ou double-clic
      ouvre RustDesk avec l'ID et le mot de passe déjà remplis (Pg20-Clients.ps1 -Quick).
    - « Pg20 - Page clients »  : la page web complète (clients, fiches à valider, renommer, masquer, oublier).
    Les deux se lancent sans fenêtre de console (conhost --headless). Elles utilisent VOTRE liste de clients.

.EXAMPLE
    .\Install-Raccourcis.ps1            # crée les deux icônes sur le bureau
.EXAMPLE
    .\Install-Raccourcis.ps1 -Remove    # les retire
#>
[CmdletBinding()]
param([switch]$Remove)
$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$target = Join-Path $scriptDir 'Pg20-Clients.ps1'
if (-not (Test-Path $target)) { throw "Script introuvable : $target" }
$desktop = [Environment]::GetFolderPath('Desktop')
$conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
$rd = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
$icon = if (Test-Path $rd) { "$rd,0" } else { "$env:WINDIR\System32\shell32.dll,15" }

$items = @(
    @{ Name = 'Pg20 - Se connecter'; Args = '-Quick';  Text = 'Se connecter à un client (liste, recherche, double-clic)' },
    @{ Name = 'Pg20 - Page clients'; Args = '';        Text = 'Page web des clients (validation, connexion, gestion)' }
)

foreach ($it in $items) {
    $lnk = Join-Path $desktop ($it.Name + '.lnk')
    if ($Remove) {
        if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "[+] Retiré : $lnk" -ForegroundColor Green } else { Write-Host "Absent : $lnk" }
        continue
    }
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = $conhost
    $s.Arguments = ('--headless powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "' + $target + '" ' + $it.Args).TrimEnd()
    $s.WorkingDirectory = $scriptDir
    $s.IconLocation = $icon
    $s.Description = $it.Text
    $s.Save()
    Write-Host "[+] Créé : $lnk" -ForegroundColor Green
}
if (-not $Remove) { Write-Host 'Double-cliquez sur « Pg20 - Se connecter » : choisissez un client, Entrée (ou double-clic).' }
