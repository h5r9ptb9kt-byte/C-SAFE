// Naming.cs — C-SAFE (Windows)
// Règles de nommage et de rangement des cartes : identiques à la version Mac (Naming.swift),
// pour que les mêmes disques passent d'un Mac à un PC sans rien changer.
//
//  <Disque>/<Projet>/J1_<AAAA-MM-JJ>/CamA_FX3/CamA_FX3_Carte01/   (caméras)
//  <Disque>/<Projet>/J1_<AAAA-MM-JJ>/SON/                          (enregistreur, copié directement)
//  <Disque>/<Projet>/J1_<AAAA-MM-JJ>/SON/HF1, HF3…                 (HF, numéro choisi)

using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace CSafe.Core;

public static class Naming
{
    public static readonly string[] DefaultTypes = { "FX2", "FX3", "FX5", "Osmo 4P", "360", "Drone", "GoPro" };
    public static readonly string[] DefaultSources = { "CamA", "CamB", "CamC", "CamD", "CamE", "CamF", "SON", "HF1", "HF2", "HF3", "HF4" };
    public const string ReportDir = "Rapports_de_copie";
    public const string HistoryFile = "historique_cartes.json";
    /// Sous-dossier masqué de Rapports_de_copie : fichiers techniques
    public const string HiddenDir = ".C-SAFE";

    // ---------- Chemins : toujours « / » dans les noms relatifs (comme sur Mac) ----------

    public static string Combine(string a, string rel)
    {
        var parts = rel.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var p = a;
        foreach (var x in parts) p = Path.Combine(p, x);
        return p;
    }

    public static string Name(string path) => Path.GetFileName(path.TrimEnd('\\', '/'));

    // ---------- Noms sûrs ----------

    static readonly Dictionary<char, string> Special = new()
    {
        ['æ'] = "ae", ['Æ'] = "AE", ['œ'] = "oe", ['Œ'] = "OE", ['ß'] = "ss", ['ø'] = "o", ['Ø'] = "O",
        ['đ'] = "d", ['Đ'] = "D", ['ł'] = "l", ['Ł'] = "L", ['þ'] = "th", ['Þ'] = "Th", ['ð'] = "d", ['Ð'] = "D",
    };

    /// Lettres sans accent, chiffres, « - » et « _ » uniquement (Premiere, Resolve, Avid, exFAT, NAS…)
    public static string Sanitize(string input, string fallback = "Projet")
    {
        var s = (input ?? "").Trim();
        var sb = new StringBuilder();
        foreach (var ch in s) sb.Append(Special.TryGetValue(ch, out var r) ? r : ch.ToString());
        var decomposed = sb.ToString().Normalize(NormalizationForm.FormKD);
        var outp = new StringBuilder();
        foreach (var ch in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) == UnicodeCategory.NonSpacingMark) continue;
            bool ok = (ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_' || ch == '-';
            outp.Append(ok ? ch : '-');
        }
        var o = outp.ToString();
        while (o.Contains("--")) o = o.Replace("--", "-");
        o = o.Trim('-', '_', '.');
        if (o.Length > 60) o = o[..60];
        return o.Length == 0 ? fallback : o;
    }

    public static bool IsHF(string s) => Regex.IsMatch(s ?? "", "^HF[0-9]+$", RegexOptions.IgnoreCase);
    public static bool IsSound(string label) => label == "SON" || IsHF(label);

    /// CamA + FX3 → CamA_FX3 · SON → SON · HF3 → HF3 · Drone + Mavic 3 → Drone_Mavic-3
    public static string Label(string source, string type = "")
    {
        var raw = Sanitize(source, "CamA");
        var up = raw.ToUpperInvariant();
        if (up == "SON" || IsHF(up)) return up;
        if (up == "HF") return "HF1";
        var b = raw;
        if (Regex.IsMatch(raw, "^(?:[Cc][Aa][Mm][-_]?)?[A-Za-z]$"))
            b = "Cam" + char.ToUpperInvariant(raw[^1]);
        var trimmed = (type ?? "").Trim();
        var t = trimmed.Length == 0 ? "" : Sanitize(trimmed, "");
        return t.Length == 0 ? b : b + "_" + t;
    }

    // ---------- Dates ----------

    public static string DayString(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    public static string DayFolder(string date, int? shootDay) => shootDay is int j ? $"J{j}_{date}" : date;

    static readonly Regex DayRe = new(@"^J([0-9]+)_([0-9]{4}-[0-9]{2}-[0-9]{2})$");

    /// Jours de tournage déjà utilisés dans le projet : J → date
    public static Dictionary<int, string> UsedShootDays(IEnumerable<string> destinations, string project)
    {
        var o = new Dictionary<int, string>();
        foreach (var d in destinations)
            foreach (var name in List(Path.Combine(d, Sanitize(project))))
            {
                var m = DayRe.Match(name);
                if (m.Success && int.TryParse(m.Groups[1].Value, out var j)) o[j] = m.Groups[2].Value;
            }
        return o;
    }

    public record DayPlanResult(int J, bool Existing, List<(int J, string Date)> Shifted);

    /// J1, J2… suivent l'ordre des dates. `manual` : numéro choisi à la main (projet rejoint en cours de route).
    public static DayPlanResult DayPlan(string date, Dictionary<int, string> used, int? manual = null)
    {
        foreach (var kv in used) if (kv.Value == date) return new(kv.Key, true, new());
        if (manual is int m && m > 0 && !used.ContainsKey(m)) return new(m, false, new());
        var before = used.Where(kv => string.CompareOrdinal(kv.Value, date) < 0).Select(kv => kv.Key).ToList();
        var after = used.Where(kv => string.CompareOrdinal(kv.Value, date) > 0).OrderBy(kv => kv.Key)
            .Select(kv => (kv.Key, kv.Value)).ToList();
        return new((before.Count == 0 ? 0 : before.Max()) + 1, false, after);
    }

    /// Renumérote (J+1) les jours plus récents que `date`, sur chaque disque, et met à jour l'historique.
    public static (List<(string Old, string New)> Renamed, List<string> Errors) RenumberDays(IEnumerable<string> destinations, string project, string date)
    {
        var renamed = new List<(string, string)>();
        var errors = new List<string>();
        foreach (var d in destinations)
        {
            var pd = Path.Combine(d, Sanitize(project));
            var items = new List<(int j, string date, string name)>();
            foreach (var name in List(pd))
            {
                var m = DayRe.Match(name);
                if (m.Success && int.TryParse(m.Groups[1].Value, out var j)) items.Add((j, m.Groups[2].Value, name));
            }
            var toShift = items.Where(i => string.CompareOrdinal(i.date, date) > 0).OrderByDescending(i => i.j).ToList();
            if (toShift.Count == 0) continue;
            var hist = History.Load(pd);
            foreach (var it in toShift)
            {
                var newName = $"J{it.j + 1}_{it.date}";
                try
                {
                    Directory.Move(Path.Combine(pd, it.name), Path.Combine(pd, newName));
                    if (!renamed.Any(r => r.Item1 == it.name)) renamed.Add((it.name, newName));
                    foreach (var key in hist.Keys.ToList())
                    {
                        var e = hist[key];
                        if (e.TryGetValue("dossier", out var dossier) && (dossier == it.name || dossier.StartsWith(it.name + "/")))
                        {
                            var ne = new Dictionary<string, string>(e) { ["dossier"] = newName + dossier[it.name.Length..] };
                            hist[key] = ne;
                        }
                    }
                }
                catch (Exception ex) { errors.Add($"{Name(d)}/{it.name} : {ex.Message}"); }
            }
            History.Save(pd, hist);
        }
        return (renamed, errors);
    }

    /// « 2026-10-17 » → « 17/10 »
    public static string ShortDate(string iso)
    {
        var p = iso.Split('-');
        return p.Length == 3 ? $"{p[2]}/{p[1]}" : iso;
    }

    // ---------- Lecture des dossiers ----------

    public static List<string> List(string path)
    {
        try
        {
            if (!Directory.Exists(path)) return new();
            return Directory.EnumerateFileSystemEntries(path).Select(Name).ToList();
        }
        catch { return new(); }
    }

    public static bool IsDir(string path) { try { return Directory.Exists(path); } catch { return false; } }
    public static bool Exists(string path) => File.Exists(path) || Directory.Exists(path);

    public static string? FirstCapture(string pattern, string s)
    {
        var m = Regex.Match(s, pattern, RegexOptions.IgnoreCase);
        return m.Success && m.Groups.Count > 1 && m.Groups[1].Success ? m.Groups[1].Value : null;
    }

    public static int NextNumber(IEnumerable<string> dirs, string pattern)
    {
        int best = 0;
        foreach (var d in dirs)
            foreach (var name in List(d))
            {
                if (name.Contains("_INCOMPLET")) continue;
                if (FirstCapture(pattern, name) is string c && int.TryParse(c, out var n)) best = Math.Max(best, n);
            }
        return best + 1;
    }

    const string HfFolderPattern = "^HF[0-9]+(_Carte[0-9]+)?$";

    /// La carte de l'enregistreur a-t-elle déjà été copiée dans SON/ ?
    public static bool SonOccupied(string son) =>
        List(son).Any(name => !Regex.IsMatch(name, HfFolderPattern, RegexOptions.IgnoreCase)
                              && !name.StartsWith(".") && !name.StartsWith("_INCOMPLET") && !name.StartsWith("SON_Carte"));

    // ---------- Où va la carte ? ----------

    public record Plan(List<string> Targets, string Display, bool Merge);

    static string Card(string label, int n) => $"{label}_Carte{n:00}";

    /// `cardNumber` : numéro choisi à la main ; null = automatique (suivant)
    public static Plan MakePlan(IList<string> destinations, string project, string day, string label, int? cardNumber = null)
    {
        var proj = Sanitize(project);
        var dayDirs = destinations.Select(d => Path.Combine(d, proj, day)).ToList();

        if (cardNumber is int n && n >= 1)
        {
            if (IsHF(label) || label == "SON")
            {
                var sonDirs = dayDirs.Select(x => Path.Combine(x, "SON")).ToList();
                if (n == 1)
                {
                    if (label == "SON") return new(sonDirs, $"{day}/SON", true);
                    return new(sonDirs.Select(x => Path.Combine(x, label)).ToList(), $"{day}/SON/{label}", false);
                }
                var nm = Card(label, n);
                return new(sonDirs.Select(x => Path.Combine(x, nm)).ToList(), $"{day}/SON/{nm}", false);
            }
            var name = Card(label, n);
            return new(dayDirs.Select(x => Path.Combine(x, label, name)).ToList(), $"{day}/{label}/{name}", false);
        }

        if (IsHF(label))
        {
            var sonDirs = dayDirs.Select(x => Path.Combine(x, "SON")).ToList();
            var name = label;
            if (sonDirs.Any(s => Exists(Path.Combine(s, label))))
            {
                var k = Math.Max(2, NextNumber(sonDirs, $"^{Regex.Escape(label)}_Carte([0-9]+)$"));
                name = Card(label, k);
            }
            return new(sonDirs.Select(x => Path.Combine(x, name)).ToList(), $"{day}/SON/{name}", false);
        }

        if (label == "SON")
        {
            var sonDirs = dayDirs.Select(x => Path.Combine(x, "SON")).ToList();
            if (sonDirs.Any(SonOccupied))
            {
                var k = Math.Max(2, NextNumber(sonDirs, "^SON_Carte([0-9]+)$"));
                var name = $"SON_Carte{k:00}";
                return new(sonDirs.Select(x => Path.Combine(x, name)).ToList(), $"{day}/SON/{name}", false);
            }
            return new(sonDirs, $"{day}/SON", true);
        }

        var camDirs = dayDirs.Select(x => Path.Combine(x, label)).ToList();
        var num = NextNumber(camDirs, $"^{Regex.Escape(label)}_Carte([0-9]+)$");
        var cname = Card(label, num);
        return new(camDirs.Select(x => Path.Combine(x, cname)).ToList(), $"{day}/{label}/{cname}", false);
    }

    /// Numéros de carte déjà copiés pour une source ce jour-là
    public static HashSet<int> UsedCardNumbers(IEnumerable<string> destinations, string project, string day, string label)
    {
        var esc = Regex.Escape(label);
        var used = new HashSet<int>();
        foreach (var dest in destinations)
        {
            var d = Path.Combine(dest, Sanitize(project), day);
            if (label == "SON" || IsHF(label))
            {
                var son = Path.Combine(d, "SON");
                if (label == "SON" ? SonOccupied(son) : IsDir(Path.Combine(son, label))) used.Add(1);
                foreach (var name in List(son))
                    if (!name.Contains("_INCOMPLET") && FirstCapture($"^{esc}_Carte([0-9]+)$", name) is string c && int.TryParse(c, out var n)) used.Add(n);
            }
            else
            {
                foreach (var name in List(Path.Combine(d, label)))
                    if (!name.Contains("_INCOMPLET") && FirstCapture($"^{esc}_Carte([0-9]+)$", name) is string c && int.TryParse(c, out var n)) used.Add(n);
            }
        }
        return used;
    }

    /// Numéros des cartes déjà copiées pour une source ce jour-là, quel que soit le modèle
    public static List<int> DoneCardNumbers(IEnumerable<string> destinations, string project, string day, string source)
    {
        var b = Label(source);
        var esc = Regex.Escape(b);
        var nums = new HashSet<int>();
        foreach (var dest in destinations)
        {
            var dayDir = Path.Combine(dest, Sanitize(project), day);
            if (IsSound(b))
            {
                var son = Path.Combine(dayDir, "SON");
                if (b == "SON" ? SonOccupied(son) : IsDir(Path.Combine(son, b))) nums.Add(1);
                foreach (var name in List(son))
                    if (!name.Contains("_INCOMPLET") && FirstCapture($"^{esc}_Carte([0-9]+)$", name) is string c && int.TryParse(c, out var n)) nums.Add(n);
            }
            else
            {
                foreach (var camDir in List(dayDir).Where(x => x == b || x.StartsWith(b + "_")))
                    foreach (var name in List(Path.Combine(dayDir, camDir)))
                        if (!name.Contains("_INCOMPLET") && FirstCapture("_Carte([0-9]+)$", name) is string c && int.TryParse(c, out var n)) nums.Add(n);
            }
        }
        return nums.OrderBy(x => x).ToList();
    }

    // ---------- Une lettre de caméra = un seul modèle par jour ----------

    public static Dictionary<string, string> DayLabels(IEnumerable<string> destinations, string project, string day)
    {
        var o = new Dictionary<string, string>();
        foreach (var dest in destinations)
        {
            var dayDir = Path.Combine(dest, Sanitize(project), day);
            foreach (var e in List(dayDir).OrderBy(x => x, StringComparer.Ordinal))
            {
                if (e.StartsWith(".") || e.StartsWith("_") || e == "SON") continue;
                var p = Path.Combine(dayDir, e);
                if (!IsDir(p) || !List(p).Any(x => !x.Contains("_INCOMPLET") && !x.StartsWith("."))) continue;
                var b = e.Split('_', 2)[0];
                if (!o.ContainsKey(b)) o[b] = e;
            }
        }
        return o;
    }

    /// « CamA_FX3 » alors que « CamA_FX2 » existe déjà ce jour-là → « CamA_FX2 »
    public static string? ConflictingLabel(IEnumerable<string> destinations, string project, string day, string label)
    {
        if (IsSound(label)) return null;
        var b = label.Split('_', 2)[0];
        return DayLabels(destinations, project, day).TryGetValue(b, out var existing) && existing != label ? existing : null;
    }

    // ---------- Sources déjà déchargées ce jour-là ----------

    public static List<string> DoneSources(IEnumerable<string> destinations, string project, string day, IEnumerable<string> sources)
    {
        var names = new HashSet<string>();
        foreach (var dest in destinations)
        {
            var dayDir = Path.Combine(dest, Sanitize(project), day);
            foreach (var e in List(dayDir))
            {
                if (e.StartsWith(".") || e.StartsWith("_")) continue;
                var p = Path.Combine(dayDir, e);
                if (!IsDir(p)) continue;
                if (e == "SON")
                {
                    if (SonOccupied(p)) names.Add("SON");
                    foreach (var x in List(p))
                        if (!x.Contains("_INCOMPLET") && FirstCapture("^(HF[0-9]+)", x) is string hf) names.Add(hf.ToUpperInvariant());
                }
                else if (List(p).Any(x => !x.Contains("_INCOMPLET") && !x.StartsWith("."))) names.Add(e);
            }
        }
        return sources.Where(s =>
        {
            var lab = Label(s);
            if (IsSound(lab)) return names.Contains(lab);
            return names.Any(n => n == lab || n.StartsWith(lab + "_"));
        }).ToList();
    }
}
