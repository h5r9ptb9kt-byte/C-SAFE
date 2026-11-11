// PdfReport.cs — C-SAFE (Windows)
// Rapport PDF lisible par la production et le montage, identique à la version Mac :
// résumé, grille de clips (vignette, TC début → fin, durée, format, taille, empreinte),
// rapport du jour avec frise de synchro au timecode. Dessiné avec SkiaSharp.

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using MetadataExtractor;
using MetadataExtractor.Formats.Exif;
using SkiaSharp;
using Dir = System.IO.Directory;

namespace CSafe.Core;

public static class PdfReport
{
    // ---------------- Données (même JSON que la version Mac, dans Rapports_de_copie/.C-SAFE/rapports) ----------------

    public sealed class Clip
    {
        public string Name { get; set; } = "";
        public long Size { get; set; }
        public string Kind { get; set; } = "";      // « vidéo », « photo », « son »
        public double? Duration { get; set; }
        public string? Resolution { get; set; }
        public string? Fps { get; set; }
        public string? Codec { get; set; }
        public string Hash { get; set; } = "";
        public byte[]? Thumb { get; set; }
        public long? TcFrames { get; set; }
        public int? TcRate { get; set; }
        public bool? TcDrop { get; set; }
        public string? Camera { get; set; }
        public string? Lens { get; set; }
        public string? Note { get; set; }

        [JsonIgnore] public string ShortName => Name.Contains('/') ? Name[(Name.LastIndexOf('/') + 1)..] : Name;
        [JsonIgnore] public double? TcSeconds => TcFrames is long f && TcRate is int r && r > 0 ? f / (TcDrop == true ? r * 1000.0 / 1001 : r) : null;
        [JsonIgnore] public string? TcIn => TcFrames is long f && TcRate is int r ? TC.Format(f, r, TcDrop == true) : null;
        [JsonIgnore]
        public string? TcOut
        {
            get
            {
                if (TcFrames is not long f || TcRate is not int r || Duration is not double d) return null;
                double real = TcDrop == true ? r * 1000.0 / 1001 : r;
                return TC.Format(f + Math.Max(0, (long)Math.Round(d * real) - 1), r, TcDrop == true);
            }
        }
    }

    public sealed class CardData
    {
        public string Project { get; set; } = "";
        public string Day { get; set; } = "";
        public string Display { get; set; } = "";
        public string Label { get; set; } = "";
        public string CardName { get; set; } = "";
        public string Date { get; set; } = "";
        public int Files { get; set; }
        public long TotalBytes { get; set; }
        public int Seconds { get; set; }
        public long Speed { get; set; }
        public string Hash { get; set; } = "";
        public bool Verified { get; set; }
        public List<string> Destinations { get; set; } = new();
        public List<Clip> Clips { get; set; } = new();
        public int ExtraFiles { get; set; }
    }

    static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public static readonly HashSet<string> VideoExt = new() { "mp4", "mov", "mxf", "mts", "m2ts", "avi", "insv", "m4v", "braw", "r3d", "crm" };
    public static readonly HashSet<string> PhotoExt = new() { "jpg", "jpeg", "heic", "heif", "png", "dng", "arw", "cr2", "cr3", "nef", "raf", "rw2", "orf", "insp" };
    public static readonly HashSet<string> AudioExt = new() { "wav", "bwf", "mp3", "aif", "aiff", "m4a" };
    /// Dossiers de la caméra qui ne contiennent pas de rushes (vignettes, proxys, index)
    public static readonly HashSet<string> AnnexDirs = new() { "THMBNL", "SUB", "PROXY", "PROXIES", "THUMBNAIL", "THUMBNAILS", "AVF_INFO", "GENERAL", "CACHE", "MISC", "TAKE", "XDROOT_GENERAL" };

    static string Ext(string rel) => Path.GetExtension(rel).TrimStart('.').ToLowerInvariant();

    public static bool IsMedia(string rel)
    {
        var e = Ext(rel);
        return VideoExt.Contains(e) || PhotoExt.Contains(e) || AudioExt.Contains(e);
    }

    /// Vrai rush (et pas une vignette caméra, un proxy ou un fichier caché)
    public static bool IsClip(string rel, HashSet<string> videoStems)
    {
        if (!IsMedia(rel)) return false;
        var parts = rel.Split('/');
        if (parts.Any(p => p.StartsWith("."))) return false;
        if (parts.Take(parts.Length - 1).Any(p => AnnexDirs.Contains(p.ToUpperInvariant()))) return false;
        var name = parts[^1];
        if (PhotoExt.Contains(Ext(name)))
        {
            var stem = Path.GetFileNameWithoutExtension(name).ToUpperInvariant();
            var m = Regex.Match(stem, @"T\d{2}$");
            if (m.Success && videoStems.Contains(stem[..m.Index])) return false;
        }
        return true;
    }

    /// Analyse les clips copiés (sur le premier disque, déjà vérifié) : vignettes, infos techniques, timecode.
    public static CardData Prepare(CardData data, string cardFolder, List<(string Rel, long Size)> files,
                                   Dictionary<string, string> hashes, Action<int, int>? progress = null)
    {
        var stems = files.Where(f => VideoExt.Contains(Ext(f.Rel)))
            .Select(f => Path.GetFileNameWithoutExtension(f.Rel.Split('/')[^1]).ToUpperInvariant()).ToHashSet();
        var media = files.Where(f => IsClip(f.Rel, stems)).ToList();
        progress?.Invoke(0, media.Count);
        int done = 0;
        foreach (var f in media)
        {
            var path = Naming.Combine(cardFolder, f.Rel);
            var clip = new Clip { Name = f.Rel, Size = f.Size, Hash = hashes.GetValueOrDefault(f.Rel) ?? "" };
            var e = Ext(f.Rel);
            try
            {
                if (VideoExt.Contains(e)) { clip.Kind = "vidéo"; DescribeVideo(path, clip); }
                else if (PhotoExt.Contains(e)) { clip.Kind = "photo"; DescribePhoto(path, clip); }
                else { clip.Kind = "son"; DescribeAudio(path, clip); }
            }
            catch { }
            data.Clips.Add(clip);
            progress?.Invoke(++done, media.Count);
        }
        data.ExtraFiles = files.Count - media.Count;
        return data;
    }

    /// Écrit le PDF de la carte + ses données (pour le rapport du jour). Retourne le chemin du PDF.
    public static string? Write(CardData data, string projectDir, string reportName)
    {
        var rd = Path.Combine(projectDir, Naming.ReportDir);
        var hidden = Path.Combine(rd, Naming.HiddenDir);
        var store = Path.Combine(hidden, "rapports");
        try
        {
            Dir.CreateDirectory(store);
            Util.HideIfDotFolder(hidden);
            Util.WriteAtomic(Path.Combine(store, reportName + ".json"), JsonSerializer.Serialize(data, Json));
        }
        catch { }
        var pdf = Path.Combine(rd, reportName + "_rapport.pdf");
        var title = "Rapport de copie — " + (data.Display.Split('/').LastOrDefault() ?? data.Label);
        return Render(title, $"{data.Project} · {data.Day}", new() { data }, false, pdf) ? pdf : null;
    }

    /// Rassemble toutes les cartes d'un jour dans un seul PDF : « J1_2026-11-04_rapport_du_jour.pdf »
    public static string? DayReport(string projectDir, string day)
    {
        var rd = Path.Combine(projectDir, Naming.ReportDir);
        var cards = SavedCards(projectDir).Where(c => c.Day == day).OrderBy(c => c.Display, StringComparer.Ordinal).ToList();
        if (cards.Count == 0) return null;
        var pdf = Path.Combine(rd, $"{day}_rapport_du_jour.pdf");
        return Render($"Rapport du jour — {day}", cards[0].Project, cards, true, pdf) ? pdf : null;
    }

    static string StoreDir(string projectDir) => Path.Combine(projectDir, Naming.ReportDir, Naming.HiddenDir, "rapports");

    public static int SavedCardCount(string projectDir, string day) =>
        Naming.List(StoreDir(projectDir)).Count(n => n.StartsWith(day + "_") && n.EndsWith(".json"));

    public static List<CardData> SavedCards(string projectDir)
    {
        var o = new List<CardData>();
        foreach (var n in Naming.List(StoreDir(projectDir)).Where(n => n.EndsWith(".json")))
        {
            try
            {
                var c = JsonSerializer.Deserialize<CardData>(File.ReadAllText(Path.Combine(StoreDir(projectDir), n)), Json);
                if (c != null) o.Add(c);
            }
            catch { }
        }
        return o;
    }

    // ---------------- Analyse des fichiers ----------------

    static void DescribeVideo(string path, Clip clip)
    {
        var info = MediaProbe.Probe(path);
        if (info != null)
        {
            clip.Duration = info.Duration;
            clip.Resolution = info.Resolution;
            clip.Fps = info.Fps;
            clip.Codec = info.Codec;
            clip.Camera = info.Camera;
        }
        clip.Thumb = MediaProbe.Thumbnail(path, Math.Min(1.0, (clip.Duration ?? 0) * 0.1));
        var sony = MediaProbe.SonyXML(path);
        if (MediaProbe.MovTimecode(path) is { } tc) { clip.TcFrames = tc.frames; clip.TcRate = tc.rate; clip.TcDrop = tc.drop; }
        else if (info?.Timecode is { } t2) { clip.TcFrames = t2.frames; clip.TcRate = t2.rate; clip.TcDrop = t2.drop; }
        else if (sony is { Rate: > 0 }) { clip.TcFrames = sony.Frames; clip.TcRate = sony.Rate; clip.TcDrop = sony.Drop; }
        if (sony?.Camera != null) clip.Camera = sony.Camera;
        clip.Lens = sony?.Lens;
        clip.Note = sony?.Slowmo;
    }

    static void DescribePhoto(string path, Clip clip)
    {
        try
        {
            var dirs = ImageMetadataReader.ReadMetadata(path);
            var ifd0 = dirs.OfType<ExifIfd0Directory>().FirstOrDefault();
            var cam = string.Join(" ", new[] { ifd0?.GetDescription(ExifDirectoryBase.TagMake), ifd0?.GetDescription(ExifDirectoryBase.TagModel) }
                .Where(x => !string.IsNullOrWhiteSpace(x)).Select(x => x!.Trim()));
            if (cam.Length > 0) clip.Camera = cam;
            var sub = dirs.OfType<ExifSubIfdDirectory>().FirstOrDefault();
            if (sub != null && sub.TryGetInt32(ExifDirectoryBase.TagExifImageWidth, out var w) && sub.TryGetInt32(ExifDirectoryBase.TagExifImageHeight, out var h) && w > 0 && h > 0)
                clip.Resolution = $"{w}×{h}";
            // Aperçu JPEG intégré aux fichiers RAW (ARW, DNG, NEF, CR2…)
            if (!new[] { "jpg", "jpeg", "png", "heic", "heif" }.Contains(Ext(path)))
            {
                byte[]? best = null;
                using var fs = File.OpenRead(path);
                foreach (var d in dirs.OfType<ExifDirectoryBase>())
                {
                    if (!d.TryGetInt64(0x0201, out var off) || !d.TryGetInt64(0x0202, out var len)) continue;
                    if (len <= 0 || len > 30_000_000 || off + len > fs.Length || (best != null && len <= best.Length)) continue;
                    var buf = new byte[len];
                    fs.Position = off;
                    fs.ReadExactly(buf);
                    if (buf.Length > 2 && buf[0] == 0xFF && buf[1] == 0xD8) best = buf;
                }
                if (best != null) clip.Thumb = Resize(best);
            }
        }
        catch { }
        if (clip.Thumb == null)
        {
            try
            {
                var bytes = File.ReadAllBytes(path);
                using var codec = SKCodec.Create(new SKMemoryStream(bytes));
                if (codec != null && clip.Resolution == null) clip.Resolution = $"{codec.Info.Width}×{codec.Info.Height}";
                clip.Thumb = Resize(bytes);
            }
            catch { }
        }
        clip.Thumb ??= MediaProbe.Thumbnail(path, 0);
    }

    static void DescribeAudio(string path, Clip clip)
    {
        var info = MediaProbe.Probe(path);
        var e = Ext(path);
        MediaProbe.Bwf? b = e == "wav" || e == "bwf" ? MediaProbe.BwfInfo(path) : null;
        clip.Duration = info?.Duration ?? b?.Duration;
        int sr = info?.SampleRate > 0 ? info.SampleRate : b?.SampleRate ?? 0;
        int ch = info?.Channels > 0 ? info.Channels : b?.Channels ?? 0;
        int bits = info?.Bits > 0 ? info.Bits : b?.Bits ?? 0;
        if (sr > 0) clip.Codec = $"{sr / 1000} kHz{(bits > 0 ? $" · {bits} bits" : "")} · {ch} piste(s)";
        if (b?.Seconds is double s)
        {
            double real = b.Drop ? b.Rate * 1000.0 / 1001 : b.Rate;
            clip.TcFrames = (long)Math.Round(s * real); clip.TcRate = b.Rate; clip.TcDrop = b.Drop;
        }
        if (b?.Note != null) clip.Note = b.Note;
    }

    /// Image → JPEG ~320 px
    static byte[]? Resize(byte[] data)
    {
        try
        {
            using var codec = SKCodec.Create(new SKMemoryStream(data));
            if (codec == null) return null;
            var info = codec.Info;
            float scale = Math.Min(1f, 320f / Math.Max(info.Width, info.Height));
            // Décodage réduit (rapide pour les grosses photos)
            var dims = codec.GetScaledDimensions(scale);
            using var bmp = new SKBitmap(new SKImageInfo(dims.Width, dims.Height, SKColorType.Rgba8888, SKAlphaType.Premul));
            if (codec.GetPixels(bmp.Info, bmp.GetPixels()) is not (SKCodecResult.Success or SKCodecResult.IncompleteInput))
            {
                using var full = SKBitmap.Decode(data);
                if (full == null) return null;
                return Encode(full, scale);
            }
            return Encode(bmp, Math.Min(1f, 320f / Math.Max(bmp.Width, bmp.Height)), codec.EncodedOrigin);
        }
        catch { return null; }
    }

    static byte[] Encode(SKBitmap src, float scale, SKEncodedOrigin origin = SKEncodedOrigin.TopLeft)
    {
        int w = Math.Max(1, (int)(src.Width * scale)), h = Math.Max(1, (int)(src.Height * scale));
        using var small = src.Resize(new SKImageInfo(w, h), SKFilterQuality.Medium) ?? src.Copy();
        SKBitmap oriented = small;
        if (origin is SKEncodedOrigin.RightTop or SKEncodedOrigin.LeftBottom or SKEncodedOrigin.BottomRight)
        {
            bool quarter = origin != SKEncodedOrigin.BottomRight;
            oriented = new SKBitmap(quarter ? small.Height : small.Width, quarter ? small.Width : small.Height);
            using var c = new SKCanvas(oriented);
            if (origin == SKEncodedOrigin.RightTop) { c.Translate(oriented.Width, 0); c.RotateDegrees(90); }
            else if (origin == SKEncodedOrigin.LeftBottom) { c.Translate(0, oriented.Height); c.RotateDegrees(270); }
            else { c.Translate(oriented.Width, oriented.Height); c.RotateDegrees(180); }
            c.DrawBitmap(small, 0, 0);
        }
        using var img = SKImage.FromBitmap(oriented);
        using var d = img.Encode(SKEncodedImageFormat.Jpeg, 72);
        var bytes = d.ToArray();
        if (!ReferenceEquals(oriented, small)) oriented.Dispose();
        return bytes;
    }

    // ---------------- Résumés ----------------

    public static string DurationText(double s)
    {
        int t = (int)Math.Round(s);
        if (t >= 3600) return $"{t / 3600} h {(t % 3600) / 60:00} min";
        if (t >= 60) return $"{t / 60} min {t % 60:00} s";
        return $"{t} s";
    }

    static string? MostCommon(IEnumerable<string?> values)
    {
        var counts = new Dictionary<string, int>();
        foreach (var v in values) if (!string.IsNullOrEmpty(v)) counts[v] = counts.GetValueOrDefault(v) + 1;
        if (counts.Count == 0) return null;
        var best = counts.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal).First();
        return counts.Count > 1 ? $"{best.Key} (+ {counts.Count - 1} autre{(counts.Count > 2 ? "s" : "")})" : best.Key;
    }

    static string CountText(List<Clip> clips)
    {
        int v = clips.Count(c => c.Kind == "vidéo"), p = clips.Count(c => c.Kind == "photo"), a = clips.Count(c => c.Kind == "son");
        var parts = new List<string>();
        if (v > 0) parts.Add($"{v} vidéo{(v > 1 ? "s" : "")}");
        if (p > 0) parts.Add($"{p} photo{(p > 1 ? "s" : "")}");
        if (a > 0) parts.Add($"{a} son{(a > 1 ? "s" : "")}");
        return parts.Count == 0 ? "aucun rush" : string.Join(" · ", parts);
    }

    static string? FormatText(List<Clip> clips)
    {
        var vids = clips.Where(c => c.Kind == "vidéo").ToList();
        if (vids.Count == 0) return MostCommon(clips.Select(c => c.Codec));
        return MostCommon(vids.Select(c => string.Join(" · ", new[] { c.Resolution, c.Fps, c.Codec }.Where(x => x != null))));
    }

    static string? TcRange(List<Clip> clips)
    {
        var withTC = clips.Where(c => c.TcSeconds != null).OrderBy(c => c.TcSeconds).ToList();
        if (withTC.Count == 0 || withTC[0].TcIn is not string a) return null;
        var last = withTC.MaxBy(c => c.TcSeconds!.Value + (c.Duration ?? 0))!;
        var b = last.TcOut ?? last.TcIn ?? "";
        int missing = clips.Count(c => c.Kind != "photo" && c.TcSeconds == null);
        return $"{a} → {b}" + (missing > 0 ? $"  ({missing} sans TC)" : "");
    }

    static double Rushes(List<Clip> clips) => clips.Where(c => c.Kind != "photo").Sum(c => c.Duration ?? 0);

    // ---------------- Mise en page (A4, couleurs C-FOCUS) ----------------

    const float W = 595, H = 842, M = 32;
    static SKColor Rgb(uint hex) => new((byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);
    static readonly SKColor Navy = Rgb(0x0F1924), Orange = Rgb(0xE8742A), Cream = Rgb(0xF1EAD6), Ink = Rgb(0x1D2733),
        Gray = Rgb(0x6B7A89), Light = Rgb(0xEEF1F4), Line = Rgb(0xDDE2E8), Paper = Rgb(0xF7F8FA), Green = Rgb(0x2FA874), Red = Rgb(0xD9443C);
    static readonly SKColor[] Lanes = { Rgb(0xE8742A), Rgb(0x2F6FB5), Rgb(0x2FA874), Rgb(0x8E5BC2), Rgb(0xC9A227), Rgb(0xD9443C), Rgb(0x2AA3A3), Rgb(0x6B7A89) };

    sealed class Page : IDisposable
    {
        readonly SKDocument doc;
        public SKCanvas? C;
        public float Y;
        public int Number;
        public readonly string Footer;
        static readonly SKTypeface Sans = SKTypeface.FromFamilyName("Arial", SKFontStyle.Normal) ?? SKTypeface.Default;
        static readonly SKTypeface SansBold = SKTypeface.FromFamilyName("Arial", SKFontStyle.Bold) ?? SKTypeface.Default;
        static readonly SKTypeface Mono = SKTypeface.FromFamilyName("Consolas", SKFontStyle.Normal) ?? SKTypeface.FromFamilyName("Courier New") ?? SKTypeface.Default;
        static readonly SKTypeface MonoBold = SKTypeface.FromFamilyName("Consolas", SKFontStyle.Bold) ?? Mono;

        public Page(SKDocument doc, string footer) { this.doc = doc; Footer = footer; }

        public void New()
        {
            if (Number > 0) Finish();
            Number++;
            C = doc.BeginPage(W, H);
            Y = M;
            if (Number > 1)
            {
                Rect(0, 0, W, 4, Orange);
                Text(Footer, M, 14, 7.5f, color: Gray, maxWidth: W - 2 * M);
                Y = 34;
            }
        }

        public void Finish()
        {
            Rect(M, H - 30, W - 2 * M, 0.5f, Line);
            Text("C-SAFE · C-FOCUS", M, H - 24, 7.5f, bold: true, color: Gray);
            Text($"page {Number}", W - M, H - 24, 7.5f, color: Gray, alignRight: true);
            doc.EndPage();
            C = null;
        }

        public void Need(float h) { if (Y + h > H - 40) New(); }

        public void Rect(float x, float top, float w, float h, SKColor fill, float radius = 0)
        {
            using var p = new SKPaint { Color = fill, IsAntialias = true, Style = SKPaintStyle.Fill };
            float r = Math.Min(radius, Math.Min(w / 2, h / 2));
            if (r > 0) C!.DrawRoundRect(new SKRect(x, top, x + w, top + h), r, r, p);
            else C!.DrawRect(new SKRect(x, top, x + w, top + h), p);
        }

        public void Stroke(float x, float top, float w, float h, SKColor color, float radius = 0)
        {
            using var p = new SKPaint { Color = color, IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 0.5f };
            C!.DrawRoundRect(new SKRect(x + 0.25f, top + 0.25f, x + w - 0.25f, top + h - 0.25f), radius, radius, p);
        }

        static SKTypeface Face(bool bold, bool mono) => mono ? (bold ? MonoBold : Mono) : (bold ? SansBold : Sans);

        static readonly Dictionary<int, SKTypeface> Fallbacks = new();

        // Texte découpé en morceaux : chaque caractère absent de la police (✓, ✗, ♪…) prend une police qui l'a
        static List<(string s, SKTypeface tf)> Runs(string s, SKTypeface primary)
        {
            var runs = new List<(string, SKTypeface)>();
            var sb = new System.Text.StringBuilder();
            SKTypeface? cur = null;
            for (int i = 0; i < s.Length; i++)
            {
                int cp = char.ConvertToUtf32(s, i);
                string chs = char.ConvertFromUtf32(cp);
                if (char.IsHighSurrogate(s[i])) i++;
                SKTypeface tf = primary;
                if (!primary.ContainsGlyph(cp))
                {
                    lock (Fallbacks)
                    {
                        if (!Fallbacks.TryGetValue(cp, out var fb))
                        {
                            fb = SKFontManager.Default.MatchCharacter(primary.FamilyName,
                                     new SKFontStyle(primary.FontWeight, primary.FontWidth, primary.FontSlant), null, cp) ?? primary;
                            Fallbacks[cp] = fb;
                        }
                        tf = fb;
                    }
                }
                if (cur != null && tf != cur) { runs.Add((sb.ToString(), cur)); sb.Clear(); }
                cur = tf;
                sb.Append(chs);
            }
            if (cur != null && sb.Length > 0) runs.Add((sb.ToString(), cur));
            return runs;
        }

        static float Measure(string s, SKTypeface primary, float size)
        {
            float w = 0;
            foreach (var (t, tf) in Runs(s, primary)) { using var f = new SKFont(tf, size); w += f.MeasureText(t); }
            return w;
        }

        /// Texte sur une ligne (tronqué si besoin). `top` = haut de la ligne. Retourne la largeur dessinée.
        public float Text(string s, float x, float top, float size, bool bold = false, bool mono = false, SKColor? color = null,
                          float maxWidth = 520, bool alignRight = false, bool truncateEnd = false)
        {
            var tf = Face(bold, mono);
            string line = s;
            if (Measure(line, tf, size) > maxWidth)
            {
                // Coupe au milieu (noms de fichiers) ou à la fin, avec « … »
                int lo = 0, hi = s.Length;
                string best = "…";
                while (lo <= hi)
                {
                    int mid = (lo + hi) / 2;
                    string cand = truncateEnd ? s[..mid].TrimEnd() + "…"
                                              : s[..((mid + 1) / 2)] + "…" + s[(s.Length - mid / 2)..];
                    if (Measure(cand, tf, size) <= maxWidth) { best = cand; lo = mid + 1; } else hi = mid - 1;
                }
                line = best;
            }
            float width = Measure(line, tf, size);
            float px = alignRight ? x - width : x;
            float baseline = top + size;
            using var paint = new SKPaint { Color = color ?? Ink, IsAntialias = true };
            foreach (var (t, f) in Runs(line, tf))
            {
                using var font = new SKFont(f, size);
                C!.DrawText(t, px, baseline, font, paint);
                px += font.MeasureText(t);
            }
            return width;
        }

        public void Image(byte[]? data, float x, float top, float w, float h, string placeholder)
        {
            Rect(x, top, w, h, Navy, 3);
            SKImage? img = null;
            try { if (data != null) img = SKImage.FromEncodedData(data); } catch { }
            if (img == null)
            {
                Text(placeholder, x + w / 2 - 3, top + h / 2 - 5, 9, bold: true, color: Gray, maxWidth: w - 4);
                return;
            }
            using (img)
            {
                float scale = Math.Max(w / img.Width, h / img.Height);   // remplit la case (recadrage léger)
                float dw = img.Width * scale, dh = img.Height * scale;
                C!.Save();
                C.ClipRoundRect(new SKRoundRect(new SKRect(x, top, x + w, top + h), 3, 3), antialias: true);
                using var p = new SKPaint { FilterQuality = SKFilterQuality.High, IsAntialias = true };
                C.DrawImage(img, new SKRect(x + (w - dw) / 2, top + (h - dh) / 2, x + (w + dw) / 2, top + (h + dh) / 2), p);
                C.Restore();
            }
        }

        public void Dispose() { }
    }

    static bool Render(string title, string subtitle, List<CardData> cards, bool dayMode, string path)
    {
        try
        {
            var tmp = path + ".tmp";
            using (var stream = new SKFileWStream(tmp))
            using (var doc = SKDocument.CreatePdf(stream, new SKDocumentPdfMetadata { Title = title, Creator = "C-SAFE · C-FOCUS", Producer = "C-SAFE pour Windows" }))
            {
                var page = new Page(doc, $"{title} · {subtitle}");
                page.New();

                // Bandeau
                page.Rect(0, 0, W, 70, Navy);
                page.Rect(0, 70, W, 3, Orange);
                page.Text("C-SAFE", M, 18, 21, bold: true, color: Cream);
                page.Text("par C-FOCUS", M, 43, 8.5f, color: Orange);
                page.Text(title, W - M, 20, 13, bold: true, color: Cream, maxWidth: 380, alignRight: true);
                page.Text(subtitle, W - M, 40, 9, color: Cream, maxWidth: 380, alignRight: true);
                page.Y = 88;

                var allClips = cards.SelectMany(c => c.Clips).ToList();
                if (dayMode)
                {
                    bool ok = cards.All(c => c.Verified);
                    long total = cards.Sum(c => c.TotalBytes);
                    int n = cards.Count;
                    Badge(page, ok, ok ? $"✓ {n} carte{(n > 1 ? "s" : "")} copiée{(n > 1 ? "s" : "")} et vérifiée{(n > 1 ? "s" : "")} sur tous les disques"
                                       : "✗ Au moins une carte n'a pas été vérifiée : ne formate rien, voir le détail");
                    double r = Rushes(allClips);
                    Tiles(page, new()
                    {
                        ("Cartes", $"{n}", string.Join(" · ", cards.Select(c => c.Label).Distinct().OrderBy(x => x, StringComparer.Ordinal))),
                        ("Rushes", $"{allClips.Count}", CountText(allClips)),
                        ("Durée", r > 0 ? DurationText(r) : "—", "vidéo + son"),
                        ("Volume", Util.Human(total), $"{cards.Sum(c => c.Files)} fichiers"),
                    });
                    SyncTimeline(page, cards);
                    CardList(page, cards);
                }
                else
                {
                    var c = cards[0];
                    Badge(page, c.Verified, c.Verified
                        ? $"✓ Copie vérifiée ({c.Hash}) : chaque fichier relu sur chaque disque — tu peux formater la carte"
                        : "✗ Vérification en échec : NE FORMATE PAS la carte");
                    double r = Rushes(c.Clips);
                    Tiles(page, new()
                    {
                        ("Rushes", $"{c.Clips.Count}", CountText(c.Clips)),
                        ("Durée", r > 0 ? DurationText(r) : "—", "total des clips"),
                        ("Volume", Util.Human(c.TotalBytes), $"{c.Files} fichiers"),
                        ("Copie", DurationText(c.Seconds), $"{Util.Human(c.Speed)}/s"),
                    });
                }
                for (int i = 0; i < cards.Count; i++) CardSection(page, cards[i], dayMode);
                page.Finish();
                doc.Close();
            }
            File.Move(tmp, path, true);
            return true;
        }
        catch { return false; }
    }

    static void Badge(Page page, bool ok, string text)
    {
        page.Rect(M, page.Y, W - 2 * M, 26, ok ? Rgb(0xE6F6EE) : Rgb(0xFBE7E5), 6);
        page.Rect(M, page.Y, 4, 26, ok ? Green : Red, 2);
        page.Text(text, M + 12, page.Y + 8, 9.5f, bold: true, color: ok ? Green : Red, maxWidth: W - 2 * M - 22);
        page.Y += 34;
    }

    static void Tiles(Page page, List<(string, string, string)> items)
    {
        float gap = 8, n = items.Count;
        float w = (W - 2 * M - gap * (n - 1)) / n, h = 52;
        for (int i = 0; i < items.Count; i++)
        {
            var t = items[i];
            float x = M + i * (w + gap);
            page.Rect(x, page.Y, w, h, Paper, 6);
            page.Stroke(x, page.Y, w, h, Line, 6);
            page.Text(t.Item1.ToUpperInvariant(), x + 10, page.Y + 8, 6.5f, bold: true, color: Gray, maxWidth: w - 20);
            page.Text(t.Item2, x + 10, page.Y + 19, 15, bold: true, color: Ink, maxWidth: w - 20);
            page.Text(t.Item3, x + 10, page.Y + 38, 7, color: Gray, maxWidth: w - 20, truncateEnd: true);
        }
        page.Y += h + 14;
    }

    static void SectionTitle(Page page, string s, string? right = null)
    {
        page.Text(s, M, page.Y, 11, bold: true, color: Ink);
        if (right != null) page.Text(right, W - M, page.Y + 2, 7.5f, color: Gray, alignRight: true);
        page.Rect(M, page.Y + 16, 22, 2, Orange);
        page.Y += 24;
    }

    /// « OK · E:\Projet\… » → (ok, « X10 Pro », « Projet/… »)
    static (bool ok, string disk, string path) SplitDestination(string d)
    {
        bool ok = d.StartsWith("OK");
        var idx = d.IndexOf(" · ", StringComparison.Ordinal);
        var path = idx >= 0 ? d[(idx + 3)..] : d;
        if (path.StartsWith("/Volumes/"))
        {
            var parts = path["/Volumes/".Length..].Split('/', 2);
            return (ok, parts[0], parts.Length > 1 ? parts[1] : "");
        }
        if (Regex.IsMatch(path, @"^[A-Za-z]:[\\/]"))
        {
            var rest = path[3..].Replace('\\', '/');
            string disk;
            try { disk = Volumes.Label(path); } catch { disk = path[..2]; }
            if (disk.Length == 0) disk = path[..2];
            return (ok, disk, rest);
        }
        var comps = path.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        return (ok, comps.Length > 4 ? comps[^5] : (comps.FirstOrDefault() ?? path), string.Join("/", comps.TakeLast(4)));
    }

    static void InfoGrid(Page page, List<(string, string)> info)
    {
        float colW = (W - 2 * M) / 2;
        for (int i = 0; i < info.Count; i++)
        {
            float x = M + (i % 2) * colW;
            if (i % 2 == 0 && i > 0) page.Y += 15;
            page.Text(info[i].Item1, x, page.Y, 7.5f, color: Gray, maxWidth: 76);
            page.Text(info[i].Item2, x + 78, page.Y, 8.5f, bold: true, color: Ink, maxWidth: colW - 86, truncateEnd: true);
        }
        page.Y += 19;
    }

    static void CardSection(Page page, CardData c, bool dayMode)
    {
        var cardTitle = c.Display.Split('/').LastOrDefault() ?? c.Label;
        page.Need(dayMode ? 190 : 150);
        if (dayMode)
        {
            page.Rect(M, page.Y, W - 2 * M, 24, Navy, 5);
            page.Text(c.Verified ? "✓" : "✗", M + 10, page.Y + 7, 10, bold: true, color: c.Verified ? Green : Red);
            page.Text(cardTitle, M + 26, page.Y + 7, 10, bold: true, color: Cream, maxWidth: 300);
            double r = Rushes(c.Clips);
            page.Text($"{CountText(c.Clips)} · {(r > 0 ? DurationText(r) + " · " : "")}{Util.Human(c.TotalBytes)}",
                      W - M - 10, page.Y + 8, 8, color: Cream, maxWidth: 220, alignRight: true);
            page.Y += 34;
        }
        var info = new List<(string, string)>();
        if (!dayMode) { info.Add(("Projet", c.Project)); info.Add(("Jour", c.Day)); }
        info.Add(("Source", c.Label)); info.Add(("Carte d'origine", c.CardName));
        if (MostCommon(c.Clips.Select(x => x.Camera)) is string cam) info.Add(("Caméra", cam));
        if (MostCommon(c.Clips.Select(x => x.Lens)) is string lens) info.Add(("Objectif", lens));
        if (FormatText(c.Clips) is string f) info.Add(("Format", f));
        if (TcRange(c.Clips) is string tc) info.Add(("Timecode", tc));
        info.Add(("Copie terminée", c.Date)); info.Add(("Vérification", $"{c.Hash} — {(c.Verified ? "OK" : "ÉCHEC")}"));
        if (dayMode) info.Add(("Copie", $"{DurationText(c.Seconds)} · {Util.Human(c.Speed)}/s"));
        InfoGrid(page, info);

        page.Text("Dossier", M, page.Y, 7.5f, color: Gray);
        page.Text(c.Display, M + 78, page.Y, 8.5f, mono: true, color: Ink, maxWidth: W - 2 * M - 78);
        page.Y += 15;
        for (int i = 0; i < c.Destinations.Count; i++)
        {
            var s = SplitDestination(c.Destinations[i]);
            page.Text(i == 0 ? "Disques" : "", M, page.Y, 7.5f, color: Gray);
            float w = page.Text($"{(s.ok ? "✓" : "✗")}  {s.disk}", M + 78, page.Y, 8.5f, bold: true, color: s.ok ? Ink : Red, maxWidth: 160);
            page.Text(s.path, M + 78 + w + 8, page.Y + 1, 7, color: Gray, maxWidth: W - 2 * M - 86 - w);
            page.Y += 13;
        }
        page.Y += 10;

        // Grille des clips : 2 par ligne
        float gap = 10, cellW = (W - 2 * M - gap) / 2, cellH = 58, thumbW = 84, thumbH = 47;
        if (c.Clips.Count > 0)
        {
            page.Need(cellH + 30);
            SectionTitle(page, dayMode ? $"Clips — {cardTitle}" : $"Clips ({c.Clips.Count})",
                         $"TC début → fin · durée · format · taille · empreinte {c.Hash}");
        }
        var sorted = c.Clips.OrderBy(x => x.Name, NaturalComparer.Instance).ToList();
        for (int i = 0; i < sorted.Count; i += 2)
        {
            page.Need(cellH);
            for (int col = 0; col < 2 && i + col < sorted.Count; col++)
            {
                var clip = sorted[i + col];
                float x = M + col * (cellW + gap), top = page.Y;
                page.Rect(x, top, cellW, cellH - 6, Paper, 5);
                page.Image(clip.Thumb, x + 3, top + 3, thumbW, thumbH, clip.Kind == "son" ? "♪" : "—");
                float tx = x + thumbW + 10, tw = cellW - thumbW - 16;
                float sizeW = page.Text(Util.Human(clip.Size), x + cellW - 6, top + 6, 7.5f, color: Gray, alignRight: true);
                page.Text(clip.ShortName, tx, top + 5, 8.5f, bold: true, color: Ink, maxWidth: tw - sizeW - 6);
                if (clip.TcIn is string a)
                    page.Text($"{a} → {clip.TcOut ?? ""}", tx, top + 17, 7.5f, mono: true, color: Orange, maxWidth: tw);
                else
                    page.Text(clip.Kind == "photo" ? "photo" : "pas de timecode", tx, top + 17, 7.5f, color: Gray, maxWidth: tw);
                var details = new List<string>();
                if (clip.Duration is double d) details.Add(DurationText(d));
                if (clip.Note != null) details.Add(clip.Note);
                if (clip.Resolution != null) details.Add(clip.Resolution);
                if (clip.Fps != null) details.Add(clip.Fps);
                if (clip.Codec != null) details.Add(clip.Codec);
                page.Text(string.Join(" · ", details), tx, top + 28, 7.5f, color: Ink, maxWidth: tw, truncateEnd: true);
                page.Text(clip.Hash, tx, top + 39, 6.5f, mono: true, color: Gray, maxWidth: tw);
            }
            page.Y += cellH;
        }
        if (c.ExtraFiles > 0)
        {
            page.Need(16);
            page.Text($"+ {c.ExtraFiles} fichier{(c.ExtraFiles > 1 ? "s" : "")} annexe{(c.ExtraFiles > 1 ? "s" : "")} de la carte (XML, vignettes caméra, proxys, index…) : copiés et vérifiés aussi, détail dans le .mhl.",
                      M, page.Y + 2, 7.5f, color: Gray, maxWidth: W - 2 * M);
            page.Y += 18;
        }
        page.Y += 16;
    }

    static void CardList(Page page, List<CardData> cards)
    {
        page.Need(60);
        SectionTitle(page, "Cartes du jour");
        foreach (var (t, x) in new[] { ("Carte", 0f), ("Rushes", 200f), ("Timecode", 300f), ("Volume", 470f) })
            page.Text(t.ToUpperInvariant(), M + 6 + x, page.Y, 6.5f, bold: true, color: Gray);
        page.Y += 12;
        for (int i = 0; i < cards.Count; i++)
        {
            var c = cards[i];
            page.Need(18);
            if (i % 2 == 0) page.Rect(M, page.Y - 3, W - 2 * M, 17, Paper, 3);
            page.Text(c.Verified ? "✓" : "✗", M + 6, page.Y + 1, 8.5f, bold: true, color: c.Verified ? Green : Red);
            page.Text(c.Display.Split('/').LastOrDefault() ?? c.Display, M + 18, page.Y + 1, 8.5f, bold: true, color: Ink, maxWidth: 180);
            page.Text(CountText(c.Clips), M + 206, page.Y + 1, 8, color: Ink, maxWidth: 92);
            page.Text(TcRange(c.Clips) ?? "—", M + 306, page.Y + 1, 7.5f, mono: true, color: Ink, maxWidth: 160);
            page.Text(Util.Human(c.TotalBytes), W - M - 6, page.Y + 1, 8, color: Ink, alignRight: true);
            page.Y += 17;
        }
        page.Y += 14;
    }

    static void SyncTimeline(Page page, List<CardData> cards)
    {
        var order = new List<string>();
        var bySource = new Dictionary<string, List<Clip>>();
        foreach (var c in cards)
        {
            if (!bySource.ContainsKey(c.Label)) { order.Add(c.Label); bySource[c.Label] = new(); }
            bySource[c.Label].AddRange(c.Clips.Where(x => x.Kind != "photo"));
        }
        var timed = order.Select(l => (label: l, clips: bySource[l].Where(x => x.TcSeconds != null).ToList())).ToList();
        var all = timed.SelectMany(t => t.clips).ToList();
        page.Need(80);
        SectionTitle(page, "Synchro au timecode", all.Count == 0 ? null : "chaque trait = un clip, placé selon son TC");
        if (all.Count == 0)
        {
            page.Text("Aucun timecode lu sur les clips du jour : la synchro devra se faire au son (dérushage).", M, page.Y, 8.5f, color: Gray, maxWidth: W - 2 * M);
            page.Y += 24;
            return;
        }
        double minS = all.Min(x => x.TcSeconds!.Value), maxS = all.Max(x => x.TcSeconds!.Value + Math.Max(x.Duration ?? 0, 1));
        double span = Math.Max(maxS - minS, 60);
        double step = new double[] { 60, 300, 600, 900, 1800, 3600, 7200 }.FirstOrDefault(s => span / s <= 8, 7200);
        double start = Math.Floor(minS / step) * step, end = Math.Ceiling(maxS / step) * step;
        if (end <= start) end = start + step;
        float labelW = 92, x0 = M + labelW, w = W - M - x0, laneH = 18;
        var rows = timed.Where(t => t.clips.Count > 0).ToList();
        float h = rows.Count * laneH + 20;
        page.Need(h + 40);
        float top = page.Y;
        float XFor(double s) => x0 + (float)((s - start) / (end - start)) * w;
        page.Rect(x0, top, w, rows.Count * laneH, Paper, 4);
        for (double t = start; t <= end + 0.5; t += step)
        {
            float x = XFor(t);
            page.Rect(x, top, 0.5f, rows.Count * laneH + 3, Line);
            int hh = (int)t / 3600 % 24, mm = (int)t / 60 % 60;
            page.Text($"{hh:00}:{mm:00}", x - 10, top + rows.Count * laneH + 5, 6.5f, color: Gray);
        }
        for (int r = 0; r < rows.Count; r++)
        {
            float y = top + r * laneH;
            var color = Lanes[Math.Max(0, order.IndexOf(rows[r].label)) % Lanes.Length];
            page.Rect(M, y + 5, 6, 8, color, 2);
            page.Text(rows[r].label, M + 10, y + 5, 7.5f, bold: true, color: Ink, maxWidth: labelW - 14);
            foreach (var clip in rows[r].clips)
            {
                double s = clip.TcSeconds!.Value;
                float x = XFor(s), xe = XFor(s + Math.Max(clip.Duration ?? 0, 1));
                page.Rect(x, y + 4, Math.Max(xe - x, 1.2f), laneH - 8, color, 1.5f);
            }
        }
        page.Y = top + h + 6;
        var notes = new List<string>();
        for (int i = 0; i < rows.Count; i++)
            for (int j = i + 1; j < rows.Count; j++)
            {
                double overlap = 0;
                foreach (var a in rows[i].clips)
                    foreach (var b in rows[j].clips)
                    {
                        double s = Math.Max(a.TcSeconds!.Value, b.TcSeconds!.Value);
                        double e = Math.Min(a.TcSeconds!.Value + (a.Duration ?? 0), b.TcSeconds!.Value + (b.Duration ?? 0));
                        if (e > s) overlap += e - s;
                    }
                if (overlap >= 1) notes.Add($"{rows[i].label} + {rows[j].label} : {DurationText(overlap)} en commun");
            }
        int missing = order.Sum(l => bySource[l].Count(x => x.TcSeconds == null));
        if (notes.Count > 0)
        {
            page.Text("Tournés en même temps — " + string.Join("  ·  ", notes), M, page.Y, 7.5f, color: Ink, maxWidth: W - 2 * M, truncateEnd: true);
            page.Y += 12;
        }
        page.Text("Les clips calés sur le même TC (jam-sync / boîtier) se synchronisent au timecode dans Premiere ou DaVinci." +
                  (missing > 0 ? $" {missing} clip(s) sans TC : synchro au son." : ""), M, page.Y, 7, color: Gray, maxWidth: W - 2 * M, truncateEnd: true);
        page.Y += 22;
    }
}

/// Tri « naturel » (C0002 avant C0010), comme le Finder
public sealed class NaturalComparer : IComparer<string>
{
    public static readonly NaturalComparer Instance = new();
    public int Compare(string? a, string? b)
    {
        a ??= ""; b ??= "";
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsDigit(a[i]) && char.IsDigit(b[j]))
            {
                int si = i, sj = j;
                while (i < a.Length && char.IsDigit(a[i])) i++;
                while (j < b.Length && char.IsDigit(b[j])) j++;
                var na = a[si..i].TrimStart('0'); var nb = b[sj..j].TrimStart('0');
                if (na.Length != nb.Length) return na.Length.CompareTo(nb.Length);
                int c = string.CompareOrdinal(na, nb);
                if (c != 0) return c;
            }
            else
            {
                int c = char.ToUpperInvariant(a[i]).CompareTo(char.ToUpperInvariant(b[j]));
                if (c != 0) return c;
                i++; j++;
            }
        }
        return (a.Length - i).CompareTo(b.Length - j);
    }
}
