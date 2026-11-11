// App.xaml.cs — C-SAFE (Windows) : démarrage, une seule fenêtre ; mode « capture d'écran » pour les tests GitHub.

using System.IO;
using System.Windows;
using System.Windows.Threading;
using CSafe.Core;

namespace CSafe.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        OffloadJob.Version = Updater.CurrentVersion;
        DispatcherUnhandledException += (_, ex) =>
        {
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "C-SAFE");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "erreurs.txt"), $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {ex.Exception}\n\n");
            }
            catch { }
            MessageBox.Show("Erreur inattendue : " + ex.Exception.Message + "\n\nC-SAFE continue. Détail dans %APPDATA%\\C-SAFE\\erreurs.txt.",
                            "C-SAFE", MessageBoxButton.OK, MessageBoxImage.Warning);
            ex.Handled = true;
        };

        // Test automatique du bouton « Mise à jour » : cherche la dernière version, écrit le résultat et quitte
        var upd = Environment.GetEnvironmentVariable("CSAFE_UPDATECHECK");
        if (!string.IsNullOrEmpty(upd))
        {
            var (found, error) = Updater.Check();
            File.WriteAllText(upd, found != null ? $"OK {found.Version} {found.Build} {found.Url ?? found.LocalPath} (app {Updater.CurrentVersion})" : $"ERREUR {error}");
            Environment.Exit(0);
        }

        var w = new MainWindow();
        MainWindow = w;
        w.Show();

        // Tests automatiques : C-SAFE ouvre une carte et deux disques fictifs, fait une capture puis se ferme
        var shot = Environment.GetEnvironmentVariable("CSAFE_SCREENSHOT");
        var demo = Environment.GetEnvironmentVariable("CSAFE_DEMO");
        if (!string.IsNullOrEmpty(demo))
        {
            var p = demo.Split('|');
            if (p.Length == 3) w.State.Demo(p[0], p[1], p[2]);
        }
        if (!string.IsNullOrEmpty(shot))
        {
            var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
            t.Tick += (_, _) =>
            {
                t.Stop();
                try
                {
                    w.SaveScreenshot(shot);
                    w.SaveScreenshot(Path.ChangeExtension(shot, null) + "-journal.png", true);
                }
                catch (Exception ex) { File.WriteAllText(shot + ".erreur.txt", ex.ToString()); }
                w.State.Save();
                Environment.Exit(0);
            };
            t.Start();
        }
    }
}
