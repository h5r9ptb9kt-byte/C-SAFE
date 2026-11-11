// OffloadJob.cs — C-SAFE (Windows)
// Copie une carte vers plusieurs disques EN MÊME TEMPS (une seule lecture), vérifie chaque copie
// (xxHash64 ou MD5, relecture sans cache), écrit MHL + rapports, gère doublons et échecs.
// Même logique et mêmes fichiers que la version Mac (OffloadEngine.swift).

using System.Diagnostics;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CSafe.Core;

public record CardFile(string Path, string Rel, long Size, long Mtime);

public class OffloadResult
{
    public bool Ok;
    public bool Duplicate;
    public string Display = "";
    public bool Cancelled;
    public bool VerifyFailed;
    public string Message = "";
    public string Name = "";
    public string Source = "";
    public string? ReportPDF;
}

public abstract record OffloadEvent
{
    public sealed record Log(string Text) : OffloadEvent;
    public sealed record Started(string Name) : OffloadEvent;
    public sealed record Progress(string Phase, long Done, long Total, double BytesPerSecond) : OffloadEvent;
    public sealed record Finished(OffloadResult Result) : OffloadEvent;
}

public sealed class CancelFlag
{
    volatile bool v;
    public void Set() => v = true;
    public bool IsSet => v;
}

public sealed class PreviousCopy
{
    public string Path = "";      // « test / J1_2026-10-18 / CamA_FX3 / CamA_FX3_Carte01 »
    public List<string> Disks = new();
    public string When = "";      // « le 18/10 à 11:31 »
    public string Size = "";
    public string Message
    {
        get
        {
            var on = Disks.Count == 1 ? $"sur le disque {Disks[0]}" : $"sur les disques {string.Join(" et ", Disks)}";
            return $"Cette carte{(Size.Length == 0 ? "" : $" ({Size})")} a déjà été copiée{(When.Length == 0 ? "" : " " + When)} dans {Path}, {on}.";
        }
    }
    public string Short => $"{Path} · {string.Join(", ", Disks)}";
}

public sealed class OffloadJob
{
    public const int ChunkSize = 16 * 1024 * 1024;
    /// Au-delà de cette taille, un volume est un disque, pas une carte (les plus grosses cartes font 4 To)
    public const long MaxCardBytes = 4_100_000_000_000;

    public static readonly HashSet<string> CardMarkers = new() { "DCIM", "PRIVATE", "M4ROOT", "XDROOT", "CONTENTS", "AVCHD", "BPAV", "CANONMSC" };
    public static readonly HashSet<string> DeepExtensions = new() { "wav", "bwf", "r3d", "braw", "ari", "arx", "mxf" };
    public static readonly HashSet<string> CameraExtensions = new()
    {
        "mov", "mp4", "mxf", "r3d", "braw", "crm", "ari", "arx", "mts", "m2ts",
        "insv", "insp", "lrv", "dng", "wav", "avi", "cr3", "cr2", "arw", "nef", "360",
    };
    public static readonly HashSet<string> IgnoredNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", "System Volume Information",
        "$RECYCLE.BIN", ".DS_Store", "Thumbs.db", ".DocumentRevisions-V100", "desktop.ini",
    };
    /// Dossiers qui n'existent qu'à l'intérieur d'une carte
    public static readonly HashSet<string> InsideCardNames = new()
    {
        "M4ROOT", "PRIVATE", "CLIP", "SUB", "THMBNL", "GENERAL", "AVF_INFO", "SONY", "DCIM", "XDROOT",
        "CONTENTS", "AVCHD", "BPAV", "CANONMSC", "MISC", "DATABASE",
    };

    public readonly string Source;
    public readonly List<string> Destinations;
    public readonly string Project, Label, Day;
    public readonly bool Force;
    public readonly int? CardNumber;
    public readonly CancelFlag Cancel = new();
    public HashKind HashKind = HashKind.Xxh64;
    public bool MakePDF = true;
    readonly Action<OffloadEvent> emit;
    HashSet<string>? mergeTops;
    readonly Stopwatch clock = Stopwatch.StartNew();
    double lastEmit = -1;
    readonly object emitLock = new();

    public OffloadJob(string source, IEnumerable<string> destinations, string project, string label, string day,
                      bool force, int? cardNumber, Action<OffloadEvent> emit)
    {
        Source = source; Destinations = destinations.ToList(); Project = project; Label = label; Day = day;
        Force = force; CardNumber = cardNumber; this.emit = emit;
    }

    public void Run()
    {
        var created = new List<string>();
        try
        {
            emit(new OffloadEvent.Finished(Perform(created)));
        }
        catch (OffloadCancelled)
        {
            MarkIncomplete(created);
            emit(new OffloadEvent.Finished(new OffloadResult { Ok = false, Cancelled = true, Message = "Copie annulée.", Source = Source }));
        }
        catch (Exception e)
        {
            MarkIncomplete(created);
            var msg = e is OffloadException ? e.Message : e.Message;
            emit(new OffloadEvent.Finished(new OffloadResult { Ok = false, Message = "Erreur : " + msg, Source = Source }));
        }
    }

    void Log(string s) => emit(new OffloadEvent.Log(s));
    void Check() { if (Cancel.IsSet) throw new OffloadCancelled(); }

    void ProgressEv(string phase, long done, long total, double since, bool force = false)
    {
        double now = clock.Elapsed.TotalSeconds;
        lock (emitLock)
        {
            if (!force && now - lastEmit < 0.2) return;
            lastEmit = now;
        }
        double elapsed = Math.Max(now - since, 0.001);
        emit(new OffloadEvent.Progress(phase, done, Math.Max(total, 1), done / elapsed));
    }

    OffloadResult Perform(List<string> created)
    {
        var t0 = DateTime.Now;
        double t0s = clock.Elapsed.TotalSeconds;
        var cardName = Volumes.CardName(Source);
        Log($"Analyse de la carte « {Volumes.DisplayName(Source)} »…");
        var files = Scan(Source);
        if (files.Count == 0) throw new OffloadException("la carte est vide (aucun fichier à copier).");
        long total = files.Sum(f => f.Size);
        Log($"{files.Count} fichiers, {Util.Human(total)}");

        var proj = Naming.Sanitize(Project);
        var projectDirs = Destinations.Select(d => Path.Combine(d, proj)).ToList();
        foreach (var pd in projectDirs) Directory.CreateDirectory(Path.Combine(pd, Naming.ReportDir));

        // Doublon ? La carte est reconnue par son contenu (liste, poids et dates des fichiers)
        var sig = Signature(files);
        if (!Force && FindPreviousCopy(new[] { sig, SignatureV2(files), LegacySignature(files, cardName) }, Destinations) is { } dup)
            return new OffloadResult { Ok = false, Duplicate = true, Message = dup.Message, Source = Source };

        // Espace libre, regroupé par disque physique
        foreach (var g in projectDirs.GroupBy(p => Volumes.Root(p), StringComparer.OrdinalIgnoreCase))
        {
            if (Volumes.Free(g.First()) is long free)
            {
                long required = total * g.Count() + 200L * 1024 * 1024;
                if (free < required)
                    throw new OffloadException($"pas assez d'espace sur {Volumes.Label(g.First())} (libre {Util.Human(free)}, nécessaire {Util.Human(required)}).");
            }
        }

        // Une lettre de caméra = un seul modèle par jour
        if (Naming.ConflictingLabel(Destinations, Project, Day, Label) is string existing)
        {
            var b = existing.Split('_', 2)[0];
            throw new OffloadException($"{b} est déjà « {existing} » ce jour-là : une caméra ne peut pas avoir deux modèles le même jour. Choisis une autre lettre pour « {Label} ».");
        }

        var plan = Naming.MakePlan(Destinations, Project, Day, Label, CardNumber);
        if (plan.Merge && plan.Targets.Any(Naming.SonOccupied))
            throw new OffloadException("la carte son n°1 de ce jour est déjà copiée (dossier SON). Choisis un autre numéro.");
        var shortName = plan.Display.Contains('/') ? plan.Display[(plan.Display.IndexOf('/') + 1)..] : plan.Display;
        if (plan.Merge) mergeTops = files.Select(f => f.Rel.Split('/')[0]).ToHashSet();
        foreach (var t in plan.Targets)
        {
            if (!plan.Merge && Naming.Exists(t)) throw new OffloadException($"le dossier {Naming.Name(t)} existe déjà.");
            Directory.CreateDirectory(t);
            created.Add(t);
        }
        emit(new OffloadEvent.Started(shortName));
        Log($"→ {plan.Display} vers {plan.Targets.Count} disque(s)");

        // ---- Copie simultanée : une lecture, N écritures en parallèle ----
        var hashes = new Dictionary<string, string>();
        long done = 0;
        double copyStart = clock.Elapsed.TotalSeconds;
        var stats = new SpeedStats(plan.Targets.Count);
        foreach (var f in files)
        {
            Check();
            var targets = plan.Targets.Select(t => Naming.Combine(t, f.Rel)).ToList();
            foreach (var t in targets) Directory.CreateDirectory(Path.GetDirectoryName(t)!);
            var tmps = targets.Select(t => t + ".partial").ToList();
            var outs = new List<SafeFileHandle>();
            var hasher = new FileHasher(HashKind);
            try
            {
                foreach (var tmp in tmps)
                {
                    try
                    {
                        outs.Add(File.OpenHandle(tmp, FileMode.Create, FileAccess.Write, FileShare.None, FileOptions.None, f.Size));
                    }
                    catch (Exception e) { throw new OffloadException($"impossible d'écrire {Path.GetFileName(tmp)} sur {Path.GetDirectoryName(tmp)} ({e.Message})."); }
                }
                // Pipeline : morceaux de la carte lus en avance pendant que le morceau courant s'écrit sur tous
                // les disques ET que son empreinte se calcule. Mémoire stable : ~4 morceaux de 16 Mo par copie.
                ReadAhead.Stream(f.Path, ChunkSize, 4, true, stats, Check, chunk =>
                {
                    var work = new Task[outs.Count + 1];
                    work[0] = Task.Run(() =>
                    {
                        var sw = Stopwatch.StartNew();
                        hasher.Update(chunk.Span);
                        stats.AddHash(sw.Elapsed.TotalSeconds);
                    });
                    for (int i = 0; i < outs.Count; i++)
                    {
                        int k = i;
                        var o = outs[k];
                        work[k + 1] = Task.Run(() =>
                        {
                            var sw = Stopwatch.StartNew();
                            RandomAccess.Write(o, chunk.Span, chunk.Offset);
                            stats.AddWrite(sw.Elapsed.TotalSeconds, k);
                        });
                    }
                    try { Task.WaitAll(work); }
                    catch (AggregateException ae) { throw ae.InnerExceptions[0]; }
                    stats.AddBytes(chunk.Length);
                    done += chunk.Length;
                    ProgressEv("Copie", done, total, copyStart);
                });
                // Les données vont vraiment sur les disques avant la vérification
                Parallel.For(0, outs.Count, k =>
                {
                    var sw = Stopwatch.StartNew();
                    using var fs = new FileStream(outs[k], FileAccess.Write, 1);
                    fs.Flush(true);
                    stats.AddWrite(sw.Elapsed.TotalSeconds, k);
                });
                outs.Clear();
            }
            finally
            {
                foreach (var o in outs) o.Dispose();
            }

            var src = new FileInfo(f.Path);
            for (int i = 0; i < tmps.Count; i++)
            {
                if (File.Exists(targets[i])) File.Delete(targets[i]);
                File.Move(tmps[i], targets[i]);
                try
                {
                    File.SetCreationTimeUtc(targets[i], src.CreationTimeUtc);
                    File.SetLastWriteTimeUtc(targets[i], src.LastWriteTimeUtc);
                }
                catch { }
                CopyHidden(f.Path, targets[i]);
            }
            hashes[f.Rel] = hasher.Hex();
        }
        ProgressEv("Copie", total, total, copyStart, true);

        // Les dossiers gardent aussi leur date d'origine (et l'attribut « masqué », ex. AVF_INFO des Sony)
        var relDirs = new HashSet<string>();
        foreach (var f in files)
        {
            var parts = f.Rel.Split('/').ToList();
            parts.RemoveAt(parts.Count - 1);
            while (parts.Count > 0) { relDirs.Add(string.Join("/", parts)); parts.RemoveAt(parts.Count - 1); }
        }
        foreach (var rel in relDirs.OrderByDescending(r => r.Length))
        {
            var s = Naming.Combine(Source, rel);
            if (!Directory.Exists(s)) continue;
            var di = new DirectoryInfo(s);
            foreach (var t in plan.Targets)
            {
                var d = Naming.Combine(t, rel);
                try
                {
                    Directory.SetCreationTimeUtc(d, di.CreationTimeUtc);
                    Directory.SetLastWriteTimeUtc(d, di.LastWriteTimeUtc);
                }
                catch { }
                CopyHidden(s, d);
            }
        }
        double copySeconds = clock.Elapsed.TotalSeconds - t0s;

        // ---- Vérification : chaque disque relu en parallèle, sans cache ----
        Log($"Vérification des copies : relecture de chaque fichier sur chaque disque ({HashKind.Title()})…");
        long vtotal = total * plan.Targets.Count;
        double verifyStart = clock.Elapsed.TotalSeconds;
        long vdone = 0;
        var results = new List<string>[plan.Targets.Count];
        Parallel.For(0, plan.Targets.Count, new ParallelOptions { MaxDegreeOfParallelism = plan.Targets.Count }, i =>
        {
            var errors = new List<string>();
            var dd = plan.Targets[i];
            foreach (var f in files)
            {
                if (Cancel.IsSet) break;
                var p = Naming.Combine(dd, f.Rel);
                long size = -1;
                try { size = new FileInfo(p).Length; } catch { }
                if (size != f.Size) { errors.Add($"taille différente : {f.Rel}"); continue; }
                try
                {
                    var h = new FileHasher(HashKind);
                    ReadAhead.Stream(p, ChunkSize, 4, false, null, Check, c =>
                    {
                        h.Update(c.Span);
                        var cur = Interlocked.Add(ref vdone, c.Length);
                        ProgressEv("Vérification", cur, vtotal, verifyStart);
                    });
                    if (h.Hex() != hashes[f.Rel]) errors.Add($"checksum différent : {f.Rel}");
                }
                catch (OffloadCancelled) { break; }
                catch { errors.Add($"illisible : {f.Rel}"); }
            }
            results[i] = errors;
        });
        Check();
        ProgressEv("Vérification", vtotal, vtotal, verifyStart, true);

        bool allOK = true;
        for (int i = 0; i < plan.Targets.Count; i++)
        {
            if (results[i].Count == 0) Log($"✓ {plan.Targets[i]}");
            else
            {
                allOK = false;
                Log($"✗ {plan.Targets[i]} : {results[i].Count} erreur(s)");
                foreach (var e in results[i].Take(20)) Log("    " + e);
            }
        }

        // ---- Rapports ----
        var end = DateTime.Now;
        double elapsed = (end - t0).TotalSeconds;
        double speed = copySeconds > 0 ? total / copySeconds : 0;
        var diskNames = plan.Targets.Select(Volumes.Label).ToList();
        var speedNote = stats.Summary(diskNames);
        if (speedNote.Length > 0) Log(speedNote);

        var report = new List<string>
        {
            "C-SAFE — rapport de déchargement",
            new string('=', 50),
            $"Date            : {Util.Stamp(end, "yyyy-MM-dd HH:mm:ss")}",
            $"Projet          : {proj}",
            $"Dossier carte   : {plan.Display}",
            $"Jour            : {Day}",
            $"Source          : {Label}",
            $"Carte d'origine : {cardName} ({Source})",
            $"Fichiers        : {files.Count}",
            $"Taille totale   : {Util.Human(total)}",
            $"Durée totale    : {(int)elapsed / 60} min {(int)elapsed % 60} s",
            $"Débit de copie  : {Util.Human((long)speed)}/s",
            $"Vitesses        : {(speedNote.Length == 0 ? "—" : speedNote)}",
            $"Vérification    : {(allOK ? "OK — toutes les copies sont identiques" : "ÉCHEC")} ({HashKind.Title()}, relecture de chaque fichier sur chaque disque)",
            $"Logiciel        : C-SAFE pour Windows {Version}",
            "",
            "Destinations :",
        };
        for (int i = 0; i < plan.Targets.Count; i++)
        {
            report.Add($"  [{(results[i].Count == 0 ? "OK" : "ERREUR")}] {plan.Targets[i]}");
            foreach (var e in results[i]) report.Add("        " + e);
        }
        report.Add("");
        report.Add($"Fichiers (empreinte {HashKind.Title()}) :");
        foreach (var f in files) report.Add($"  {hashes[f.Rel]}  {Util.Human(f.Size)}  {f.Rel}");
        var reportText = string.Join("\r\n", report) + "\r\n";
        var reportName = $"{Day}_{Naming.Name(plan.Targets[0])}";
        if (allOK) WriteMHL(projectDirs, plan.Targets, plan.Display, reportName, files, hashes, t0, end);

        // Rapport PDF : données préparées une fois, PDF écrit sur chaque disque
        string? pdfPath = null;
        if (MakePDF)
        {
            Log("Rapport PDF : vignettes et infos des clips…");
            var data = new PdfReport.CardData
            {
                Project = proj, Day = Day, Display = plan.Display, Label = Label, CardName = cardName,
                Date = Util.Stamp(end, "yyyy-MM-dd HH:mm"), Files = files.Count, TotalBytes = total,
                Seconds = (int)elapsed, Speed = (long)speed, Hash = HashKind.Title(), Verified = allOK,
                Destinations = plan.Targets.Select((t, i) => $"{(results[i].Count == 0 ? "OK" : "ERREUR")} · {t}").ToList(),
            };
            double pdfStart = clock.Elapsed.TotalSeconds;
            try
            {
                var info = PdfReport.Prepare(data, plan.Targets[0], files.Select(f => (f.Rel, f.Size)).ToList(), hashes,
                    (d, c) => ProgressEv("Rapport PDF", d, Math.Max(c, 1), pdfStart, d == c));
                foreach (var pd in projectDirs)
                {
                    var u = PdfReport.Write(info, pd, reportName);
                    if (u != null) pdfPath ??= u; else Log($"PDF non écrit dans {pd}");
                }
            }
            catch (Exception e) { Log($"PDF non écrit : {e.Message}"); }
        }

        foreach (var pd in projectDirs)
        {
            var rd = Path.Combine(pd, Naming.ReportDir);
            try
            {
                var hidden = Path.Combine(rd, Naming.HiddenDir);
                Directory.CreateDirectory(hidden);
                Util.HideIfDotFolder(hidden);
                Util.WriteAtomic(Path.Combine(rd, $"{reportName}_rapport.txt"), reportText);
                if (allOK)
                {
                    var entry = new Dictionary<string, string>
                    {
                        ["dossier"] = plan.Display, ["projet"] = proj, ["date"] = Util.Stamp(end, "yyyy-MM-dd HH:mm:ss"),
                        ["label"] = cardName, ["taille"] = Util.Human(total), ["fichiers"] = files.Count.ToString(),
                    };
                    History.Update(pd, t => t[sig] = entry);
                }
            }
            catch (Exception e) { Log($"Impossible d'écrire le rapport dans {rd} : {e.Message}"); }
        }

        if (!allOK)
            return new OffloadResult { Ok = false, Display = plan.Display, VerifyFailed = true, Name = shortName, Source = Source,
                Message = $"{shortName} : la vérification a échoué ! Ne formatez pas la carte." };
        return new OffloadResult
        {
            Ok = true, Display = plan.Display, Name = shortName, Source = Source, ReportPDF = pdfPath,
            Message = $"{shortName} : {Util.Human(total)} copiés et vérifiés sur {plan.Targets.Count} disque(s) en {(int)elapsed / 60} min {(int)elapsed % 60} s (copie à {Util.Human((long)speed)}/s)."
                      + (speedNote.Length == 0 ? "" : " " + speedNote + "."),
        };
    }

    public static string Version = "1.0";

    // ---- Échec / annulation : rien n'est jamais présenté comme une copie valide ----

    void MarkIncomplete(List<string> created)
    {
        var stamp = Util.Stamp(DateTime.Now, "HHmmss");
        foreach (var dd in created)
        {
            if (!Directory.Exists(dd)) continue;
            try
            {
                foreach (var p in Directory.EnumerateFiles(dd, "*.partial", SearchOption.AllDirectories).ToList())
                    try { File.Delete(p); } catch { }
            }
            catch { }
            if (mergeTops != null)
            {
                var bad = Path.Combine(dd, $"_INCOMPLET_{stamp}");
                bool moved = false;
                foreach (var top in mergeTops.Where(t => t.Length > 0))
                {
                    var p = Path.Combine(dd, top);
                    if (!Naming.Exists(p)) continue;
                    try
                    {
                        Directory.CreateDirectory(bad);
                        if (Directory.Exists(p)) Directory.Move(p, Path.Combine(bad, top)); else File.Move(p, Path.Combine(bad, top));
                        moved = true;
                    }
                    catch { }
                }
                if (moved) Log($"Copie incomplète rangée dans SON/_INCOMPLET_{stamp}");
                continue;
            }
            var renamed = Path.Combine(Path.GetDirectoryName(dd)!, $"{Naming.Name(dd)}_INCOMPLET_{stamp}");
            try { Directory.Move(dd, renamed); Log($"Dossier incomplet renommé : {Naming.Name(renamed)}"); } catch { }
        }
    }

    // ---- MHL 1.1 (standard DIT : Silverstack, ShotPut, Hedge, YoYotta, Resolve…) ----

    void WriteMHL(List<string> projectDirs, List<string> targets, string display, string reportName,
                  List<CardFile> files, Dictionary<string, string> hashes, DateTime start, DateTime end)
    {
        static string Iso(DateTime d) => d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
        var stamp = Util.Stamp(end, "yyyy-MM-dd_HHmmss");
        for (int i = 0; i < projectDirs.Count; i++)
        {
            var lines = new List<string>
            {
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                "<hashlist version=\"1.1\">",
                "  <creatorinfo>",
                $"    <username>{Util.Xml(Environment.UserName)}</username>",
                $"    <hostname>{Util.Xml(Environment.MachineName)}</hostname>",
                "    <tool>C-SAFE 1.0</tool>",
                $"    <startdate>{Iso(start)}</startdate>",
                $"    <finishdate>{Iso(end)}</finishdate>",
                "  </creatorinfo>",
            };
            foreach (var f in files)
            {
                var p = Naming.Combine(targets[i], f.Rel);
                var mod = File.Exists(p) ? File.GetLastWriteTime(p) : end;
                lines.Add("  <hash>");
                lines.Add($"    <file>{Util.Xml($"../{display}/{f.Rel}")}</file>");
                lines.Add($"    <size>{f.Size}</size>");
                lines.Add($"    <lastmodificationdate>{Iso(mod)}</lastmodificationdate>");
                lines.Add($"    <{HashKind.MhlTag()}>{hashes[f.Rel]}</{HashKind.MhlTag()}>");
                lines.Add($"    <hashdate>{Iso(end)}</hashdate>");
                lines.Add("  </hash>");
            }
            lines.Add("</hashlist>");
            var url = Path.Combine(projectDirs[i], Naming.ReportDir, $"{reportName}_{stamp}.mhl");
            try { Util.WriteAtomic(url, string.Join("\n", lines) + "\n"); }
            catch (Exception e) { Log($"MHL non écrit dans {targets[i]} : {e.Message}"); }
        }
    }

    // ---- Doublons ----

    /// Cherche si cette carte a déjà été copiée et si la copie est toujours sur un disque.
    public static PreviousCopy? FindPreviousCopy(IEnumerable<string> signatures, IEnumerable<string> destinations)
    {
        var disks = new List<string>();
        Dictionary<string, string>? entry = null;
        var sigs = signatures.ToList();
        foreach (var d in destinations)
        {
            foreach (var proj in Naming.List(d))
            {
                if (proj.StartsWith(".")) continue;
                var pd = Path.Combine(d, proj);
                if (!Naming.IsDir(pd)) continue;
                foreach (var dir in new[] { Naming.ReportDir, History.LegacyDir })
                {
                    var hist = History.Load(pd, dir);
                    foreach (var sig in sigs)
                    {
                        if (!hist.TryGetValue(sig, out var e)) continue;
                        if (CopyStillExists(pd, e.GetValueOrDefault("dossier") ?? ""))
                        {
                            var disk = Volumes.IsRoot(d) ? Volumes.Label(d) : Naming.Name(d);
                            if (!disks.Contains(disk)) disks.Add(disk);
                            var full = new Dictionary<string, string>(e);
                            if (!full.ContainsKey("projet")) full["projet"] = proj;
                            entry ??= full;
                        }
                        else
                        {
                            var s = sig;
                            History.Update(pd, t => t.Remove(s), dir);
                        }
                    }
                }
            }
        }
        if (entry == null) return null;
        var when = "";
        if (entry.TryGetValue("date", out var date) && date.Length >= 16)
        {
            var p = date[..10].Split('-');
            if (p.Length == 3) when = $"le {p[2]}/{p[1]} à {date.Substring(11, 5)}";
        }
        var path = string.Join(" / ", new[] { entry.GetValueOrDefault("projet") ?? "" }
            .Concat((entry.GetValueOrDefault("dossier") ?? "").Split('/')).Where(x => x.Length > 0));
        return new PreviousCopy { Path = path, Disks = disks, When = when, Size = entry.GetValueOrDefault("taille") ?? "" };
    }

    /// Empreintes d'une carte branchée : actuelle (contenu) et anciennes
    public static List<string> CardSignatures(string root)
    {
        try
        {
            var files = Scan(root);
            if (files.Count == 0) return new();
            return new() { Signature(files), SignatureV2(files), LegacySignature(files, Volumes.CardName(root)) };
        }
        catch { return new(); }
    }

    public static string LegacySignature(List<CardFile> files, string cardName)
    {
        var sb = new StringBuilder(cardName);
        foreach (var f in files) sb.Append($"{f.Rel}|{f.Size}\n");
        return Util.Md5Hex(sb.ToString());
    }

    public static string Signature(List<CardFile> files)
    {
        var sb = new StringBuilder("csafe-v3\n");
        foreach (var f in files) sb.Append($"{f.Rel}|{f.Size}|{f.Mtime}\n");
        return Util.Md5Hex(sb.ToString());
    }

    public static string SignatureV2(List<CardFile> files)
    {
        var sb = new StringBuilder("csafe-v2\n");
        foreach (var f in files) sb.Append($"{f.Rel}|{f.Size}\n");
        return Util.Md5Hex(sb.ToString());
    }

    public static bool CopyStillExists(string projectDir, string display)
    {
        if (display.Length == 0) return false;
        var url = Naming.Combine(projectDir, display);
        if (display.EndsWith("/SON")) return Naming.SonOccupied(url);
        return Naming.IsDir(url) && Naming.List(url).Any(x => !x.StartsWith("."));
    }

    // ---- Lecture de la carte ----

    public static List<CardFile> Scan(string root)
    {
        if (!Directory.Exists(root)) throw new OffloadException("impossible de lire la carte.");
        var o = new List<CardFile>();
        var opts = new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = 0, RecurseSubdirectories = false };
        var stack = new Stack<(string dir, string rel)>();
        stack.Push((root, ""));
        while (stack.Count > 0)
        {
            var (dir, rel) = stack.Pop();
            IEnumerable<FileSystemInfo> entries;
            try { entries = new DirectoryInfo(dir).EnumerateFileSystemInfos("*", opts).ToList(); } catch { continue; }
            foreach (var e in entries)
            {
                var name = e.Name;
                var r = rel.Length == 0 ? name : rel + "/" + name;
                if (e is DirectoryInfo di)
                {
                    if (IgnoredNames.Contains(name) || name.StartsWith(".")) continue;
                    if (di.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                    stack.Push((di.FullName, r));
                }
                else if (e is FileInfo fi)
                {
                    if (IgnoredNames.Contains(name) || name.StartsWith("._")) continue;
                    if (fi.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                    o.Add(new CardFile(fi.FullName, r, fi.Length, Util.UnixSeconds(fi.LastWriteTimeUtc)));
                }
            }
        }
        o.Sort((a, b) => string.CompareOrdinal(a.Rel, b.Rel));
        return o;
    }

    static string Ext(string n) => Path.GetExtension(n).TrimStart('.').ToLowerInvariant();

    /// Marque / format reconnus d'après l'arborescence de la carte
    public static string? CameraKind(string root)
    {
        var top = Naming.List(root).Select(x => x.ToUpperInvariant()).ToHashSet();
        bool Has(string p) => Naming.Exists(Naming.Combine(root, p));
        bool DcimHas(string needle) => Naming.List(Path.Combine(root, "DCIM")).Any(x => x.ToUpperInvariant().Contains(needle));
        if (top.Contains("PRIVATE"))
        {
            if (Has("PRIVATE/M4ROOT")) return "Sony XAVC";
            if (Has("PRIVATE/XDROOT")) return "Sony XDCAM";
            if (Has("PRIVATE/AVCHD")) return "AVCHD";
        }
        if (top.Contains("XDROOT")) return "Sony XDCAM";
        if (top.Contains("M4ROOT")) return "Sony";
        if (top.Contains("CONTENTS")) return "Panasonic P2";
        if (top.Contains("CANONMSC") || DcimHas("CANON")) return "Canon";
        if (top.Contains("DCIM"))
        {
            if (DcimHas("GOPRO")) return "GoPro";
            if (DcimHas("DJI")) return "DJI";
            if (DcimHas("INSTA") || DcimHas("CAMERA01")) return "Insta360";
            if (DcimHas("_PANA")) return "Panasonic";
            if (DcimHas("NIKON") || DcimHas("NCZ")) return "Nikon";
            if (DcimHas("_FUJI")) return "Fujifilm";
            return "Photo / vidéo (DCIM)";
        }
        var exts = Naming.List(root).Select(Ext).ToHashSet();
        if (exts.Contains("braw")) return "Blackmagic RAW";
        if (exts.Contains("r3d") || top.Contains("RED")) return "RED";
        if (top.Contains("ARRI") || exts.Contains("ari") || exts.Contains("arx")) return "ARRI";
        var allowed = new HashSet<string> { "wav", "bwf", "txt", "xml", "csv", "sys", "ini", "" };
        if (exts.Count > 0 && exts.IsSubsetOf(allowed) && exts.Contains("wav")) return "Son (WAV)";
        return null;
    }

    /// Une carte caméra / son se reconnaît à sa racine. Lecture limitée : instantané même sur un gros disque.
    public static bool LooksLikeCameraCard(string root)
    {
        if (IsBackupDisk(root)) return false;
        if (CameraKind(root) != null) return true;
        var names = Naming.List(root).Where(n => !n.StartsWith(".")).ToList();
        if (names.Any(n => CardMarkers.Contains(n.ToUpperInvariant()))) return true;
        if (names.Any(n => CameraExtensions.Contains(Ext(n)))) return true;
        int dirs = 0;
        foreach (var n in names)
        {
            if (IgnoredNames.Contains(n)) continue;
            var d = Path.Combine(root, n);
            if (!Naming.IsDir(d)) continue;
            if (++dirs > 12) break;
            var sub = Naming.List(d).Take(300).ToList();
            if (sub.Any(x => CameraExtensions.Contains(Ext(x)))) return true;
            foreach (var x in sub.Take(20).Where(x => !x.StartsWith(".")))
            {
                var dd = Path.Combine(d, x);
                if (!Naming.IsDir(dd)) continue;
                if (Naming.List(dd).Take(300).Any(y => DeepExtensions.Contains(Ext(y)))) return true;
            }
        }
        return false;
    }

    /// Un dossier choisi à l'intérieur d'une carte (ex. « M4ROOT ») : renvoie la carte entière.
    public static string? EnclosingCard(string path)
    {
        if (Volumes.IsRoot(path)) return null;
        var root = Volumes.Root(path);
        var sys = Volumes.Root(Environment.GetFolderPath(Environment.SpecialFolder.Windows));
        if (string.Equals(root, sys, StringComparison.OrdinalIgnoreCase)) return null;
        return LooksLikeCameraCard(root) ? root : null;
    }

    /// Plus gros qu'une carte (au-delà de 4 To) ou contient déjà des copies C-SAFE
    public static bool IsBackupDisk(string root)
    {
        if (Volumes.IsRoot(root) && Volumes.Total(root) is long t && t > MaxCardBytes) return true;
        var names = Naming.List(root);
        if (names.Contains(Naming.ReportDir) || names.Contains("_Rapports")) return true;
        foreach (var n in names.Where(n => !n.StartsWith(".") && !IgnoredNames.Contains(n)).Take(40))
        {
            var sub = Naming.List(Path.Combine(root, n));
            if (sub.Contains(Naming.ReportDir) || sub.Contains("_Rapports")) return true;
        }
        return false;
    }

    /// Recopie l'attribut « masqué » de la carte vers la copie
    public static void CopyHidden(string src, string dst)
    {
        try
        {
            if (Naming.Name(src).StartsWith(".")) return;
            var a = File.GetAttributes(src);
            if (!a.HasFlag(FileAttributes.Hidden)) return;
            File.SetAttributes(dst, File.GetAttributes(dst) | FileAttributes.Hidden);
        }
        catch { }
    }
}
