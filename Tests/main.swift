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
check(r1.ok, "copie et vérification de 2 Go sur 2 disques")
check(r1.display == "J1_2026-10-18/CamA_FX3/CamA_FX3_Carte01", "nom du dossier (\(r1.display))")
check(maxRSSMB() < 400, String(format: "mémoire stable (%.0f Mo max, limite 400 Mo)", maxRSSMB()))
let copied = d2.appendingPathComponent("Tournage-ete/J1_2026-10-18/CamA_FX3/CamA_FX3_Carte01/PRIVATE/M4ROOT/CLIP/C0002.MP4")
check(fm.fileExists(atPath: copied.path), "arborescence caméra conservée sur le disque 2")
let cardFolder = d2.appendingPathComponent("Tournage-ete/J1_2026-10-18/CamA_FX3/CamA_FX3_Carte01")
let inCard = (try? fm.contentsOfDirectory(atPath: cardFolder.path)) ?? []
check(inCard == ["PRIVATE"], "dossier de carte identique à la carte, aucun fichier ajouté (\(inCard))")
let reports = (try? fm.contentsOfDirectory(atPath: d2.appendingPathComponent("Tournage-ete/Rapports_de_copie").path)) ?? []
check(reports.contains { $0.hasSuffix(".mhl") } && reports.contains { $0.hasSuffix(".md5") } && reports.contains { $0.hasSuffix("_rapport.txt") },
      "rapports et .mhl dans Rapports_de_copie (\(reports.count) fichiers)")
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
let rn = Naming.renumberDays(destinations: [dz], project: "Film", after: "2026-10-20")
used = Naming.usedShootDays(destinations: [dz], project: "Film")
check(rn.errors.isEmpty && used[3] == "2026-10-25" && used[1] == "2026-10-18" && used[2] == nil, "renumérotation : J2_2026-10-25 → J3_2026-10-25")
check(History.load(pj)["sigtest"]?["dossier"] == "J3_2026-10-25/CamA/CamA_Carte01", "historique mis à jour après renumérotation")

try? fm.removeItem(at: base)
print(failures == 0 ? "BILAN tous les tests sont passés" : "BILAN \(failures) test(s) en échec")
exit(failures == 0 ? 0 : 1)
