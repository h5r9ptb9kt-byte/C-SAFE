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
    var id: String { key }
    let url: URL
    let name: String
    let detail: String
    let isCamera: Bool
    let ejectable: Bool
    var kind: String? = nil                        // marque / format reconnus (« Sony XAVC », « Son (WAV) »…)
    var key: String = ""                           // chemin + identifiant du volume (une carte = une clé)
    var previous: OffloadJob.PreviousCopy? = nil   // déjà copiée : où et sur quel disque
}

/// Une copie en cours (plusieurs possibles en même temps)
struct RunningCopy: Identifiable {
    var id: String { path }
    let path: String
    let cardName: String
    let label: String
    var progress: Double = 0
    var text: String = "Analyse de la carte…"
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
    var maxParallel = 2
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
    @Published private(set) var dayExisting = false
    /// Jours plus récents à renuméroter si la date choisie est plus ancienne (copie en retard)
    @Published private(set) var dayShift: [DayShift] = []
    struct DayShift: Hashable { let j: Int; let date: String }
    private var useShootDay = true

    // État
    @Published private(set) var watching = false
    /// Copies en cours, par carte (chemin)
    @Published private(set) var running: [String: RunningCopy] = [:]
    /// Nombre de copies simultanées (1 = l'une après l'autre ; 2-3 conseillé sur SSD)
    @Published var maxParallel: Int = 2 { didSet { save(); startNext() } }
    var busy: Bool { !running.isEmpty }
    /// Avancement global (moyenne des copies en cours)
    var progress: Double { running.isEmpty ? (lastSuccess == true ? 1 : 0) : running.values.map(\.progress).reduce(0, +) / Double(running.count) }
    @Published private(set) var progressText = ""
    @Published private(set) var status = "Prêt"
    @Published private(set) var lastSuccess: Bool?
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var done: [String] = []
    @Published private(set) var nextPreview = ""
    @Published private var duplicateQueue: [OffloadResult] = []
    var duplicatePrompt: OffloadResult? {
        get { duplicateQueue.first }
        set { if newValue == nil { if !duplicateQueue.isEmpty { duplicateQueue.removeFirst() } } else if let v = newValue { duplicateQueue.append(v) } }
    }
    @Published var errorMessage: String?
    @Published var alreadyMounted: [URL] = []
    @Published private(set) var cards: [CardVolume] = []
    /// Source attribuée à chaque carte (clé de la carte → « CamA », « SON »…)
    @Published private(set) var assignments: [String: String] = [:]
    @Published private(set) var copiedCards: Set<String> = []

    private var camTypes: [String: String]
    private var pickedCards: [URL] = []
    private var signatureCache: [String: [String]] = [:]   // carte (chemin + identifiant du volume) → empreintes
    private var copiedWhere: [String: String] = [:]   // carte → « Projet/J1_…/CamA_…/CamA_…_Carte01 »
    private var refreshTimer: Timer?
    private var autoWatch: Bool
    /// Une carte à copier. label/day/project sont figés pour « Recommencer » (même numéro, même jour).
    private struct QueueItem {
        let url: URL
        let force: Bool
        let scoped: Bool
        var label: String? = nil
        var day: String? = nil
        var project: String? = nil
    }
    private var queue: [QueueItem] = []
    private var jobs: [String: (job: OffloadJob, item: QueueItem)] = [:]
    private var duplicateItems: [String: QueueItem] = [:]   // carte → réglages, pour « Copier quand même »

    /// Copie ratée, interrompue ou incomplète : affichée avec « Recommencer »
    struct CopyFailure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let source: URL
        let label: String
        let day: String
        let project: String
    }
    @Published private var failureQueue: [CopyFailure] = []
    var failure: CopyFailure? {
        get { failureQueue.first }
        set {
            if let v = newValue {
                if failureQueue.isEmpty { failureQueue.append(v) } else { failureQueue[0] = v }
            } else if !failureQueue.isEmpty {
                failureQueue.removeFirst()
            }
        }
    }
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
        maxParallel = min(3, max(1, s.maxParallel))
        addLog("C-SAFE prêt. Ajoute au moins 2 disques de sauvegarde.")
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.busy { self.refresh() }
                self.refreshCards()
            }
        }
        #if os(macOS)
        observeVolumes()
        refreshCards()
        #endif
    }

    // MARK: - Cartes source (colonne de gauche)

    /// Carte + « déjà copiée ? » (reconnue par son contenu, jamais par son nom ou son emplacement)
    private func cardWithHistory(_ url: URL) -> CardVolume {
        var c = Self.cardInfo(url)
        let uuid = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? ""
        let key = url.path + "|" + uuid
        c.key = key
        c.kind = OffloadJob.cameraKind(url)
        if signatureCache[key] == nil { signatureCache[key] = OffloadJob.cardSignatures(url) }
        if let sigs = signatureCache[key], !sigs.isEmpty {
            c.previous = OffloadJob.findPreviousCopy(signatures: sigs, destinations: destinationURLs())
        }
        return c
    }

    static func cardInfo(_ url: URL) -> CardVolume {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeURLKey]
        let v = try? url.resourceValues(forKeys: keys)
        let isRoot = v?.volume?.standardizedFileURL.path == url.standardizedFileURL.path
        let name = isRoot ? (v?.volumeLocalizedName ?? url.lastPathComponent) : url.lastPathComponent
        var parts: [String] = []
        if let kind = OffloadJob.cameraKind(url) { parts.append(kind) }
        if isRoot, let total = v?.volumeTotalCapacity, let free = v?.volumeAvailableCapacity, total > 0 {
            parts.append("\(OffloadJob.human(Int64(total - free))) sur \(OffloadJob.human(Int64(total)))")
        }
        let detail = parts.joined(separator: " · ")
        let ejectable = isRoot && ((v?.volumeIsEjectable ?? false) || (v?.volumeIsRemovable ?? false))
        return CardVolume(url: url, name: name, detail: detail,
                          isCamera: OffloadJob.looksLikeCameraCard(url), ejectable: ejectable)
    }

    func refreshCards() {
        #if os(macOS)
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let mounted = vols.filter { $0.path.hasPrefix("/Volumes/") && isCandidate($0) && OffloadJob.looksLikeCameraCard($0) }
        pickedCards.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        let extra = pickedCards.filter { p in !mounted.contains { $0.standardizedFileURL.path == p.standardizedFileURL.path } }
        let mountedPaths = Set(vols.map { $0.path })
        let pickedPaths = Set(pickedCards.map { $0.path })
        signatureCache = signatureCache.filter { entry in
            let path = String(entry.key.split(separator: "|").first ?? "")
            return mountedPaths.contains(path) || pickedPaths.contains(path)
        }
        cards = (mounted.map(cardWithHistory).sorted { ($0.isCamera ? 0 : 1, $0.name) < ($1.isCamera ? 0 : 1, $1.name) })
            + extra.map(cardWithHistory)
        #else
        pickedCards.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        cards = pickedCards.map(cardWithHistory)
        #endif
        autoAssign()
    }

    // MARK: - Une source par carte

    /// Attribue une source à chaque nouvelle carte : la carte son reçoit SON, les autres la
    /// première caméra libre (pas encore copiée ce jour, pas déjà attribuée à une autre carte).
    private func autoAssign() {
        let present = Set(cards.map(\.key))
        assignments = assignments.filter { present.contains($0.key) }
        for c in cards where assignments[c.key] == nil && c.previous == nil {
            let taken = Set(assignments.values)
            let free = sources.filter { !done.contains($0) && !taken.contains($0) }
            if c.kind == "Son (WAV)", free.contains("SON") {
                assignments[c.key] = "SON"
            } else if let s = free.first(where: { !Naming.isSound(Naming.label(source: $0)) }) ?? free.first {
                assignments[c.key] = s
            }
        }
    }

    func sourceFor(_ card: CardVolume) -> String { assignments[card.key] ?? "—" }

    func typeFor(source: String) -> String {
        Naming.isSound(Naming.label(source: source)) ? "" : (camTypes[source] ?? types.first ?? "")
    }

    func labelFor(source: String) -> String {
        Naming.label(source: source, type: typeFor(source: source))
    }

    func assign(_ source: String, to card: CardVolume) {
        assignments[card.key] = source
        addLog("« \(card.name) » → \(source)")
    }

    func setType(_ t: String, for source: String) {
        camTypes[source] = t
        save()
        objectWillChange.send()
    }

    /// Sources proposées pour une carte : toutes sauf celles attribuées à une autre carte
    func sourceChoices(for card: CardVolume) -> (fresh: [String], doneToday: [String]) {
        let others = Set(assignments.filter { $0.key != card.key }.values)
        let usable = sources.filter { !others.contains($0) }
        return (usable.filter { !done.contains($0) }, usable.filter { done.contains($0) })
    }

    /// Dossier qui sera créé pour cette carte (« CamA_FX3_Carte02 », « SON », « HF2 »…)
    func previewFor(_ card: CardVolume) -> String {
        guard let s = assignments[card.key] else { return "" }
        let plan = Naming.plan(destinations: destinationURLs(), project: project, day: day, label: labelFor(source: s))
        return String(plan.display.split(separator: "/").last ?? "")
    }

    /// Copie manuelle d'une carte de la colonne source
    /// Seul le bouton « Démarrer la copie » lance les copies :
    /// toutes les cartes source pas encore copiées, puis (sur Mac) chaque carte branchée ensuite.
    func startCopy() {
        guard checkReady() else { return }
        let already = cards.filter { $0.previous != nil && running[$0.url.path] == nil }
        for c in already {
            addLog("Déjà copiée : « \(c.name) » → \(c.previous!.short)")
            duplicatePrompt = OffloadResult(ok: false, duplicate: true, message: c.previous!.message, source: c.url)
        }
        let pending = cards.filter {
            ($0.isCamera || pickedCards.contains($0.url))
                && $0.previous == nil
                && running[$0.url.path] == nil
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
    var isToday: Bool { Calendar.current.isDateInToday(shootDate) }

    /// Date plus ancienne que des jours existants : décale J+1 les jours suivants sur tous les disques.
    func renumberFollowingDays() {
        guard !busy, !dayShift.isEmpty else { return }
        let result = Naming.renumberDays(destinations: destinationURLs(), project: project, after: dateString)
        let proj = Naming.sanitize(project)
        for (old, new) in result.renamed {
            addLog("Jour renuméroté : \(old) → \(new)")
            for (card, where_) in copiedWhere where where_.hasPrefix("\(proj)/\(old)/") || where_ == "\(proj)/\(old)" {
                copiedWhere[card] = "\(proj)/\(new)" + String(where_.dropFirst("\(proj)/\(old)".count))
            }
        }
        if !result.errors.isEmpty {
            errorMessage = "Certains dossiers n'ont pas pu être renommés :\n" + result.errors.joined(separator: "\n")
        }
        refresh()
    }
    var availableSources: [String] { sources.filter { !done.contains($0) } }
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
        s.maxParallel = maxParallel
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
        // Jour de tournage (J1, J2…) : automatique, toujours dans l'ordre des dates
        usedDays = Naming.usedShootDays(destinations: urls, project: project)
        let dayPlan = Naming.dayPlan(date: dateString, used: usedDays)
        shootDay = dayPlan.j
        dayExisting = dayPlan.existing
        let shift = dayPlan.shifted.map { DayShift(j: $0.j, date: $0.date) }
        if shift != dayShift { dayShift = shift }
        done = Naming.doneSources(destinations: urls, project: project, day: day, sources: sources)
        nextPreview = "\(Naming.sanitize(project)) / \(day)"
    }

    // MARK: - Sources et types (listes personnalisables)

    /// Nouvelle source (« Drone »…) ajoutée à la liste et attribuée à la carte
    func addSource(_ name: String, for card: CardVolume?) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if !sources.contains(n) { sources.append(n) }
        if let card { assign(n, to: card) }
        save()
    }

    func removeSource(_ name: String) {
        sources.removeAll { $0 == name }
        if sources.isEmpty { sources = Naming.defaultSources }
        assignments = assignments.filter { $0.value != name }
        autoAssign()
        save()
    }

    /// Nouveau type (« FX6 »…) ajouté à la liste et attribué à la source
    func addType(_ name: String, for source: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if !types.contains(n) { types.append(n) }
        setType(n, for: source)
    }

    func removeType(_ name: String) {
        types.removeAll { $0 == name }
        if types.isEmpty { types = Naming.defaultTypes }
        for (k, v) in camTypes where v == name { camTypes[k] = nil }
        save()
        objectWillChange.send()
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
        if !dayShift.isEmpty {
            errorMessage = "Le \(Naming.shortDate(dateString)) est avant des jours déjà copiés. Clique « Renuméroter » (ou choisis une autre date) avant de lancer la copie."
            return false
        }
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

    func enqueue(_ url: URL, force: Bool = false, scoped: Bool = false,
                 label: String? = nil, day: String? = nil, project: String? = nil) {
        guard !queue.contains(where: { $0.url == url }) else { return }
        queue.append(QueueItem(url: url, force: force, scoped: scoped, label: label, day: day, project: project))
        if busy { addLog("En file d'attente : \(url.lastPathComponent)") }
        startNext()
    }

    /// Lance les copies en attente, jusqu'à `maxParallel` en même temps.
    /// Jamais deux copies de la même source en même temps (numérotation des cartes sûre).
    private func startNext() {
        guard !queue.isEmpty, running.count < maxParallel else { return }
        guard checkReady() else {
            queue.forEach { if $0.scoped { $0.url.stopAccessingSecurityScopedResource() } }
            queue.removeAll()
            return
        }
        var i = 0
        while running.count < maxParallel && i < queue.count {
            var item = queue[i]
            let label = item.label ?? labelForQueued(item.url)
            guard let label else {
                addLog("« \(item.url.lastPathComponent) » : aucune source attribuée, copie ignorée.")
                queue.remove(at: i)
                continue
            }
            if running.values.contains(where: { $0.label == label }) { i += 1; continue }
            queue.remove(at: i)
            item.label = label
            item.day = item.day ?? day
            item.project = item.project ?? project
            launch(item)
        }
    }

    private func labelForQueued(_ url: URL) -> String? {
        guard let card = cards.first(where: { $0.url.path == url.path }), let s = assignments[card.key] else { return nil }
        return labelFor(source: s)
    }

    private func launch(_ item: QueueItem) {
        let path = item.url.path
        let label = item.label ?? "CamA"
        if running.isEmpty {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Copie de carte C-SAFE")
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
        lastSuccess = nil
        running[path] = RunningCopy(path: path, cardName: cardName(item.url), label: label)
        status = running.count > 1 ? "\(running.count) copies en cours" : "Copie en cours"
        let newJob = OffloadJob(source: item.url, destinations: destinationURLs(), project: item.project ?? project,
                                label: label, day: item.day ?? day, force: item.force) { [weak self] ev in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(ev, path: path) }
            }
        }
        jobs[path] = (newJob, item)
        DispatchQueue.global(qos: .userInitiated).async { newJob.run() }
    }

    private func cardName(_ url: URL) -> String {
        cards.first(where: { $0.url.path == url.path })?.name ?? url.lastPathComponent
    }

    /// Annule toutes les copies en cours
    func cancelCopy() {
        guard busy else { return }
        jobs.values.forEach { $0.job.cancel.set() }
        addLog("Annulation demandée…")
    }

    /// Annule la copie d'une seule carte
    func cancelCopy(of card: CardVolume) {
        guard let j = jobs[card.url.path] else { return }
        j.job.cancel.set()
        addLog("Annulation demandée : « \(card.name) »")
    }

    func runningCopy(for card: CardVolume) -> RunningCopy? { running[card.url.path] }

    /// « Copier quand même » une carte déjà copiée : nouvelle copie, sous un nouveau numéro
    func confirmDuplicate(_ r: OffloadResult) {
        duplicatePrompt = nil
        let saved = duplicateItems.removeValue(forKey: r.source.path)
        var label = saved?.label
        if label == nil, let card = cards.first(where: { $0.url.path == r.source.path }) {
            if assignments[card.key] == nil {
                let taken = Set(assignments.values)
                assignments[card.key] = sources.first { !done.contains($0) && !taken.contains($0) } ?? sources.first
            }
            label = assignments[card.key].map { labelFor(source: $0) }
        }
        let scoped = r.source.startAccessingSecurityScopedResource()
        enqueue(r.source, force: true, scoped: scoped, label: label, day: saved?.day, project: saved?.project)
    }

    /// « Recommencer » : même carte, même source, même jour, même projet.
    func retry(_ f: CopyFailure) {
        failure = nil
        guard FileManager.default.fileExists(atPath: f.source.path) else {
            failure = CopyFailure(title: "Carte introuvable",
                                  message: "La carte « \(f.source.lastPathComponent) » n'est plus branchée. Rebranche-la, puis clique « Recommencer ».",
                                  source: f.source, label: f.label, day: f.day, project: f.project)
            return
        }
        addLog("Nouvelle tentative : \(f.source.lastPathComponent)")
        let scoped = f.source.startAccessingSecurityScopedResource()
        enqueue(f.source, force: true, scoped: scoped, label: f.label, day: f.day, project: f.project)
    }

    private func handle(_ ev: OffloadEvent, path: String) {
        switch ev {
        case .log(let s):
            let who = running[path]?.label ?? ""
            addLog(running.count > 1 && !who.isEmpty ? "[\(who)] \(s)" : s)
        case .started(let name):
            running[path]?.text = "Copie de \(name)"
        case .progress(let phase, let doneBytes, let total, let bps):
            let p = Double(doneBytes) / Double(total)
            let remaining = bps > 0 ? Double(total - doneBytes) / bps : 0
            running[path]?.progress = p
            running[path]?.text = "\(phase) · \(Int(p * 100)) % · \(OffloadJob.human(Int64(bps)))/s · reste \(Self.duration(remaining))"
        case .finished(let r):
            finish(r, path: path)
        }
    }

    private func finish(_ r: OffloadResult, path: String) {
        running[path] = nil
        let entry = jobs.removeValue(forKey: path)
        let item = entry?.item
        let scoped = item?.scoped ?? false
        status = running.isEmpty ? status : "\(running.count) copie(s) en cours"
        if r.ok {
            copiedCards.insert(r.source.path)
            copiedWhere[r.source.path] = "\(Naming.sanitize(item?.project ?? project))/\(r.display)"
        }
        if running.isEmpty {
            if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        if scoped { r.source.stopAccessingSecurityScopedResource() }

        if r.duplicate {
            if let item { duplicateItems[r.source.path] = item }
            addLog(r.message)
            status = "Carte déjà déchargée"
            duplicatePrompt = r
        } else if r.ok {
            addLog("✓ " + r.message)
            if running.isEmpty { status = "Terminé — \(r.name)" }
            progressText = "\(r.name) : copié et vérifié sur tous les disques"
            lastSuccess = true
            feedback(success: true)
            #if os(macOS)
            if eject { ejectIfVolume(r.source) }
            #endif
        } else {
            addLog("✗ " + r.message)
            status = r.message
            lastSuccess = false
            feedback(success: false)
            let card = r.source.lastPathComponent
            let title: String
            let explanation: String
            if r.cancelled {
                title = "Copie arrêtée"
                explanation = "La copie de « \(card) » a été arrêtée avant la fin. Les fichiers déjà copiés sont rangés dans un dossier « _INCOMPLET »."
            } else if r.verifyFailed {
                title = "Copie incomplète"
                explanation = "La vérification a trouvé des fichiers manquants ou différents sur au moins un disque (détail dans le journal et dans Rapports_de_copie)."
            } else {
                title = "La copie a échoué"
                explanation = "\(r.message.replacingOccurrences(of: "Erreur : ", with: "").capitalizedFirst)\nVérifie que la carte et les disques sont bien branchés."
            }
            failure = CopyFailure(title: title,
                                  message: explanation + "\n\nNe formate pas la carte. « Recommencer » relance la même copie (même numéro de carte).",
                                  source: r.source,
                                  label: item?.label ?? "CamA",
                                  day: item?.day ?? day,
                                  project: item?.project ?? project)
        }
        if running.isEmpty { refresh() }
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
    /// Suit les branchements / débranchements pour tenir la colonne source à jour.
    private func observeVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        let mounted = nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.volumeMounted(url) }
        }
        let unmounted = nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCards()
                self?.refresh()
            }
        }
        volumeObservers = [mounted, unmounted]
    }

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
                    if let c = self.cards.first(where: { $0.url.path == url.path }), let prev = c.previous {
                        self.duplicatePrompt = OffloadResult(ok: false, duplicate: true, message: prev.message, source: url)
                    } else {
                        self.enqueue(url)
                    }
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

private extension String {
    var capitalizedFirst: String { self.prefix(1).uppercased() + String(self.dropFirst()) }
}
