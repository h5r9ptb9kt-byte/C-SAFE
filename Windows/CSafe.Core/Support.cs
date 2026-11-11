// Support.cs — C-SAFE (Windows)
// Historique des cartes, empreintes (xxHash64 / MD5), lecture anticipée, vitesses, infos des disques.

using System.Diagnostics;
using System.Globalization;
using System.IO.Hashing;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace CSafe.Core;

// ---------------- Historique (même format JSON que la version Mac) ----------------

public static class History
{
    /// Ancien nom du dossier de rapports (anciennes versions de C-SAFE), relu pour la compatibilité
    public const string LegacyDir = "_Rapports";
    static readonly object Lock = new();

    public static string Url(string projectDir, string dir = Naming.ReportDir) =>
        dir == Naming.ReportDir
            ? Path.Combine(projectDir, dir, Naming.HiddenDir, Naming.HistoryFile)
            : Path.Combine(projectDir, dir, Naming.HistoryFile);

    public static string OldUrl(string projectDir) => Path.Combine(projectDir, Naming.ReportDir, Naming.HistoryFile);

    static Dictionary<string, Dictionary<string, string>>? Read(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<Dictionary<string, Dictionary<string, string>>>(File.ReadAllText(path));
        }
        catch { return null; }
    }

    public static Dictionary<string, Dictionary<string, string>> Load(string projectDir, string dir = Naming.ReportDir)
    {
        var t = new Dictionary<string, Dictionary<string, string>>();
        if (dir == Naming.ReportDir && Read(OldUrl(projectDir)) is { } old) foreach (var kv in old) t[kv.Key] = kv.Value;
        if (Read(Url(projectDir, dir)) is { } cur) foreach (var kv in cur) t[kv.Key] = kv.Value;
        return t;
    }

    /// Lecture-modification-écriture protégée (copies simultanées)
    public static void Update(string projectDir, Action<Dictionary<string, Dictionary<string, string>>> change, string dir = Naming.ReportDir)
    {
        lock (Lock)
        {
            var t = Load(projectDir, dir);
            change(t);
            Save(projectDir, t, dir);
        }
    }

    static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static void Save(string projectDir, Dictionary<string, Dictionary<string, string>> t, string dir = Naming.ReportDir)
    {
        try
        {
            var u = Url(projectDir, dir);
            Directory.CreateDirectory(Path.GetDirectoryName(u)!);
            Util.HideIfDotFolder(Path.GetDirectoryName(u)!);
            var sorted = new SortedDictionary<string, SortedDictionary<string, string>>(StringComparer.Ordinal);
            foreach (var kv in t) sorted[kv.Key] = new SortedDictionary<string, string>(kv.Value, StringComparer.Ordinal);
            Util.WriteAtomic(u, JsonSerializer.Serialize(sorted, Pretty));
            if (dir == Naming.ReportDir && File.Exists(OldUrl(projectDir))) File.Delete(OldUrl(projectDir));
        }
        catch { }
    }
}

// ---------------- Empreintes ----------------

public enum HashKind { Xxh64, Md5 }

public static class HashKindInfo
{
    public static string Title(this HashKind k) => k == HashKind.Xxh64 ? "xxHash64" : "MD5";
    public static string MhlTag(this HashKind k) => k == HashKind.Xxh64 ? "xxhash64be" : "md5";
    public static string Explanation(this HashKind k) =>
        k == HashKind.Xxh64 ? "rapide, standard des DIT (recommandé)" : "plus lent, si la production ou l'assurance l'exige";
    public static string Raw(this HashKind k) => k == HashKind.Xxh64 ? "xxh64" : "md5";
    public static HashKind Parse(string? s) => s == "md5" ? HashKind.Md5 : HashKind.Xxh64;
}

public sealed class FileHasher
{
    readonly HashKind kind;
    readonly XxHash64? xx;
    readonly IncrementalHash? md;
    public FileHasher(HashKind kind)
    {
        this.kind = kind;
        if (kind == HashKind.Xxh64) xx = new XxHash64(); else md = IncrementalHash.CreateHash(HashAlgorithmName.MD5);
    }
    public void Update(ReadOnlySpan<byte> data)
    {
        if (xx != null) xx.Append(data); else md!.AppendData(data);
    }
    /// xxHash64 : 16 caractères, ordre « big-endian » comme dans les MHL (xxhash64be) et la version Mac
    public string Hex() => xx != null ? xx.GetCurrentHashAsUInt64().ToString("x16") : Convert.ToHexString(md!.GetHashAndReset()).ToLowerInvariant();
}

// ---------------- Lecture anticipée ----------------

/// Morceau lu (mémoire non gérée, alignée pour les lectures sans cache)
public readonly unsafe struct Chunk
{
    public readonly IntPtr Ptr;
    public readonly int Length;
    public readonly long Offset;
    public Chunk(IntPtr p, int l, long o) { Ptr = p; Length = l; Offset = o; }
    public ReadOnlySpan<byte> Span => new((void*)Ptr, Length);
}

public static unsafe class ReadAhead
{
    const FileOptions NoBuffering = (FileOptions)0x20000000;

    /// Lit un fichier par morceaux avec plusieurs lectures en vol. `cached: true` pour la carte (lecture
    /// anticipée de Windows), `cached: false` pour la vérification : on relit vraiment le disque.
    public static void Stream(string path, int chunk, int depth, bool cached, SpeedStats? stats,
                              Action check, Action<Chunk> body)
    {
        SafeFileHandle h;
        bool direct = !cached && OperatingSystem.IsWindows();
        try
        {
            h = File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete,
                                direct ? NoBuffering : FileOptions.SequentialScan);
        }
        catch when (direct)
        {
            direct = false;
            h = File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, FileOptions.SequentialScan);
        }
        using (h)
        {
            long size = RandomAccess.GetLength(h);
            int count = (int)((size + chunk - 1) / chunk);
            if (count == 0) return;
            // Taille réelle des tampons : jamais plus grand que le fichier (arrondi à 4 Ko pour les lectures directes)
            int bufSize = (int)Math.Min(chunk, ((size + 4095) / 4096) * 4096);
            int nbuf = Math.Min(depth, count);
            var buffers = new IntPtr[nbuf];
            for (int i = 0; i < nbuf; i++) buffers[i] = (IntPtr)NativeMemory.AlignedAlloc((nuint)bufSize, 4096);
            var pending = new Queue<(Task<int> task, int buf, long offset, int length)>();
            try
            {
                int next = 0;
                Task<int> Start(int i, int b)
                {
                    long offset = (long)i * chunk;
                    int length = (int)Math.Min(chunk, size - offset);
                    IntPtr p = buffers[b];
                    bool d = direct;
                    stats?.BeginRead();
                    return Task.Run(() =>
                    {
                        try
                        {
                            int got = 0;
                            // Lecture directe : taille demandée multiple de 4 Ko (la fin du fichier s'arrête d'elle-même)
                            int want = d ? (int)Math.Min(bufSize, ((length + 4095L) / 4096) * 4096) : length;
                            while (got < length)
                            {
                                int r = RandomAccess.Read(h, new Span<byte>((byte*)p + got, want - got), offset + got);
                                if (r <= 0) break;
                                got += r;
                                if (d && got < length && (got % 4096) != 0) break;
                            }
                            return Math.Min(got, length);
                        }
                        finally { stats?.EndRead(); }
                    });
                }
                for (; next < nbuf; next++) pending.Enqueue((Start(next, next), next, (long)next * chunk, (int)Math.Min(chunk, size - (long)next * chunk)));
                for (int i = 0; i < count; i++)
                {
                    check();
                    var (task, b, offset, length) = pending.Dequeue();
                    int got = task.GetAwaiter().GetResult();
                    if (got < length) throw new OffloadException($"fichier tronqué ou illisible : {Path.GetFileName(path)}");
                    body(new Chunk(buffers[b], length, offset));
                    if (next < count) { pending.Enqueue((Start(next, b), b, (long)next * chunk, (int)Math.Min(chunk, size - (long)next * chunk))); next++; }
                }
            }
            finally
            {
                foreach (var p in pending) { try { p.task.Wait(); } catch { } }
                foreach (var b in buffers) NativeMemory.AlignedFree((void*)b);
            }
        }
    }
}

// ---------------- Vitesse de chaque maillon ----------------

public sealed class SpeedStats
{
    readonly object l = new();
    public long Bytes;
    double readSeconds, hashSeconds;
    readonly double[] writeSeconds;
    int inFlight;
    readonly Stopwatch sw = Stopwatch.StartNew();
    double busySince;
    public SpeedStats(int disks) { writeSeconds = new double[disks]; }
    public void BeginRead() { lock (l) { if (inFlight == 0) busySince = sw.Elapsed.TotalSeconds; inFlight++; } }
    public void EndRead() { lock (l) { inFlight--; if (inFlight == 0) readSeconds += sw.Elapsed.TotalSeconds - busySince; } }
    public void AddHash(double s) { lock (l) hashSeconds += s; }
    public void AddWrite(double s, int disk) { lock (l) writeSeconds[disk] += s; }
    public void AddBytes(long b) { lock (l) Bytes += b; }
    double Rate(double s) => s > 0.01 ? Bytes / s : 0;

    /// « Maillon le plus lent : la carte (lecteur) — carte 980 Mo/s · SSD1 1.0 Go/s · empreinte 4.1 Go/s »
    public string Summary(IList<string> diskNames)
    {
        lock (l)
        {
            if (Bytes <= 64L * 1024 * 1024) return "";
            var parts = new List<(string name, string shortName, double rate)> { ("la carte (lecteur)", "carte", Rate(readSeconds)) };
            for (int i = 0; i < writeSeconds.Length; i++)
            {
                var n = i < diskNames.Count ? diskNames[i] : $"{i + 1}";
                parts.Add(($"le disque « {n} »", $"« {n} »", Rate(writeSeconds[i])));
            }
            parts.Add(("le calcul de l'empreinte", "empreinte", Rate(hashSeconds)));
            var known = parts.Where(p => p.rate > 0).ToList();
            if (known.Count == 0) return "";
            var slowest = known.MinBy(p => p.rate);
            return $"Maillon le plus lent : {slowest.name} — " + string.Join(" · ", known.Select(p => $"{p.shortName} {Util.Human((long)p.rate)}/s"));
        }
    }
}

public class OffloadException : Exception { public OffloadException(string m) : base(m) { } }
public class OffloadCancelled : Exception { }

// ---------------- Outils ----------------

public static class Util
{
    static readonly string[] Units = { "o", "Ko", "Mo", "Go", "To" };

    public static string Human(long n)
    {
        double v = n;
        foreach (var u in Units)
        {
            if (v < 1024 || u == "To") return u == "o" ? $"{(long)v} o" : v.ToString("0.0", CultureInfo.InvariantCulture) + " " + u;
            v /= 1024;
        }
        return $"{n} o";
    }

    public static string Stamp(DateTime d, string format) => d.ToString(format, CultureInfo.InvariantCulture);

    public static string Xml(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    public static string Md5Hex(string s) => Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(s))).ToLowerInvariant();

    public static void WriteAtomic(string path, string text)
    {
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, text, new UTF8Encoding(false));
        File.Move(tmp, path, true);
    }

    /// Dossier « .C-SAFE » : masqué aussi sous Windows
    public static void HideIfDotFolder(string dir)
    {
        try
        {
            if (Naming.Name(dir).StartsWith(".") && Directory.Exists(dir))
            {
                var di = new DirectoryInfo(dir);
                if (!di.Attributes.HasFlag(FileAttributes.Hidden)) di.Attributes |= FileAttributes.Hidden;
            }
        }
        catch { }
    }

    public static long UnixSeconds(DateTime utc) => (long)Math.Floor((utc - DateTime.UnixEpoch).TotalSeconds);

    public static string Duration(double seconds)
    {
        int s = (int)Math.Round(seconds);
        if (s >= 3600) return $"{s / 3600} h {s % 3600 / 60} min";
        if (s >= 60) return $"{s / 60} min {s % 60} s";
        return $"{s} s";
    }
}

// ---------------- Disques (Windows : lettres de lecteur) ----------------

public static class Volumes
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool GetVolumeInformationW(string root, StringBuilder? name, int nameSize, out uint serial,
                                             out uint maxComp, out uint flags, StringBuilder? fs, int fsSize);

    public static string Root(string path)
    {
        try { return Path.GetPathRoot(Path.GetFullPath(path)) ?? path; } catch { return path; }
    }

    public static bool IsRoot(string path)
    {
        try
        {
            var full = Path.GetFullPath(path).TrimEnd('\\', '/');
            var root = Root(path).TrimEnd('\\', '/');
            return string.Equals(full, root, StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    static DriveInfo? Drive(string path)
    {
        try { var d = new DriveInfo(Root(path)); return d.IsReady ? d : null; } catch { return null; }
    }

    public static long? Total(string path) => Drive(path)?.TotalSize;
    public static long? Free(string path) => Drive(path)?.AvailableFreeSpace;

    /// Nom du disque : « X10 Pro » (sinon la lettre)
    public static string Label(string path)
    {
        var d = Drive(path);
        var root = Root(path).TrimEnd('\\');
        if (d == null) return root;
        string label = "";
        try { label = d.VolumeLabel; } catch { }
        return string.IsNullOrWhiteSpace(label) ? (d.DriveType == DriveType.Removable ? "Carte" : "Disque") + $" ({root})" : label;
    }

    /// Nom affiché d'une carte ou d'un dossier : « SONY (E:) » pour un lecteur, sinon le nom du dossier
    public static string DisplayName(string path)
    {
        if (!IsRoot(path)) return Naming.Name(path);
        var root = Root(path).TrimEnd('\\');
        var d = Drive(path);
        string label = "";
        try { label = d?.VolumeLabel ?? ""; } catch { }
        return string.IsNullOrWhiteSpace(label) ? $"Carte ({root})" : $"{label} ({root})";
    }

    /// Nom de la carte comme sur Mac (nom du volume) pour les rapports et l'ancienne empreinte
    public static string CardName(string path)
    {
        if (!IsRoot(path)) return Naming.Name(path);
        var d = Drive(path);
        string label = "";
        try { label = d?.VolumeLabel ?? ""; } catch { }
        return string.IsNullOrWhiteSpace(label) ? "Untitled" : label;
    }

    public static string Serial(string path)
    {
        if (!OperatingSystem.IsWindows()) return "";
        try
        {
            return GetVolumeInformationW(Root(path), null, 0, out var serial, out _, out _, null, 0) ? serial.ToString("X8") : "";
        }
        catch { return ""; }
    }

    /// Identifiant stable d'un disque (numéro de série du volume, sinon son chemin)
    public static string Id(string path)
    {
        var s = Serial(path);
        return s.Length > 0 ? s : Path.GetFullPath(path).TrimEnd('\\');
    }

    public static bool IsRemovable(string path) => Drive(path)?.DriveType == DriveType.Removable;

    /// Lecteurs branchés (sauf le disque système)
    public static List<string> Mounted()
    {
        var sys = Root(Environment.GetFolderPath(Environment.SpecialFolder.Windows));
        var o = new List<string>();
        try
        {
            foreach (var d in DriveInfo.GetDrives())
            {
                try
                {
                    if (!d.IsReady) continue;
                    if (d.DriveType != DriveType.Removable && d.DriveType != DriveType.Fixed) continue;
                    if (string.Equals(d.RootDirectory.FullName, sys, StringComparison.OrdinalIgnoreCase)) continue;
                    o.Add(d.RootDirectory.FullName);
                }
                catch { }
            }
        }
        catch { }
        return o;
    }

    /// Disque SSD ? (Windows : Get-PhysicalDisk ; null si inconnu, ex. boîtier USB ou NAS)
    public static bool? IsSSD(string path)
    {
        if (!OperatingSystem.IsWindows()) return null;
        var letter = Root(path).TrimEnd('\\', ':');
        if (letter.Length != 1) return null;
        try
        {
            var psi = new ProcessStartInfo("powershell.exe",
                $"-NoProfile -NonInteractive -Command \"$n=(Get-Partition -DriveLetter {letter}).DiskNumber; (Get-PhysicalDisk | Where-Object {{ $_.DeviceId -eq \\\"$n\\\" }}).MediaType\"")
            { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
            using var p = Process.Start(psi)!;
            var o = p.StandardOutput.ReadToEnd().Trim();
            if (!p.WaitForExit(8000)) { try { p.Kill(); } catch { } return null; }
            if (o.Equals("SSD", StringComparison.OrdinalIgnoreCase)) return true;
            if (o.Equals("HDD", StringComparison.OrdinalIgnoreCase)) return false;
            return null;
        }
        catch { return null; }
    }
}
