//
//  AppState.swift — C-SAFE
//  État de l'application : réglages mémorisés, disques, file d'attente des cartes,
//  détection automatique des cartes (Mac) et choix manuel (iPad / iPhone).
//

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct Destination: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var bookmark: Data?
}

/// Carte branchée, affichée sous le même nom que dans la barre latérale du Finder.
struct CardVolume: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let detail: String
    let isCamera: Bool
    let ejectable: Bool
}

struct LogLine: Identifiable {
    let id = UUID()
    let time: String
    let text: String
}

private struct StoredSettings: Codable {
    var project = "MonProjet"
    var source = "CamA"
    var type = "FX3"
    var sources = Naming.defaultSources
    var types = Naming.defaultTypes
    var camTypes: [String: String] = [:]
    var destinations: [Destination] = []
    var eject = true
    var autoWatch = false
    var useShootDay = true
}

@MainActor
final class AppState: ObservableObject {

    // Réglages
    @Published var project: String
    @Published var shootDate = Date()
    @Published private(set) var source: String
    @Published private(set) var type: String
    @Published private(set) var sources: [String]
    @Published private(set) var types: [String]
    @Published private(set) var destinations: [Destination]
    @Published var eject: Bool
    @Published var extraCard = false
    @Published private(set) var shootDay: Int?
    @Published private(set) var usedDays: [Int: String] = [:]
    private var useShootDay = true

    // État
    @Published private(set) var watching = false
    @Published private(set) var busy = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressText = ""
    @Published private(set) var status = "Prêt"
    @Published private(set) var lastSuccess: Bool?
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var done: [String] = []
    @Published private(set) var nextPreview = ""
    @Published var duplicatePrompt: OffloadResult?
    @Published var errorMessage: String?
    @Published var alreadyMounted: [URL] = []
    @Published private(set) var cards: [CardVolume] = []
    @Published private(set) var activeCard: URL?
    @Published private(set) var copiedCards: Set<String> = []

    private var camTypes: [String: String]
    private var pickedCards: [URL] = []
    private var copiedWhere: [String: String] = [:]   // carte → « Projet/J1_…/CamA_…/CamA_…_Carte01 »
    private var refreshTimer: Timer?
    private var autoWatch: Bool
    private var queue: [(url: URL, force: Bool, scoped: Bool)] = []
    private var job: OffloadJob?
    private var resolved: [UUID: URL] = [:]
    private var activity: NSObjectProtocol?
    #if os(macOS)
    private var volumeObservers: [NSObjectProtocol] = []
    #endif

    private static let settingsKey = "csafe.settings.v1"

    init() {
        var s = StoredSettings()
        if let d = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(StoredSettings.self, from: d) {
            s = decoded
        }
        project = s.project
        source = s.source
        type = s.type
        sources = s.sources.isEmpty ? Naming.defaultSources : s.sources
        types = s.types.isEmpty ? Naming.defaultTypes : s.types
        camTypes = s.camTypes
        destinations = s.destinations
        eject = s.eject
        autoWatch = s.autoWatch
        useShootDay = s.useShootDay
        addLog("C-SAFE prêt. Ajoute au moins 2 disques de sauvegarde.")
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.busy else { return }
                self.refresh()
                self.refreshCards()
            }
        }
        #if os(macOS)
        observeVolumes()
        refreshCards()
        #endif
    }

    // MARK: - Cartes source (colonne de gauche)

    static func cardInfo(_ url: URL) -> CardVolume {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeURLKey]
        let v = try? url.resourceValues(forKeys: keys)
        let isRoot = v?.volume?.standardizedFileURL.path == url.standardizedFileURL.path
        let name = isRoot ? (v?.volumeLocalizedName ?? url.lastPathComponent) : url.lastPathComponent
        var detail = ""
        if isRoot, let total = v?.volumeTotalCapacity, let free = v?.volumeAvailableCapacity, total > 0 {
            detail = "\(OffloadJob.human(Int64(total - free))) utilisés sur \(OffloadJob.human(Int64(total)))"
        }
        let ejectable = isRoot && ((v?.volumeIsEjectable ?? false) || (v?.volumeIsRemovable ?? false))
        return CardVolume(url: url, name: name, detail: detail,
                          isCamera: OffloadJob.looksLikeCameraCard(url), ejectable: ejectable)
    }

    func refreshCards() {
        #if os(macOS)
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let mounted = vols.filter { $0.path.hasPrefix("/Volumes/") && isCandidate($0) }
        pickedCards.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        let extra = pickedCards.filter { p in !mounted.contains { $0.standardizedFileURL.path == p.standardizedFileURL.path } }
        cards = (mounted.map(Self.cardInfo).sorted { ($0.isCamera ? 0 : 1, $0.name) < ($1.isCamera ? 0 : 1, $1.name) })
            + extra.map(Self.cardInfo)
        #else
        pickedCards.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        cards = pickedCards.map(Self.cardInfo)
        #endif
    }

    /// Copie manuelle d'une carte de la colonne source
    /// Seul le bouton « Démarrer la copie » lance les copies :
    /// toutes les cartes source pas encore copiées, puis (sur Mac) chaque carte branchée ensuite.
    func startCopy() {
        guard checkReady() else { return }
        let pending = cards.filter {
            ($0.isCamera || pickedCards.contains($0.url))
                && !copiedCards.contains($0.url.path)
                && activeCard?.path != $0.url.path
        }
        #if os(macOS)
        watching = true
        addLog(pending.isEmpty ? "Copie démarrée : branche une carte, elle sera copiée toute seule."
                               : "Copie démarrée : \(pending.count) carte(s) en cours, les suivantes seront copiées dès leur branchement.")
        if destinations.count < 2 { addLog("⚠ Un seul disque de sauvegarde : 2 sont recommandés.") }
        #else
        if pending.isEmpty { addLog("Choisis d'abord une carte.") }
        #endif
        pending.forEach { enqueue($0.url) }
        save()
    }

    func stopCopy() {
        #if os(macOS)
        watching = false
        addLog("Copie automatique arrêtée : les nouvelles cartes ne seront plus copiées.")
        #endif
        save()
    }

    /// iPad / iPhone : carte choisie dans Fichiers
    func pickCard(_ url: URL) {
        // L'accès à la carte reste ouvert tant qu'elle est affichée dans la colonne source.
        _ = url.startAccessingSecurityScopedResource()
        if !pickedCards.contains(url) { pickedCards.append(url) }
        refreshCards()
        addLog("Carte ajoutée : « \(url.lastPathComponent) ». Clique « Démarrer la copie ».")
    }

    /// iPad / iPhone : retirer la carte de la colonne (avant de la débrancher)
    func forgetCard(_ card: CardVolume) {
        pickedCards.removeAll { $0 == card.url }
        card.url.stopAccessingSecurityScopedResource()
        refreshCards()
    }

    func ejectCard(_ card: CardVolume) {
        #if os(macOS)
        ejectIfVolume(card.url)
        #endif
        refreshCards()
    }

    // MARK: - Valeurs calculées

    var dateString: String { Naming.dayString(shootDate) }
    /// Nom du dossier du jour : « J1_2026-10-18 » (ou « 2026-10-18 » sans numéro)
    var day: String { Naming.dayFolder(date: dateString, shootDay: shootDay) }
    /// Choix proposés : J1… jusqu'à quelques jours après le dernier utilisé
    var shootDayChoices: [Int] { Array(1...max(10, (usedDays.keys.max() ?? 0) + 5)) }

    func selectShootDay(_ j: Int?) {
        if let j, let used = usedDays[j], used != dateString { return }   // déjà pris par un autre jour
        shootDay = j
        useShootDay = j != nil
        save()
        refresh()
    }
    var isSoundSource: Bool { Naming.isSound(Naming.label(source: source)) }
    var currentLabel: String { Naming.label(source: source, type: isSoundSource ? "" : type) }
    var availableSources: [String] { extraCard ? sources : sources.filter { !done.contains($0) } }
    var isMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Sauvegarde des réglages

    func save() {
        var s = StoredSettings()
        s.project = project
        s.source = source
        s.type = type
        s.sources = sources
        s.types = types
        s.camTypes = camTypes
        s.destinations = destinations
        s.eject = eject
        s.autoWatch = watching
        s.useShootDay = useShootDay
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: Self.settingsKey) }
    }

    /// Recalcule les sources déjà faites et l'aperçu du prochain dossier.
    func refresh() {
        let urls = destinationURLs()
        // Copie mise à la corbeille depuis le Finder ? La carte redevient « à copier ».
        for (path, where_) in copiedWhere where !urls.contains(where: { OffloadJob.copyStillExists(projectDir: $0, display: where_) }) {
            copiedWhere[path] = nil
            copiedCards.remove(path)
            addLog("Copie supprimée détectée (\(where_)) : la carte peut être recopiée.")
        }
        // Jour de tournage (J1, J2…) : reprend celui de la date s'il existe déjà, sinon le prochain libre
        usedDays = Naming.usedShootDays(destinations: urls, project: project)
        if useShootDay {
            if let existing = usedDays.first(where: { $0.value == dateString })?.key {
                shootDay = existing
            } else if shootDay == nil || (usedDays[shootDay ?? 0].map { $0 != dateString } ?? false) {
                shootDay = (usedDays.keys.max() ?? 0) + 1
            }
        } else {
            shootDay = nil
        }
        done = Naming.doneSources(destinations: urls, project: project, day: day, sources: sources)
        if !extraCard, done.contains(source), let first = availableSources.first {
            addLog("Source « \(source) » déjà copiée ce jour → « \(first) » sélectionnée.")
            selectSource(first, refreshAfter: false)
        }
        let plan = Naming.plan(destinations: urls, project: project, day: day, label: currentLabel)
        nextPreview = "\(Naming.sanitize(project)) / " + plan.display.replacingOccurrences(of: "/", with: " / ")
    }

    // MARK: - Sources et types (listes personnalisables)

    func selectSource(_ s: String, refreshAfter: Bool = true) {
        source = s
        if !Naming.isSound(Naming.label(source: s)), let t = camTypes[s] { type = t }
        save()
        if refreshAfter { refresh() }
    }

    func selectType(_ t: String) {
        type = t
        camTypes[source] = t
        save()
        refresh()
    }

    func addSource(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if !sources.contains(n) { sources.append(n) }
        selectSource(n)
    }

    func removeSource(_ name: String) {
        sources.removeAll { $0 == name }
        if sources.isEmpty { sources = Naming.defaultSources }
        if source == name { selectSource(availableSources.first ?? sources[0]) } else { save(); refresh() }
    }

    func addType(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if !types.contains(n) { types.append(n) }
        selectType(n)
    }

    func removeType(_ name: String) {
        types.removeAll { $0 == name }
        if types.isEmpty { types = Naming.defaultTypes }
        if type == name { selectType(types[0]) } else { save() }
    }

    // MARK: - Disques de sauvegarde

    func destinationURLs() -> [URL] {
        destinations.map { url(for: $0) }
    }

    private func url(for d: Destination) -> URL {
        if let u = resolved[d.id] { return u }
        var u = URL(fileURLWithPath: d.path)
        if let b = d.bookmark {
            var stale = false
            if let r = try? URL(resolvingBookmarkData: b, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                u = r
            }
        }
        _ = u.startAccessingSecurityScopedResource()
        resolved[d.id] = u
        return u
    }

    func isReachable(_ d: Destination) -> Bool {
        Naming.isDir(url(for: d))
    }

    func freeSpace(_ d: Destination) -> String {
        guard let free = try? url(for: d).resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else {
            return ""
        }
        return "\(OffloadJob.human(Int64(free))) libres"
    }

    func addDestination(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        guard !destinations.contains(where: { $0.path == url.path }) else { return }
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let volName = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? ""
        let name = volName.isEmpty || volName == url.lastPathComponent ? url.lastPathComponent : "\(volName) › \(url.lastPathComponent)"
        let d = Destination(name: name, path: url.path, bookmark: bookmark)
        resolved[d.id] = url
        destinations.append(d)
        addLog("Disque ajouté : \(name)")
        save()
        refresh()
    }

    func removeDestination(_ d: Destination) {
        destinations.removeAll { $0.id == d.id }
        resolved[d.id] = nil
        save()
        refresh()
    }

    private func checkReady() -> Bool {
        if destinations.isEmpty {
            errorMessage = "Ajoute au moins un disque de sauvegarde (2 recommandés)."
            return false
        }
        let missing = destinations.filter { !isReachable($0) }.map(\.name)
        if !missing.isEmpty {
            errorMessage = "Disque(s) introuvable(s) : \(missing.joined(separator: ", ")). Vérifie qu'ils sont branchés."
            return false
        }
        return true
    }

    // MARK: - File d'attente des cartes

    func enqueue(_ url: URL, force: Bool = false, scoped: Bool = false) {
        guard !queue.contains(where: { $0.url == url }) else { return }
        queue.append((url, force, scoped))
        if busy { addLog("En file d'attente : \(url.lastPathComponent)") }
        startNext()
    }

    private func startNext() {
        guard !busy, !queue.isEmpty else { return }
        guard checkReady() else {
            queue.forEach { if $0.scoped { $0.url.stopAccessingSecurityScopedResource() } }
            queue.removeAll()
            return
        }
        let item = queue.removeFirst()
        activeCard = item.url
        busy = true
        progress = 0
        progressText = ""
        lastSuccess = nil
        status = "Analyse de la carte…"
        save()

        let scoped = item.scoped
        let newJob = OffloadJob(source: item.url, destinations: destinationURLs(), project: project,
                                label: currentLabel, day: day, force: item.force) { [weak self] ev in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(ev, scoped: scoped) }
            }
        }
        job = newJob
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Copie de carte C-SAFE")
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        DispatchQueue.global(qos: .userInitiated).async { newJob.run() }
    }

    func cancelCopy() {
        guard busy else { return }
        job?.cancel.set()
        addLog("Annulation demandée…")
    }

    func confirmDuplicate(_ r: OffloadResult) {
        duplicatePrompt = nil
        let scoped = r.source.startAccessingSecurityScopedResource()
        enqueue(r.source, force: true, scoped: scoped)
    }

    private func handle(_ ev: OffloadEvent, scoped: Bool) {
        switch ev {
        case .log(let s):
            addLog(s)
        case .started(let name):
            status = "Copie de \(name)"
        case .progress(let phase, let doneBytes, let total, let bps):
            progress = Double(doneBytes) / Double(total)
            let remaining = bps > 0 ? Double(total - doneBytes) / bps : 0
            progressText = "\(phase) · \(Int(progress * 100)) % · \(OffloadJob.human(Int64(bps)))/s · reste \(Self.duration(remaining))"
        case .finished(let r):
            finish(r, scoped: scoped)
        }
    }

    private func finish(_ r: OffloadResult, scoped: Bool) {
        busy = false
        job = nil
        activeCard = nil
        if r.ok {
            copiedCards.insert(r.source.path)
            copiedWhere[r.source.path] = "\(Naming.sanitize(project))/\(r.display)"
        }
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        if scoped { r.source.stopAccessingSecurityScopedResource() }

        if r.duplicate {
            addLog(r.message)
            status = "Carte déjà déchargée"
            duplicatePrompt = r
        } else if r.ok {
            addLog("✓ " + r.message)
            status = "Terminé — \(r.name)"
            progress = 1
            progressText = "Copié et vérifié sur tous les disques"
            lastSuccess = true
            extraCard = false
            feedback(success: true)
            #if os(macOS)
            if eject { ejectIfVolume(r.source) }
            #endif
        } else {
            addLog("✗ " + r.message)
            status = r.message
            lastSuccess = false
            feedback(success: false)
            errorMessage = r.message
        }
        refresh()
        refreshCards()
        startNext()
    }

    // MARK: - Journal et retours

    func addLog(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append(LogLine(time: f.string(from: Date()), text: s))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private func feedback(success: Bool) {
        #if os(macOS)
        NSSound(named: NSSound.Name(success ? "Glass" : "Basso"))?.play()
        #else
        UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .error)
        #endif
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600) h \(s % 3600 / 60) min" }
        if s >= 60 { return "\(s / 60) min \(s % 60) s" }
        return "\(s) s"
    }

    // MARK: - Mac : détection automatique des cartes

    #if os(macOS)
    private func isCandidate(_ volume: URL) -> Bool {
        let p = volume.standardizedFileURL.path
        if p == "/" { return false }
        let destVolumes = destinationURLs().compactMap {
            (try? $0.resourceValues(forKeys: [.volumeURLKey]).volume)?.standardizedFileURL.path
        }
        return !destVolumes.contains(p)
    }

    private func mountedCards() -> [URL] {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return vols.filter { $0.path.hasPrefix("/Volumes/") && isCandidate($0) && OffloadJob.looksLikeCameraCard($0) }
    }

    private func volumeMounted(_ url: URL) {
        guard isCandidate(url) else { refresh(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, FileManager.default.fileExists(atPath: url.path) else { return }
                self.refreshCards()
                guard self.watching else { return }
                if OffloadJob.looksLikeCameraCard(url) {
                    self.addLog("Carte détectée : « \(url.lastPathComponent) »")
                    self.enqueue(url)
                } else {
                    self.addLog("Volume « \(url.lastPathComponent) » ignoré (pas reconnu comme carte caméra). Utilise « Choisir une carte » si besoin.")
                }
            }
        }
    }

    private func ejectIfVolume(_ url: URL) {
        guard (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            addLog("Carte éjectée : tu peux la retirer.")
        } catch {
            addLog("Impossible d'éjecter la carte (elle est peut-être utilisée).")
        }
    }
    #endif
}
