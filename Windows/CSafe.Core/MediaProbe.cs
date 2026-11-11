// MediaProbe.cs — C-SAFE (Windows)
// Infos des clips pour le rapport PDF : timecode (piste tmcd MOV/MP4, XML Sony, BWF), durée, format,
// vignette. ffprobe / ffmpeg (livrés avec C-SAFE) pour la durée, le format et la vignette.

using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CSafe.Core;

public static class TC
{
    /// Images → « 10:00:00:00 » (« ; » avant les images en drop-frame)
    public static string Format(long frames, int rate, bool drop)
    {
        if (rate <= 0) return "--:--:--:--";
        long f = frames;
        if (drop && (rate == 30 || rate == 60))
        {
            int d = rate == 60 ? 4 : 2;
            long per10 = rate * 600 - d * 9, per1 = rate * 60 - d;
            long tens = f / per10, rest = f % per10;
            f += d * 9 * tens + (rest > d ? d * ((rest - d) / per1) : 0);
        }
        long day = rate * 86400L;
        f = ((f % day) + day) % day;
        long ff = f % rate, s = f / rate % 60, m = f / rate / 60 % 60, h = f / rate / 3600;
        return $"{h:00}:{m:00}:{s:00}{(drop ? ";" : ":")}{ff:00}";
    }

    public static long Frames(int h, int m, int s, int f, int rate, bool drop)
    {
        long total = ((h * 60L + m) * 60 + s) * rate + f;
        if (drop && (rate == 30 || rate == 60))
        {
            int d = rate == 60 ? 4 : 2;
            int mins = h * 60 + m;
            total -= d * (mins - mins / 10);
        }
        return total;
    }

    /// « 10:16:31:00 » ou « 10:16:31;00 » → images
    public static (long frames, bool drop)? Parse(string s, int rate)
    {
        var m = Regex.Match(s ?? "", @"^(\d{1,2})[:;.](\d{2})[:;.](\d{2})([:;.])(\d{2})$");
        if (!m.Success) return null;
        bool drop = m.Groups[4].Value != ":";
        return (Frames(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), int.Parse(m.Groups[3].Value),
                       int.Parse(m.Groups[5].Value), rate, drop), drop);
    }

    /// Valeur Sony « LtcChange value="FFSSMMHH" » (BCD, octets à l'envers) → lectures possibles
    public static List<(int h, int m, int s, int f, bool drop)> Sony(string hex)
    {
        var o = new List<(int, int, int, int, bool)>();
        if (hex.Length != 8 || !uint.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v)) return o;
        byte[] b = { (byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v };
        static int Bcd(int x) => (x >> 4) * 10 + (x & 0x0F);
        var a = (Bcd(b[3] & 0x3F), Bcd(b[2] & 0x7F), Bcd(b[1] & 0x7F), Bcd(b[0] & 0x3F), (b[0] & 0x40) != 0);
        var r = (Bcd(b[0] & 0x3F), Bcd(b[1] & 0x7F), Bcd(b[2] & 0x7F), Bcd(b[3] & 0x3F), (b[3] & 0x40) != 0);
        foreach (var t in new[] { a, r })
            if (t.Item1 < 24 && t.Item2 < 60 && t.Item3 < 60 && t.Item4 < 60) o.Add(t);
        return o;
    }
}

public static class MediaProbe
{
    // ---------------- XML Sony (C0001.MP4 → C0001M01.XML) ----------------

    public record SonyInfo(long Frames, int Rate, bool Drop, string? Camera, string? Lens, string? Slowmo);

    static string? Attr(string tag, string name, string s)
    {
        var m = Regex.Match(s, $"<{tag}\\b[^>]*>");
        if (!m.Success) return null;
        var a = Regex.Match(m.Value, $"\\b{name}=\"([^\"]*)\"");
        return a.Success ? a.Groups[1].Value : null;
    }

    public static SonyInfo? SonyXML(string videoPath)
    {
        var dir = Path.GetDirectoryName(videoPath)!;
        var stem = Path.GetFileNameWithoutExtension(videoPath).ToUpperInvariant();
        var candidates = Naming.List(dir);
        var xmlName = candidates.FirstOrDefault(c => c.ToUpperInvariant().StartsWith(stem + "M0") && c.ToUpperInvariant().EndsWith(".XML"))
                      ?? candidates.FirstOrDefault(c => c.ToUpperInvariant() == stem + ".XML");
        if (xmlName == null) return null;
        string xml;
        try { xml = File.ReadAllText(Path.Combine(dir, xmlName)); } catch { return null; }

        var manufacturer = Attr("Device", "manufacturer", xml);
        var model = Attr("Device", "modelName", xml);
        var camera = string.Join(" ", new[] { manufacturer, model }.Where(x => !string.IsNullOrEmpty(x)));
        var lens = Attr("Lens", "modelName", xml);
        string? slowmo = null;
        double? Num(string? x) => double.TryParse(new string((x ?? "").Where(c => char.IsDigit(c) || c == '.').ToArray()),
                                                   NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;
        var cap = Num(Attr("VideoFrame", "captureFps", xml));
        var fmt = Num(Attr("VideoFrame", "formatFps", xml));
        if (cap is double c && fmt is double f && f > 0 && Math.Abs(c - f) > 0.5)
        {
            var r = c / f;
            slowmo = c > f ? $"Ralenti ×{(r % 1 == 0 ? ((int)r).ToString() : r.ToString("0.0", CultureInfo.InvariantCulture))} ({(int)c}p)"
                           : $"Accéléré ({c.ToString("0.##", CultureInfo.InvariantCulture)} i/s)";
        }

        var changes = new List<(long count, string value)>();
        foreach (Match m in Regex.Matches(xml, "<LtcChange\\b[^>]*>"))
        {
            var cnt = Attr("LtcChange", "frameCount", m.Value);
            var val = Attr("LtcChange", "value", m.Value);
            if (long.TryParse(cnt, out var n) && val != null) changes.Add((n, val));
        }
        int rate = int.TryParse(Attr("LtcChangeTable", "tcFps", xml), out var tr) ? tr
                 : (fmt is double ff ? (int)Math.Round(ff) : 25);
        string? cam = camera.Length == 0 ? null : camera;
        if (changes.Count == 0) return cam == null && slowmo == null ? null : new SonyInfo(0, 0, false, cam, lens, slowmo);
        var start = changes.FirstOrDefault(x => x.count == 0);
        if (start.value == null) start = changes[0];
        var options = TC.Sony(start.value);
        if (options.Count > 1)
        {
            var end = changes[^1];
            if (end.count > start.count)
            {
                var endOptions = TC.Sony(end.value);
                for (int i = 0; i < options.Count && i < endOptions.Count; i++)
                {
                    var o = options[i]; var e = endOptions[i];
                    var a = TC.Frames(o.h, o.m, o.s, o.f, rate, o.drop);
                    var b = TC.Frames(e.h, e.m, e.s, e.f, rate, e.drop);
                    if (b - a == end.count - start.count) { options = new() { o }; break; }
                }
            }
        }
        if (options.Count == 0) return cam == null && slowmo == null ? null : new SonyInfo(0, 0, false, cam, lens, slowmo);
        var t = options[0];
        return new SonyInfo(TC.Frames(t.h, t.m, t.s, t.f, rate, t.drop) - start.count, rate, t.drop, cam, lens, slowmo);
    }

    // ---------------- Piste timecode (tmcd) lue directement dans le MOV/MP4 ----------------

    static uint Be32(byte[] d, long o) => (uint)(d[o] << 24 | d[o + 1] << 16 | d[o + 2] << 8 | d[o + 3]);
    static ulong Be64(byte[] d, long o) => (ulong)Be32(d, o) << 32 | Be32(d, o + 4);

    public static (long frames, int rate, bool drop)? MovTimecode(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            long fileSize = fs.Length, off = 0;
            byte[]? moov = null;
            var hd = new byte[16];
            while (off + 8 <= fileSize)
            {
                fs.Position = off;
                int n = fs.Read(hd, 0, 16);
                if (n < 8) break;
                long size = Be32(hd, 0), hl = 8;
                var type = Encoding.ASCII.GetString(hd, 4, 4);
                if (size == 1 && n >= 16) { size = (long)Be64(hd, 8); hl = 16; }
                if (size == 0) size = fileSize - off;
                if (size < hl) break;
                if (type == "moov")
                {
                    if (size > 64L << 20) return null;
                    moov = new byte[size - hl];
                    fs.Position = off + hl;
                    fs.ReadExactly(moov);
                    break;
                }
                off += size;
            }
            if (moov == null) return null;

            List<(string type, long start, long end)> Children(long from, long to)
            {
                var o = new List<(string, long, long)>();
                long p = from;
                while (p + 8 <= to)
                {
                    long size = Be32(moov, p), hl = 8;
                    var type = Encoding.ASCII.GetString(moov, (int)p + 4, 4);
                    if (size == 1 && p + 16 <= to) { size = (long)Be64(moov, p + 8); hl = 16; }
                    if (size == 0) size = to - p;
                    if (size < hl || p + size > to) break;
                    o.Add((type, p + hl, p + size));
                    p += size;
                }
                return o;
            }
            (long s, long e)? Find(long from, long to, params string[] path)
            {
                if (path.Length == 0) return (from, to);
                foreach (var c in Children(from, to))
                    if (c.type == path[0] && Find(c.start, c.end, path[1..]) is { } r) return r;
                return null;
            }
            foreach (var trak in Children(0, moov.Length).Where(c => c.type == "trak"))
            {
                var hdlr = Find(trak.start, trak.end, "mdia", "hdlr");
                if (hdlr is not { } h || h.e - h.s < 12 || Encoding.ASCII.GetString(moov, (int)h.s + 8, 4) != "tmcd") continue;
                if (Find(trak.start, trak.end, "mdia", "minf", "stbl") is not { } stbl) continue;
                if (Find(stbl.s, stbl.e, "stsd") is not { } stsd || stsd.e - stsd.s < 41) continue;
                long e0 = stsd.s + 8;
                if (Encoding.ASCII.GetString(moov, (int)e0 + 4, 4) != "tmcd") continue;
                uint flags = Be32(moov, e0 + 20);
                int quanta = moov[e0 + 32];
                long? chunk = null;
                if (Find(stbl.s, stbl.e, "stco") is { } stco && stco.e - stco.s >= 12) chunk = Be32(moov, stco.s + 8);
                else if (Find(stbl.s, stbl.e, "co64") is { } co64 && co64.e - co64.s >= 16) chunk = (long)Be64(moov, co64.s + 8);
                if (chunk is not long c || quanta <= 0) continue;
                fs.Position = c;
                var v = new byte[4];
                if (fs.Read(v, 0, 4) != 4) continue;
                return ((int)Be32(v, 0), quanta, (flags & 1) != 0);
            }
            return null;
        }
        catch { return null; }
    }

    // ---------------- BWF : TimeReference (bext) + cadence, scène et prise (iXML) ----------------

    public record Bwf(double? Seconds, int Rate, bool Drop, string? Note, int SampleRate, int Channels, int Bits, double? Duration);

    public static Bwf BwfInfo(string path)
    {
        double? seconds = null; int rate = 25; bool drop = false; string? note = null;
        int channels = 0, bits = 0; long dataSize = -1;
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var head = new byte[12];
            if (fs.Read(head, 0, 12) != 12) return new(null, rate, drop, null, 0, 0, 0, null);
            var riff = Encoding.ASCII.GetString(head, 0, 4);
            if (riff != "RIFF" && riff != "RF64") return new(null, rate, drop, null, 0, 0, 0, null);
            double sampleRate = 0; ulong? timeRef = null;
            long offset = 12;
            var ch = new byte[8];
            for (int i = 0; i < 64; i++)
            {
                fs.Position = offset;
                if (fs.Read(ch, 0, 8) != 8) break;
                var id = Encoding.ASCII.GetString(ch, 0, 4);
                uint size = BitConverter.ToUInt32(ch, 4);
                if (id == "data") { if (size != 0xFFFFFFFF) dataSize = size; else break; }
                if (id == "fmt ")
                {
                    var d = new byte[16];
                    if (fs.Read(d, 0, 16) == 16)
                    {
                        sampleRate = BitConverter.ToUInt32(d, 4);
                        channels = BitConverter.ToUInt16(d, 2);
                        bits = BitConverter.ToUInt16(d, 14);
                    }
                }
                else if (id == "bext" && size >= 346)
                {
                    var d = new byte[346];
                    if (fs.Read(d, 0, 346) == 346) timeRef = BitConverter.ToUInt64(d, 338);
                }
                else if (id == "iXML")
                {
                    var d = new byte[Math.Min(size, 256 * 1024)];
                    int got = fs.Read(d, 0, d.Length);
                    var x = Encoding.UTF8.GetString(d, 0, got);
                    string? Tag(string t)
                    {
                        var m = Regex.Match(x, $"<{t}>([^<]*)</{t}>");
                        var v = m.Success ? m.Groups[1].Value.Trim() : "";
                        return v.Length == 0 ? null : v;
                    }
                    if (Tag("TIMECODE_RATE") is string tr)
                    {
                        var p = tr.Split('/').Select(z => double.TryParse(z, NumberStyles.Float, CultureInfo.InvariantCulture, out var q) ? q : 0).ToList();
                        if (p.Count > 0 && p[0] > 0) rate = (int)Math.Round(p[0] / (p.Count > 1 && p[1] > 0 ? p[1] : 1));
                    }
                    if (Tag("TIMECODE_FLAG") is string fl) drop = fl.ToUpperInvariant() == "DF";
                    var parts = new[] { Tag("SCENE") is string sc ? $"Sc {sc}" : null, Tag("TAKE") is string tk ? $"Prise {tk}" : null }
                        .Where(z => z != null).ToList();
                    if (parts.Count > 0) note = string.Join(" · ", parts);
                }
                offset += 8 + size + (size & 1);
            }
            if (timeRef is ulong t && sampleRate > 0) seconds = t / sampleRate;
            double? duration = dataSize > 0 && sampleRate > 0 && channels > 0 && bits > 0 ? dataSize / (sampleRate * channels * (bits / 8.0)) : null;
            return new(seconds, rate, drop, note, (int)sampleRate, channels, bits, duration);
        }
        catch { }
        return new(seconds, rate, drop, note, 0, 0, 0, null);
    }

    // ---------------- ffprobe / ffmpeg (livrés dans le dossier de C-SAFE) ----------------

    public static string? Tool(string name)
    {
        var exe = OperatingSystem.IsWindows() ? name + ".exe" : name;
        var env = Environment.GetEnvironmentVariable("CSAFE_FFMPEG");
        var dirs = new List<string>();
        if (!string.IsNullOrEmpty(env)) dirs.Add(env);
        dirs.Add(Path.Combine(AppContext.BaseDirectory, "ffmpeg"));
        dirs.Add(AppContext.BaseDirectory);
        dirs.AddRange((Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries));
        foreach (var d in dirs)
        {
            try { var p = Path.Combine(d, exe); if (File.Exists(p)) return p; } catch { }
        }
        return null;
    }

    static byte[]? Run(string exe, IEnumerable<string> args, int timeoutMs = 30000)
    {
        try
        {
            var psi = new ProcessStartInfo(exe) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi)!;
            using var ms = new MemoryStream();
            var copy = p.StandardOutput.BaseStream.CopyToAsync(ms);
            var err = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(timeoutMs)) { try { p.Kill(true); } catch { } return null; }
            copy.Wait(5000);
            return p.ExitCode == 0 ? ms.ToArray() : null;
        }
        catch { return null; }
    }

    public record VideoInfo(double? Duration, string? Resolution, string? Fps, string? Codec, string? Camera,
                            (long frames, int rate, bool drop)? Timecode, int SampleRate, int Channels, int Bits);

    static readonly Dictionary<string, string> CodecNames = new()
    {
        ["avc1"] = "H.264", ["avc3"] = "H.264", ["hvc1"] = "H.265", ["hev1"] = "H.265",
        ["apco"] = "ProRes 422 Proxy", ["apcs"] = "ProRes 422 LT", ["apcn"] = "ProRes 422",
        ["apch"] = "ProRes 422 HQ", ["ap4h"] = "ProRes 4444", ["ap4x"] = "ProRes 4444 XQ",
        ["aprn"] = "ProRes RAW", ["aprh"] = "ProRes RAW HQ", ["mjpg"] = "Motion JPEG", ["dvh1"] = "Dolby Vision",
        ["h264"] = "H.264", ["hevc"] = "H.265", ["prores"] = "ProRes", ["mjpeg"] = "Motion JPEG", ["mpeg4"] = "MPEG-4",
        ["mpeg2video"] = "MPEG-2", ["dnxhd"] = "DNxHD", ["av1"] = "AV1", ["vp9"] = "VP9",
    };

    public static VideoInfo? Probe(string path)
    {
        var ffprobe = Tool("ffprobe");
        if (ffprobe == null) return null;
        var o = Run(ffprobe, new[] { "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path });
        if (o == null) return null;
        try
        {
            using var doc = JsonDocument.Parse(o);
            var root = doc.RootElement;
            double? duration = null;
            string? res = null, fps = null, codec = null, camera = null;
            (long, int, bool)? tc = null;
            int sr = 0, chans = 0, bits = 0;
            string? Str(JsonElement e, string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            if (root.TryGetProperty("format", out var fmt))
            {
                if (double.TryParse(Str(fmt, "duration"), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) && d > 0) duration = d;
                if (fmt.TryGetProperty("tags", out var tags))
                {
                    string? T(string k)
                    {
                        foreach (var p in tags.EnumerateObject()) if (p.Name.Equals(k, StringComparison.OrdinalIgnoreCase)) return p.Value.GetString();
                        return null;
                    }
                    var cam = string.Join(" ", new[] { T("com.apple.quicktime.make") ?? T("make"), T("com.apple.quicktime.model") ?? T("model") }
                        .Where(x => !string.IsNullOrWhiteSpace(x)));
                    if (cam.Length > 0) camera = cam;
                }
            }
            string? tcString = null;
            if (root.TryGetProperty("streams", out var streams))
            {
                foreach (var s in streams.EnumerateArray())
                {
                    var type = Str(s, "codec_type");
                    if (s.TryGetProperty("tags", out var tg) && tg.TryGetProperty("timecode", out var tcv)) tcString ??= tcv.GetString();
                    if (type == "video" && res == null)
                    {
                        if (s.TryGetProperty("disposition", out var disp) && disp.TryGetProperty("attached_pic", out var ap) && ap.GetInt32() == 1) continue;
                        int w = s.TryGetProperty("width", out var wv) ? wv.GetInt32() : 0;
                        int h = s.TryGetProperty("height", out var hv) ? hv.GetInt32() : 0;
                        int rot = 0;
                        if (s.TryGetProperty("side_data_list", out var sdl))
                            foreach (var sd in sdl.EnumerateArray())
                                if (sd.TryGetProperty("rotation", out var rv) && rv.ValueKind == JsonValueKind.Number) rot = (int)rv.GetDouble();
                        if (tg.ValueKind == JsonValueKind.Object && tg.TryGetProperty("rotate", out var rr) && int.TryParse(rr.GetString(), out var r2)) rot = r2;
                        if (Math.Abs(rot) % 180 == 90) (w, h) = (h, w);
                        if (w > 0 && h > 0) res = $"{w}×{h}";
                        var rate = Str(s, "avg_frame_rate") is string ar && ar != "0/0" ? ar : Str(s, "r_frame_rate");
                        if (rate != null)
                        {
                            var p = rate.Split('/');
                            if (p.Length == 2 && double.TryParse(p[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var a)
                                && double.TryParse(p[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var b) && b > 0 && a > 0)
                            {
                                var v = a / b;
                                fps = Math.Abs(v - Math.Round(v)) < 0.005 ? $"{(int)Math.Round(v)} i/s" : v.ToString("0.00", CultureInfo.InvariantCulture) + " i/s";
                            }
                        }
                        var tag = (Str(s, "codec_tag_string") ?? "").Trim();
                        var name = Str(s, "codec_name") ?? "";
                        codec = CodecNames.TryGetValue(tag, out var c1) ? c1 : CodecNames.TryGetValue(name, out var c2) ? c2
                              : name.Length > 0 ? name.ToUpperInvariant() : null;
                        if (name == "prores" && Str(s, "profile") is string prof && !CodecNames.ContainsKey(tag)) codec = "ProRes " + prof;
                    }
                    else if (type == "audio" && sr == 0)
                    {
                        int.TryParse(Str(s, "sample_rate"), out sr);
                        chans = s.TryGetProperty("channels", out var cv) ? cv.GetInt32() : 0;
                        bits = s.TryGetProperty("bits_per_sample", out var bv) ? bv.GetInt32() : 0;
                        if (bits == 0 && int.TryParse(Str(s, "bits_per_raw_sample"), out var br)) bits = br;
                    }
                }
            }
            if (tcString != null && fps != null)
            {
                var r = (int)Math.Round(double.Parse(fps.Split(' ')[0], CultureInfo.InvariantCulture));
                if (TC.Parse(tcString, r) is { } p) tc = (p.frames, r, p.drop);
            }
            return new VideoInfo(duration, res, fps, codec, camera, tc, sr, chans, bits);
        }
        catch { return null; }
    }

    /// Vignette JPEG (~320 px) à l'instant `at`
    public static byte[]? Thumbnail(string path, double at)
    {
        var ffmpeg = Tool("ffmpeg");
        if (ffmpeg == null) return null;
        var t = at.ToString("0.###", CultureInfo.InvariantCulture);
        var o = Run(ffmpeg, new[] { "-v", "error", "-ss", t, "-i", path, "-frames:v", "1",
                                    "-vf", "scale='min(320,iw)':-2", "-f", "image2pipe", "-vcodec", "mjpeg", "-q:v", "5", "-" });
        if (o == null || o.Length < 100)
            o = Run(ffmpeg, new[] { "-v", "error", "-i", path, "-frames:v", "1",
                                    "-vf", "scale='min(320,iw)':-2", "-f", "image2pipe", "-vcodec", "mjpeg", "-q:v", "5", "-" });
        return o != null && o.Length >= 100 ? o : null;
    }
}
