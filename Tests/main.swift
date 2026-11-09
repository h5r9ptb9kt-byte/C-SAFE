//
//  Test automatique du moteur C-SAFE (lancé par GitHub sur un vrai Mac à chaque version).
//  - copie une fausse carte de ~2 Go vers 2 disques, mesure mémoire et vitesse
//  - vérifie : doublon détecté, copie mise à la corbeille → numéro réutilisé, plus de doublon
//

import Foundation

let fm = FileManager.default
let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("csafe-test-\(UUID().uuidString)")
let card = base.appendingPathComponent("EOS_DIGITAL")
let clips = card.appendingPathComponent("PRIVATE/M4ROOT/CLIP")
let d1 = base.appendingPathComponent("SSD1")
let d2 = base.appendingPathComponent("SSD2")
try! fm.createDirectory(at: clips, withIntermediateDirectories: true)
try! fm.createDirectory(at: d1, withIntermediateDirectories: true)
try! fm.createDirectory(at: d2, withIntermediateDirectories: true)

func makeFile(_ url: URL, mb: Int) {
    fm.createFile(atPath: url.path, contents: nil)
    let h = try! FileHandle(forWritingTo: url)
    var block = Data(count: 1 << 20)
    for _ in 0..<mb {
        block.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, 1 << 20) }
        try! h.write(contentsOf: block)
    }
    try! h.close()
}
makeFile(clips.appendingPathComponent("C0001.MP4"), mb: 900)
makeFile(clips.appendingPathComponent("C0002.MP4"), mb: 700)
makeFile(clips.appendingPathComponent("C0003.MP4"), mb: 400)
try! "<xml/>".write(to: clips.appendingPathComponent("C0001M01.XML"), atomically: true, encoding: .utf8)

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "TEST OK   \(what)" : "TEST ÉCHEC \(what)")
    if !ok { failures += 1 }
}

func maxRSSMB() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_maxrss) / 1_048_576   // octets sur macOS
}

func run(force: Bool = false) -> OffloadResult {
    var result: OffloadResult?
    let job = OffloadJob(source: card, destinations: [d1, d2], project: "Tournage été", label: "CamA_FX3",
                         day: "J1_2026-10-18", force: force) { ev in
        if case .finished(let r) = ev { result = r }
    }
    job.run()
    return result!
}

check(OffloadJob.cameraKind(card) == "Sony XAVC", "marque reconnue : \(OffloadJob.cameraKind(card) ?? "aucune")")
check(OffloadJob.looksLikeCameraCard(card), "carte caméra reconnue")
check(!OffloadJob.looksLikeCameraCard(d1), "disque vide non pris pour une carte")

// 1. Copie complète
let t0 = Date()
let r1 = run()
let secs = Date().timeIntervalSince(t0)
print("RESULTAT copie : ok=\(r1.ok) dossier=\(r1.display) — \(r1.message)")
print(String(format: "MESURE durée totale (copie + vérification) %.1f s · débit carte %.0f Mo/s · mémoire max %.0f Mo",
             secs, 2000 / secs, maxRSSMB()))
check(r1.message.contains("Maillon le plus lent"), "goulot de vitesse indiqué : \(r1.message.components(separatedBy: "Maillon").last ?? "")")
check(r1.ok, "copie et vérification de 2 Go sur 2 disques")
check(r1.display == "J1_2026-10-18/CamA_FX3/CamA_FX3_Carte01", "nom du dossier (\(r1.display))")
check(maxRSSMB() < 400, String(format: "mémoire stable (%.0f Mo max, limite 400 Mo)", maxRSSMB()))
let copied = d2.appendingPathComponent("Tournage-ete/J1_2026-10-18/CamA_FX3/CamA_FX3_Carte01/PRIVATE/M4ROOT/CLIP/C0002.MP4")
check(fm.fileExists(atPath: copied.path), "arborescence caméra conservée sur le disque 2")
let cardFolder = d2.appendingPathComponent("Tournage-ete/J1_2026-10-18/CamA_FX3/CamA_FX3_Carte01")
let inCard = (try? fm.contentsOfDirectory(atPath: cardFolder.path)) ?? []
check(inCard == ["PRIVATE"], "dossier de carte identique à la carte, aucun fichier ajouté (\(inCard))")
let reports = (try? fm.contentsOfDirectory(atPath: d2.appendingPathComponent("Tournage-ete/Rapports_de_copie").path)) ?? []
check(reports.contains { $0.hasSuffix(".mhl") } && reports.contains { $0.hasSuffix("_rapport.pdf") } && reports.contains { $0.hasSuffix("_rapport.txt") },
      "Rapports_de_copie : PDF + .mhl + .txt (\(reports.sorted()))")
check(!reports.contains { $0.hasSuffix(".json") || $0.hasSuffix(".xxh64") }, "fichiers techniques (.json, .xxh64) rangés à part")
let hiddenItems = (try? fm.contentsOfDirectory(atPath: d2.appendingPathComponent("Tournage-ete/Rapports_de_copie/.C-SAFE").path)) ?? []
check(hiddenItems.contains(Naming.historyFile) && !hiddenItems.contains { $0.hasSuffix(".xxh64") },
      "historique dans le dossier masqué .C-SAFE, plus de .xxh64 en doublon du .mhl (\(hiddenItems.sorted()))")
if let pdfName = reports.first(where: { $0.hasSuffix("_rapport.pdf") }),
   let head = try? FileHandle(forReadingFrom: d2.appendingPathComponent("Tournage-ete/Rapports_de_copie/\(pdfName)")).read(upToCount: 5) {
    check(String(data: head, encoding: .ascii) == "%PDF-", "le rapport PDF est un vrai PDF")
}
check(r1.reportPDF != nil, "le résultat donne le lien du PDF")
let mhlName = reports.first { $0.hasSuffix(".mhl") } ?? ""
let mhlText = (try? String(contentsOf: d2.appendingPathComponent("Tournage-ete/Rapports_de_copie/\(mhlName)"), encoding: .utf8)) ?? ""
check(mhlText.contains("<xxhash64be>"), "MHL en xxHash64 par défaut")
let projectItems = ((try? fm.contentsOfDirectory(atPath: d2.appendingPathComponent("Tournage-ete").path)) ?? []).sorted()
check(projectItems.last == "Rapports_de_copie", "Rapports_de_copie rangé après les jours (\(projectItems))")

let srcDate = (try? fm.attributesOfItem(atPath: clips.path))?[.modificationDate] as? Date
let dstDate = (try? fm.attributesOfItem(atPath: cardFolder.appendingPathComponent("PRIVATE/M4ROOT/CLIP").path))?[.modificationDate] as? Date
let dateGap = (srcDate != nil && dstDate != nil) ? abs(srcDate!.timeIntervalSince(dstDate!)) : 999
check(dateGap < 1, String(format: "dossiers copiés avec leur date d'origine (écart %.6f s)", dateGap))

let prev = OffloadJob.findPreviousCopy(signatures: OffloadJob.cardSignatures(card), destinations: [d1, d2])
check(prev?.short.contains("CamA_FX3_Carte01") == true && prev?.disks.isEmpty == false,
      "carte branchée reconnue comme déjà copiée, avec l'endroit : \(prev?.short ?? "rien")")

// 2. Même carte rebranchée → doublon signalé
let r2 = run()
check(r2.duplicate, "carte déjà copiée détectée")
print("RESULTAT message doublon : \(r2.message)")
check(r2.message.contains("CamA_FX3_Carte01") && r2.message.contains("disque"), "le message dit où et sur quel disque")
// même carte renommée → toujours reconnue (par le contenu et le poids des fichiers)
let renamed = base.appendingPathComponent("Untitled")
try! fm.moveItem(at: card, to: renamed)
var r2b: OffloadResult?
OffloadJob(source: renamed, destinations: [d1, d2], project: "Autre projet", label: "CamB_FX5", day: "J2_2026-10-19", force: false) { ev in
    if case .finished(let r) = ev { r2b = r }
}.run()
check(r2b?.duplicate == true, "carte renommée, autre projet et autre jour : toujours reconnue")
try! fm.moveItem(at: renamed, to: card)

// 3. Copie mise à la corbeille sur les deux disques → plus de doublon, numéro 01 réutilisé
for d in [d1, d2] {
    try? fm.removeItem(at: d.appendingPathComponent("Tournage-ete/J1_2026-10-18/CamA_FX3/CamA_FX3_Carte01"))
}
let plan = Naming.plan(destinations: [d1, d2], project: "Tournage été", day: "J1_2026-10-18", label: "CamA_FX3")
check(plan.display.hasSuffix("CamA_FX3_Carte01"), "numéro libéré après suppression (\(plan.display))")
let done = Naming.doneSources(destinations: [d1, d2], project: "Tournage été", day: "J1_2026-10-18", sources: ["CamA"])
check(done.isEmpty, "CamA redevient disponible après suppression")
let r3 = run()
check(r3.ok && !r3.duplicate && r3.display.hasSuffix("CamA_FX3_Carte01"), "recopie possible après suppression (\(r3.display))")

// 5. Deux copies simultanées vers les mêmes disques
func makeCard(_ name: String, mb: Int) -> URL {
    let c = base.appendingPathComponent(name)
    let dir = c.appendingPathComponent("DCIM/100GOPRO")
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    makeFile(dir.appendingPathComponent("GX010001.MP4"), mb: mb)
    return c
}
let cardB = makeCard("GOPRO_B", mb: 600)
let cardC = makeCard("GOPRO_C", mb: 500)
var rB: OffloadResult?, rC: OffloadResult?
let group = DispatchGroup()
let tPar = Date()
for (c, lab) in [(cardB, "CamB_GoPro"), (cardC, "CamC_GoPro")] {
    group.enter()
    DispatchQueue.global().async {
        OffloadJob(source: c, destinations: [d1, d2], project: "Tournage été", label: lab, day: "J1_2026-10-18", force: false) { ev in
            if case .finished(let r) = ev { if lab == "CamB_GoPro" { rB = r } else { rC = r } }
        }.run()
        group.leave()
    }
}
group.wait()
print(String(format: "MESURE 2 copies simultanées (1,1 Go) : %.1f s · mémoire max %.0f Mo", Date().timeIntervalSince(tPar), maxRSSMB()))
check(rB?.ok == true && rC?.ok == true, "2 copies simultanées réussies sur le même disque (\(rB?.display ?? "?") + \(rC?.display ?? "?"))")
let histAll = History.load(d1.appendingPathComponent("Tournage-ete"))
let sigB = OffloadJob.signature(try! OffloadJob.scan(cardB)), sigC = OffloadJob.signature(try! OffloadJob.scan(cardC))
check(histAll[sigB] != nil && histAll[sigC] != nil, "historique complet après copies simultanées")
check(maxRSSMB() < 400, String(format: "mémoire stable avec 2 copies simultanées (%.0f Mo)", maxRSSMB()))

// 6. Numéro de carte choisi à la main : la n°2 copiée avant la n°1 reste dans l'ordre
let cardN2 = makeCard("CARTE_N2", mb: 50), cardN1 = makeCard("CARTE_N1", mb: 40)
var rN2: OffloadResult?, rN1: OffloadResult?
OffloadJob(source: cardN2, destinations: [d1, d2], project: "Tournage été", label: "CamD_FX5", day: "J1_2026-10-18",
           force: false, cardNumber: 2) { ev in if case .finished(let r) = ev { rN2 = r } }.run()
let usedAfter2 = Naming.usedCardNumbers(destinations: [d1, d2], project: "Tournage été", day: "J1_2026-10-18", label: "CamD_FX5")
OffloadJob(source: cardN1, destinations: [d1, d2], project: "Tournage été", label: "CamD_FX5", day: "J1_2026-10-18",
           force: false, cardNumber: 1) { ev in if case .finished(let r) = ev { rN1 = r } }.run()
check(rN2?.display.hasSuffix("CamD_FX5_Carte02") == true && rN1?.display.hasSuffix("CamD_FX5_Carte01") == true && usedAfter2 == [2],
      "carte n°2 copiée avant la n°1 : \(rN2?.display ?? "?") puis \(rN1?.display ?? "?")")

check(Naming.doneCardNumbers(destinations: [d1, d2], project: "Tournage été", day: "J1_2026-10-18", source: "CamD") == [1, 2],
      "pastille « CamD · n°1, 2 »")

// 7. Une lettre de caméra = un seul modèle par jour ; plusieurs lettres peuvent avoir le même modèle
let PJ = "Tournage été", J1 = "J1_2026-10-18"
check(Naming.dayLabels(destinations: [d1, d2], project: PJ, day: J1)["CamA"] == "CamA_FX3", "CamA verrouillée sur FX3 le J1")
check(Naming.conflictingLabel(destinations: [d1, d2], project: PJ, day: J1, label: "CamA_FX2") == "CamA_FX3", "CamA_FX2 refusée le J1 (CamA_FX3 existe)")
check(Naming.conflictingLabel(destinations: [d1, d2], project: PJ, day: J1, label: "CamA_FX3") == nil, "CamA_FX3 : carte suivante acceptée")
var rConf: OffloadResult?, rSame: OffloadResult?, rDay2: OffloadResult?
OffloadJob(source: makeCard("CARTE_CONFLIT", mb: 3), destinations: [d1, d2], project: PJ, label: "CamA_FX2", day: J1,
           force: false) { ev in if case .finished(let r) = ev { rConf = r } }.run()
check(rConf?.ok == false && rConf?.message.contains("deux modèles") == true, "moteur : CamA_FX2 bloquée le même jour (\(rConf?.message ?? "?"))")
check(!fm.fileExists(atPath: d1.appendingPathComponent("Tournage-ete/\(J1)/CamA_FX2").path), "aucun dossier CamA_FX2 créé")
OffloadJob(source: makeCard("CARTE_FX3_BIS", mb: 6), destinations: [d1, d2], project: PJ, label: "CamE_FX3", day: J1,
           force: false) { ev in if case .finished(let r) = ev { rSame = r } }.run()
check(rSame?.ok == true, "plusieurs FX3 le même jour : CamE_FX3 acceptée (\(rSame?.display ?? "?"))")
OffloadJob(source: makeCard("CARTE_J2", mb: 7), destinations: [d1, d2], project: PJ, label: "CamA_FX2", day: "J2_2026-10-19",
           force: false) { ev in if case .finished(let r) = ev { rDay2 = r } }.run()
check(rDay2?.ok == true && rDay2?.display.hasPrefix("J2_2026-10-19/CamA_FX2/") == true, "nouveau jour : CamA peut être une FX2 (\(rDay2?.display ?? "?"))")
check(Naming.conflictingLabel(destinations: [d1, d2], project: PJ, day: J1, label: "SON") == nil, "le son n'est pas concerné")

// 9. xxHash64 : valeurs de référence de l'algorithme officiel (bibliothèque xxhash)
func pattern(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }
let refs: [(Int, String)] = [(0, "ef46db3751d8e999"), (1, "a96c7f0ce858bbb7"), (3, "56e6957632a487f9"), (4, "c60d15b1e3ff8f04"),
    (7, "afbefc3d6c6f9a8e"), (8, "3da5c7aa269683e0"), (9, "4b17a9ba9e215c09"), (31, "4a74f3a1a39ad4a1"), (32, "8d57d6a4671cc43d"),
    (33, "62c9fd21ed857664"), (63, "5c320a0d2707057f"), (64, "7bbabbc45729d17e"), (100, "efa0ad2d3e70c151"),
    (1000, "99594f4828043d35"), (1048589, "5ef8192c1492aa4d")]
var xxOK = true
for (n, ref) in refs {
    var h = XXHash64(); h.update(data: pattern(n))
    var hs = XXHash64(); let d = pattern(n); var i = 0; var k = 1
    while i < n { let j = min(n, i + k); hs.update(data: d.subdata(in: i..<j)); i = j; k = k % 37 + 5 }
    if h.hexDigest() != ref || hs.hexDigest() != ref { xxOK = false; print("xxh64 \(n) : \(h.hexDigest()) / \(hs.hexDigest()) attendu \(ref)") }
}
var habc = XXHash64(); habc.update(data: Data("abc".utf8))
check(xxOK && habc.hexDigest() == "44bc2cf5ad770999", "xxHash64 identique à l'algorithme officiel (15 tailles, en un bloc et en morceaux)")
let big64 = pattern(256 * 1024 * 1024)
let tx = Date(); var hb = XXHash64(); hb.update(data: big64)
let xxRate = 256.0 / Date().timeIntervalSince(tx)
check(xxRate > 1500, String(format: "xxHash64 rapide : %.0f Mo/s", xxRate))

// 8. Reconnaissance des cartes : un disque de sauvegarde n'est jamais une source
func touch(_ u: URL) { try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); fm.createFile(atPath: u.path, contents: Data([1])) }
let vol = base.appendingPathComponent("VOLUMES")
let backup = vol.appendingPathComponent("TERRAMASTER")
touch(backup.appendingPathComponent("Film/J1_2026-10-18/CamA_FX3/CamA_FX3_Carte01/PRIVATE/M4ROOT/CLIP/C0001.MP4"))
try! fm.createDirectory(at: backup.appendingPathComponent("Film/\(Naming.reportDir)"), withIntermediateDirectories: true)
check(!OffloadJob.looksLikeCameraCard(backup), "disque de sauvegarde C-SAFE jamais pris pour une carte")
let archive = vol.appendingPathComponent("ARCHIVES")
touch(archive.appendingPathComponent("Films/2024/Vacances/clip.mp4"))
touch(archive.appendingPathComponent("MISC/notes.txt"))
check(!OffloadJob.looksLikeCameraCard(archive), "disque d'archives (vidéos rangées en profondeur, dossier MISC) pas pris pour une carte")
let zoom = vol.appendingPathComponent("ZOOM_F6")
touch(zoom.appendingPathComponent("FOLDER01/ZOOM0001/ZOOM0001_TR1.WAV"))
check(OffloadJob.looksLikeCameraCard(zoom), "carte d'enregistreur son (WAV deux niveaux plus bas) reconnue")
let bm = vol.appendingPathComponent("BMPCC")
touch(bm.appendingPathComponent("A001_C001.braw"))
check(OffloadJob.looksLikeCameraCard(bm), "carte Blackmagic (BRAW à la racine) reconnue")
check(OffloadJob.looksLikeCameraCard(card), "carte Sony toujours reconnue")
check(OffloadJob.insideCardNames.contains("M4ROOT") && OffloadJob.insideCardNames.contains("CLIP"), "dossiers internes de carte reconnus (M4ROOT, CLIP…)")
// Gros disque : 30 000 fichiers en profondeur, la détection doit rester instantanée
let big = vol.appendingPathComponent("GROS_DISQUE")
for i in 0..<300 { for j in 0..<100 { touch(big.appendingPathComponent("P\(i)/A/B/C/f\(j).mov")) } }
let tDet = Date()
let bigIsCard = OffloadJob.looksLikeCameraCard(big)
let detMs = Date().timeIntervalSince(tDet) * 1000
check(!bigIsCard && detMs < 300, String(format: "gros disque analysé en %.0f ms sans être pris pour une carte", detMs))

// 10. Vérification en MD5 au choix + rapport du jour
var rMD5: OffloadResult?
let md5Job = OffloadJob(source: makeCard("CARTE_MD5", mb: 9), destinations: [d1, d2], project: "Tournage été", label: "CamF_FX3",
                        day: "J1_2026-10-18", force: false) { ev in if case .finished(let r) = ev { rMD5 = r } }
md5Job.hashKind = .md5
md5Job.run()
check(rMD5?.ok == true, "copie vérifiée en MD5 (\(rMD5?.message.prefix(60) ?? "?"))")
let rep2 = (try? fm.contentsOfDirectory(atPath: d1.appendingPathComponent("Tournage-ete/Rapports_de_copie").path)) ?? []
let mhlMD5 = rep2.first { $0.contains("CamF_FX3_Carte01") && $0.hasSuffix(".mhl") }.flatMap {
    try? String(contentsOf: d1.appendingPathComponent("Tournage-ete/Rapports_de_copie/\($0)"), encoding: .utf8) } ?? ""
check(mhlMD5.contains("<md5>"), "MHL en MD5 quand le MD5 est choisi")
let dayPDF = PDFReport.dayReport(projectDir: d1.appendingPathComponent("Tournage-ete"), day: "J1_2026-10-18")
let daySize = ((try? fm.attributesOfItem(atPath: dayPDF?.path ?? ""))?[.size] as? NSNumber)?.intValue ?? 0
check(PDFReport.savedCardCount(projectDir: d1.appendingPathComponent("Tournage-ete"), day: "J1_2026-10-18") >= 7,
      "compteur : cartes prêtes pour le rapport du jour")
check(dayPDF != nil && daySize > 2000, "rapport du jour J1 en un seul PDF (\(daySize / 1024) Ko, \(PDFReport.savedCards(projectDir: d1.appendingPathComponent("Tournage-ete")).count) cartes)")
// Historique des anciennes versions (à la vue) : relu puis rangé dans .C-SAFE
let oldProj = base.appendingPathComponent("ANCIEN/Projet")
try! fm.createDirectory(at: oldProj.appendingPathComponent(Naming.reportDir), withIntermediateDirectories: true)
try! JSONEncoder().encode(["sigold": ["dossier": "J1_2026-01-01/CamA/CamA_Carte01"]])
    .write(to: oldProj.appendingPathComponent("\(Naming.reportDir)/\(Naming.historyFile)"))
check(History.load(oldProj)["sigold"] != nil, "ancien historique relu")
History.update(oldProj) { $0["signew"] = ["dossier": "x"] }
let oldGone = !fm.fileExists(atPath: oldProj.appendingPathComponent("\(Naming.reportDir)/\(Naming.historyFile)").path)
check(oldGone && History.load(oldProj)["sigold"] != nil && History.load(oldProj)["signew"] != nil, "ancien historique fusionné et rangé dans .C-SAFE")

// 11. Vraie vidéo (fabriquée par ffmpeg dans la CI) : vignette, durée, résolution, codec dans le PDF
let sample = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("sample.mp4")
if fm.fileExists(atPath: sample.path) {
    let vcard = base.appendingPathComponent("CARTE_VIDEO")
    let vclip = vcard.appendingPathComponent("PRIVATE/M4ROOT/CLIP")
    try! fm.createDirectory(at: vclip, withIntermediateDirectories: true)
    try! fm.copyItem(at: sample, to: vclip.appendingPathComponent("C0001.MP4"))
    var rV: OffloadResult?
    OffloadJob(source: vcard, destinations: [d1], project: "Tournage été", label: "CamB_FX3", day: "J2_2026-10-19",
               force: false) { ev in if case .finished(let r) = ev { rV = r } }.run()
    let cardsV = PDFReport.savedCards(projectDir: d1.appendingPathComponent("Tournage-ete")).filter { $0.day == "J2_2026-10-19" }
    let clipV = cardsV.flatMap { $0.clips }.first { $0.name.hasSuffix("C0001.MP4") }
    check(rV?.ok == true && clipV?.thumb != nil && clipV?.resolution == "1280×720" && clipV?.duration != nil,
          "PDF : vignette et infos d'une vraie vidéo (\(clipV?.resolution ?? "?"), \(clipV?.fps ?? "?"), \(clipV?.codec ?? "?"))")
    if let u = rV?.reportPDF { try? fm.copyItem(at: u, to: URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("exemple-rapport-carte.pdf")) }
}
if let u = PDFReport.dayReport(projectDir: d1.appendingPathComponent("Tournage-ete"), day: "J1_2026-10-18") {
    try? fm.copyItem(at: u, to: URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("exemple-rapport-du-jour.pdf"))
}

// 12. Dossier masqué sur la carte (AVF_INFO des Sony) : reste masqué sur les disques
let hcard = base.appendingPathComponent("CARTE_SONY_MASQUE")
touch(hcard.appendingPathComponent("M4ROOT/CLIP/C0001.MP4"))
touch(hcard.appendingPathComponent("AVF_INFO/AVIN0001.BNP"))
var hv = URLResourceValues(); hv.isHidden = true
var avf = hcard.appendingPathComponent("AVF_INFO"); try? avf.setResourceValues(hv)
var rH: OffloadResult?
OffloadJob(source: hcard, destinations: [d1], project: "Tournage été", label: "CamC_FX3", day: "J2_2026-10-19",
           force: false) { ev in if case .finished(let r) = ev { rH = r } }.run()
let avfCopy = d1.appendingPathComponent("Tournage-ete/\(rH?.display ?? "")/AVF_INFO")
check(rH?.ok == true && (try? avfCopy.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true,
      "AVF_INFO masqué sur la carte reste masqué dans la copie")

// 4. Jours de tournage dans l'ordre des dates
let dz = base.appendingPathComponent("SSD_JOURS")
let pj = dz.appendingPathComponent("Film")
try! fm.createDirectory(at: pj.appendingPathComponent("J1_2026-10-18/CamA/CamA_Carte01"), withIntermediateDirectories: true)
try! fm.createDirectory(at: pj.appendingPathComponent("J2_2026-10-25/CamA/CamA_Carte01"), withIntermediateDirectories: true)
try! fm.createDirectory(at: pj.appendingPathComponent(Naming.reportDir), withIntermediateDirectories: true)
History.save(pj, ["sigtest": ["dossier": "J2_2026-10-25/CamA/CamA_Carte01"]])
var used = Naming.usedShootDays(destinations: [dz], project: "Film")
check(Naming.dayPlan(date: "2026-10-25", used: used).j == 2, "date déjà utilisée : on reprend son J")
check(Naming.dayPlan(date: "2026-11-02", used: used).j == 3, "date plus récente (une semaine après) : J suivant")
let late = Naming.dayPlan(date: "2026-10-20", used: used)
check(late.j == 2 && late.shifted.map { $0.j } == [2], "date insérée en retard : devient J2, J2 à décaler")
// Projet rejoint en cours de route : J7 choisi à la main, puis la suite continue à J8
let joined: [Int: String] = [:]
let m7 = Naming.dayPlan(date: "2026-11-05", used: joined, manual: 7)
check(m7.j == 7 && !m7.existing && m7.shifted.isEmpty, "jour choisi à la main : J7 pour le premier jour copié")
let after7 = Naming.dayPlan(date: "2026-11-06", used: [7: "2026-11-05"])
check(after7.j == 8, "après un J7 choisi à la main, le jour suivant devient J8")
check(Naming.dayPlan(date: "2026-11-05", used: [7: "2026-11-05"], manual: 3).j == 7, "une date déjà copiée garde son J, même si on choisit un autre numéro")
check(Naming.dayPlan(date: "2026-11-07", used: [7: "2026-11-05"], manual: 7).j == 8, "un numéro déjà pris par une autre date est refusé")
let rn = Naming.renumberDays(destinations: [dz], project: "Film", after: "2026-10-20")
used = Naming.usedShootDays(destinations: [dz], project: "Film")
check(rn.errors.isEmpty && used[3] == "2026-10-25" && used[1] == "2026-10-18" && used[2] == nil, "renumérotation : J2_2026-10-25 → J3_2026-10-25")
check(History.load(pj)["sigtest"]?["dossier"] == "J3_2026-10-25/CamA/CamA_Carte01", "historique mis à jour après renumérotation")

try? fm.removeItem(at: base)
print(failures == 0 ? "BILAN tous les tests sont passés" : "BILAN \(failures) test(s) en échec")
exit(failures == 0 ? 0 : 1)
