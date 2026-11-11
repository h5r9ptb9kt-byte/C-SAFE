// AppState.cs — C-SAFE (Windows)
// État de l'application : réglages mémorisés, disques, file d'attente des cartes, détection des cartes.
// Même comportement que la version Mac (AppState.swift).

using System.Globalization;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Threading;
using CSafe.Core;

namespace CSafe.App;

public sealed class Destination
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
}

public sealed class CardVolume
{
    public string Path = "";
    public string Name = "";
    public string Detail = "";
    public bool IsCamera;
    public bool Ejectable;
    public string? Kind;
    public string Key = "";
    public PreviousCopy? Previous;
    public bool Analyzing;
}

public sealed class RunningCopy
{
    public string Path = "";
    public string CardName = "";
    public string Label = "";
    public double Progress;
    public string Text = "Analyse de la carte…";
}

public sealed class CopyFailure
{
    public string Title = "", Message = "", Source = "", Label = "", Day = "", Project = "";
    public int? CardNumber;
}

public sealed class Settings
{
    public string Project { get; set; } = "MonProjet";
    public List<string> Sources { get; set; } = Naming.DefaultSources.ToList();
    public List<string> Types { get; set; } = Naming.DefaultTypes.ToList();
    public Dictionary<string, string> CamTypes { get; set; } = new();
    public List<Destination> Destinations { get; set; } = new();
    public bool Eject { get; set; } = true;
    public string HashKind { get; set; } = "xxh64";
    public bool MakePDF { get; set; } = true;
    public Dictionary<string, int> ManualDays { get; set; } = new();
    public List<string> IgnoredVolumes { get; set; } = new();
}

public sealed class AppState
{
    // ---------------- Événements pour la fenêtre ----------------
    public event Action? Changed;
    public event Action? ProgressChanged;
    readonly Dispatcher ui;

    // ---------------- Réglages ----------------
    Settings s;
    static string SettingsDir => System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "C-SAFE");
    static string SettingsPath => System.IO.Path.Combine(SettingsDir, "reglages.json");

    public string Project { get => s.Project; set { if (s.Project != value) { s.Project = value; Save(); Refresh(); } } }
    DateTime shootDate = DateTime.Today;
    public DateTime ShootDate { get => shootDate; set { if (shootDate.Date != value.Date) { shootDate = value.Date; Refresh(); } } }
    public List<string> Sources => s.Sources;
    public List<string> Types => s.Types;
    public List<Destination> Destinations => s.Destinations;
    public bool Eject { get => s.Eject; set { s.Eject = value; Save(); } }
    public HashKind HashKind { get => HashKindInfo.Parse(s.HashKind); set { s.HashKind = value.Raw(); Save(); Notify(); } }
    public bool MakePDF { get => s.MakePDF; set { s.MakePDF = value; Save(); Notify(); } }
    public HashSet<string> IgnoredVolumes => s.IgnoredVolumes.ToHashSet();

    // ---------------- Jour de tournage ----------------
    public int? ShootDay { get; private set; }
    public Dictionary<int, string> UsedDays { get; private set; } = new();
    public bool DayExisting { get; private set; }
    public bool DayManual { get; private set; }
    public List<(int J, string Date)> DayShift { get; private set; } = new();

    // ---------------- État ----------------
    public Dictionary<string, RunningCopy> Running { get; } = new();
    public int MaxParallel { get; private set; } = 1;
    public bool Busy => Running.Count > 0;
    public bool? LastSuccess { get; private set; }
    public double Progress => Running.Count == 0 ? (LastSuccess == true ? 1 : 0) : Running.Values.Average(r => r.Progress);
    public string ProgressText { get; private set; } = "";
    public string Status { get; private set; } = "Prêt";
    public List<(string Time, string Text)> Log { get; } = new();
    public List<string> Done { get; private set; } = new();
    public Dictionary<string, string> DayLabels { get; private set; } = new();
    public Dictionary<string, List<int>> DoneNumbers { get; private set; } = new();
    public List<CardVolume> Cards { get; private set; } = new();
    public Dictionary<string, string> Assignments { get; } = new();
    public Dictionary<string, int> CardNumbers { get; } = new();
    public string? LastReport { get; private set; }
    public bool MakingDayReport { get; private set; }
    public DateTime? DayReportStart { get; private set; }

    // Messages à afficher (la fenêtre les présente un par un)
    public Queue<string> Errors { get; } = new();
    public Queue<OffloadResult> Duplicates { get; } = new();
    public Queue<CopyFailure> Failures { get; } = new();

    readonly Dictionary<string, List<string>> signatureCache = new();
    readonly HashSet<string> pendingSignatures = new();
    readonly List<string> pickedCards = new();
    readonly Dictionary<string, string> copiedWhere = new();
    readonly Dictionary<string, bool?> ssdCache = new();
    readonly HashSet<string> ssdPending = new();

    sealed class QueueItem
    {
        public string Url = "";
        public bool Force;
        public string? Label, Day, Project;
        public int? CardNumber;
    }
    readonly List<QueueItem> queue = new();
    readonly Dictionary<string, (OffloadJob Job, QueueItem Item)> jobs = new();
    readonly Dictionary<string, QueueItem> duplicateItems = new();
    readonly DispatcherTimer timer;

    public AppState(Dispatcher ui)
    {
        this.ui = ui;
        s = LoadSettings();
        s.Sources.RemoveAll(x => x == "CamG" || x == "CamH");
        if (s.Sources.Count == 0) s.Sources = Naming.DefaultSources.ToList();
        if (s.Types.Count == 0) s.Types = Naming.DefaultTypes.ToList();
        AddLog("C-SAFE prêt. Ajoute au moins 2 disques de sauvegarde.");
        Refresh();
        RefreshCards();
        timer = new DispatcherTimer(TimeSpan.FromSeconds(3), DispatcherPriority.Background, (_, _) =>
        {
            if (!Busy) Refresh();
            RefreshCards();
        }, ui);
        timer.Start();
    }

    static Settings LoadSettings()
    {
        try
        {
            if (File.Exists(SettingsPath)) return JsonSerializer.Deserialize<Settings>(File.ReadAllText(SettingsPath)) ?? new Settings();
        }
        catch { }
        return new Settings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(SettingsDir);
            Util.WriteAtomic(SettingsPath, JsonSerializer.Serialize(s, new JsonSerializerOptions { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
        }
        catch { }
    }

    void Notify() => Changed?.Invoke();
    void OnUI(Action a) => ui.BeginInvoke(a);

    // ---------------- Cartes (colonne de gauche) ----------------

    CardVolume CardWithHistory(string path)
    {
        var c = CardInfo(path);
        var key = path + "|" + Volumes.Serial(path);
        c.Key = key;
        if (!signatureCache.ContainsKey(key))
        {
            c.Analyzing = true;
            if (pendingSignatures.Add(key))
            {
                Task.Run(() =>
                {
                    var sigs = OffloadJob.CardSignatures(path);
                    OnUI(() =>
                    {
                        pendingSignatures.Remove(key);
                        signatureCache[key] = sigs;
                        RefreshCards();
                    });
                });
            }
        }
        if (signatureCache.TryGetValue(key, out var sg) && sg.Count > 0)
            c.Previous = OffloadJob.FindPreviousCopy(sg, DestinationPaths());
        return c;
    }

    public static CardVolume CardInfo(string path)
    {
        bool isRoot = Volumes.IsRoot(path);
        var parts = new List<string>();
        var kind = OffloadJob.CameraKind(path);
        if (kind != null) parts.Add(kind);
        if (isRoot && Volumes.Total(path) is long total && Volumes.Free(path) is long free && total > 0)
            parts.Add($"{Util.Human(total - free)} sur {Util.Human(total)}");
        return new CardVolume
        {
            Path = path, Name = Volumes.DisplayName(path), Detail = string.Join(" · ", parts), Kind = kind,
            IsCamera = OffloadJob.LooksLikeCameraCard(path), Ejectable = isRoot && Volumes.IsRemovable(path),
        };
    }

    bool IsCandidate(string root)
    {
        var destRoots = DestinationPaths().Select(Volumes.Root).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return !destRoots.Contains(Volumes.Root(root));
    }

    public void RefreshCards()
    {
        var ignored = IgnoredVolumes;
        var mounted = Volumes.Mounted().Where(v => IsCandidate(v) && !ignored.Contains(Volumes.Id(v)) && OffloadJob.LooksLikeCameraCard(v)).ToList();
        pickedCards.RemoveAll(p => !Directory.Exists(p));
        var extra = pickedCards.Where(p => !mounted.Any(m => string.Equals(m, p, StringComparison.OrdinalIgnoreCase))).ToList();
        var present = mounted.Concat(pickedCards).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var k in signatureCache.Keys.ToList())
            if (!present.Contains(k.Split('|')[0])) signatureCache.Remove(k);
        var list = mounted.Select(CardWithHistory).OrderBy(c => c.IsCamera ? 0 : 1).ThenBy(c => c.Name, StringComparer.CurrentCulture).ToList();
        list.AddRange(extra.Select(CardWithHistory));
        var before = Signature(Cards);
        Cards = list;
        AutoAssign();
        if (Signature(Cards) != before) Notify();
    }

    string Signature(List<CardVolume> cards) =>
        string.Join("\n", cards.Select(c => $"{c.Key}|{c.Name}|{c.Detail}|{c.IsCamera}|{c.Analyzing}|{c.Previous?.Short}|{Assignments.GetValueOrDefault(c.Key)}"));

    /// Attribue une source à chaque nouvelle carte
    void AutoAssign()
    {
        var holding = Cards.Where(c => c.Previous == null || Running.ContainsKey(c.Path)).Select(c => c.Key).ToHashSet();
        foreach (var k in Assignments.Keys.ToList()) if (!holding.Contains(k)) Assignments.Remove(k);
        foreach (var k in CardNumbers.Keys.ToList()) if (!holding.Contains(k)) CardNumbers.Remove(k);
        foreach (var c in Cards.Where(c => !Assignments.ContainsKey(c.Key) && c.Previous == null))
        {
            var taken = Assignments.Values.ToHashSet();
            var free = Sources.Where(x => !Done.Contains(x) && !taken.Contains(x)).ToList();
            if (c.Kind == "Son (WAV)" && free.Contains("SON")) Assignments[c.Key] = "SON";
            else if ((free.FirstOrDefault(IsCamLetter) ?? free.FirstOrDefault(x => !Naming.IsSound(Naming.Label(x))) ?? free.FirstOrDefault()) is string x)
                Assignments[c.Key] = x;
        }
    }

    public string SourceFor(CardVolume c) => Assignments.GetValueOrDefault(c.Key) ?? "—";

    public string TypeFor(string source)
    {
        if (Naming.IsSound(Naming.Label(source))) return "";
        return LockedType(source) ?? s.CamTypes.GetValueOrDefault(source) ?? Types.FirstOrDefault() ?? "";
    }

    /// Modèle imposé à cette lettre parce qu'elle a déjà été copiée ce jour-là (null = libre)
    public string? LockedType(string source)
    {
        var b = Naming.Label(source);
        if (Naming.IsSound(b) || !DayLabels.TryGetValue(b, out var folder)) return null;
        if (Types.FirstOrDefault(t => Naming.Label(source, t) == folder) is string t1) return t1;
        if (s.CamTypes.TryGetValue(source, out var t2) && Naming.Label(source, t2) == folder) return t2;
        return folder == b ? "" : folder[(b.Length + 1)..];
    }

    public string LabelFor(string source) => Naming.Label(source, TypeFor(source));

    public void Assign(string source, CardVolume card)
    {
        Assignments[card.Key] = source;
        CardNumbers.Remove(card.Key);
        AddLog($"« {card.Name} » → {source}");
        Notify();
    }

    /// Change le modèle. Une lettre déjà copiée ce jour-là garde son modèle : la carte reçoit la prochaine lettre libre.
    public void SetType(string t, string source, CardVolume? card = null)
    {
        try
        {
            var locked = LockedType(source);
            if (locked == null || Naming.Label(source, locked) == Naming.Label(source, t)) { s.CamTypes[source] = t; return; }
            if (card == null) { AddLog($"{source} est déjà « {Naming.Label(source, locked)} » aujourd'hui : modèle inchangé."); return; }
            var taken = Assignments.Where(kv => kv.Key != card.Key).Select(kv => kv.Value).ToHashSet();
            var target = Sources.FirstOrDefault(x => IsCamLetter(x) && !Done.Contains(x) && !taken.Contains(x) && LockedType(x) == null);
            if (target != null)
            {
                s.CamTypes[target] = t;
                Assign(target, card);
                AddLog($"{source} est déjà une {locked} aujourd'hui : cette carte devient {Naming.Label(target, t)}.");
            }
            else Errors.Enqueue($"{source} est déjà une {locked} aujourd'hui et il n'y a plus de lettre libre. Ajoute une caméra avec « Autre… ».");
        }
        finally { Save(); Notify(); }
    }

    /// Sources proposées : les lettres de caméra suivent l'ordre A, B, C… sans trou
    public (List<string> Fresh, List<string> DoneToday) SourceChoices(CardVolume card)
    {
        var mine = Assignments.GetValueOrDefault(card.Key);
        var taken = Assignments.Where(kv => kv.Key != card.Key).Select(kv => kv.Value).ToHashSet();
        var nextLetter = Sources.FirstOrDefault(x => IsCamLetter(x) && !Done.Contains(x) && !taken.Contains(x));
        var fresh = Sources.Where(x => !Done.Contains(x) && (!IsCamLetter(x) || x == mine || x == nextLetter)).ToList();
        return (fresh, Sources.Where(Done.Contains).ToList());
    }

    public string NameWithModel(string source)
    {
        var t = TypeFor(source);
        return t.Length == 0 ? source : $"{source} {t}";
    }

    public static bool IsCamLetter(string x) => Regex.IsMatch(Naming.Label(x), "^Cam[A-Z]$");

    public int? CardNumber(CardVolume c) => CardNumbers.TryGetValue(c.Key, out var n) ? n : null;

    public void SetCardNumber(int? n, CardVolume c)
    {
        if (n is int k) { CardNumbers[c.Key] = k; AddLog($"« {c.Name} » → carte n°{k}"); } else CardNumbers.Remove(c.Key);
        Notify();
    }

    public HashSet<int> UsedCardNumbersFor(CardVolume c) =>
        Assignments.TryGetValue(c.Key, out var src) ? Naming.UsedCardNumbers(DestinationPaths(), Project, Day, LabelFor(src)) : new();

    static int? CardNo(string name)
    {
        var m = Regex.Match(name, "_Carte([0-9]+)$");
        return m.Success ? int.Parse(m.Groups[1].Value) : null;
    }

    public int AutoCardNumber(CardVolume c) => CardNo(PreviewFor(c, true)) ?? 1;

    public string NextCardText(string source)
    {
        var plan = Naming.MakePlan(DestinationPaths(), Project, Day, LabelFor(source));
        var n = CardNo(plan.Display.Split('/').Last());
        return n is int k ? $"{NameWithModel(source)} — carte n°{k}" : $"{NameWithModel(source)} — carte suivante";
    }

    /// Dossier qui sera créé pour cette carte (« CamA_FX3_Carte02 », « SON », « HF2 »…)
    public string PreviewFor(CardVolume card, bool ignoringManual = false)
    {
        if (!Assignments.TryGetValue(card.Key, out var src)) return "";
        var label = LabelFor(src);
        if (!ignoringManual && CardNumbers.TryGetValue(card.Key, out var n))
            return Naming.MakePlan(DestinationPaths(), Project, Day, label, n).Display.Split('/').Last();
        var name = Naming.MakePlan(DestinationPaths(), Project, Day, label).Display.Split('/').Last();
        int before = Cards.TakeWhile(c => c.Key != card.Key).Count(c => c.Previous == null && !Running.ContainsKey(c.Path) && Assignments.GetValueOrDefault(c.Key) == src);
        var m = Regex.Match(name, "_Carte([0-9]+)$");
        if (before == 0 || !m.Success) return name;
        return name[..m.Index] + $"_Carte{int.Parse(m.Groups[1].Value) + before:00}";
    }

    /// « Démarrer la copie » : seulement les cartes présentes à ce moment-là. Rien ne part jamais tout seul.
    public void StartCopy()
    {
        if (!CheckReady()) { Notify(); return; }
        foreach (var c in Cards.Where(c => c.Previous != null && !Running.ContainsKey(c.Path)))
        {
            AddLog($"Déjà copiée : « {c.Name} » → {c.Previous!.Short}");
            Duplicates.Enqueue(new OffloadResult { Duplicate = true, Message = c.Previous.Message, Source = c.Path });
        }
        var pending = Cards.Where(c => (c.IsCamera || pickedCards.Contains(c.Path)) && c.Previous == null && !Running.ContainsKey(c.Path)).ToList();
        if (pending.Count == 0) AddLog("Aucune carte à copier : branche ou choisis une carte, nomme-la, puis clique « Démarrer la copie ».");
        else
        {
            AddLog($"Copie démarrée : {pending.Count} carte(s).");
            if (Destinations.Count < 2) AddLog("⚠ Un seul disque de sauvegarde : 2 sont recommandés.");
        }
        foreach (var c in pending) Enqueue(c.Path);
        Save();
        Notify();
    }

    /// Carte choisie à la main (dossier)
    public void PickCard(string picked)
    {
        var url = picked;
        if (OffloadJob.EnclosingCard(picked) is string card)
        {
            url = card;
            AddLog($"« {Naming.Name(picked)} » est un dossier de la carte : C-SAFE copie la carte entière « {Volumes.DisplayName(card)} ».");
        }
        else if (OffloadJob.InsideCardNames.Contains(Naming.Name(picked).ToUpperInvariant()))
        {
            Errors.Enqueue($"« {Naming.Name(picked)} » est un dossier à l'intérieur d'une carte. Choisis la carte elle-même (sa lettre de lecteur dans l'Explorateur), pour que la copie soit complète.");
            Notify();
            return;
        }
        if (!pickedCards.Contains(url, StringComparer.OrdinalIgnoreCase)) pickedCards.Add(url);
        RefreshCards();
        AddLog($"Carte ajoutée : « {Volumes.DisplayName(url)} ». Clique « Démarrer la copie ».");
        Notify();
    }

    public void IgnoreCard(CardVolume c)
    {
        if (!s.IgnoredVolumes.Contains(Volumes.Id(c.Path))) s.IgnoredVolumes.Add(Volumes.Id(c.Path));
        Save();
        pickedCards.RemoveAll(p => p == c.Path);
        Assignments.Remove(c.Key);
        AddLog($"« {c.Name} » retiré des sources (« Réafficher » sous la liste pour le remettre).");
        RefreshCards();
        Notify();
    }

    public void ShowIgnoredVolumes()
    {
        s.IgnoredVolumes.Clear();
        Save();
        AddLog("Disques retirés réaffichés.");
        RefreshCards();
        Notify();
    }

    public void MakeDestination(CardVolume c)
    {
        pickedCards.RemoveAll(p => p == c.Path);
        Assignments.Remove(c.Key);
        AddDestination(c.Path);
        RefreshCards();
    }

    public void EjectCard(CardVolume c)
    {
        EjectVolume(c.Path);
        RefreshCards();
    }

    // ---------------- Valeurs calculées ----------------

    public string DateString => Naming.DayString(ShootDate);
    public string Day => Naming.DayFolder(DateString, ShootDay);
    public bool IsToday => ShootDate.Date == DateTime.Today;

    public void RenumberFollowingDays()
    {
        if (Busy || DayShift.Count == 0) return;
        var result = Naming.RenumberDays(DestinationPaths(), Project, DateString);
        var proj = Naming.Sanitize(Project);
        foreach (var (old, nw) in result.Renamed)
        {
            AddLog($"Jour renuméroté : {old} → {nw}");
            foreach (var kv in copiedWhere.ToList())
                if (kv.Value.StartsWith($"{proj}/{old}/") || kv.Value == $"{proj}/{old}")
                    copiedWhere[kv.Key] = $"{proj}/{nw}" + kv.Value[$"{proj}/{old}".Length..];
        }
        if (result.Errors.Count > 0) Errors.Enqueue("Certains dossiers n'ont pas pu être renommés :\n" + string.Join("\n", result.Errors));
        Refresh();
    }

    // ---------------- Rapports ----------------

    public string? ProjectDirOnFirstDisk =>
        DestinationPaths().FirstOrDefault(Directory.Exists) is string d ? System.IO.Path.Combine(d, Naming.Sanitize(Project)) : null;

    public int DayReportCards => ProjectDirOnFirstDisk is string pd ? PdfReport.SavedCardCount(pd, Day) : 0;
    public int DayReportEstimate => Math.Max(2, DayReportCards);

    public void MakeDayReport()
    {
        if (ProjectDirOnFirstDisk is not string pd || MakingDayReport)
        {
            Errors.Enqueue("Branche un disque de destination pour faire le rapport du jour.");
            Notify();
            return;
        }
        var d = Day;
        MakingDayReport = true;
        DayReportStart = DateTime.Now;
        Notify();
        Task.Run(() =>
        {
            string? url = null;
            try { url = PdfReport.DayReport(pd, d); } catch { }
            OnUI(() =>
            {
                MakingDayReport = false;
                var took = (int)Math.Round((DateTime.Now - (DayReportStart ?? DateTime.Now)).TotalSeconds);
                DayReportStart = null;
                if (url != null)
                {
                    AddLog($"Rapport du jour fait en {took} s.");
                    LastReport = url;
                    AddLog($"Rapport du jour : {System.IO.Path.GetFileName(url)}");
                    OpenReport(url);
                }
                else Errors.Enqueue($"Aucune carte copiée avec rapport pour {d} sur ce disque.");
                Notify();
            });
        });
    }

    public void OpenReport(string path)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception e) { Errors.Enqueue($"Impossible d'ouvrir le PDF : {e.Message}"); Notify(); }
    }

    public void RevealReport(string path)
    {
        try { System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{path}\""); } catch { }
    }

    // ---------------- Jour choisi à la main ----------------

    string ManualDayKey => Naming.Sanitize(Project) + "|" + DateString;
    public int AutoShootDay => Naming.DayPlan(DateString, UsedDays).J;

    public void SetShootDay(int? j)
    {
        if (Busy) return;
        if (j is int k && UsedDays.TryGetValue(k, out var used))
        {
            Errors.Enqueue($"J{k} est déjà utilisé le {Naming.ShortDate(used)}. Choisis un autre numéro.");
            Notify();
            return;
        }
        if (j is int v) s.ManualDays[ManualDayKey] = v; else s.ManualDays.Remove(ManualDayKey);
        Save();
        Refresh();
        AddLog(j is int x ? $"Jour choisi à la main : J{x} pour le {Naming.ShortDate(DateString)}." : "Jour de tournage : numérotation automatique.");
    }

    /// Recalcule les sources déjà faites et le jour de tournage.
    public void Refresh()
    {
        var urls = DestinationPaths();
        foreach (var kv in copiedWhere.ToList())
            if (!urls.Any(u => OffloadJob.CopyStillExists(u, kv.Value)))
            {
                copiedWhere.Remove(kv.Key);
                AddLog($"Copie supprimée détectée ({kv.Value}) : la carte peut être recopiée.");
            }
        UpdateParallel();
        UsedDays = Naming.UsedShootDays(urls, Project);
        int? manual = s.ManualDays.TryGetValue(ManualDayKey, out var m) ? m : null;
        var plan = Naming.DayPlan(DateString, UsedDays, manual);
        ShootDay = plan.J;
        DayExisting = plan.Existing;
        DayManual = !plan.Existing && manual != null && plan.J == manual;
        DayShift = plan.Shifted;
        Done = Naming.DoneSources(urls, Project, Day, Sources);
        DayLabels = Naming.DayLabels(urls, Project, Day);
        DoneNumbers = Done.ToDictionary(x => x, x => Naming.DoneCardNumbers(urls, Project, Day, x));
        Notify();
    }

    // ---------------- Sources et types ----------------

    public void AddSource(string name, CardVolume? card)
    {
        var n = name.Trim();
        if (n.Length == 0) return;
        if (!Sources.Contains(n)) Sources.Add(n);
        if (card != null) Assign(n, card);
        Save();
        Notify();
    }

    public void RemoveSource(string name)
    {
        Sources.Remove(name);
        if (Sources.Count == 0) s.Sources = Naming.DefaultSources.ToList();
        foreach (var kv in Assignments.Where(kv => kv.Value == name).ToList()) Assignments.Remove(kv.Key);
        AutoAssign();
        Save();
        Notify();
    }

    public void AddType(string name, string source, CardVolume? card = null)
    {
        var n = name.Trim();
        if (n.Length == 0) return;
        if (!Types.Contains(n)) Types.Add(n);
        SetType(n, source, card);
    }

    public void RemoveType(string name)
    {
        Types.Remove(name);
        if (Types.Count == 0) s.Types = Naming.DefaultTypes.ToList();
        foreach (var kv in s.CamTypes.Where(kv => kv.Value == name).ToList()) s.CamTypes.Remove(kv.Key);
        Save();
        Notify();
    }

    // ---------------- Disques de sauvegarde ----------------

    public List<string> DestinationPaths() => Destinations.Select(d => d.Path).ToList();
    public bool IsReachable(Destination d) => Directory.Exists(d.Path);

    public string FreeSpace(Destination d) => Volumes.Free(d.Path) is long f ? $"{Util.Human(f)} libres" : "";

    public string ParallelInfo { get; private set; } = "";

    /// Combien de cartes copier en même temps : tous SSD → 2 ; disque dur ou inconnu → 1
    void UpdateParallel()
    {
        var reachable = Destinations.Where(IsReachable).ToList();
        if (reachable.Count == 0) { MaxParallel = 1; ParallelInfo = ""; return; }
        var kinds = new List<(string name, bool? ssd)>();
        foreach (var d in reachable)
        {
            var root = Volumes.Root(d.Path);
            if (!ssdCache.TryGetValue(root, out var v))
            {
                v = null;
                if (ssdPending.Add(root))
                    Task.Run(() => Volumes.IsSSD(root)).ContinueWith(t => OnUI(() => { ssdCache[root] = t.Result; ssdPending.Remove(root); UpdateParallel(); }));
            }
            kinds.Add((d.Name, v));
        }
        var slow = kinds.Where(k => k.ssd != true).Select(k => k.name).ToList();
        int n = slow.Count == 0 ? 2 : 1;
        ParallelInfo = slow.Count == 0 ? "2 cartes en même temps (disques SSD)."
            : $"1 carte à la fois : {string.Join(", ", slow)} " + (slow.Count > 1 ? "sont des disques durs" : "est un disque dur") + " ou non reconnu, c'est le plus rapide.";
        if (n != MaxParallel) { MaxParallel = n; StartNext(); }
    }

    public void AddDestination(string path)
    {
        path = System.IO.Path.GetFullPath(path);
        if (Destinations.Any(d => string.Equals(d.Path, path, StringComparison.OrdinalIgnoreCase))) return;
        var label = Volumes.Label(path);
        var name = Volumes.IsRoot(path) ? label : $"{label} › {Naming.Name(path)}";
        Destinations.Add(new Destination { Name = name, Path = path });
        AddLog($"Disque ajouté : {name}");
        Save();
        Refresh();
        RefreshCards();
    }

    public void RemoveDestination(Destination d)
    {
        Destinations.RemoveAll(x => x.Id == d.Id);
        Save();
        Refresh();
        RefreshCards();
    }

    bool CheckReady()
    {
        if (DayShift.Count > 0)
        {
            Errors.Enqueue($"Le {Naming.ShortDate(DateString)} est avant des jours déjà copiés. Clique « Renuméroter » (ou choisis une autre date) avant de lancer la copie.");
            return false;
        }
        if (Destinations.Count == 0) { Errors.Enqueue("Ajoute au moins un disque de sauvegarde (2 recommandés)."); return false; }
        var missing = Destinations.Where(d => !IsReachable(d)).Select(d => d.Name).ToList();
        if (missing.Count > 0) { Errors.Enqueue($"Disque(s) introuvable(s) : {string.Join(", ", missing)}. Vérifie qu'ils sont branchés."); return false; }
        return true;
    }

    // ---------------- File d'attente des cartes ----------------

    void Enqueue(string url, bool force = false, string? label = null, string? day = null, string? project = null, int? cardNumber = null)
    {
        if (queue.Any(q => q.Url == url)) return;
        queue.Add(new QueueItem { Url = url, Force = force, Label = label, Day = day, Project = project, CardNumber = cardNumber });
        if (Busy) AddLog($"En file d'attente : {Volumes.DisplayName(url)}");
        StartNext();
    }

    /// Lance les copies en attente, jusqu'à MaxParallel en même temps (jamais deux copies de la même source).
    void StartNext()
    {
        if (queue.Count == 0 || Running.Count >= MaxParallel) return;
        if (!CheckReady()) { queue.Clear(); Notify(); return; }
        int i = 0;
        while (Running.Count < MaxParallel && i < queue.Count)
        {
            var item = queue[i];
            var label = item.Label ?? LabelForQueued(item.Url);
            if (label == null)
            {
                AddLog($"« {Volumes.DisplayName(item.Url)} » : aucune source attribuée, copie ignorée.");
                queue.RemoveAt(i);
                continue;
            }
            if (Running.Values.Any(r => r.Label == label)) { i++; continue; }
            queue.RemoveAt(i);
            bool auto = item.Label == null;
            item.Label = label;
            if (item.CardNumber == null && auto && Cards.FirstOrDefault(c => c.Path == item.Url) is { } card && CardNumbers.TryGetValue(card.Key, out var n))
                item.CardNumber = n;
            item.Day ??= Day;
            item.Project ??= Project;
            Launch(item);
        }
    }

    string? LabelForQueued(string url) =>
        Cards.FirstOrDefault(c => c.Path == url) is { } card && Assignments.TryGetValue(card.Key, out var src) ? LabelFor(src) : null;

    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 0x00000001;

    void Launch(QueueItem item)
    {
        var path = item.Url;
        var label = item.Label ?? "CamA";
        if (Running.Count == 0) ui.Invoke(() => SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED));
        LastSuccess = null;
        Running[path] = new RunningCopy { Path = path, CardName = CardName(path), Label = label };
        Status = Running.Count > 1 ? $"{Running.Count} copies en cours" : "Copie en cours";
        var job = new OffloadJob(path, DestinationPaths(), item.Project ?? Project, label, item.Day ?? Day, item.Force, item.CardNumber,
            ev => OnUI(() => Handle(ev, path)))
        { HashKind = HashKind, MakePDF = MakePDF };
        jobs[path] = (job, item);
        var th = new Thread(job.Run) { IsBackground = true, Name = "Copie " + label, Priority = ThreadPriority.AboveNormal };
        th.Start();
        Notify();
    }

    string CardName(string url) => Cards.FirstOrDefault(c => c.Path == url)?.Name ?? Volumes.DisplayName(url);

    public void CancelCopy()
    {
        if (!Busy) return;
        foreach (var j in jobs.Values) j.Job.Cancel.Set();
        AddLog("Annulation demandée…");
    }

    public void CancelCopy(CardVolume c)
    {
        if (!jobs.TryGetValue(c.Path, out var j)) return;
        j.Job.Cancel.Set();
        AddLog($"Annulation demandée : « {c.Name} »");
    }

    public RunningCopy? RunningCopyFor(CardVolume c) => Running.GetValueOrDefault(c.Path);

    /// « Copier quand même » une carte déjà copiée : nouvelle copie, sous un nouveau numéro
    public void ConfirmDuplicate(OffloadResult r)
    {
        duplicateItems.Remove(r.Source, out var saved);
        var label = saved?.Label;
        if (label == null && Cards.FirstOrDefault(c => c.Path == r.Source) is { } card)
        {
            if (!Assignments.ContainsKey(card.Key))
            {
                var taken = Assignments.Values.ToHashSet();
                Assignments[card.Key] = Sources.FirstOrDefault(x => !Done.Contains(x) && !taken.Contains(x)) ?? Sources.First();
            }
            label = LabelFor(Assignments[card.Key]);
        }
        Enqueue(r.Source, true, label, saved?.Day, saved?.Project, saved?.CardNumber);
        Notify();
    }

    /// « Recommencer » : même carte, même source, même jour, même projet.
    public void Retry(CopyFailure f)
    {
        if (!Directory.Exists(f.Source))
        {
            Failures.Enqueue(new CopyFailure
            {
                Title = "Carte introuvable", Message = $"La carte « {Volumes.DisplayName(f.Source)} » n'est plus branchée. Rebranche-la, puis clique « Recommencer ».",
                Source = f.Source, Label = f.Label, Day = f.Day, Project = f.Project, CardNumber = f.CardNumber,
            });
            Notify();
            return;
        }
        AddLog($"Nouvelle tentative : {Volumes.DisplayName(f.Source)}");
        Enqueue(f.Source, true, f.Label, f.Day, f.Project, f.CardNumber);
        Notify();
    }

    void Handle(OffloadEvent ev, string path)
    {
        switch (ev)
        {
            case OffloadEvent.Log l:
                var who = Running.GetValueOrDefault(path)?.Label ?? "";
                AddLog(Running.Count > 1 && who.Length > 0 ? $"[{who}] {l.Text}" : l.Text);
                break;
            case OffloadEvent.Started st:
                if (Running.TryGetValue(path, out var r0)) r0.Text = "Copie de " + st.Name;
                ProgressChanged?.Invoke();
                break;
            case OffloadEvent.Progress p:
                if (Running.TryGetValue(path, out var r))
                {
                    double frac = (double)p.Done / p.Total;
                    double remaining = p.BytesPerSecond > 0 ? (p.Total - p.Done) / p.BytesPerSecond : 0;
                    r.Progress = frac;
                    r.Text = p.Phase.StartsWith("Rapport")
                        ? $"Rapport PDF · clip {p.Done}/{p.Total}" + (p.Done > 0 && p.BytesPerSecond > 0 ? $" · reste ≈ {Util.Duration(remaining)}" : " · vignettes en cours")
                        : $"{p.Phase} · {(int)(frac * 100)} % · {Util.Human((long)p.BytesPerSecond)}/s · reste {Util.Duration(remaining)}";
                }
                ProgressChanged?.Invoke();
                break;
            case OffloadEvent.Finished f:
                Finish(f.Result, path);
                break;
        }
    }

    void Finish(OffloadResult r, string path)
    {
        Running.Remove(path);
        jobs.Remove(path, out var entry);
        var item = entry.Item;
        if (Running.Count > 0) Status = $"{Running.Count} copie(s) en cours";
        if (r.Ok) copiedWhere[r.Source] = $"{Naming.Sanitize(item?.Project ?? Project)}/{r.Display}";
        if (Running.Count == 0) SetThreadExecutionState(ES_CONTINUOUS);

        if (r.Duplicate)
        {
            if (item != null) duplicateItems[r.Source] = item;
            AddLog(r.Message);
            Status = "Carte déjà déchargée";
            Duplicates.Enqueue(r);
        }
        else if (r.Ok)
        {
            AddLog("✓ " + r.Message);
            if (r.ReportPDF != null) { LastReport = r.ReportPDF; AddLog($"Rapport PDF : {System.IO.Path.GetFileName(r.ReportPDF)}"); }
            if (Running.Count == 0) Status = $"Terminé — {r.Name}";
            ProgressText = $"{r.Name} : copié et vérifié sur tous les disques";
            LastSuccess = true;
            SystemSounds.Asterisk.Play();
            if (Eject) EjectVolume(r.Source);
        }
        else
        {
            AddLog("✗ " + r.Message);
            Status = r.Message;
            LastSuccess = false;
            SystemSounds.Hand.Play();
            var card = Volumes.DisplayName(r.Source);
            string title, explanation;
            if (r.Cancelled)
            {
                title = "Copie arrêtée";
                explanation = $"La copie de « {card} » a été arrêtée avant la fin. Les fichiers déjà copiés sont rangés dans un dossier « _INCOMPLET ».";
            }
            else if (r.VerifyFailed)
            {
                title = "Copie incomplète";
                explanation = "La vérification a trouvé des fichiers manquants ou différents sur au moins un disque (détail dans le journal et dans Rapports_de_copie).";
            }
            else
            {
                title = "La copie a échoué";
                var m = r.Message.Replace("Erreur : ", "");
                explanation = (m.Length > 0 ? char.ToUpper(m[0]) + m[1..] : m) + "\nVérifie que la carte et les disques sont bien branchés.";
            }
            Failures.Enqueue(new CopyFailure
            {
                Title = title, Message = explanation + "\n\nNe formate pas la carte. « Recommencer » relance la même copie (même numéro de carte).",
                Source = r.Source, Label = item?.Label ?? "CamA", Day = item?.Day ?? Day, Project = item?.Project ?? Project, CardNumber = item?.CardNumber,
            });
        }
        if (Running.Count == 0) Refresh();
        RefreshCards();
        StartNext();
        Notify();
    }

    // ---------------- Éjection (Windows : « Éjecter » de l'Explorateur) ----------------

    void EjectVolume(string path)
    {
        if (!Volumes.IsRoot(path) || !Volumes.IsRemovable(path)) return;
        var letter = Volumes.Root(path).TrimEnd('\\');
        var th = new Thread(() =>
        {
            bool ok = false;
            try
            {
                var t = Type.GetTypeFromProgID("Shell.Application");
                if (t != null)
                {
                    dynamic shell = Activator.CreateInstance(t)!;
                    dynamic item = shell.NameSpace(17).ParseName(letter);
                    item.InvokeVerb("Eject");
                    for (int i = 0; i < 10 && !ok; i++) { Thread.Sleep(500); ok = !Directory.Exists(path); }
                }
            }
            catch { }
            OnUI(() =>
            {
                AddLog(ok ? "Carte éjectée : tu peux la retirer." : "Impossible d'éjecter la carte (elle est peut-être utilisée).");
                RefreshCards();
            });
        });
        th.SetApartmentState(ApartmentState.STA);
        th.IsBackground = true;
        th.Start();
    }

    // ---------------- Journal ----------------

    public void AddLog(string text)
    {
        Log.Add((DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture), text));
        if (Log.Count > 300) Log.RemoveRange(0, Log.Count - 300);
        Notify();
    }

    /// Démonstration (capture d'écran automatique) : une carte et deux disques fictifs
    public void Demo(string card, string d1, string d2)
    {
        AddDestination(d1);
        AddDestination(d2);
        PickCard(card);
    }
}
