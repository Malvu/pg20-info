// Lanceur autonome : embarque Pg20-Client-Installation.ps1, demande les droits administrateur (manifeste),
// extrait le script dans un dossier temporaire, l'exécute puis nettoie. Compatible csc C# 5 (.NET Framework 4).
//
// Application Windows SANS console : un double-clic n'ouvre plus de fenêtre noire. Le script affiche ses propres fenêtres (conditions, progression,
// résumé, erreur) ; en attendant la première, le lanceur montre un petit écran de démarrage. Lancé depuis un terminal (déploiement, -Uninstall...), il
// s'attache à ce terminal : la sortie du script y reste visible, comme avant.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;

// Titre, description, société, produit, version : générés par Pg20-Exe-Compiler.ps1 (AssemblyInfo.cs temporaire) pour porter la marque du technicien.

internal static class Program
{
    // Journal du lanceur : %TEMP%\Pg20-Info-Setup.log (jamais de mot de passe : seuls les NOMS des options sont consignés).
    // Si ce fichier n'existe pas après un double-clic, l'exe n'a pas pu démarrer (SmartScreen, antivirus, droits...).
    private static readonly string LogPath = Path.Combine(Path.GetTempPath(), "Pg20-Info-Setup.log");

    [DllImport("kernel32.dll")]
    private static extern bool AttachConsole(uint processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    private static bool hasConsole = false;           // lancé depuis un terminal : on y écrit
    private static volatile bool splashStop = false;
    private static Thread splashThread = null;

    private static void Log(string message)
    {
        try
        {
            if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 100000) File.Delete(LogPath);
            File.AppendAllText(LogPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + Environment.NewLine, new UTF8Encoding(false));
        }
        catch (Exception) { }
    }

    // Texte dans le terminal d'où l'exe a été lancé (rien si double-clic : pas de terminal)
    private static void ConsoleWrite(string text)
    {
        if (!hasConsole) return;
        try
        {
            IntPtr h = CreateFile("CONOUT$", 0x40000000, 2, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (h == new IntPtr(-1)) return;
            using (FileStream fs = new FileStream(new SafeFileHandle(h, true), FileAccess.Write))
            using (StreamWriter w = new StreamWriter(fs, Console.OutputEncoding))
            {
                w.Write(text + Environment.NewLine);
            }
        }
        catch (Exception) { }
    }

    private static void ShowError(string text, string title)
    {
        try { MessageBox.Show(text, title, MessageBoxButtons.OK, MessageBoxIcon.Error); }
        catch (Exception) { }
    }

    private static string ReadResource(string name)
    {
        Assembly asm = Assembly.GetExecutingAssembly();
        using (Stream s = asm.GetManifestResourceStream(name))
        {
            if (s == null) return null;
            using (StreamReader r = new StreamReader(s, new UTF8Encoding(false)))
            {
                return r.ReadToEnd();
            }
        }
    }

    private static bool HasResource(string name)
    {
        foreach (string n in Assembly.GetExecutingAssembly().GetManifestResourceNames())
        {
            if (string.Equals(n, name, StringComparison.Ordinal)) return true;
        }
        return false;
    }

    // Copie en flux (l'installeur embarqué fait plusieurs dizaines de Mo) ; le BOM UTF-8 du script est conservé
    private static void ExtractResource(string name, string path)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        using (FileStream f = new FileStream(path, FileMode.Create, FileAccess.Write))
        {
            s.CopyTo(f);
        }
    }

    private static string Quote(string arg)
    {
        if (arg.Length > 0 && arg.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return arg;
        return "\"" + arg.Replace("\"", "\\\"") + "\"";
    }

    private static bool HasArg(List<string> args, string name)
    {
        foreach (string a in args)
        {
            if (string.Equals(a, name, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    // Écran de démarrage : PowerShell met quelques secondes à ouvrir la première fenêtre, sans lui on croirait que rien ne se passe (et on relancerait l'exe).
    // Il se ferme tout seul dès que le script écrit son témoin « ready.flag » (première fenêtre prête), ou au bout de 45 s.
    private static void StartSplash(string brand, string flagPath)
    {
        try
        {
            splashStop = false;
            splashThread = new Thread(delegate ()
            {
                try
                {
                    Application.EnableVisualStyles();
                    DateTime t0 = DateTime.UtcNow;
                    Form f = new Form();
                    f.Text = (brand.Length > 0 ? brand + " - " : "") + "Installation";
                    f.FormBorderStyle = FormBorderStyle.FixedDialog;
                    f.ControlBox = false; f.MaximizeBox = false; f.MinimizeBox = false;
                    f.StartPosition = FormStartPosition.CenterScreen; f.TopMost = true;
                    f.ClientSize = new Size(400, 120);
                    f.Font = new Font("Segoe UI", 10f);
                    Label l = new Label();
                    l.Text = "Démarrage de l'installation…" + Environment.NewLine + "Merci de patienter quelques secondes.";
                    l.Location = new Point(16, 16); l.Size = new Size(368, 48);
                    ProgressBar pb = new ProgressBar();
                    pb.Style = ProgressBarStyle.Marquee; pb.MarqueeAnimationSpeed = 30;
                    pb.Location = new Point(16, 76); pb.Size = new Size(368, 18);
                    f.Controls.Add(l); f.Controls.Add(pb);
                    System.Windows.Forms.Timer t = new System.Windows.Forms.Timer();
                    t.Interval = 200;
                    t.Tick += delegate (object sender, EventArgs e)
                    {
                        if (splashStop || File.Exists(flagPath) || (DateTime.UtcNow - t0).TotalSeconds > 45) { t.Stop(); f.Close(); }
                    };
                    t.Start();
                    Application.Run(f);
                }
                catch (Exception) { }
            });
            splashThread.SetApartmentState(ApartmentState.STA);
            splashThread.IsBackground = true;
            splashThread.Start();
        }
        catch (Exception) { }
    }

    private static void StopSplash()
    {
        splashStop = true;
        try { if (splashThread != null) splashThread.Join(1500); } catch (Exception) { }
    }

    // Lance PowerShell sur le script extrait ; renvoie son code de sortie. createNoWindow : pas de console visible (double-clic) ;
    // sinon il hérite du terminal du lanceur, ou en ouvre une nouvelle si le lanceur n'en a pas (repli).
    private static int RunPowerShell(string scriptPath, List<string> scriptArgs, bool createNoWindow)
    {
        StringBuilder cmd = new StringBuilder();
        cmd.Append("-NoProfile -Sta -ExecutionPolicy Bypass -File ").Append(Quote(scriptPath));
        foreach (string a in scriptArgs) cmd.Append(' ').Append(Quote(a));

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        psi.Arguments = cmd.ToString();
        psi.UseShellExecute = false;
        psi.CreateNoWindow = createNoWindow;
        psi.WorkingDirectory = Path.GetTempPath();           // jamais le dossier de la clé USB : un dossier de travail sur la clé la tiendrait occupée

        StringBuilder names = new StringBuilder();
        foreach (string a in scriptArgs) { if (a.StartsWith("-")) names.Append(a).Append(' '); }
        Log("Script extrait. PowerShell : " + psi.FileName + " (présent : " + File.Exists(psi.FileName) + ") | fenêtre cachée : " + createNoWindow + " | options : " + names.ToString().TrimEnd());

        using (Process p = Process.Start(psi))
        {
            Log("PowerShell lancé (processus " + p.Id + ").");
            p.WaitForExit();
            Log("PowerShell terminé, code de sortie " + p.ExitCode + ".");
            return p.ExitCode;
        }
    }

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern uint GetLongPathName(string shortPath, StringBuilder longPath, uint size);

    // Double-clic sur l'exe : ferme TOUT DE SUITE la fenêtre de l'Explorateur de fichiers qui affiche son dossier (la clé USB). Elle encombre l'écran du client et
    // empêche d'éjecter la clé. Seule la fenêtre qui affiche EXACTEMENT ce dossier est fermée, aucune autre. Sans effet si l'exe est lancé d'un terminal.
    // Exécuté sur son propre fil avec un délai maximal : l'Explorateur occupé ne doit jamais retarder l'installation.
    private static void CloseExplorerWindowFor(string dir)
    {
        Thread t = new Thread(delegate ()
        {
            try
            {
                string target = Path.GetFullPath(dir).TrimEnd('\\');
                try { StringBuilder sb = new StringBuilder(1024); if (GetLongPathName(target, sb, 1024) > 0) target = sb.ToString().TrimEnd('\\'); } catch (Exception) { }
                Type shellType = Type.GetTypeFromProgID("Shell.Application");
                if (shellType == null) return;
                object shell = Activator.CreateInstance(shellType);
                object windows = shellType.InvokeMember("Windows", BindingFlags.InvokeMethod, null, shell, null);
                List<long> hits = new List<long>();
                foreach (object w in (System.Collections.IEnumerable)windows)
                {
                    try
                    {
                        Type wt = w.GetType();
                        string full = Convert.ToString(wt.InvokeMember("FullName", BindingFlags.GetProperty, null, w, null));
                        if (full == null || !full.EndsWith("\\explorer.exe", StringComparison.OrdinalIgnoreCase)) continue;
                        string loc = Convert.ToString(wt.InvokeMember("LocationURL", BindingFlags.GetProperty, null, w, null));
                        if (string.IsNullOrEmpty(loc) || !loc.StartsWith("file:", StringComparison.OrdinalIgnoreCase)) continue;
                        string path = Uri.UnescapeDataString(new Uri(loc).LocalPath).TrimEnd('\\');
                        if (string.Equals(path, target, StringComparison.OrdinalIgnoreCase))
                        {
                            hits.Add(Convert.ToInt64(wt.InvokeMember("HWND", BindingFlags.GetProperty, null, w, null)));
                            wt.InvokeMember("Quit", BindingFlags.InvokeMethod, null, w, null);
                        }
                    }
                    catch (Exception) { }
                }
                if (hits.Count > 0)
                {
                    // Quit() ne suffit pas toujours (processus élevé face à un Explorateur normal) : on demande alors la fermeture à la fenêtre elle-même (WM_CLOSE)
                    Thread.Sleep(400);
                    foreach (long h in hits) { IntPtr p = new IntPtr(h); if (IsWindow(p)) PostMessage(p, 0x0010, IntPtr.Zero, IntPtr.Zero); }
                    Log("Fenêtre de l'Explorateur fermée : " + target);
                }
            }
            catch (Exception ex) { Log("Fenêtre de l'Explorateur : " + ex.Message); }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.IsBackground = true;
        t.Start();
        t.Join(4000);
    }

    // Assistant d'éjection (PowerShell caché, lancé par le lanceur juste avant de se terminer). Il attend la fin du lanceur (l'exe est SUR la clé : tant qu'il
    // tourne, la clé est occupée), demande à Windows « Éjecter » sur ce lecteur (le verbe du menu de l'Explorateur), vérifie que le lecteur a bien disparu,
    // note le résultat dans le journal du lanceur ET l'affiche : « clé éjectée, vous pouvez la retirer » (8 s) ou « éjection impossible, faites-le à la main ».
    // Interne et testé : drive = « H: » seulement.
    private static string BuildEjectCommand(string drive, int pid)
    {
        string code = @"
$ErrorActionPreference = 'SilentlyContinue'
$log = '{LOG}'
function Say([string]$t) { try { [IO.File]::AppendAllText($log, ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $t + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false))) } catch { } }
function Show-Notice([string]$text, [bool]$ok, [int]$seconds) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $h = $(if ($ok) { 56 } else { 134 })
        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'Pg20 Info - clé USB'; $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false; $f.TopMost = $true
        $f.ClientSize = New-Object System.Drawing.Size(470, ($h + 72))
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Font = New-Object System.Drawing.Font('Segoe UI', 11); $l.UseMnemonic = $false
        $l.Location = New-Object System.Drawing.Point(16, 14); $l.Size = New-Object System.Drawing.Size(438, $h)
        $l.ForeColor = $(if ($ok) { [System.Drawing.Color]::FromArgb(14, 122, 84) } else { [System.Drawing.Color]::FromArgb(138, 82, 0) })
        $b = New-Object System.Windows.Forms.Button
        $b.Text = 'OK'; $b.Location = New-Object System.Drawing.Point(354, ($h + 26)); $b.Size = New-Object System.Drawing.Size(100, 32)
        $b.Add_Click({ $f.Close() })
        $f.Controls.Add($l); $f.Controls.Add($b); $f.AcceptButton = $b
        if ($seconds -gt 0) { $t = New-Object System.Windows.Forms.Timer; $t.Interval = $seconds * 1000; $t.Add_Tick({ $f.Close() }); $t.Start() }
        [void]$f.ShowDialog()
    } catch { }
}
try { Wait-Process -Id {PID} -Timeout 60 } catch { }
Start-Sleep -Seconds 2
$it = (New-Object -ComObject Shell.Application).NameSpace(17).ParseName('{DRIVE}')
if (-not $it) { Say 'Éjection de {DRIVE} : lecteur introuvable (clé déjà retirée ?).' }
else {
    $v = $null
    foreach ($x in @($it.Verbs())) { if ((($x.Name) -replace '&', '') -match '(?i)^(éjecter|ejecter|eject|auswerfen|expulsar|espelli|uitwerpen)') { $v = $x } }
    if ($v) { $v.DoIt() } else { $it.InvokeVerb('Eject') }
    $gone = $false
    for ($i = 0; $i -lt 24; $i++) { Start-Sleep -Milliseconds 500; if (-not [IO.Directory]::Exists('{DRIVE}\')) { $gone = $true; break } }
    if ($gone) {
        Say 'Éjection de {DRIVE} : réussie (le lecteur a disparu).'
        Show-Notice ('La clé USB ({DRIVE}) a été éjectée.' + [Environment]::NewLine + 'Vous pouvez la retirer maintenant.') $true 8
    }
    else {
        Say 'Éjection de {DRIVE} : ÉCHEC, le lecteur est toujours présent après 12 s (utilisé par un programme ou une fenêtre ?).'
        Show-Notice ('La clé USB ({DRIVE}) n''a pas pu être éjectée automatiquement : un programme ou une fenêtre l''utilise peut-être encore.' + [Environment]::NewLine + [Environment]::NewLine + 'Fermez-les, puis éjectez la clé à la main (clic droit sur le lecteur, « Éjecter »).') $false 0
    }
}
";
        return code.Replace("{LOG}", LogPath.Replace("'", "''")).Replace("{PID}", pid.ToString()).Replace("{DRIVE}", drive);
    }
    // Fiche validée et « Éjecter la clé USB » demandé dans la fenêtre : une fois ce programme terminé (la clé n'est plus occupée), un assistant éjecte la clé.
    // Refusé si le dossier de l'exe n'est pas sur un disque AMOVIBLE : jamais un disque dur.
    private static void StartEjectHelper(string exeDir)
    {
        try
        {
            string root = Path.GetPathRoot(exeDir);
            if (string.IsNullOrEmpty(root) || root.Length < 2 || root[1] != ':') { Log("Éjection ignorée : lecteur inconnu (" + exeDir + ")."); return; }
            DriveInfo di = new DriveInfo(root);
            if (di.DriveType != DriveType.Removable) { Log("Éjection ignorée : " + root + " n'est pas un disque amovible."); return; }
            string drive = root.Substring(0, 2).ToUpperInvariant();
            string enc = Convert.ToBase64String(Encoding.Unicode.GetBytes(BuildEjectCommand(drive, Process.GetCurrentProcess().Id)));
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            psi.Arguments = "-NoProfile -NonInteractive -Sta -ExecutionPolicy Bypass -EncodedCommand " + enc;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);      // jamais le dossier de la clé : il la tiendrait occupée
            Process.Start(psi);
            Log("Éjection de " + drive + " demandée (dès la fin de ce programme).");
        }
        catch (Exception ex) { Log("Éjection impossible : " + ex.Message); }
    }
    [STAThread]
    private static int Main(string[] argv)
    {
        try { hasConsole = AttachConsole(0xFFFFFFFF); }       // ATTACH_PARENT_PROCESS : vrai si lancé depuis un terminal
        catch (Exception) { hasConsole = false; }

        bool isAdmin = false;
        try { isAdmin = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); }
        catch (Exception) { }
        Log("--- Démarrage : " + Assembly.GetExecutingAssembly().Location + " | Windows " + Environment.OSVersion.Version
            + " | administrateur : " + isAdmin + " | utilisateur : " + Environment.UserName + " | terminal : " + hasConsole);
        List<string> userArgs = new List<string>(argv);

        // Options propres au lanceur (non transmises au script)
        bool silent = false;
        bool save = false;
        bool accept = false;
        bool clean = false;
        for (int i = userArgs.Count - 1; i >= 0; i--)
        {
            if (string.Equals(userArgs[i], "/silent", StringComparison.OrdinalIgnoreCase)) { silent = true; userArgs.RemoveAt(i); }
            else if (string.Equals(userArgs[i], "/save", StringComparison.OrdinalIgnoreCase)) { save = true; userArgs.RemoveAt(i); }
            else if (string.Equals(userArgs[i], "/accept", StringComparison.OrdinalIgnoreCase)) { accept = true; userArgs.RemoveAt(i); }
            else if (string.Equals(userArgs[i], "/clean", StringComparison.OrdinalIgnoreCase)) { clean = true; userArgs.RemoveAt(i); }
        }

        // Paramètres figés à la compilation (serveur, clé, nom du client...), un argument par ligne
        List<string> scriptArgs = new List<string>();
        string defaults = ReadResource("defaults.txt");
        if (!string.IsNullOrEmpty(defaults))
        {
            foreach (string line in defaults.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                scriptArgs.Add(line);
            }
        }
        scriptArgs.AddRange(userArgs);

        // Marque figée à la compilation (-BrandName) : titre de l'écran de démarrage
        string brand = "";
        try
        {
            int bi = scriptArgs.IndexOf("-BrandName");
            if (bi >= 0 && bi + 1 < scriptArgs.Count && scriptArgs[bi + 1].Length > 0 && scriptArgs[bi + 1].Length <= 60) brand = scriptArgs[bi + 1];
        }
        catch (Exception) { }

        // Déploiement par script : /accept = le client a accepté les conditions (la preuve note « accepté par paramètre »)
        if (accept && !HasArg(scriptArgs, "-AcceptTerms")) scriptArgs.Add("-AcceptTerms");

        // Réinstallation propre : /clean à la volée, ou -CleanReinstall figé dans l'exe (Pg20-Exe-Compiler -CleanReinstall)
        if (clean && !HasArg(scriptArgs, "-CleanReinstall")) scriptArgs.Add("-CleanReinstall");

        // Mode silencieux : aucune question (nom du client, mot de passe) ni fenêtre
        if (silent && !HasArg(scriptArgs, "-NoPrompt")) scriptArgs.Add("-NoPrompt");

        // Fenêtres système (conditions, progression, résumé) : installation interactive, dans une session ouverte
        bool gui = Environment.UserInteractive && !silent && !HasArg(scriptArgs, "-Uninstall") && !HasArg(scriptArgs, "-NoPrompt") && !HasArg(scriptArgs, "-NoGui");

        // Le mot de passe généré ne doit pas rester sur le PC du client :
        // le CSV n'est écrit que si le lanceur est sur une clé USB (ou avec /save).
        string exeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        bool removable = false;
        try
        {
            DriveInfo drive = new DriveInfo(Path.GetPathRoot(exeDir));
            removable = drive.DriveType == DriveType.Removable;
        }
        catch (Exception) { }

        if (!HasArg(scriptArgs, "-OutDir") && !HasArg(scriptArgs, "-NoSaveCredentials"))
        {
            if (save || removable) { scriptArgs.Add("-OutDir"); scriptArgs.Add(exeDir); }
            else { scriptArgs.Add("-NoSaveCredentials"); }
        }

        // Double-clic : la fenêtre de l'Explorateur de la clé se ferme tout de suite ; et ce programme ne garde pas le dossier de la clé comme dossier de travail
        if (gui) CloseExplorerWindowFor(exeDir);
        try { Environment.CurrentDirectory = Path.GetTempPath(); } catch (Exception) { }

        string workDir = Path.Combine(Path.GetTempPath(), "rd-deploy-" + Guid.NewGuid().ToString("N"));
        int exitCode = 1;
        bool uiErrorShown = false;
        try
        {
            Directory.CreateDirectory(workDir);
            string scriptPath = Path.Combine(workDir, "Pg20-Client-Installation.ps1");
            ExtractResource("Pg20-Client-Installation.ps1", scriptPath);

            // Installeur RustDesk embarqué (build avec -Bundle ou -InstallerFile) : plus de téléchargement chez le client
            if (HasResource("rustdesk-setup.exe") && !HasArg(scriptArgs, "-InstallerPath"))
            {
                string setupPath = Path.Combine(workDir, "rustdesk-setup.exe");
                ExtractResource("rustdesk-setup.exe", setupPath);
                scriptArgs.Add("-InstallerPath");
                scriptArgs.Add(setupPath);
            }

            // Conditions d'installation embarquées (build avec -TermsFile) : le script exige leur acceptation avant toute installation
            if (HasResource("terms.txt") && !HasArg(scriptArgs, "-TermsPath"))
            {
                string termsPath = Path.Combine(workDir, "terms.txt");
                ExtractResource("terms.txt", termsPath);
                scriptArgs.Add("-TermsPath");
                scriptArgs.Add(termsPath);
            }

            // Logo de la marque embarqué (build avec -LogoFile) : affiché dans les fenêtres
            if (HasResource("logo.png") && !HasArg(scriptArgs, "-LogoPath"))
            {
                string logoPath = Path.Combine(workDir, "logo.png");
                ExtractResource("logo.png", logoPath);
                scriptArgs.Add("-LogoPath");
                scriptArgs.Add(logoPath);
            }

            // Tâche de maintenance embarquée (build sans -NoAgent) : désinstallation à distance sur ordre signé du technicien, décrite dans les conditions
            if (HasResource("Pg20-Client-Maintenance.ps1") && !HasArg(scriptArgs, "-AgentPath") && !HasArg(scriptArgs, "-NoAgent"))
            {
                string agentPath = Path.Combine(workDir, "Pg20-Client-Maintenance.ps1");
                ExtractResource("Pg20-Client-Maintenance.ps1", agentPath);
                scriptArgs.Add("-AgentPath");
                scriptArgs.Add(agentPath);
            }

            // Dossier d'où l'exe est lancé (la clé USB) : le script ferme la fenêtre de l'Explorateur qui l'affiche quand l'installation démarre
            if (gui && !HasArg(scriptArgs, "-LaunchDir")) { scriptArgs.Add("-LaunchDir"); scriptArgs.Add(exeDir); scriptArgs.Add("-ExplorerClosed"); }

            if (gui) StartSplash(brand, Path.Combine(workDir, "ready.flag"));

            exitCode = RunPowerShell(scriptPath, scriptArgs, !hasConsole);

            // 30 = le script n'a pu ouvrir aucune fenêtre (affichage graphique indisponible) : on recommence avec une console visible, tout en texte
            if (exitCode == 30 && gui)
            {
                Log("Fenêtres indisponibles : nouvelle tentative avec une console visible (-NoGui).");
                StopSplash();
                List<string> retry = new List<string>(scriptArgs);
                retry.Add("-NoGui");
                exitCode = RunPowerShell(scriptPath, retry, false);
            }
            uiErrorShown = File.Exists(Path.Combine(workDir, "ui-error-shown"));
        }
        catch (Exception ex)
        {
            Log("ERREUR du lanceur : " + ex.GetType().Name + " : " + ex.Message);
            string msg = "Erreur du lanceur : " + ex.Message + Environment.NewLine + "Détails : " + LogPath;
            if (hasConsole) ConsoleWrite(msg); else if (gui) ShowError(msg, "Installation");
            exitCode = 1;
            uiErrorShown = true;
        }
        finally
        {
            StopSplash();
            try { Directory.Delete(workDir, true); } catch (Exception) { }
        }

        // Code 10 = fiche validée par le technicien (le script l'a déjà annoncé) : succès. Code 11 = validée ET « Éjecter la clé USB » demandé dans la fenêtre.
        bool ejectRequested = false;
        if (exitCode == 11) { Log("Fiche validée par le technicien ; éjection de la clé demandée."); exitCode = 0; ejectRequested = true; }
        if (exitCode == 10) { Log("Fiche validée par le technicien."); exitCode = 0; }

        if (exitCode == 20) Log("Conditions refusées : rien n'a été installé.");
        else if (exitCode == 21) ConsoleWrite("Installation refusée : les conditions doivent être acceptées (option /accept pour un déploiement par script).");
        else if (exitCode != 0 && !uiErrorShown)
        {
            // Échec que le script n'a pas pu montrer lui-même (PowerShell absent, script illisible...)
            string msg = "Échec de l'installation (code " + exitCode + "). Détails : " + LogPath;
            if (hasConsole) ConsoleWrite(msg); else if (gui) ShowError(msg, "Installation");
        }
        if (ejectRequested) StartEjectHelper(exeDir);
        return exitCode;
    }
}
