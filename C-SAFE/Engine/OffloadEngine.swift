//
//  OffloadEngine.swift — C-SAFE
//  Copie une carte vers plusieurs disques EN MÊME TEMPS (une seule lecture),
//  vérifie chaque copie (MD5), écrit MHL + rapports, gère doublons et échecs.
//

import Foundation
import CryptoKit

struct CardFile {
    let url: URL
    let rel: String      // chemin relatif dans la carte, avec « / »
    let size: Int64
}

struct OffloadResult {
    var ok: Bool
    var duplicate: Bool = false
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

    static func url(_ projectDir: URL) -> URL {
        projectDir.appendingPathComponent(Naming.reportDir).appendingPathComponent(Naming.historyFile)
    }

    static func load(_ projectDir: URL) -> Table {
        guard let d = try? Data(contentsOf: url(projectDir)),
              let t = try? JSONDecoder().decode(Table.self, from: d) else { return [:] }
        return t
    }

    static func save(_ projectDir: URL, _ t: Table) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(t) { try? d.write(to: url(projectDir), options: .atomic) }
    }
}

// MARK: - Moteur

final class OffloadJob {

    static let chunkSize = 8 * 1024 * 1024

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
    let cancel = CancelFlag()
    private let emit: (OffloadEvent) -> Void
    private var mergeTops: Set<String>?
    private var lastEmit = Date.distantPast
    private let emitLock = NSLock()
    private let fm = FileManager.default

    init(source: URL, destinations: [URL], project: String, label: String, day: String,
         force: Bool, emit: @escaping (OffloadEvent) -> Void) {
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
            emit(.finished(OffloadResult(ok: false, message: "Copie annulée.", source: source)))
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

        // Doublon ?
        let sig = Self.signature(files, cardName)
        if !force {
            for pd in projectDirs {
                if let entry = History.load(pd)[sig] {
                    return OffloadResult(ok: false, duplicate: true,
                                         message: "Cette carte a déjà été déchargée : \(entry["dossier"] ?? "?")",
                                         source: source)
                }
            }
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

        // Où va la carte ?
        let plan = Naming.plan(destinations: destinations, project: project, day: day, label: label)
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
                outs.append(try FileHandle(forWritingTo: tmp))
            }
            let input = try FileHandle(forReadingFrom: f.url)
            var hasher = Insecure.MD5()
            do {
                while true {
                    try check()
                    guard let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
                    hasher.update(data: chunk)
                    try Self.writeAll(chunk, to: outs)
                    done += Int64(chunk.count)
                    progress("Copie", done, total, since: copyStart)
                }
                for o in outs { try o.synchronize() }
            } catch {
                try? input.close()
                outs.forEach { try? $0.close() }
                throw error
            }
            try? input.close()
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
            hashes[f.rel] = Self.hex(hasher.finalize())
        }
        progress("Copie", total, total, since: copyStart, force: true)
        let copySeconds = Date().timeIntervalSince(t0)

        // ---- Vérification : chaque disque relu en parallèle ----
        log("Vérification des copies (checksum MD5)…")
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
        if allOK { writeMHL(targets: plan.targets, files: files, hashes: hashes, start: t0, end: end) }

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

        for pd in projectDirs {
            let rd = pd.appendingPathComponent(Naming.reportDir)
            do {
                try md5Text.write(to: rd.appendingPathComponent("\(reportName).md5"), atomically: true, encoding: .utf8)
                try reportText.write(to: rd.appendingPathComponent("\(reportName)_rapport.txt"), atomically: true, encoding: .utf8)
                if allOK {
                    var h = History.load(pd)
                    h[sig] = ["dossier": plan.display, "date": Self.stamp(end, "yyyy-MM-dd HH:mm:ss"), "label": cardName]
                    History.save(pd, h)
                }
            } catch {
                log("Impossible d'écrire le rapport dans \(rd.path) : \(error.localizedDescription)")
            }
        }

        if !allOK {
            return OffloadResult(ok: false, message: "\(shortName) : la vérification a échoué ! Ne formatez pas la carte.",
                                 name: shortName, source: source)
        }
        return OffloadResult(ok: true,
                             message: "\(shortName) : \(Self.human(total)) copiés et vérifiés sur \(plan.targets.count) disque(s) en \(Int(elapsed) / 60) min \(Int(elapsed) % 60) s.",
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

    private func writeMHL(targets: [URL], files: [CardFile], hashes: [String: String], start: Date, end: Date) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: "UTC")
        let stamp = Self.stamp(end, "yyyy-MM-dd_HHmmss")
        for dd in targets {
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
                    "    <file>\(Self.xml(f.rel))</file>",
                    "    <size>\(f.size)</size>",
                    "    <lastmodificationdate>\(iso.string(from: mod))</lastmodificationdate>",
                    "    <md5>\(hashes[f.rel] ?? "")</md5>",
                    "    <hashdate>\(iso.string(from: end))</hashdate>",
                    "  </hash>",
                ]
            }
            lines.append("</hashlist>")
            let url = dd.appendingPathComponent("\(dd.lastPathComponent)_\(stamp).mhl")
            do {
                try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                log("MHL non écrit dans \(dd.path) : \(error.localizedDescription)")
            }
        }
    }

    // MARK: Outils

    private func md5(of url: URL, onChunk: (Int) -> Void) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = Insecure.MD5()
        while true {
            if cancel.isSet { throw OffloadCancelled() }
            guard let chunk = try h.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            onChunk(chunk.count)
        }
        return Self.hex(hasher.finalize())
    }

    private static func writeAll(_ data: Data, to outs: [FileHandle]) throws {
        if outs.count == 1 {
            try outs[0].write(contentsOf: data)
            return
        }
        let box = ErrorBox()
        DispatchQueue.concurrentPerform(iterations: outs.count) { i in
            do { try outs[i].write(contentsOf: data) } catch { box.set(error) }
        }
        if let e = box.error { throw e }
    }

    static func scan(_ root: URL) throws -> [CardFile] {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
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
            out.append(CardFile(url: url, rel: rel, size: Int64(v?.fileSize ?? 0)))
        }
        return out.sorted { $0.rel < $1.rel }
    }

    static func looksLikeCameraCard(_ root: URL) -> Bool {
        let names = Naming.list(root)
        if names.contains(where: { cameraMarkers.contains($0.uppercased()) }) { return true }
        let base = root.standardizedFileURL.pathComponents.count
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return false }
        for case let u as URL in en {
            if u.standardizedFileURL.pathComponents.count - base > 3 { en.skipDescendants(); continue }
            if cameraExtensions.contains(u.pathExtension.lowercased()) { return true }
        }
        return false
    }

    static func signature(_ files: [CardFile], _ cardName: String) -> String {
        var h = Insecure.MD5()
        h.update(data: Data(cardName.utf8))
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
