// Tests automatiques du moteur C-SAFE pour Windows (lancés par GitHub sur un vrai PC Windows à chaque version).
// Mêmes vérifications que les tests Mac : copie vers 2 disques, vérification, doublons, numérotation,
// MHL, rapports, PDF (vignettes + timecode), fichiers masqués, annulation, compatibilité Mac ↔ PC.

using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using CSafe.Core;

int fails = 0, oks = 0;
void Check(bool ok, string what)
{
    if (ok) { oks++; Console.WriteLine($"TEST OK   {what}"); }
    else { fails++; Console.WriteLine($"TEST ÉCHEC {what}"); }
}

var here = Directory.GetCurrentDirectory();
var fixtures = Path.Combine(here, "Tests", "fixtures");
var media = Path.Combine(here, "media");
var outDir = Path.Combine(here, "exemples");
Directory.CreateDirectory(outDir);
var baseDir = Path.Combine(Path.GetTempPath(), "csafe-test-" + Guid.NewGuid().ToString("N")[..8]);
Directory.CreateDirectory(baseDir);
var d1 = Path.Combine(baseDir, "SSD1");
var d2 = Path.Combine(baseDir, "SSD2");
Directory.CreateDirectory(d1);
Directory.CreateDirectory(d2);
var dests = new List<string> { d1, d2 };

void MakeFile(string path, int mb, int seed)
{
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    var rnd = new Random(seed);
    var block = new byte[1 << 20];
    using var f = File.Create(path);
    for (int i = 0; i < mb; i++) { rnd.NextBytes(block); f.Write(block); }
}
void Touch(string path, string text = "x")
{
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    File.WriteAllText(path, text);
}

OffloadResult RunJob(string card, string label, string day, bool force = false, int? n = null, HashKind kind = HashKind.Xxh64,
                     Action<OffloadJob>? onStart = null, List<string>? logs = null)
{
    OffloadResult? res = null;
    OffloadJob? job = null;
    job = new OffloadJob(card, dests, "Tournage été", label, day, force, n, ev =>
    {
        if (ev is OffloadEvent.Finished f) res = f.Result;
        if (ev is OffloadEvent.Log l) logs?.Add(l.Text);
        if (ev is OffloadEvent.Progress p && p.Phase == "Copie" && p.Done > 50L * 1024 * 1024) onStart?.Invoke(job!);
    }) { HashKind = kind };
    job.Run();
    return res!;
}

// ---------- 1. Noms et règles (identiques au Mac) ----------
Check(Naming.Sanitize("Été 2026 à Paris !") == "Ete-2026-a-Paris", $"nom de projet sûr : « {Naming.Sanitize("Été 2026 à Paris !")} »");
Check(Naming.Label("a", "FX3") == "CamA_FX3" && Naming.Label("SON") == "SON" && Naming.Label("hf3") == "HF3" && Naming.Label("Drone", "Mavic 3") == "Drone_Mavic-3",
      "étiquettes CamA_FX3, SON, HF3, Drone_Mavic-3");
var dp = Naming.DayPlan("2026-10-20", new() { [1] = "2026-10-18", [2] = "2026-10-19" });
Check(dp.J == 3 && !dp.Existing, "jour suivant → J3");
var dp2 = Naming.DayPlan("2026-10-17", new() { [1] = "2026-10-18", [2] = "2026-10-19" });
Check(dp2.J == 1 && dp2.Shifted.Count == 2, "date plus ancienne : J1 et décalage des jours suivants");
Check(Naming.DayPlan("2026-11-05", new(), 7).J == 7, "jour choisi à la main : J7");

// ---------- 2. Empreintes ----------
string Xx(byte[] d) { var h = new FileHasher(HashKind.Xxh64); h.Update(d); return h.Hex(); }
var big = new byte[1000003];
for (int i = 0; i < big.Length; i++) big[i] = (byte)(i % 251);
Check(Xx(Array.Empty<byte>()) == "ef46db3751d8e999" && Xx(Encoding.ASCII.GetBytes("abc")) == "44bc2cf5ad770999" && Xx(big) == "a72f178960c4e5bd",
      "xxHash64 identique à l'algorithme officiel (vide, « abc », 1 Mo)");
var sw = Stopwatch.StartNew();
var buf = new byte[256 << 20];
new Random(1).NextBytes(buf);
sw.Restart();
var hh = new FileHasher(HashKind.Xxh64); hh.Update(buf); hh.Hex();
var xxSpeed = 256 / Math.Max(sw.Elapsed.TotalSeconds, 0.001);
Console.WriteLine($"MESURE    xxHash64 : {xxSpeed:0} Mo/s");
Check(xxSpeed > 1500, $"xxHash64 rapide : {xxSpeed:0} Mo/s");

// ---------- 3. Compatibilité Mac ↔ PC (même empreinte de carte, mêmes données de rapport) ----------
var sig = OffloadJob.Signature(new() { new("x", "A/B.MP4", 10, 1700000000), new("y", "C.XML", 5, 1700000001) });
var sig2 = OffloadJob.SignatureV2(new() { new("x", "A/B.MP4", 10, 1700000000), new("y", "C.XML", 5, 1700000001) });
Check(sig == "bde684b51153637b4fab78747c157017" && sig2 == "6ef6941bad273c574709052884d86a57", "empreinte de carte identique à la version Mac");
var macJson = "{\"project\":\"P\",\"day\":\"J1_2026-11-09\",\"display\":\"J1_2026-11-09/CamA_FX2/CamA_FX2_Carte01\",\"label\":\"CamA_FX2\",\"cardName\":\"Untitled\",\"date\":\"2026-11-09 22:14\",\"files\":2,\"totalBytes\":100,\"seconds\":5,\"speed\":20,\"hash\":\"xxHash64\",\"verified\":true,\"destinations\":[\"OK · /Volumes/X10 Pro/P/J1\"],\"clips\":[{\"name\":\"C0001.MP4\",\"size\":50,\"kind\":\"vidéo\",\"duration\":3,\"hash\":\"abcd\",\"thumb\":\"/9j/4AAQ\",\"tcFrames\":923263,\"tcRate\":25,\"tcDrop\":false}],\"extraFiles\":0}";
var cdj = System.Text.Json.JsonSerializer.Deserialize<PdfReport.CardData>(macJson, new System.Text.Json.JsonSerializerOptions { PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase });
Check(cdj?.Clips[0].TcIn == "10:15:30:13" && cdj.Clips[0].Thumb?.Length == 6, $"rapport écrit par le Mac relu sur PC (TC {cdj?.Clips[0].TcIn})");

// ---------- 4. Timecode ----------
Check(TC.Format(90_000, 25, false) == "01:00:00:00", "TC 25p : 90 000 images = 01:00:00:00");
Check(TC.Format(1800, 30, true) == "00:01:00;02", "TC 29,97 drop-frame : 1800 images = 00:01:00;02");
Check(TC.Frames(0, 1, 0, 2, 30, true) == 1800, "TC drop-frame aller-retour");
var xdir = Path.Combine(baseDir, "XMLTEST");
Directory.CreateDirectory(xdir);
File.Copy(Path.Combine(fixtures, "C0001M01.XML"), Path.Combine(xdir, "C0001M01.XML"));
Touch(Path.Combine(xdir, "C0001.MP4"));
var sx = MediaProbe.SonyXML(Path.Combine(xdir, "C0001.MP4"));
var sxTC = sx != null ? TC.Format(sx.Frames, sx.Rate, sx.Drop) : "?";
Check(sxTC == "10:16:29:13" && sx?.Camera == "Sony ILME-FX2" && sx?.Lens == "FE 70-200mm F2.8 GM OSS II" && sx?.Slowmo == "Ralenti ×4 (100p)",
      $"XML Sony FX2 : TC {sxTC}, {sx?.Camera}, {sx?.Lens}, {sx?.Slowmo}");
Check(!PdfReport.IsClip("PRIVATE/M4ROOT/THMBNL/C0001T01.JPG", new() { "C0001" }) && !PdfReport.IsClip("DCIM/C0001T01.JPG", new() { "C0001" })
      && PdfReport.IsClip("PRIVATE/M4ROOT/CLIP/C0001.MP4", new() { "C0001" }) && PdfReport.IsClip("DCIM/100MSDCF/DSC00012.JPG", new() { "C0001" }),
      "vignettes caméra (THMBNL, …T01.JPG) exclues des clips, vraies photos gardées");

// ---------- 5. Reconnaissance des cartes ----------
var card = Path.Combine(baseDir, "CARTE_SONY");
MakeFile(Path.Combine(card, "PRIVATE", "M4ROOT", "CLIP", "C0001.MP4"), 300, 1);
MakeFile(Path.Combine(card, "PRIVATE", "M4ROOT", "CLIP", "C0002.MP4"), 180, 2);
Touch(Path.Combine(card, "PRIVATE", "M4ROOT", "CLIP", "C0001M01.XML"), File.ReadAllText(Path.Combine(fixtures, "C0001M01.XML")));
Touch(Path.Combine(card, "PRIVATE", "M4ROOT", "THMBNL", "C0001T01.JPG"));
Touch(Path.Combine(card, "AVF_INFO", "AVIN0001.BNP"));
new DirectoryInfo(Path.Combine(card, "AVF_INFO")).Attributes |= FileAttributes.Hidden;
Check(OffloadJob.LooksLikeCameraCard(card) && OffloadJob.CameraKind(card) == "Sony XAVC", "carte Sony reconnue (Sony XAVC)");
Directory.CreateDirectory(Path.Combine(d1, "Ancien", Naming.ReportDir));
Check(!OffloadJob.LooksLikeCameraCard(d1), "disque de sauvegarde C-SAFE jamais pris pour une carte");
var son = Path.Combine(baseDir, "CARTE_SON");
Touch(Path.Combine(son, "FOLDER01", "TAKE01", "S01T01.WAV"));
Check(OffloadJob.LooksLikeCameraCard(son), "carte d'enregistreur son (WAV deux niveaux plus bas) reconnue");

// ---------- 6. Copie vers 2 disques + vérification ----------
var logs1 = new List<string>();
sw.Restart();
var r1 = RunJob(card, "CamA_FX2", "J1_2026-10-18", logs: logs1);
var secs = sw.Elapsed.TotalSeconds;
Check(r1.Ok, $"copie vérifiée sur 2 disques : {r1.Message}");
Console.WriteLine($"MESURE    480 Mo vers 2 disques + vérification en {secs:0.0} s");
var c1 = Path.Combine(d1, "Tournage-ete", "J1_2026-10-18", "CamA_FX2", "CamA_FX2_Carte01");
var c2 = Path.Combine(d2, "Tournage-ete", "J1_2026-10-18", "CamA_FX2", "CamA_FX2_Carte01");
string FileMd5(string p) { using var f = File.OpenRead(p); return Convert.ToHexString(MD5.HashData(f)); }
Check(File.Exists(Path.Combine(c1, "PRIVATE", "M4ROOT", "CLIP", "C0001.MP4")) && File.Exists(Path.Combine(c2, "PRIVATE", "M4ROOT", "CLIP", "C0002.MP4"))
      && FileMd5(Path.Combine(card, "PRIVATE", "M4ROOT", "CLIP", "C0001.MP4")) == FileMd5(Path.Combine(c2, "PRIVATE", "M4ROOT", "CLIP", "C0001.MP4")),
      "fichiers identiques à la carte sur les 2 disques (contrôle MD5 indépendant)");
Check(!Directory.EnumerateFiles(Path.Combine(d1, "Tournage-ete"), "*.partial", SearchOption.AllDirectories).Any(), "aucun fichier .partial restant");
Check(new DirectoryInfo(Path.Combine(c1, "AVF_INFO")).Attributes.HasFlag(FileAttributes.Hidden), "AVF_INFO masqué sur la carte reste masqué dans la copie");
Check(File.GetLastWriteTimeUtc(Path.Combine(c1, "PRIVATE", "M4ROOT", "CLIP", "C0001.MP4")) == File.GetLastWriteTimeUtc(Path.Combine(card, "PRIVATE", "M4ROOT", "CLIP", "C0001.MP4")),
      "date de modification d'origine gardée");
var rd = Path.Combine(d1, "Tournage-ete", Naming.ReportDir);
var reports = Naming.List(rd);
var mhl = reports.FirstOrDefault(x => x.EndsWith(".mhl"));
Check(reports.Any(x => x == "J1_2026-10-18_CamA_FX2_Carte01_rapport.pdf") && reports.Any(x => x == "J1_2026-10-18_CamA_FX2_Carte01_rapport.txt") && mhl != null,
      $"Rapports_de_copie : PDF + .mhl + .txt ({string.Join(", ", reports.OrderBy(x => x))})");
var mhlText = mhl != null ? File.ReadAllText(Path.Combine(rd, mhl)) : "";
Check(mhlText.Contains("<xxhash64be>") && mhlText.Contains("<file>../J1_2026-10-18/CamA_FX2/CamA_FX2_Carte01/PRIVATE/M4ROOT/CLIP/C0001.MP4</file>"), "MHL 1.1 avec chemins relatifs et xxhash64be");
var pdfHead = File.Exists(Path.Combine(rd, "J1_2026-10-18_CamA_FX2_Carte01_rapport.pdf")) ? File.ReadAllBytes(Path.Combine(rd, "J1_2026-10-18_CamA_FX2_Carte01_rapport.pdf"))[..5] : Array.Empty<byte>();
Check(Encoding.ASCII.GetString(pdfHead) == "%PDF-", "le rapport PDF est un vrai PDF");
Check(File.Exists(History.Url(Path.Combine(d1, "Tournage-ete"))) && new DirectoryInfo(Path.Combine(rd, Naming.HiddenDir)).Attributes.HasFlag(FileAttributes.Hidden),
      "historique dans le dossier masqué .C-SAFE");
Check(logs1.Any(l => l.StartsWith("Maillon le plus lent")), "vitesse de chaque maillon notée dans le journal");

// ---------- 7. Doublons, copie forcée, suppression ----------
var r2 = RunJob(card, "CamA_FX2", "J1_2026-10-18");
Check(r2.Duplicate && r2.Message.Contains("déjà été copiée"), $"doublon détecté : {r2.Message}");
var r3 = RunJob(card, "CamA_FX2", "J1_2026-10-18", force: true);
Check(r3.Ok && r3.Display.EndsWith("CamA_FX2_Carte02"), $"copie forcée sous un nouveau numéro ({r3.Display})");
var r4 = RunJob(card, "CamA_FX3", "J1_2026-10-18", force: true);
Check(!r4.Ok && r4.Message.Contains("deux modèles"), "CamA_FX3 refusée le jour où CamA_FX2 existe");
foreach (var d in dests) Directory.Delete(Path.Combine(d, "Tournage-ete", "J1_2026-10-18", "CamA_FX2", "CamA_FX2_Carte02"), true);
Check(Naming.MakePlan(dests, "Tournage été", "J1_2026-10-18", "CamA_FX2").Display.EndsWith("_Carte02"), "numéro libéré après suppression");

// ---------- 8. MD5, son, HF ----------
var r5 = RunJob(son, "SON", "J1_2026-10-18", kind: HashKind.Md5);
Check(r5.Ok && r5.Display == "J1_2026-10-18/SON", $"carte son copiée directement dans SON ({r5.Display})");
var mhl5 = Naming.List(rd).Where(x => x.EndsWith(".mhl") && x.Contains("_SON_")).Select(x => File.ReadAllText(Path.Combine(rd, x))).FirstOrDefault() ?? "";
Check(mhl5.Contains("<md5>"), "MHL en MD5 quand le MD5 est choisi");

// ---------- 9. Annulation : dossier marqué _INCOMPLET ----------
var card2 = Path.Combine(baseDir, "CARTE_LONGUE");
MakeFile(Path.Combine(card2, "DCIM", "100GOPRO", "GX010001.MP4"), 400, 3);
var r6 = RunJob(card2, "CamB_GoPro", "J1_2026-10-18", onStart: j => j.Cancel.Set());
var incomplete = Naming.List(Path.Combine(d1, "Tournage-ete", "J1_2026-10-18", "CamB_GoPro"));
Check(r6.Cancelled && incomplete.Any(x => x.Contains("_INCOMPLET_")), $"copie annulée → dossier « _INCOMPLET » ({string.Join(", ", incomplete)})");
Check(Naming.MakePlan(dests, "Tournage été", "J1_2026-10-18", "CamB_GoPro").Display.EndsWith("CamB_GoPro_Carte01"), "un dossier incomplet ne compte pas comme copie");

// ---------- 10. Vraies vidéos (fabriquées par ffmpeg) : timecode, vignettes, synchro ----------
if (File.Exists(Path.Combine(media, "a1.mp4")))
{
    var day3 = "J3_2026-10-20";
    var sCard = Path.Combine(baseDir, "CARTE_FX2");
    var sClip = Path.Combine(sCard, "PRIVATE", "M4ROOT", "CLIP");
    var sThumb = Path.Combine(sCard, "PRIVATE", "M4ROOT", "THMBNL");
    Directory.CreateDirectory(sClip); Directory.CreateDirectory(sThumb);
    var xml = File.ReadAllText(Path.Combine(fixtures, "C0001M01.XML"));
    var values = new[] { "13291610", "00002010", "00102410" };
    for (int i = 0; i < 3; i++)
    {
        var n = $"C{i + 1:0000}";
        File.Copy(Path.Combine(media, $"a{i + 1}.mp4"), Path.Combine(sClip, n + ".MP4"));
        File.WriteAllText(Path.Combine(sClip, n + "M01.XML"), xml.Replace("13291610", values[i]).Replace("100.00p", i == 0 ? "100.00p" : "25.00p"));
        File.Copy(Path.Combine(media, "thumb.jpg"), Path.Combine(sThumb, n + "T01.JPG"));
    }
    var bCard = Path.Combine(baseDir, "CARTE_FX3");
    Directory.CreateDirectory(Path.Combine(bCard, "DCIM"));
    File.Copy(Path.Combine(media, "b1.mov"), Path.Combine(bCard, "DCIM", "B001.MOV"));
    File.Copy(Path.Combine(media, "b2.mov"), Path.Combine(bCard, "DCIM", "B002.MOV"));
    var aCard = Path.Combine(baseDir, "CARTE_F8");
    Directory.CreateDirectory(Path.Combine(aCard, "FOLDER01"));
    File.Copy(Path.Combine(media, "son.wav"), Path.Combine(aCard, "FOLDER01", "S01T01.WAV"));
    var pCard = Path.Combine(baseDir, "CARTE_PHOTO");
    Directory.CreateDirectory(Path.Combine(pCard, "DCIM", "100MSDCF"));
    File.Copy(Path.Combine(media, "photo.jpg"), Path.Combine(pCard, "DCIM", "100MSDCF", "DSC00001.JPG"));

    var res = new Dictionary<string, OffloadResult>();
    foreach (var (c, l) in new[] { (sCard, "CamA_FX2"), (bCard, "CamB_FX3"), (aCard, "SON"), (pCard, "CamC_Photo") })
        res[l] = RunJob(c, l, day3);
    Check(res.Values.All(r => r.Ok), "4 cartes de test copiées (FX2, FX3, son, photo)");
    var cards3 = PdfReport.SavedCards(Path.Combine(d1, "Tournage-ete")).Where(c => c.Day == day3).ToList();
    var camA = cards3.FirstOrDefault(c => c.Label == "CamA_FX2");
    var a1 = camA?.Clips.FirstOrDefault(c => c.Name.EndsWith("C0001.MP4"));
    Check(camA?.Clips.Count == 3 && a1?.Thumb != null && a1.TcIn == "10:16:29:13" && a1.Camera == "Sony ILME-FX2" && a1.Resolution == "1920×1080" && a1.Duration > 2,
          $"carte FX2 : 3 clips (vignettes THMBNL à part), TC {a1?.TcIn} → {a1?.TcOut}, {a1?.Camera}, {a1?.Resolution}, {a1?.Fps}, {a1?.Codec}, {a1?.Note}");
    var b1 = cards3.FirstOrDefault(c => c.Label == "CamB_FX3")?.Clips.FirstOrDefault(c => c.Name.EndsWith("B001.MOV"));
    Check(b1?.TcIn == "10:16:31:00" && b1.Thumb != null, $"piste timecode du MOV lue : {b1?.TcIn} → {b1?.TcOut}");
    var s1 = cards3.FirstOrDefault(c => c.Label == "SON")?.Clips.FirstOrDefault();
    Check(s1?.TcIn == "10:16:28:00" && s1.Duration > 9, $"timecode du son (BWF) lu : {s1?.TcIn} · {s1?.Codec} · {s1?.Duration:0.0} s");
    var p1 = cards3.FirstOrDefault(c => c.Label == "CamC_Photo")?.Clips.FirstOrDefault();
    Check(p1?.Thumb != null && p1.Resolution != null, $"photo : vignette et résolution ({p1?.Resolution})");
    if (res["CamA_FX2"].ReportPDF is string u) File.Copy(u, Path.Combine(outDir, "exemple-rapport-carte-PC.pdf"), true);
    var dayPdf = PdfReport.DayReport(Path.Combine(d1, "Tournage-ete"), day3);
    Check(dayPdf != null && new FileInfo(dayPdf).Length > 5000, "rapport du jour avec frise de synchro");
    if (dayPdf != null) File.Copy(dayPdf, Path.Combine(outDir, "exemple-rapport-du-jour-PC.pdf"), true);
}
else Console.WriteLine("::warning title=TEST::ffmpeg absent, pas de vraies vidéos");

// ---------- 11. Rapport du jour J1 ----------
var day1 = PdfReport.DayReport(Path.Combine(d1, "Tournage-ete"), "J1_2026-10-18");
Check(day1 != null && PdfReport.SavedCardCount(Path.Combine(d1, "Tournage-ete"), "J1_2026-10-18") >= 2, "rapport du jour J1 en un seul PDF");

// Dossier de démonstration pour la capture d'écran de l'app
var demoCard = Path.Combine(here, "demo", "SONY_FX3");
MakeFile(Path.Combine(demoCard, "PRIVATE", "M4ROOT", "CLIP", "C0042.MP4"), 2, 9);
Directory.CreateDirectory(Path.Combine(here, "demo", "SSD_Samsung_T9"));
Directory.CreateDirectory(Path.Combine(here, "demo", "LaCie_Rugged"));

try { Directory.Delete(baseDir, true); } catch { }
Console.WriteLine(fails == 0 ? $"BILAN tous les tests sont passés ({oks})" : $"BILAN {fails} test(s) en échec sur {oks + fails}");
return fails == 0 ? 0 : 1;
