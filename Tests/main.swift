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
let mhl = (try? fm.contentsOfDirectory(atPath: copied.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().path))?.contains { $0.hasSuffix(".mhl") } ?? false
check(mhl, "fichier .mhl présent")

// 2. Même carte rebranchée → doublon signalé
let r2 = run()
check(r2.duplicate, "carte déjà copiée détectée")

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

try? fm.removeItem(at: base)
print(failures == 0 ? "BILAN tous les tests sont passés" : "BILAN \(failures) test(s) en échec")
exit(failures == 0 ? 0 : 1)
