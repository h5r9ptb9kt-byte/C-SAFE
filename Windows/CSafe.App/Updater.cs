// Updater.cs — C-SAFE (Windows)
// Bouton « Mise à jour » : cherche la dernière version pour PC (dossier iCloud Drive › CFocus › App PC C-FOCUS
// si iCloud pour Windows est installé, sinon la page des versions sur GitHub), la télécharge,
// lance l'installateur en silencieux puis C-SAFE se rouvre tout seul.

using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CSafe.App;

public static class Updater
{
    const string Repo = "h5r9ptb9kt-byte/C-SAFE";
    const string AssetName = "C-SAFE-Setup.exe";

    static Version AppVersion => Assembly.GetExecutingAssembly().GetName().Version ?? new Version(1, 0);
    /// « 1.12 » et numéro de fabrication (12)
    public static string CurrentVersion => $"{AppVersion.Major}.{AppVersion.Minor}";
    public static int CurrentBuild => AppVersion.Minor;

    public sealed record Found(string Version, int Build, string? Url, string? LocalPath);

    static string ICloudSetup => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                                              "iCloudDrive", "CFocus", "App PC C-FOCUS", AssetName);

    public static (Found? found, string? error) Check()
    {
        Found? best = null;
        string? error = null;
        // 1. iCloud Drive (iCloud pour Windows)
        try
        {
            if (File.Exists(ICloudSetup))
            {
                var v = FileVersionInfo.GetVersionInfo(ICloudSetup);
                var m = Regex.Match(v.ProductVersion ?? v.FileVersion ?? "", @"^(\d+)\.(\d+)");
                if (m.Success) best = new Found($"{m.Groups[1].Value}.{m.Groups[2].Value}", int.Parse(m.Groups[2].Value), null, ICloudSetup);
            }
        }
        catch { }
        // 2. GitHub : versions « pc-version-N »
        try
        {
            using var http = Http();
            var json = http.GetStringAsync($"https://api.github.com/repos/{Repo}/releases?per_page=40").GetAwaiter().GetResult();
            using var doc = JsonDocument.Parse(json);
            foreach (var r in doc.RootElement.EnumerateArray())
            {
                var tag = r.GetProperty("tag_name").GetString() ?? "";
                var m = Regex.Match(tag, @"^pc-version-(\d+)$");
                if (!m.Success) continue;
                int n = int.Parse(m.Groups[1].Value);
                string? url = null;
                foreach (var a in r.GetProperty("assets").EnumerateArray())
                    if (a.GetProperty("name").GetString() == AssetName) url = a.GetProperty("browser_download_url").GetString();
                if (url != null && (best == null || n > best.Build)) best = new Found($"1.{n}", n, url, null);
            }
        }
        catch (Exception e) { if (best == null) error = "pas de connexion à Internet ni de fichier dans iCloud Drive (" + e.Message + ")."; }
        return (best, best == null ? error : null);
    }

    static HttpClient Http()
    {
        var h = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        h.DefaultRequestHeaders.UserAgent.ParseAdd("C-SAFE-Windows/" + CurrentVersion);
        return h;
    }

    /// Télécharge et lance l'installateur. Retourne null si tout va bien (l'app doit alors se fermer), sinon l'erreur.
    public static string? Install(Found f)
    {
        try
        {
            var tmp = Path.Combine(Path.GetTempPath(), $"C-SAFE-Setup-{f.Build}.exe");
            if (f.LocalPath != null) File.Copy(f.LocalPath, tmp, true);
            else
            {
                using var http = Http();
                using var s = http.GetStreamAsync(f.Url!).GetAwaiter().GetResult();
                using var o = File.Create(tmp);
                s.CopyTo(o);
            }
            Process.Start(new ProcessStartInfo(tmp, "/SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RELAUNCH=1") { UseShellExecute = true });
            return null;
        }
        catch (Exception e) { return e.Message; }
    }
}
