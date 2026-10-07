<#
.SYNOPSIS
    Pg20 Info : un PC peut-il construire et recevoir les exes ? Diagnostic en LECTURE SEULE (rien n'est installé, créé ni modifié).

.DESCRIPTION
    À lancer sur un PC de test (Windows 10, Windows 11...) ou chez un client, de préférence en administrateur (certaines lectures en ont besoin) :
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Pg20-Diagnostic-Compatibilite.ps1
    Vérifie ce dont le montage dépend : version de Windows, PowerShell et son mode, compilateur C#, planificateur de tâches, protections qui peuvent
    bloquer un exe non signé (Smart App Control, SmartScreen, antivirus, contrôle d'applications), chiffrement des clés (DPAPI), TLS 1.2, fenêtres WinForms,
    présence de RustDesk et de la tâche de maintenance. Avec -Server, essaie aussi de joindre le port de réception des fiches (simple connexion TCP).
    Le rapport ne contient ni nom d'utilisateur ni nom du PC (sauf avec -IncludeNames). -Save l'écrit dans un fichier à côté du script.
#>
[CmdletBinding()]
param(
    [string]$Server,            # adresse[:port] du serveur (port 21120 par défaut) : test de connexion TCP seulement
    [switch]$IncludeNames,      # inclut le nom du PC et de l'utilisateur dans le rapport
    [switch]$Save               # écrit le rapport dans Rapport-Compatibilite-<date>.txt (dossier du script)
)
$ErrorActionPreference = 'Continue'
$script:lines = New-Object System.Collections.Generic.List[string]
$script:warn = 0; $script:bad = 0
function Add-Line([string]$Level, [string]$Label, [string]$Detail = '') {
    $tag = switch ($Level) { 'ok' { '[OK]       ' } 'warn' { '[ATTENTION]' } 'bad' { '[PROBLÈME] ' } default { '[info]     ' } }
    if ($Level -eq 'warn') { $script:warn++ } elseif ($Level -eq 'bad') { $script:bad++ }
    $text = "$tag $Label" + $(if ($Detail) { " : $Detail" } else { '' })
    $script:lines.Add($text)
    $color = switch ($Level) { 'ok' { 'Green' } 'warn' { 'Yellow' } 'bad' { 'Red' } default { 'Gray' } }
    Write-Host $text -ForegroundColor $color
}
function Section([string]$Title) { $script:lines.Add(''); $script:lines.Add("== $Title"); Write-Host ''; Write-Host "== $Title" -ForegroundColor Cyan }
function Try-Get([scriptblock]$Block) { try { & $Block } catch { $null } }

Write-Host "Pg20 Info : diagnostic de compatibilité (lecture seule)" -ForegroundColor Cyan
$script:lines.Add('Pg20 Info : diagnostic de compatibilité (lecture seule), ' + (Get-Date).ToString('yyyy-MM-dd HH:mm'))

# ------------------------------------------------------------------ Windows
Section 'Windows'
$os = Try-Get { Get-CimInstance Win32_OperatingSystem }
$build = [int](Try-Get { [Environment]::OSVersion.Version.Build })
if ($os) {
    $family = $(if ($build -ge 22000) { 'Windows 11' } elseif ($build -ge 10240) { 'Windows 10' } else { 'ancien Windows' })
    $ubr = Try-Get { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).DisplayVersion }
    Add-Line 'info' 'Système' "$family, build $build$(if ($ubr) { ", version $ubr" }), $($os.Caption -replace 'Microsoft ', '')"
    if ($build -lt 17763) { Add-Line 'bad' 'Version de Windows' "build $build : trop ancienne (Windows 10 1809 ou plus récent attendu)" } else { Add-Line 'ok' 'Version de Windows' "$family pris en charge par ce montage (testé : Windows 10 seulement)" }
    $arch = $os.OSArchitecture
    $procArch = $env:PROCESSOR_ARCHITECTURE; if ($env:PROCESSOR_ARCHITEW6432) { $procArch = $env:PROCESSOR_ARCHITEW6432 }
    if ($procArch -eq 'ARM64') { Add-Line 'warn' 'Processeur' "ARM64 : l'installeur RustDesk embarqué est x86_64 (émulation, non testé)" }
    elseif ($arch -match '64') { Add-Line 'ok' 'Processeur' "$arch ($procArch)" }
    else { Add-Line 'bad' 'Processeur' "$arch : l'installeur RustDesk fourni est en 64 bits" }
}
else { Add-Line 'warn' 'Système' 'version non lisible' }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Line 'info' 'Session' $(if ($isAdmin) { 'administrateur' } else { 'utilisateur standard (certaines lectures sont limitées ; relancez en administrateur pour un rapport complet)' })
if ($IncludeNames) { Add-Line 'info' 'PC / utilisateur' "$env:COMPUTERNAME / $env:USERNAME" }

# ------------------------------------------------------------------ PowerShell
Section 'PowerShell'
$psv = $PSVersionTable.PSVersion
if ($psv.Major -eq 5 -and $psv.Minor -ge 1) { Add-Line 'ok' 'Windows PowerShell' "version $psv (celle que le montage utilise)" }
elseif ($psv.Major -ge 6) { Add-Line 'warn' 'Version de ce PowerShell' "$psv : lancez plutôt Windows PowerShell 5.1 (powershell.exe) ; le montage appelle powershell.exe 5.1" }
else { Add-Line 'bad' 'Windows PowerShell' "version $psv : 5.1 requis" }
$ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath $ps51) { Add-Line 'ok' 'powershell.exe 5.1' 'présent' } else { Add-Line 'bad' 'powershell.exe 5.1' "introuvable ($ps51) : l'exe et la tâche de maintenance ne pourraient pas démarrer" }
$mode = $ExecutionContext.SessionState.LanguageMode
if ("$mode" -eq 'FullLanguage') { Add-Line 'ok' 'Mode du langage' 'FullLanguage (complet)' } else { Add-Line 'bad' 'Mode du langage' "$mode : un contrôle d'applications restreint PowerShell ; l'exe et la tâche de maintenance ne fonctionneraient pas" }
$pol = Try-Get { Get-ExecutionPolicy -List | ForEach-Object { '{0}={1}' -f $_.Scope, $_.ExecutionPolicy } }
if ($pol) {
    $mp = Try-Get { (Get-ExecutionPolicy -Scope MachinePolicy).ToString() }; $up = Try-Get { (Get-ExecutionPolicy -Scope UserPolicy).ToString() }
    if ($mp -in 'AllSigned', 'Restricted' -or $up -in 'AllSigned', 'Restricted') { Add-Line 'bad' 'Stratégie d''exécution imposée (GPO)' "MachinePolicy=$mp UserPolicy=$up : elle l'emporte sur les options de l'exe" }
    else { Add-Line 'ok' 'Stratégie d''exécution' ('pas de blocage imposé par une GPO ; ' + ($pol -join ', ')) }
}

# ------------------------------------------------------------------ construction des exes
Section 'Construction des exes (PC du technicien)'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (Test-Path -LiteralPath $csc) { Add-Line 'ok' 'Compilateur C# (csc.exe)' 'présent' } else { Add-Line 'warn' 'Compilateur C# (csc.exe)' "introuvable : Pg20-Exe-Compiler.ps1 ne pourrait pas construire d'exe sur ce PC (inutile sur un PC de client)" }
$rel = Try-Get { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release }
if ($rel -ge 378389) { Add-Line 'ok' '.NET Framework 4' "release $rel" } else { Add-Line 'bad' '.NET Framework 4' "release $rel : 4.5 ou plus requis" }
$tlsOk = $false; try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $tlsOk = ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) -ne 0 } catch { }
if ($tlsOk) { Add-Line 'ok' 'TLS 1.2' 'disponible (envoi des fiches, empreinte du certificat)' } else { Add-Line 'bad' 'TLS 1.2' 'non disponible' }
$wf = $false; try { Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop; $wf = $true } catch { }
if ($wf) { Add-Line 'ok' 'Fenêtres WinForms' 'disponibles (fenêtre d''acceptation, « Se connecter »)' } else { Add-Line 'bad' 'Fenêtres WinForms' 'indisponibles' }
$dp = $false; try { $s = ConvertTo-SecureString 'x' -AsPlainText -Force; $e = ConvertFrom-SecureString $s; $b = ConvertTo-SecureString $e; $dp = $true } catch { }
if ($dp) { Add-Line 'ok' 'Protection des clés (DPAPI)' 'fonctionne' } else { Add-Line 'bad' 'Protection des clés (DPAPI)' 'ne fonctionne pas : la clé privée ne pourrait pas être protégée' }
$rsa = $false; try { $r = New-Object Security.Cryptography.RSACryptoServiceProvider 2048; $sig = $r.SignData([byte[]](1, 2, 3), 'SHA256'); $rsa = $r.VerifyData([byte[]](1, 2, 3), 'SHA256', $sig); $r.Dispose() } catch { }
if ($rsa) { Add-Line 'ok' 'Signature RSA-SHA256' 'fonctionne (ordres de désinstallation)' } else { Add-Line 'bad' 'Signature RSA-SHA256' 'ne fonctionne pas' }

# ------------------------------------------------------------------ ce qui peut bloquer un exe non signé
Section 'Protections qui peuvent bloquer un exe non signé'
$sac = Try-Get { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState }
switch ($sac) {
    1 { Add-Line 'bad' 'Smart App Control' "ACTIVÉ : il bloque les exes non signés sans réputation, comme le nôtre (Sécurité Windows > Contrôle des applications et du navigateur)" }
    2 { Add-Line 'warn' 'Smart App Control' 'en évaluation : il peut s''activer et bloquer les exes non signés' }
    0 { if ($build -lt 22000) { Add-Line 'info' 'Smart App Control' 'sans objet sous Windows 10 (fonction propre à Windows 11)' } else { Add-Line 'ok' 'Smart App Control' 'désactivé' } }
    default { Add-Line 'info' 'Smart App Control' 'état non trouvé dans le registre (absent de ce Windows, ou lecture refusée) : vérifiez dans Sécurité Windows > Contrôle des applications et du navigateur' }
}
$ss = Try-Get { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name SmartScreenEnabled -ErrorAction Stop).SmartScreenEnabled }
if ($ss) { Add-Line 'info' 'SmartScreen (applications et fichiers)' "réglage « $ss » : un avertissement « éditeur inconnu » est normal tant que l'exe n'est pas signé" }
$av = Try-Get { @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName }) }
if ($av) { Add-Line 'info' 'Antivirus déclaré à Windows' (($av | Select-Object -Unique) -join ', ') } else { Add-Line 'info' 'Antivirus déclaré à Windows' 'non lisible (poste serveur, ou accès refusé)' }
$mp = Try-Get { Get-MpComputerStatus -ErrorAction Stop }
if ($mp) { Add-Line 'info' 'Microsoft Defender' "protection en temps réel : $($mp.RealTimeProtectionEnabled) ; réseau/cloud : $($mp.IsTamperProtected -eq $true)" }
$wdac = Try-Get { @(Get-ChildItem (Join-Path $env:WINDIR 'System32\CodeIntegrity\CiPolicies\Active') -Filter *.cip -ErrorAction Stop).Count }
$applocker = Try-Get { Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2' }
if ($wdac -gt 0) { Add-Line 'warn' 'Contrôle d''applications (WDAC / App Control)' "$wdac stratégie(s) active(s) : un exe non signé peut être refusé" } else { Add-Line 'ok' 'Contrôle d''applications (WDAC)' 'aucune stratégie active détectée' }
if ($applocker) { Add-Line 'warn' 'AppLocker' 'des règles sont configurées : à vérifier avec l''administrateur du poste' }

# ------------------------------------------------------------------ planificateur, RustDesk, tâche de maintenance
Section 'Planificateur de tâches, RustDesk, tâche de maintenance'
$sch = Try-Get { (Get-Service -Name Schedule -ErrorAction Stop).Status }
if ("$sch" -eq 'Running') { Add-Line 'ok' 'Service Planificateur de tâches' 'en cours' } else { Add-Line 'bad' 'Service Planificateur de tâches' "état : $sch : la tâche de maintenance ne pourrait pas s'exécuter" }
$rdKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$rd = Try-Get { Get-ItemProperty $rdKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'RustDesk' } | Select-Object -First 1 }
if ($rd) { Add-Line 'info' 'RustDesk installé' "version $($rd.DisplayVersion)" } else { Add-Line 'info' 'RustDesk installé' 'non' }
$svc = Try-Get { Get-Service -Name RustDesk -ErrorAction Stop }
if ($svc) { Add-Line 'info' 'Service RustDesk' "$($svc.Status), démarrage $($svc.StartType)" }
$task = Try-Get { Get-ScheduledTask -TaskName 'Pg20-Info-Maintenance' -ErrorAction Stop }
if ($task) {
    $ti = Try-Get { Get-ScheduledTaskInfo -TaskName 'Pg20-Info-Maintenance' }
    Add-Line 'info' 'Tâche de maintenance Pg20' "présente, état $($task.State), dernier résultat $($ti.LastTaskResult), dernière exécution $($ti.LastRunTime), compte $($task.Principal.UserId)"
}
else { Add-Line 'info' 'Tâche de maintenance Pg20' 'absente' }
$agentDir = Join-Path $env:ProgramFiles 'Pg20-Info\Agent'
if (Test-Path -LiteralPath $agentDir) {
    $acl = Try-Get { Get-Acl -LiteralPath $agentDir }
    $users = @($acl.Access | Where-Object { $_.IdentityReference.Value -match 'Users|Utilisateurs|Everyone|Tout le monde|Authenticated' -and $_.FileSystemRights -match 'Write|Modify|FullControl' })
    if ($users.Count) { Add-Line 'bad' 'Dossier de la tâche de maintenance' 'des utilisateurs ordinaires peuvent y écrire : un utilisateur pourrait détourner la tâche (compte système)' } else { Add-Line 'ok' 'Dossier de la tâche de maintenance' 'réservé au système et aux administrateurs' }
}

# ------------------------------------------------------------------ serveur (facultatif)
if ($Server) {
    Section 'Serveur Pg20 Info (connexion TCP seulement)'
    $h = $Server; $port = 21120
    if ($Server -match '^(?<h>[^:]+):(?<p>\d{1,5})$') { $h = $Matches.h; $port = [int]$Matches.p }
    $c = New-Object Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($h, $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(6000) -and $c.Connected) { $c.EndConnect($ar); Add-Line 'ok' "Connexion à ${h}:$port" 'le port répond (réception des fiches joignable depuis ce réseau)' }
        else { Add-Line 'bad' "Connexion à ${h}:$port" 'pas de réponse en 6 s : port bloqué par ce réseau, ou serveur éteint (l''exe retombera sur la clé USB)' }
    }
    catch { Add-Line 'bad' "Connexion à ${h}:$port" $_.Exception.Message }
    finally { $c.Close() }
}

# ------------------------------------------------------------------ bilan
$script:lines.Add('')
Write-Host ''
$verdict = $(if ($script:bad) { "$($script:bad) problème(s) à régler avant d'utiliser le montage sur ce PC" } elseif ($script:warn) { "aucun blocage certain, $($script:warn) point(s) d'attention" } else { 'aucun problème détecté' })
$script:lines.Add("BILAN : $verdict")
Write-Host "BILAN : $verdict" -ForegroundColor $(if ($script:bad) { 'Red' } elseif ($script:warn) { 'Yellow' } else { 'Green' })
Write-Host 'Ce diagnostic ne remplace pas un essai réel : lancez l''exe de test, validez la fiche, puis essayez « Désinstaller… ».' -ForegroundColor DarkGray
if ($Save) {
    $dir = $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path })
    $f = Join-Path $dir ('Rapport-Compatibilite-{0:yyyyMMdd-HHmm}.txt' -f (Get-Date))
    [IO.File]::WriteAllLines($f, $script:lines, (New-Object Text.UTF8Encoding($true)))
    Write-Host "Rapport enregistré : $f"
}
