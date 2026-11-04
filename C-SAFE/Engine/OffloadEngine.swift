//
//  OffloadEngine.swift — C-SAFE
//  Copie une carte vers plusieurs disques EN MÊME TEMPS (une seule lecture),
//  vérifie chaque copie (xxHash64), écrit MHL + rapports, gère doublons et échecs.
//

import Foundation
import CryptoKit

struct CardFile {
    let url: URL
    let rel: String      // chemin relatif dans la carte, avec « / »
    let size: Int64
    var mtime: Int = 0   // date de modification (secondes)
}

struct OffloadResult {
    var ok: Bool
    var duplicate: Bool = false
    var display: String = ""
    var cancelled: Bool = false
    var verifyFailed: Bool = false
    var message: String
    var name: String = ""
    var source: URL
}

enum OffloadEvent {
    case log(String)
    case started(String)
    case progress(phase: String, done: Int64, total: Int64, bytesPerSecond: Double)
    case finished(OffloadResult)
}

struct OffloadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct OffloadCancelled: Error {}

// Petits outils thread-safe
final class CancelFlag {
    private var value = false
    private let lock = NSLock()
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class DataBox {
    var data: Data?
    var error: Error?
}

/// Temps passé par chaque maillon (lecture carte, écriture de chaque disque, calcul MD5)
/// pour dire, après la copie, ce qui a limité la vitesse.
final class SpeedStats {
    private let lock = NSLock()
    private(set) var bytes: Int64 = 0
    private(set) var readSeconds: Double = 0
    private(set) var hashSeconds: Double = 0
    private(set) var writeSeconds: [Double]
    init(disks: Int) { writeSeconds = Array(repeating: 0, count: disks) }
    func add(read: Double) { lock.lock(); readSeconds += read; lock.unlock() }
    private var inFlight = 0
    private var busySince = Date()
    func beginRead() { lock.lock(); if inFlight == 0 { busySince = Date() }; inFlight += 1; lock.unlock() }
    func endRead() { lock.lock(); inFlight -= 1; if inFlight == 0 { readSeconds += Date().timeIntervalSince(busySince) }; lock.unlock() }
    func add(hash: Double) { lock.lock(); hashSeconds += hash; lock.unlock() }
    func add(write: Double, disk: Int) { lock.lock(); writeSeconds[disk] += write; lock.unlock() }
    func add(bytes b: Int64) { lock.lock(); bytes += b; lock.unlock() }
    /// Vitesse que chaque maillon pourrait tenir seul (octets par seconde)
    func rate(_ seconds: Double) -> Double { seconds > 0.01 ? Double(bytes) / seconds : 0 }

    /// « carte 980 Mo/s · Crucial 1,0 Go/s · MD5 1,4 Go/s → limité par la carte »
    func summary(diskNames: [String]) -> String {
        lock.lock(); defer { lock.unlock() }
        guard bytes > 64 * 1024 * 1024 else { return "" }
        var parts: [(String, Double)] = [("la carte (lecteur)", rate(readSeconds))]
        for (i, s) in writeSeconds.enumerated() {
            parts.append(("le disque « \(i < diskNames.count ? diskNames[i] : "\(i + 1)") »", rate(s)))
        }
        parts.append(("le calcul de l'empreinte", rate(hashSeconds)))
        let known = parts.filter { $0.1 > 0 }
        guard let slowest = known.min(by: { $0.1 < $1.1 }) else { return "" }
        let detail = known.map { "\($0.0.replacingOccurrences(of: "le disque ", with: "").replacingOccurrences(of: "la carte (lecteur)", with: "carte").replacingOccurrences(of: "le calcul de l'empreinte", with: "empreinte")) \(OffloadJob.human(Int64($0.1)))/s" }
            .joined(separator: " · ")
        return "Maillon le plus lent : \(slowest.0) — \(detail)"
    }
}

/// Lit un fichier par morceaux avec plusieurs lectures en vol (pread à des positions différentes) :
/// les cartes CFexpress / SSD NVMe vont bien plus vite quand on leur demande deux morceaux à la fois.
/// Le traitement d'un morceau (écritures, empreinte) se fait pendant que les suivants se lisent.
enum ReadAhead {
    static let queue = DispatchQueue(label: "csafe.lecture-anticipee", qos: .userInitiated, attributes: .concurrent)

    /// `cached: true` pour la carte : macOS garde sa lecture anticipée (comme le Finder), bien plus rapide.
    /// `cached: false` pour la vérification : on relit vraiment le disque, jamais une copie en mémoire.
    static func stream(_ url: URL, chunk: Int, depth: Int = 4, cached: Bool = false, stats: SpeedStats? = nil,
                       check: () throws -> Void, body: (Data) throws -> Void) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw OffloadError(message: "lecture impossible : \(url.lastPathComponent)") }
        if cached {
            _ = fcntl(fd, F_RDAHEAD, 1)
        } else {
            _ = fcntl(fd, F_NOCACHE, 1)
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else { close(fd); throw OffloadError(message: "lecture impossible : \(url.lastPathComponent)") }
        let size = Int64(st.st_size)
        let count = Int((size + Int64(chunk) - 1) / Int64(chunk))
        var pending: [(DispatchGroup, DataBox)] = []
        defer {
            pending.forEach { $0.0.wait() }   // jamais fermer pendant une lecture en vol
            close(fd)
        }
        func start(_ i: Int) {
            let offset = Int64(i) * Int64(chunk)
            let length = Int(min(Int64(chunk), size - offset))
            let g = DispatchGroup(), box = DataBox()
            g.enter()
            stats?.beginRead()
            queue.async {
                autoreleasepool {
                    var d = Data(count: length)
                    var got = 0
                    let ok: Bool = d.withUnsafeMutableBytes { raw in
                        while got < length {
                            let r = pread(fd, raw.baseAddress! + got, length - got, off_t(offset) + off_t(got))
                            if r < 0 { if errno == EINTR { continue }; return false }
                            if r == 0 { break }
                            got += r
                        }
                        return true
                    }
                    if !ok { box.error = OffloadError(message: "erreur de lecture : \(url.lastPathComponent) (\(String(cString: strerror(errno))))") }
                    else if got < length { box.error = OffloadError(message: "fichier tronqué pendant la lecture : \(url.lastPathComponent)") }
                    else { box.data = d }
                }
                stats?.endRead()
                g.leave()
            }
            pending.append((g, box))
        }
        var next = 0
        while next < min(depth, count) { start(next); next += 1 }
        for _ in 0..<count {
            try check()
            let (g, box) = pending.removeFirst()
            g.wait()
            if next < count { start(next); next += 1 }
            if let e = box.error { throw e }
            try body(box.data ?? Data())
        }
    }
}

private final class ErrorBox {
    private var stored: Error?
    private let lock = NSLock()
    func set(_ e: Error) { lock.lock(); if stored == nil { stored = e }; lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class ResultsBox {
    private var items: [[String]]
    private let lock = NSLock()
    init(count: Int) { items = Array(repeating: [], count: count) }
    func set(_ i: Int, _ v: [String]) { lock.lock(); items[i] = v; lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - Historique (même format que la version Python)

enum History {
    typealias Table = [String: [String: String]]

    /// Ancien nom du dossier de rapports (versions précédentes de C-SAFE), relu pour la compatibilité
    static let legacyDir = "_Rapports"

    static func url(_ projectDir: URL, dir: String = Naming.reportDir) -> URL {
        projectDir.appendingPathComponent(dir).appendingPathComponent(Naming.historyFile)
    }

    static func load(_ projectDir: URL, dir: String = Naming.reportDir) -> Table {
        guard let d = try? Data(contentsOf: url(projectDir, dir: dir)),
              let t = try? JSONDecoder().decode(Table.self, from: d) else { return [:] }
        return t
    }

    /// Verrou commun : plusieurs copies simultanées ne s'écrasent jamais l'historique
    private static let lock = NSLock()

    /// Lecture-modification-écriture protégée (copies simultanées)
    static func update(_ projectDir: URL, dir: String = Naming.reportDir, _ change: (inout Table) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var t = load(projectDir, dir: dir)
        change(&t)
        save(projectDir, t, dir: dir)
    }

    static func save(_ projectDir: URL, _ t: Table, dir: String = Naming.reportDir) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(t) { try? d.write(to: url(projectDir, dir: dir), options: .atomic) }
    }
}

// MARK: - Moteur

final class OffloadJob {

    static let chunkSize = 16 * 1024 * 1024

    /// Désactive le cache disque pour ce fichier : la mémoire du Mac n'est pas saturée,
    /// et la vérification relit vraiment les données sur le disque (pas une copie en mémoire).
    static func noCache(_ h: FileHandle) {
        _ = fcntl(h.fileDescriptor, F_NOCACHE, 1)
    }

    /// Au-delà de cette taille, un volume est un disque, pas une carte (les plus grosses cartes font 4 To)
    static let maxCardBytes: Int64 = 4_100_000_000_000
    /// Dossiers qui n'existent que sur une carte de caméra (pas de noms génériques comme MISC ou CLIP)
    static let cardMarkers: Set<String> = [
        "DCIM", "PRIVATE", "M4ROOT", "XDROOT", "CONTENTS", "AVCHD", "BPAV", "CANONMSC",
    ]
    /// Formats cherchés un niveau plus bas (enregistreurs son, RED, ARRI, Blackmagic)
    static let deepExtensions: Set<String> = ["wav", "bwf", "r3d", "braw", "ari", "arx", "mxf"]
    static let cameraMarkers: Set<String> = [
        "DCIM", "PRIVATE", "CLIP", "M4ROOT", "XDROOT", "CONTENTS", "AVCHD", "BPAV",
        "CANONMSC", "MISC", "ARRI", "RED", "BRAW", "FOOTAGE", "DJI",
    ]
    static let cameraExtensions: Set<String> = [
        "mov", "mp4", "mxf", "r3d", "braw", "crm", "ari", "arx", "mts", "m2ts",
        "insv", "insp", "lrv", "dng", "wav", "avi", "cr3", "cr2", "arw", "nef", "360",
    ]
    static let ignoredNames: Set<String> = [
        ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", "System Volume Information",
        "$RECYCLE.BIN", ".DS_Store", "Thumbs.db", ".DocumentRevisions-V100", "desktop.ini",
    ]

    let source: URL
    let destinations: [URL]
    let project: String
    let label: String
    let day: String
    let force: Bool
    let cardNumber: Int?
    let cancel = CancelFlag()
    private let emit: (OffloadEvent) -> Void
    private var mergeTops: Set<String>?
    private var lastEmit = Date.distantPast
    private let emitLock = NSLock()
    private let fm = FileManager.default

    init(source: URL, destinations: [URL], project: String, label: String, day: String,
         force: Bool, cardNumber: Int? = nil, emit: @escaping (OffloadEvent) -> Void) {
        self.cardNumber = cardNumber
        self.source = source
        self.destinations = destinations
        self.project = project
        self.label = label
        self.day = day
        self.force = force
        self.emit = emit
    }

    func run() {
        var created: [URL] = []
        do {
            let result = try perform(&created)
            emit(.finished(result))
        } catch is OffloadCancelled {
            markIncomplete(created)
            emit(.finished(OffloadResult(ok: false, cancelled: true, message: "Copie annulée.", source: source)))
        } catch {
            markIncomplete(created)
            emit(.finished(OffloadResult(ok: false, message: "Erreur : \(error.localizedDescription)", source: source)))
        }
    }

    // MARK: Étapes

    private func log(_ s: String) { emit(.log(s)) }

    private func check() throws { if cancel.isSet { throw OffloadCancelled() } }

    private func progress(_ phase: String, _ done: Int64, _ total: Int64, since start: Date, force: Bool = false) {
        emitLock.lock()
        let now = Date()
        let go = force || now.timeIntervalSince(lastEmit) > 0.2
        if go { lastEmit = now }
        emitLock.unlock()
        guard go else { return }
        let elapsed = max(now.timeIntervalSince(start), 0.001)
        emit(.progress(phase: phase, done: done, total: max(total, 1), bytesPerSecond: Double(done) / elapsed))
    }

    private func perform(_ created: inout [URL]) throws -> OffloadResult {
        let t0 = Date()
        let cardName = source.lastPathComponent
        log("Analyse de la carte « \(cardName) »…")
        let files = try Self.scan(source)
        guard !files.isEmpty else { throw OffloadError(message: "la carte est vide (aucun fichier à copier).") }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        log("\(files.count) fichiers, \(Self.human(total))")

        let proj = Naming.sanitize(project)
        let projectDirs = destinations.map { $0.appendingPathComponent(proj) }
        for pd in projectDirs {
            try fm.createDirectory(at: pd.appendingPathComponent(Naming.reportDir), withIntermediateDirectories: true)
        }

        // Doublon ? La carte est reconnue par son contenu (liste et poids de chaque fichier),
        // quel que soit son nom, dans tous les projets présents sur les disques de destination.
        let sig = Self.signature(files)
        if !force, let dup = Self.findPreviousCopy(signatures: [sig, Self.signatureV2(files), Self.legacySignature(files, cardName)],
                                                       destinations: destinations) {
            return OffloadResult(ok: false, duplicate: true, message: dup.message, source: source)
        }

        // Espace libre, regroupé par disque physique
        var perVolume: [String: (url: URL, count: Int)] = [:]
        for pd in projectDirs {
            let vol = (try? pd.resourceValues(forKeys: [.volumeURLKey]).volume)?.path ?? pd.path
            let cur = perVolume[vol]
            perVolume[vol] = (pd, (cur?.count ?? 0) + 1)
        }
        for (vol, info) in perVolume {
            if let free = try? info.url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
                let required = total * Int64(info.count) + 200 * 1024 * 1024
                if Int64(free) < required {
                    throw OffloadError(message: "pas assez d'espace sur \(vol) (libre \(Self.human(Int64(free))), nécessaire \(Self.human(required))).")
                }
            }
        }

        // Une lettre de caméra = un seul modèle par jour (CamA_FX2 et CamA_FX3 le même jour : interdit)
        if let existing = Naming.conflictingLabel(destinations: destinations, project: project, day: day, label: label) {
            let base = existing.split(separator: "_", maxSplits: 1).first.map(String.init) ?? existing
            throw OffloadError(message: "\(base) est déjà « \(existing) » ce jour-là : une caméra ne peut pas avoir deux modèles le même jour. Choisis une autre lettre pour « \(label) ».")
        }

        // Où va la carte ?
        let plan = Naming.plan(destinations: destinations, project: project, day: day, label: label, cardNumber: cardNumber)
        if plan.merge, plan.targets.contains(where: Naming.sonOccupied) {
            throw OffloadError(message: "la carte son n°1 de ce jour est déjà copiée (dossier SON). Choisis un autre numéro.")
        }
        let shortName = plan.display.split(separator: "/", maxSplits: 1).last.map(String.init) ?? plan.display
        if plan.merge {
            mergeTops = Set(files.map { String($0.rel.split(separator: "/").first ?? "") })
        }
        for t in plan.targets {
            if !plan.merge && fm.fileExists(atPath: t.path) {
                throw OffloadError(message: "le dossier \(t.lastPathComponent) existe déjà.")
            }
            try fm.createDirectory(at: t, withIntermediateDirectories: true)
            created.append(t)
        }
        emit(.started(shortName))
        log("→ \(plan.display) vers \(plan.targets.count) disque(s)")

        // ---- Copie simultanée : une lecture, N écritures en parallèle ----
        var hashes: [String: String] = [:]
        var done: Int64 = 0
        let copyStart = Date()
        let stats = SpeedStats(disks: plan.targets.count)
        for f in files {
            try check()
            let targets = plan.targets.map { $0.appendingPathComponent(f.rel) }
            for t in targets {
                try fm.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            let tmps = targets.map { URL(fileURLWithPath: $0.path + ".partial") }
            var outs: [FileHandle] = []
            for tmp in tmps {
                guard fm.createFile(atPath: tmp.path, contents: nil) else {
                    outs.forEach { try? $0.close() }
                    throw OffloadError(message: "impossible d'écrire \(tmp.lastPathComponent) sur \(tmp.deletingLastPathComponent().path).")
                }
                let out = try FileHandle(forWritingTo: tmp)
                Self.noCache(out)
                outs.append(out)
            }
            var hasher = XXHash64()
            // Pipeline : deux morceaux de la carte en lecture pendant que le morceau courant
            // s'écrit sur tous les disques ET que son empreinte se calcule. La vitesse est celle
            // du maillon le plus lent, pas la somme. Mémoire stable : ~3 morceaux de 16 Mo par copie.
            let hashQ = DispatchQueue(label: "csafe.empreinte")
            let writeError = ErrorBox()
            do {
                try ReadAhead.stream(f.url, chunk: Self.chunkSize, depth: 4, cached: true, stats: stats, check: check) { chunk in
                    let work = DispatchGroup()
                    work.enter()
                    hashQ.async {
                        let t = Date()
                        hasher.update(data: chunk)
                        stats.add(hash: Date().timeIntervalSince(t))
                        work.leave()
                    }
                    for (i, o) in outs.enumerated() {
                        work.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            let t = Date()
                            autoreleasepool {
                                do { try o.write(contentsOf: chunk) } catch { writeError.set(error) }
                            }
                            stats.add(write: Date().timeIntervalSince(t), disk: i)
                            work.leave()
                        }
                    }
                    work.wait()
                    if let e = writeError.error { throw e }
                    stats.add(bytes: Int64(chunk.count))
                    done += Int64(chunk.count)
                    progress("Copie", done, total, since: copyStart)
                }
            } catch {
                outs.forEach { try? $0.close() }
                throw error
            }
            for o in outs { try o.close() }

            let attrs = try? fm.attributesOfItem(atPath: f.url.path)
            for (tmp, t) in zip(tmps, targets) {
                if fm.fileExists(atPath: t.path) { try fm.removeItem(at: t) }
                try fm.moveItem(at: tmp, to: t)
                var keep: [FileAttributeKey: Any] = [:]
                if let m = attrs?[.modificationDate] { keep[.modificationDate] = m }
                if let c = attrs?[.creationDate] { keep[.creationDate] = c }
                if !keep.isEmpty { try? fm.setAttributes(keep, ofItemAtPath: t.path) }
            }
            hashes[f.rel] = hasher.hexDigest()
        }
        progress("Copie", total, total, since: copyStart, force: true)

        // Les dossiers gardent aussi leur date d'origine (comme sur la carte)
        var relDirs = Set<String>()
        for f in files {
            var parts = f.rel.split(separator: "/").dropLast()
            while !parts.isEmpty {
                relDirs.insert(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
        }
        for rel in relDirs.sorted(by: { $0.count > $1.count }) {
            guard let a = try? fm.attributesOfItem(atPath: source.appendingPathComponent(rel).path) else { continue }
            var keep: [FileAttributeKey: Any] = [:]
            if let m = a[.modificationDate] { keep[.modificationDate] = m }
            if let c = a[.creationDate] { keep[.creationDate] = c }
            for t in plan.targets where !keep.isEmpty {
                try? fm.setAttributes(keep, ofItemAtPath: t.appendingPathComponent(rel).path)
            }
        }
        let copySeconds = Date().timeIntervalSince(t0)

        // ---- Vérification : chaque disque relu en parallèle ----
        log("Vérification des copies (empreinte xxHash64)…")
        let vtotal = total * Int64(plan.targets.count)
        let verifyStart = Date()
        let counterLock = NSLock()
        var vdone: Int64 = 0
        let results = ResultsBox(count: plan.targets.count)
        let refHashes = hashes
        let targetsList = plan.targets
        let addProgress: (Int) -> Void = { [weak self] n in
            counterLock.lock()
            vdone += Int64(n)
            let current = vdone
            counterLock.unlock()
            self?.progress("Vérification", current, vtotal, since: verifyStart)
        }
        DispatchQueue.concurrentPerform(iterations: targetsList.count) { i in
            let dd = targetsList[i]
            var errors: [String] = []
            for f in files {
                if self.cancel.isSet { break }
                let p = dd.appendingPathComponent(f.rel)
                let size = ((try? self.fm.attributesOfItem(atPath: p.path))?[.size] as? NSNumber)?.int64Value ?? -1
                if size != f.size {
                    errors.append("taille différente : \(f.rel)")
                    continue
                }
                do {
                    let h = try self.md5(of: p, onChunk: addProgress)
                    if h != refHashes[f.rel] { errors.append("checksum différent : \(f.rel)") }
                } catch {
                    errors.append("illisible : \(f.rel)")
                }
            }
            results.set(i, errors)
        }
        try check()
        progress("Vérification", vtotal, vtotal, since: verifyStart, force: true)

        let allResults = results.all
        var allOK = true
        for (dd, errors) in zip(plan.targets, allResults) {
            if errors.isEmpty {
                log("✓ \(dd.path)")
            } else {
                allOK = false
                log("✗ \(dd.path) : \(errors.count) erreur(s)")
                errors.prefix(20).forEach { log("    \($0)") }
            }
        }

        // ---- Rapports ----
        let end = Date()
        let elapsed = end.timeIntervalSince(t0)
        let speed = copySeconds > 0 ? Double(total) / copySeconds : 0
        let diskNames = plan.targets.map {
            (try? $0.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? $0.lastPathComponent
        }
        let speedNote = stats.summary(diskNames: diskNames)
        if !speedNote.isEmpty { log(speedNote) }

        let md5Text = files.map { "\(hashes[$0.rel] ?? "")  \($0.rel)\n" }.joined()
        var report: [String] = [
            "C-SAFE — rapport de déchargement",
            String(repeating: "=", count: 50),
            "Date            : \(Self.stamp(end, "yyyy-MM-dd HH:mm:ss"))",
            "Projet          : \(proj)",
            "Dossier carte   : \(plan.display)",
            "Jour            : \(day)",
            "Source          : \(label)",
            "Carte d'origine : \(cardName) (\(source.path))",
            "Fichiers        : \(files.count)",
            "Taille totale   : \(Self.human(total))",
            "Durée totale    : \(Int(elapsed) / 60) min \(Int(elapsed) % 60) s",
            "Débit de copie  : \(Self.human(Int64(speed)))/s",
            "Vitesses        : \(speedNote.isEmpty ? "—" : speedNote)",
            "Vérification    : \(allOK ? "OK — toutes les copies sont identiques" : "ÉCHEC")",
            "",
            "Destinations :",
        ]
        for (dd, errors) in zip(plan.targets, allResults) {
            report.append("  [\(errors.isEmpty ? "OK" : "ERREUR")] \(dd.path)")
            errors.forEach { report.append("        \($0)") }
        }
        report.append("")
        report.append("Fichiers :")
        for f in files { report.append("  \(hashes[f.rel] ?? "")  \(Self.human(f.size))  \(f.rel)") }
        let reportText = report.joined(separator: "\n") + "\n"
        let reportName = "\(day)_\(plan.targets[0].lastPathComponent)"
        if allOK {
            writeMHL(projectDirs: projectDirs, targets: plan.targets, display: plan.display, reportName: reportName,
                     files: files, hashes: hashes, start: t0, end: end)
        }

        for pd in projectDirs {
            let rd = pd.appendingPathComponent(Naming.reportDir)
            do {
                try md5Text.write(to: rd.appendingPathComponent("\(reportName).xxh64"), atomically: true, encoding: .utf8)
                try reportText.write(to: rd.appendingPathComponent("\(reportName)_rapport.txt"), atomically: true, encoding: .utf8)
                if allOK {
                    let entry = ["dossier": plan.display, "projet": proj, "date": Self.stamp(end, "yyyy-MM-dd HH:mm:ss"),
                                 "label": cardName, "taille": Self.human(total), "fichiers": "\(files.count)"]
                    History.update(pd) { $0[sig] = entry }
                }
            } catch {
                log("Impossible d'écrire le rapport dans \(rd.path) : \(error.localizedDescription)")
            }
        }

        if !allOK {
            return OffloadResult(ok: false, display: plan.display, verifyFailed: true,
                                 message: "\(shortName) : la vérification a échoué ! Ne formatez pas la carte.",
                                 name: shortName, source: source)
        }
        return OffloadResult(ok: true, display: plan.display,
                             message: "\(shortName) : \(Self.human(total)) copiés et vérifiés sur \(plan.targets.count) disque(s) en \(Int(elapsed) / 60) min \(Int(elapsed) % 60) s (copie à \(Self.human(Int64(speed)))/s)." + (speedNote.isEmpty ? "" : " " + speedNote + "."),
                             name: shortName, source: source)
    }

    // MARK: Échec / annulation : rien n'est jamais présenté comme une copie valide

    private func markIncomplete(_ created: [URL]) {
        let stamp = Self.stamp(Date(), "HHmmss")
        for dd in created where Naming.isDir(dd) {
            var partials: [URL] = []
            if let en = fm.enumerator(at: dd, includingPropertiesForKeys: nil) {
                for case let u as URL in en where u.lastPathComponent.hasSuffix(".partial") { partials.append(u) }
            }
            partials.forEach { try? fm.removeItem(at: $0) }

            if let tops = mergeTops {
                // Copie directe dans SON/ : on ne touche pas aux HF, on isole ce qui vient de cette carte
                let bad = dd.appendingPathComponent("_INCOMPLET_\(stamp)")
                var moved = false
                for top in tops where !top.isEmpty {
                    let p = dd.appendingPathComponent(top)
                    if fm.fileExists(atPath: p.path) {
                        try? fm.createDirectory(at: bad, withIntermediateDirectories: true)
                        if (try? fm.moveItem(at: p, to: bad.appendingPathComponent(top))) != nil { moved = true }
                    }
                }
                if moved { log("Copie incomplète rangée dans SON/_INCOMPLET_\(stamp)") }
                continue
            }
            let renamed = dd.deletingLastPathComponent().appendingPathComponent("\(dd.lastPathComponent)_INCOMPLET_\(stamp)")
            if (try? fm.moveItem(at: dd, to: renamed)) != nil {
                log("Dossier incomplet renommé : \(renamed.lastPathComponent)")
            }
        }
    }

    // MARK: MHL 1.1 (standard DIT : Silverstack, ShotPut, Hedge, YoYotta, Resolve…)

    /// Écrit le .mhl dans Rapports_de_copie (chemins relatifs « ../J1_…/CamA_…/… ») :
    /// les dossiers de cartes restent identiques à la carte, sans aucun fichier ajouté.
    private func writeMHL(projectDirs: [URL], targets: [URL], display: String, reportName: String,
                          files: [CardFile], hashes: [String: String], start: Date, end: Date) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: "UTC")
        let stamp = Self.stamp(end, "yyyy-MM-dd_HHmmss")
        for (pd, dd) in zip(projectDirs, targets) {
            var lines = [
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                "<hashlist version=\"1.1\">",
                "  <creatorinfo>",
                "    <username>\(Self.xml(NSUserName()))</username>",
                "    <hostname>\(Self.xml(ProcessInfo.processInfo.hostName))</hostname>",
                "    <tool>C-SAFE 1.0</tool>",
                "    <startdate>\(iso.string(from: start))</startdate>",
                "    <finishdate>\(iso.string(from: end))</finishdate>",
                "  </creatorinfo>",
            ]
            for f in files {
                let p = dd.appendingPathComponent(f.rel)
                let mod = (try? fm.attributesOfItem(atPath: p.path))?[.modificationDate] as? Date ?? end
                lines += [
                    "  <hash>",
                    "    <file>\(Self.xml("../\(display)/\(f.rel)"))</file>",
                    "    <size>\(f.size)</size>",
                    "    <lastmodificationdate>\(iso.string(from: mod))</lastmodificationdate>",
                    "    <xxhash64be>\(hashes[f.rel] ?? "")</xxhash64be>",
                    "    <hashdate>\(iso.string(from: end))</hashdate>",
                    "  </hash>",
                ]
            }
            lines.append("</hashlist>")
            let url = pd.appendingPathComponent(Naming.reportDir).appendingPathComponent("\(reportName)_\(stamp).mhl")
            do {
                try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                log("MHL non écrit dans \(dd.path) : \(error.localizedDescription)")
            }
        }
    }

    // MARK: Outils

    private func md5(of url: URL, onChunk: (Int) -> Void) throws -> String {
        var hasher = XXHash64()
        try ReadAhead.stream(url, chunk: Self.chunkSize, depth: 4, cached: false,
                             check: { if cancel.isSet { throw OffloadCancelled() } }) { chunk in
            hasher.update(data: chunk)
            onChunk(chunk.count)
        }
        return hasher.hexDigest()
    }

    /// Copie déjà faite d'une carte : où, quand, sur quels disques.
    struct PreviousCopy: Equatable {
        let path: String      // « test / J1_2026-10-18 / CamA_FX3 / CamA_FX3_Carte01 »
        let disks: [String]
        let when: String      // « le 18/10 à 11:31 »
        let size: String
        var message: String {
            let on = disks.count == 1 ? "sur le disque \(disks[0])" : "sur les disques \(disks.joined(separator: " et "))"
            return "Cette carte\(size.isEmpty ? "" : " (\(size))") a déjà été copiée\(when.isEmpty ? "" : " \(when)") dans \(path), \(on)."
        }
        var short: String { "\(path) · \(disks.joined(separator: ", "))" }
    }

    /// Cherche si cette carte a déjà été copiée et si la copie est toujours sur un disque.
    /// Les copies mises à la corbeille sont oubliées. Relit aussi l'ancien historique (_Rapports).
    static func findPreviousCopy(signatures: [String], destinations: [URL]) -> PreviousCopy? {
        var disks: [String] = []
        var entry: [String: String]?
        for d in destinations {
            for proj in Naming.list(d) where !proj.hasPrefix(".") {
                let pd = d.appendingPathComponent(proj)
                guard Naming.isDir(pd) else { continue }
                for dir in [Naming.reportDir, History.legacyDir] {
                    let hist = History.load(pd, dir: dir)
                    for sig in signatures {
                        guard let e = hist[sig] else { continue }
                        if copyStillExists(projectDir: pd, display: e["dossier"] ?? "") {
                            let disk = (try? d.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? d.lastPathComponent
                            if !disks.contains(disk) { disks.append(disk) }
                            var full = e
                            full["projet"] = full["projet"] ?? proj
                            entry = entry ?? full
                        } else {
                            History.update(pd, dir: dir) { $0[sig] = nil }
                        }
                    }
                }
            }
        }
        guard let e = entry else { return nil }
        var when = ""
        if let date = e["date"], date.count >= 16 {
            let p = date.prefix(10).split(separator: "-")
            if p.count == 3 { when = "le \(p[2])/\(p[1]) à \(date.dropFirst(11).prefix(5))" }
        }
        let path = ([e["projet"] ?? ""] + (e["dossier"] ?? "").split(separator: "/").map(String.init))
            .filter { !$0.isEmpty }.joined(separator: " / ")
        return PreviousCopy(path: path, disks: disks, when: when, size: e["taille"] ?? "")
    }

    /// Empreintes d'une carte branchée : actuelle (contenu seul) et ancienne (nom + contenu)
    static func cardSignatures(_ root: URL) -> [String] {
        guard let files = try? scan(root), !files.isEmpty else { return [] }
        return [signature(files), signatureV2(files), legacySignature(files, root.lastPathComponent)]
    }

    /// Empreinte utilisée par les versions précédentes (nom de la carte + contenu)
    static func legacySignature(_ files: [CardFile], _ cardName: String) -> String {
        var h = Insecure.MD5()
        h.update(data: Data(cardName.utf8))
        for f in files { h.update(data: Data("\(f.rel)|\(f.size)\n".utf8)) }
        return hex(h.finalize())
    }

    /// Une copie enregistrée dans l'historique est-elle toujours sur ce disque ?
    static func copyStillExists(projectDir: URL, display: String) -> Bool {
        guard !display.isEmpty else { return false }
        let url = projectDir.appendingPathComponent(display)
        if display.hasSuffix("/SON") { return Naming.sonOccupied(url) }
        return Naming.isDir(url) && !Naming.list(url).filter { !$0.hasPrefix(".") }.isEmpty
    }

    static func scan(_ root: URL) throws -> [CardFile] {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                      errorHandler: { _, _ in true }) else {
            throw OffloadError(message: "impossible de lire la carte.")
        }
        var out: [CardFile] = []
        for case let url as URL in en {
            let name = url.lastPathComponent
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if ignoredNames.contains(name) || name.hasPrefix(".") { en.skipDescendants() }
                continue
            }
            guard v?.isRegularFile == true else { continue }
            if ignoredNames.contains(name) || name.hasPrefix("._") { continue }
            let p = url.resolvingSymlinksInPath().standardizedFileURL.path
            var rel = p.hasPrefix(rootPath) ? String(p.dropFirst(rootPath.count)) : name
            while rel.hasPrefix("/") { rel.removeFirst() }
            out.append(CardFile(url: url, rel: rel, size: Int64(v?.fileSize ?? 0),
                                mtime: Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)))
        }
        return out.sorted { $0.rel < $1.rel }
    }

    /// Marque / format reconnus d'après l'arborescence de la carte (affiché sous son nom).
    static func cameraKind(_ root: URL) -> String? {
        let fm = FileManager.default
        let top = Set(Naming.list(root).map { $0.uppercased() })
        func has(_ path: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(path).path) }
        func dcimHas(_ needle: String) -> Bool {
            Naming.list(root.appendingPathComponent("DCIM")).contains { $0.uppercased().contains(needle) }
        }
        if top.contains("PRIVATE") {
            if has("PRIVATE/M4ROOT") { return "Sony XAVC" }
            if has("PRIVATE/XDROOT") { return "Sony XDCAM" }
            if has("PRIVATE/AVCHD") { return "AVCHD" }
        }
        if top.contains("XDROOT") { return "Sony XDCAM" }
        if top.contains("M4ROOT") { return "Sony" }
        if top.contains("CONTENTS") { return "Panasonic P2" }
        if top.contains("CANONMSC") || dcimHas("CANON") { return "Canon" }
        if top.contains("DCIM") {
            if dcimHas("GOPRO") { return "GoPro" }
            if dcimHas("DJI") { return "DJI" }
            if dcimHas("INSTA") || dcimHas("CAMERA01") { return "Insta360" }
            if dcimHas("_PANA") { return "Panasonic" }
            if dcimHas("NIKON") || dcimHas("NCZ") { return "Nikon" }
            if dcimHas("_FUJI") { return "Fujifilm" }
            return "Photo / vidéo (DCIM)"
        }
        let exts = Set(Naming.list(root).map { ($0 as NSString).pathExtension.lowercased() })
        if exts.contains("braw") { return "Blackmagic RAW" }
        if exts.contains("r3d") || top.contains("RED") { return "RED" }
        if top.contains("ARRI") || exts.contains("ari") || exts.contains("arx") { return "ARRI" }
        if !exts.isEmpty && exts.isSubset(of: ["wav", "bwf", "txt", "xml", "csv", "sys", "ini", ""]) && exts.contains("wav") {
            return "Son (WAV)"
        }
        return nil
    }

    /// Une carte caméra / son se reconnaît à sa racine : structure de carte (DCIM, PRIVATE/M4ROOT…)
    /// ou fichiers caméra directement dessus ou dans un dossier de premier niveau.
    /// Lecture limitée (quelques dossiers, jamais tout le disque) : instantané même sur un disque de 20 To.
    /// Un disque de sauvegarde (déjà utilisé par C-SAFE) ou un très gros disque n'est jamais une carte.
    static func looksLikeCameraCard(_ root: URL) -> Bool {
        if isBackupDisk(root) { return false }
        if cameraKind(root) != nil { return true }
        let names = Naming.list(root).filter { !$0.hasPrefix(".") }
        if names.contains(where: { cardMarkers.contains($0.uppercased()) }) { return true }
        func ext(_ n: String) -> String { (n as NSString).pathExtension.lowercased() }
        if names.contains(where: { cameraExtensions.contains(ext($0)) }) { return true }
        var dirs = 0
        for n in names {
            let d = root.appendingPathComponent(n)
            guard Naming.isDir(d) else { continue }
            dirs += 1
            if dirs > 12 { break }
            let sub = Naming.list(d).prefix(300)
            if sub.contains(where: { cameraExtensions.contains(ext($0)) }) { return true }
            // Enregistreurs son (Zoom…), RED, ARRI : un niveau de plus, formats pro uniquement
            for x in sub.prefix(20) where !x.hasPrefix(".") {
                let dd = d.appendingPathComponent(x)
                guard Naming.isDir(dd) else { continue }
                if Naming.list(dd).prefix(300).contains(where: { deepExtensions.contains(ext($0)) }) { return true }
            }
        }
        return false
    }

    /// Dossiers qui n'existent qu'à l'intérieur d'une carte : les choisir seuls donnerait une copie
    /// incomplète et une structure cassée pour les logiciels de montage (Catalyst, Premiere…).
    static let insideCardNames: Set<String> = [
        "M4ROOT", "PRIVATE", "CLIP", "SUB", "THMBNL", "GENERAL", "AVF_INFO", "SONY", "DCIM", "XDROOT",
        "CONTENTS", "AVCHD", "BPAV", "CANONMSC", "MISC", "DATABASE",
    ]

    /// Un dossier choisi à l'intérieur d'une carte (ex. « M4ROOT ») : renvoie la carte entière.
    static func enclosingCard(of url: URL) -> URL? {
        guard let vol = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              vol.standardizedFileURL.path != url.standardizedFileURL.path,
              vol.standardizedFileURL.path != "/" else { return nil }
        return looksLikeCameraCard(vol) ? vol : nil
    }

    /// Plus gros qu'une carte (au-delà de 4 To) ou contient déjà des copies C-SAFE
    static func isBackupDisk(_ root: URL) -> Bool {
        let v = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeURLKey])
        let isVolumeRoot = v?.volume?.standardizedFileURL.path == root.standardizedFileURL.path
        if isVolumeRoot, let total = v?.volumeTotalCapacity, Int64(total) > maxCardBytes { return true }
        let names = Naming.list(root)
        if names.contains(Naming.reportDir) || names.contains("_Rapports") { return true }
        for n in names.prefix(40) where !n.hasPrefix(".") {
            let sub = Naming.list(root.appendingPathComponent(n))
            if sub.contains(Naming.reportDir) || sub.contains("_Rapports") { return true }
        }
        return false
    }

    /// Empreinte de la carte : liste des fichiers et poids de chacun (indépendante du nom de la carte).
    static func signature(_ files: [CardFile]) -> String {
        var h = Insecure.MD5()
        h.update(data: Data("csafe-v3\n".utf8))
        for f in files { h.update(data: Data("\(f.rel)|\(f.size)|\(f.mtime)\n".utf8)) }
        return hex(h.finalize())
    }

    /// Empreinte v2 (chemin + poids), utilisée par la version précédente
    static func signatureV2(_ files: [CardFile]) -> String {
        var h = Insecure.MD5()
        h.update(data: Data("csafe-v2\n".utf8))
        for f in files { h.update(data: Data("\(f.rel)|\(f.size)\n".utf8)) }
        return hex(h.finalize())
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func stamp(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: d)
    }

    static func human(_ n: Int64) -> String {
        var v = Double(n)
        for unit in ["o", "Ko", "Mo", "Go", "To"] {
            if v < 1024 || unit == "To" {
                return unit == "o" ? "\(Int(v)) o" : String(format: "%.1f %@", v, unit)
            }
            v /= 1024
        }
        return "\(n) o"
    }
}

// MARK: - xxHash64 (empreinte des fichiers)
//
// Standard des logiciels de DIT (ShotPut Pro, Silverstack, Hedge, MHL « xxhash64be ») :
// aussi sûr que le MD5 pour vérifier une copie, mais bien plus rapide à calculer.
// Implémentation fidèle de l'algorithme officiel (graine 0), en flux continu.
struct XXHash64 {
    private static let p1: UInt64 = 11400714785074694791
    private static let p2: UInt64 = 14029467366897019727
    private static let p3: UInt64 = 1609587929392839161
    private static let p4: UInt64 = 9650029242287828579
    private static let p5: UInt64 = 2870177450012600261

    private var v1: UInt64 = 0 &+ p1 &+ p2
    private var v2: UInt64 = 0 &+ p2
    private var v3: UInt64 = 0
    private var v4: UInt64 = 0 &- p1
    private var buffer = [UInt8](repeating: 0, count: 32)
    private var buffered = 0
    private var total: UInt64 = 0

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }
    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }
    @inline(__always) private static func merge(_ h: UInt64, _ v: UInt64) -> UInt64 {
        (h ^ round(0, v)) &* p1 &+ p4
    }

    @inline(__always) private mutating func stripe(_ p: UnsafeRawPointer) {
        v1 = Self.round(v1, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 0, as: UInt64.self)))
        v2 = Self.round(v2, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
        v3 = Self.round(v3, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
        v4 = Self.round(v4, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 24, as: UInt64.self)))
    }

    mutating func update(data: Data) {
        data.withUnsafeBytes { raw in update(raw) }
    }

    mutating func update(_ raw: UnsafeRawBufferPointer) {
        guard var p = raw.baseAddress, raw.count > 0 else { return }
        var n = raw.count
        total &+= UInt64(n)
        if buffered > 0 {
            let take = min(32 - buffered, n)
            buffer.withUnsafeMutableBytes { b in
                (b.baseAddress! + buffered).copyMemory(from: p, byteCount: take)
            }
            buffered += take
            p += take
            n -= take
            if buffered < 32 { return }
            buffer.withUnsafeBytes { b in stripe(b.baseAddress!) }
            buffered = 0
        }
        while n >= 32 {
            stripe(p)
            p += 32
            n -= 32
        }
        if n > 0 {
            buffer.withUnsafeMutableBytes { b in b.baseAddress!.copyMemory(from: p, byteCount: n) }
            buffered = n
        }
    }

    func finalize() -> UInt64 {
        var h: UInt64
        if total >= 32 {
            h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7) &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            h = Self.merge(h, v1); h = Self.merge(h, v2); h = Self.merge(h, v3); h = Self.merge(h, v4)
        } else {
            h = v3 &+ Self.p5
        }
        h &+= total
        buffer.withUnsafeBytes { b in
            let p = b.baseAddress!
            var i = 0
            while buffered - i >= 8 {
                h ^= Self.round(0, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: i, as: UInt64.self)))
                h = Self.rotl(h, 27) &* Self.p1 &+ Self.p4
                i += 8
            }
            if buffered - i >= 4 {
                h ^= UInt64(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i, as: UInt32.self))) &* Self.p1
                h = Self.rotl(h, 23) &* Self.p2 &+ Self.p3
                i += 4
            }
            while i < buffered {
                h ^= UInt64(p.load(fromByteOffset: i, as: UInt8.self)) &* Self.p5
                h = Self.rotl(h, 11) &* Self.p1
                i += 1
            }
        }
        h ^= h >> 33; h &*= Self.p2
        h ^= h >> 29; h &*= Self.p3
        h ^= h >> 32
        return h
    }

    /// 16 caractères hexadécimaux, ordre « big-endian » comme dans les MHL (xxhash64be)
    func hexDigest() -> String { String(format: "%016llx", finalize()) }
}
