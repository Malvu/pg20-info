// Lanceur autonome : embarque Deploy-RustDesk.ps1, demande les droits administrateur (manifeste),
// extrait le script dans un dossier temporaire, l'exécute puis nettoie. Compatible csc C# 5 (.NET Framework 4).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Text;

[assembly: AssemblyTitle("Déploiement RustDesk")]
[assembly: AssemblyDescription("Installe et configure RustDesk en accès sans surveillance")]
[assembly: AssemblyVersion("1.0.0.0")]

internal static class Program
{
    // Journal du lanceur : %TEMP%\Pg20-Info-Setup.log (jamais de mot de passe : seuls les NOMS des options sont consignés).
    // Si ce fichier n'existe pas après un double-clic, l'exe n'a pas pu démarrer (SmartScreen, antivirus, droits...).
    private static readonly string LogPath = Path.Combine(Path.GetTempPath(), "Pg20-Info-Setup.log");

    private static void Log(string message)
    {
        try
        {
            if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 100000) File.Delete(LogPath);
            File.AppendAllText(LogPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + Environment.NewLine, new UTF8Encoding(false));
        }
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

    private static int Main(string[] argv)
    {
        bool isAdmin = false;
        try { isAdmin = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator); }
        catch (Exception) { }
        Log("--- Démarrage : " + Assembly.GetExecutingAssembly().Location + " | Windows " + Environment.OSVersion.Version
            + " | administrateur : " + isAdmin + " | utilisateur : " + Environment.UserName);
        List<string> userArgs = new List<string>(argv);

        // Options propres au lanceur (non transmises au script)
        bool silent = false;
        bool save = false;
        for (int i = userArgs.Count - 1; i >= 0; i--)
        {
            if (string.Equals(userArgs[i], "/silent", StringComparison.OrdinalIgnoreCase)) { silent = true; userArgs.RemoveAt(i); }
            else if (string.Equals(userArgs[i], "/save", StringComparison.OrdinalIgnoreCase)) { save = true; userArgs.RemoveAt(i); }
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

        // Mode silencieux : aucune question (nom du client, mot de passe) ni pause finale
        if (silent && !HasArg(scriptArgs, "-NoPrompt")) scriptArgs.Add("-NoPrompt");

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

        string workDir = Path.Combine(Path.GetTempPath(), "rd-deploy-" + Guid.NewGuid().ToString("N"));
        int exitCode = 1;
        try
        {
            Directory.CreateDirectory(workDir);
            string scriptPath = Path.Combine(workDir, "Deploy-RustDesk.ps1");
            ExtractResource("Deploy-RustDesk.ps1", scriptPath);

            // Installeur RustDesk embarqué (build avec -Bundle ou -InstallerFile) : plus de téléchargement chez le client
            if (HasResource("rustdesk-setup.exe") && !HasArg(scriptArgs, "-InstallerPath"))
            {
                string setupPath = Path.Combine(workDir, "rustdesk-setup.exe");
                ExtractResource("rustdesk-setup.exe", setupPath);
                scriptArgs.Add("-InstallerPath");
                scriptArgs.Add(setupPath);
            }

            StringBuilder cmd = new StringBuilder();
            cmd.Append("-NoProfile -ExecutionPolicy Bypass -File ").Append(Quote(scriptPath));
            foreach (string a in scriptArgs) cmd.Append(' ').Append(Quote(a));

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            psi.Arguments = cmd.ToString();
            psi.UseShellExecute = false;

            StringBuilder names = new StringBuilder();
            foreach (string a in scriptArgs) { if (a.StartsWith("-")) names.Append(a).Append(' '); }
            Log("Script extrait. PowerShell : " + psi.FileName + " (présent : " + File.Exists(psi.FileName) + ") | options : " + names.ToString().TrimEnd());

            using (Process p = Process.Start(psi))
            {
                Log("PowerShell lancé (processus " + p.Id + ").");
                p.WaitForExit();
                exitCode = p.ExitCode;
                Log("PowerShell terminé, code de sortie " + exitCode + ".");
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Erreur du lanceur : " + ex.Message);
            Log("ERREUR du lanceur : " + ex.GetType().Name + " : " + ex.Message);
            exitCode = 1;
        }
        finally
        {
            try { Directory.Delete(workDir, true); } catch (Exception) { }
        }

        // Code 10 = fiche validée par le technicien (le script l'a déjà annoncé) : la fenêtre se ferme sans attendre une touche
        bool validatedExit = (exitCode == 10);
        if (validatedExit) { Log("Fiche validée par le technicien : fermeture sans pause."); exitCode = 0; }

        if (!silent && !validatedExit)
        {
            Console.WriteLine();
            Console.WriteLine(exitCode == 0 ? "Terminé. Appuyez sur une touche pour fermer cette fenêtre..." : "Échec (code " + exitCode + "). Appuyez sur une touche pour fermer cette fenêtre...");
            try { Console.ReadKey(true); } catch (InvalidOperationException) { }
        }
        return exitCode;
    }
}
