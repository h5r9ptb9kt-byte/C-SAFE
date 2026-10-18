//
//  Naming.swift — C-SAFE
//  Règles de nommage et de rangement des cartes.
//
//  <Disque>/<Projet>/<AAAA-MM-JJ>/CamA_FX3/CamA_FX3_Carte01/   (caméras)
//  <Disque>/<Projet>/<AAAA-MM-JJ>/SON/                          (enregistreur, copié directement)
//  <Disque>/<Projet>/<AAAA-MM-JJ>/SON/HF1, HF3…                 (HF, numéro choisi)
//

import Foundation

enum Naming {

    static let defaultTypes = ["FX2", "FX3", "FX5", "Osmo 4P", "360", "Drone", "GoPro"]
    static let defaultSources = ["CamA", "CamB", "CamC", "CamD", "CamE", "CamF", "CamG", "CamH",
                                 "SON", "HF1", "HF2", "HF3", "HF4"]
    /// Nom sans « _ » initial : il se range toujours après J1, J2, J3… dans le Finder
    static let reportDir = "Rapports_de_copie"
    static let historyFile = "historique_cartes.json"

    // MARK: - Noms sûrs

    /// Nom compatible avec tous les logiciels (Premiere, Resolve, Final Cut, Avid,
    /// Silverstack, ShotPut, Hedge…) et tous les systèmes (macOS, Windows, exFAT, NAS) :
    /// lettres sans accent, chiffres, « - » et « _ » uniquement.
    static func sanitize(_ input: String, fallback: String = "Projet") -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let latin = s.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) {
            s = latin
        }
        s = s.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || scalar == "_" || scalar == "-"
            out.append(ok ? Character(scalar) : "-")
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        if out.count > 60 { out = String(out.prefix(60)) }
        return out.isEmpty ? fallback : out
    }

    static func isHF(_ s: String) -> Bool {
        s.range(of: #"^HF[0-9]+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isSound(_ label: String) -> Bool {
        label == "SON" || isHF(label)
    }

    /// CamA + FX3 → CamA_FX3 · SON → SON · HF3 → HF3 · Drone + Mavic 3 → Drone_Mavic-3
    static func label(source: String, type: String = "") -> String {
        let raw = sanitize(source, fallback: "CamA")
        let up = raw.uppercased()
        if up == "SON" || isHF(up) { return up }
        if up == "HF" { return "HF1" }
        var base = raw
        if raw.range(of: #"^(?:[Cc][Aa][Mm][-_]?)?[A-Za-z]$"#, options: .regularExpression) != nil, let last = raw.last {
            base = "Cam" + String(last).uppercased()
        }
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = trimmed.isEmpty ? "" : sanitize(trimmed, fallback: "")
        return t.isEmpty ? base : base + "_" + t
    }

    // MARK: - Dates

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// Dossier du jour : « J1_2026-10-18 »
    static func dayFolder(date: String, shootDay: Int?) -> String {
        guard let j = shootDay else { return date }
        return "J\(j)_\(date)"
    }

    /// Jours de tournage déjà utilisés dans le projet : J → date
    static func usedShootDays(destinations: [URL], project: String) -> [Int: String] {
        var out: [Int: String] = [:]
        guard let re = try? NSRegularExpression(pattern: #"^J([0-9]+)_([0-9]{4}-[0-9]{2}-[0-9]{2})$"#) else { return out }
        for d in destinations {
            for name in list(d.appendingPathComponent(sanitize(project))) {
                let ns = name as NSString
                guard let m = re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
                      let j = Int(ns.substring(with: m.range(at: 1))) else { continue }
                out[j] = ns.substring(with: m.range(at: 2))
            }
        }
        return out
    }

    // MARK: - Jours de tournage : toujours dans l'ordre des dates

    struct DayPlan {
        let j: Int                              // numéro du jour pour la date choisie
        let existing: Bool                      // ce jour existe déjà (on le reprend)
        let shifted: [(j: Int, date: String)]   // jours plus récents à renuméroter (J+1) si on insère une date plus ancienne
    }

    /// J1, J2… suivent l'ordre chronologique : une date déjà utilisée reprend son J,
    /// une date plus récente prend le J suivant (même une semaine plus tard),
    /// une date plus ancienne s'insère à sa place et décale les jours suivants.
    static func dayPlan(date: String, used: [Int: String]) -> DayPlan {
        if let j = used.first(where: { $0.value == date })?.key {
            return DayPlan(j: j, existing: true, shifted: [])
        }
        let before = used.filter { $0.value < date }
        let after = used.filter { $0.value > date }.sorted { $0.key < $1.key }.map { (j: $0.key, date: $0.value) }
        return DayPlan(j: (before.keys.max() ?? 0) + 1, existing: false, shifted: after)
    }

    /// Renumérote (J+1) les jours plus récents que `date`, sur chaque disque, et met à jour l'historique.
    /// Retourne les renommages effectués (ancien → nouveau nom) et les éventuelles erreurs.
    static func renumberDays(destinations: [URL], project: String, after date: String)
        -> (renamed: [(old: String, new: String)], errors: [String]) {
        let fm = FileManager.default
        var renamed: [(old: String, new: String)] = []
        var errors: [String] = []
        guard let re = try? NSRegularExpression(pattern: #"^J([0-9]+)_([0-9]{4}-[0-9]{2}-[0-9]{2})$"#) else { return ([], []) }
        for d in destinations {
            let pd = d.appendingPathComponent(sanitize(project))
            var items: [(j: Int, date: String, name: String)] = []
            for name in list(pd) {
                let ns = name as NSString
                guard let m = re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
                      let j = Int(ns.substring(with: m.range(at: 1))) else { continue }
                items.append((j, ns.substring(with: m.range(at: 2)), name))
            }
            let toShift = items.filter { $0.date > date }.sorted { $0.j > $1.j }   // du plus grand au plus petit
            guard !toShift.isEmpty else { continue }
            var hist = History.load(pd)
            for it in toShift {
                let newName = "J\(it.j + 1)_\(it.date)"
                do {
                    try fm.moveItem(at: pd.appendingPathComponent(it.name), to: pd.appendingPathComponent(newName))
                    if !renamed.contains(where: { $0.old == it.name }) { renamed.append((it.name, newName)) }
                    for (key, entry) in hist {
                        if let dossier = entry["dossier"], dossier == it.name || dossier.hasPrefix(it.name + "/") {
                            var e = entry
                            e["dossier"] = newName + String(dossier.dropFirst(it.name.count))
                            hist[key] = e
                        }
                    }
                } catch {
                    errors.append("\(d.lastPathComponent)/\(it.name) : \(error.localizedDescription)")
                }
            }
            History.save(pd, hist)
        }
        return (renamed, errors)
    }

    /// « 2026-10-17 » → « 17/10 »
    static func shortDate(_ iso: String) -> String {
        let p = iso.split(separator: "-")
        return p.count == 3 ? "\(p[2])/\(p[1])" : iso
    }

    // MARK: - Lecture des dossiers

    static func list(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    static func firstCapture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }

    static func nextNumber(in dirs: [URL], pattern: String) -> Int {
        var best = 0
        for d in dirs {
            for name in list(d) where !name.contains("_INCOMPLET") {
                if let c = firstCapture(pattern, in: name), let n = Int(c) { best = max(best, n) }
            }
        }
        return best + 1
    }

    private static let hfFolderPattern = #"^HF[0-9]+(_Carte[0-9]+)?$"#

    /// La carte de l'enregistreur a-t-elle déjà été copiée dans SON/ ?
    static func sonOccupied(_ son: URL) -> Bool {
        list(son).contains { name in
            name.range(of: hfFolderPattern, options: [.regularExpression, .caseInsensitive]) == nil
                && !name.hasPrefix(".") && !name.hasPrefix("_INCOMPLET") && !name.hasPrefix("SON_Carte")
        }
    }

    // MARK: - Où va la carte ?

    struct Plan {
        let targets: [URL]
        let display: String
        let merge: Bool      // true = copie directe dans un dossier existant (SON)
    }

    static func plan(destinations: [URL], project: String, day: String, label: String) -> Plan {
        let proj = sanitize(project)
        let dayDirs = destinations.map { $0.appendingPathComponent(proj).appendingPathComponent(day) }

        if isHF(label) {
            let sonDirs = dayDirs.map { $0.appendingPathComponent("SON") }
            var name = label
            if sonDirs.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(label).path) }) {
                let esc = NSRegularExpression.escapedPattern(for: label)
                let n = max(2, nextNumber(in: sonDirs, pattern: "^\(esc)_Carte([0-9]+)$"))
                name = String(format: "%@_Carte%02d", label, n)
            }
            return Plan(targets: sonDirs.map { $0.appendingPathComponent(name) }, display: "\(day)/SON/\(name)", merge: false)
        }

        if label == "SON" {
            let sonDirs = dayDirs.map { $0.appendingPathComponent("SON") }
            if sonDirs.contains(where: sonOccupied) {
                let n = max(2, nextNumber(in: sonDirs, pattern: "^SON_Carte([0-9]+)$"))
                let name = String(format: "SON_Carte%02d", n)
                return Plan(targets: sonDirs.map { $0.appendingPathComponent(name) }, display: "\(day)/SON/\(name)", merge: false)
            }
            return Plan(targets: sonDirs, display: "\(day)/SON", merge: true)
        }

        let camDirs = dayDirs.map { $0.appendingPathComponent(label) }
        let esc = NSRegularExpression.escapedPattern(for: label)
        let n = nextNumber(in: camDirs, pattern: "^\(esc)_Carte([0-9]+)$")
        let name = String(format: "%@_Carte%02d", label, n)
        return Plan(targets: camDirs.map { $0.appendingPathComponent(name) }, display: "\(day)/\(label)/\(name)", merge: false)
    }

    // MARK: - Sources déjà déchargées ce jour-là

    static func doneSources(destinations: [URL], project: String, day: String, sources: [String]) -> [String] {
        var names = Set<String>()
        for d in destinations {
            let dayDir = d.appendingPathComponent(sanitize(project)).appendingPathComponent(day)
            for e in list(dayDir) where !e.hasPrefix(".") && !e.hasPrefix("_") {
                let p = dayDir.appendingPathComponent(e)
                guard isDir(p) else { continue }
                if e == "SON" {
                    if sonOccupied(p) { names.insert("SON") }
                    for x in list(p) where !x.contains("_INCOMPLET") {
                        if let hf = firstCapture(#"^(HF[0-9]+)"#, in: x) { names.insert(hf.uppercased()) }
                    }
                } else if list(p).contains(where: { !$0.contains("_INCOMPLET") && !$0.hasPrefix(".") }) {
                    names.insert(e)
                }
            }
        }
        return sources.filter { s in
            let lab = label(source: s)
            if isSound(lab) { return names.contains(lab) }
            return names.contains { $0 == lab || $0.hasPrefix(lab + "_") }
        }
    }
}
