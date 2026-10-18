//
//  ContentView.swift — C-SAFE
//  Écran principal (Mac, iPad, iPhone) — version compacte, à garder dans un coin du bureau.
//

import SwiftUI
import UniformTypeIdentifiers

private enum ImportTarget { case destination, card }
/// Ajout d'un nom personnalisé : une source pour une carte, ou un type pour une source
struct NameRequest: Identifiable {
    enum Kind { case source, type }
    let kind: Kind
    var card: CardVolume? = nil   // carte à laquelle attribuer la nouvelle source
    var source: String = ""       // source à laquelle attribuer le nouveau type
    var id: String { "\(kind)-\(card?.key ?? "")-\(source)" }
    var title: String { kind == .source ? "Nouvelle source" : "Nouveau type de caméra" }
    var hint: String { kind == .source ? "Ex. Drone, GoPro-Casque, Plateau" : "Ex. FX6, Mavic 3, Alexa" }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var importTarget: ImportTarget = .destination
    @State private var showImporter = false
    @State private var nameRequest: NameRequest?
    @State private var newName = ""

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            #if os(macOS)
            // Mac : hauteur pile à la taille du contenu, largeur réglable (et retenue par macOS)
            VStack(spacing: 0) {
                panels.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minWidth: 400, idealWidth: 430, maxWidth: 760)
            #else
            ScrollView {
                panels
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
            }
            #endif
        }
        .preferredColorScheme(.dark)
        .tint(Theme.orange)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            switch importTarget {
            case .destination: state.addDestination(url)
            case .card: state.pickCard(url)
            }
        }
        .alert("Carte déjà déchargée",
               isPresented: Binding(get: { state.duplicatePrompt != nil }, set: { if !$0 { state.duplicatePrompt = nil } }),
               presenting: state.duplicatePrompt) { r in
            Button("Copier quand même") { state.confirmDuplicate(r) }
            Button("Annuler", role: .cancel) { state.duplicatePrompt = nil }
        } message: { r in
            Text(r.message + "\n\nLa copier quand même sous un nouveau numéro ?")
        }
        .background(
            Color.clear
                .alert("C-SAFE",
                       isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
                    Button("OK", role: .cancel) { state.errorMessage = nil }
                } message: {
                    Text(state.errorMessage ?? "")
                }
        )
        .onChange(of: state.project) { state.refresh() }
        .onChange(of: state.shootDate) { state.refresh() }
    }

    private var panels: some View {
        VStack(spacing: 8) {
                    HeaderView()
                        .alert(state.failure?.title ?? "",
                               isPresented: Binding(get: { state.failure != nil }, set: { if !$0 { state.failure = nil } }),
                               presenting: state.failure) { f in
                            Button("Recommencer") { state.retry(f) }
                            Button("Fermer", role: .cancel) { state.failure = nil }
                        } message: { f in
                            Text(f.message)
                        }
                    ShootPanel(askName: { nameRequest = $0; newName = "" })
                        .alert(nameRequest?.title ?? "", isPresented: Binding(get: { nameRequest != nil }, set: { if !$0 { nameRequest = nil } })) {
                        TextField(nameRequest?.hint ?? "", text: $newName)
                        Button("Ajouter") {
                        if let r = nameRequest {
                        if r.kind == .source { state.addSource(newName, for: r.card) } else { state.addType(newName, for: r.source) }
                        }
                        nameRequest = nil
                        }
                        Button("Annuler", role: .cancel) { nameRequest = nil }
                        } message: {
                        Text("Il restera dans la liste pour les prochaines fois.")
                        }
                    TransferPanel(onPickCard: { open(.card) }, onAddDestination: { open(.destination) },
                                  askName: { nameRequest = $0; newName = "" })
                    CopyPanel(onPickCard: { open(.card) })
                    LogPanel()
                }
        .padding(10)
    }

    private func open(_ target: ImportTarget) {
        importTarget = target
        showImporter = true
    }
}

// MARK: - En-tête

struct HeaderView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.cream, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 0) {
                Text("C-SAFE")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.cream)
                Text("par C-FOCUS")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.orange)
            }
            Spacer(minLength: 6)
            StatusPill()
        }
    }
}

struct StatusPill: View {
    @EnvironmentObject var state: AppState

    private var text: String {
        if state.busy { return "Copie" }
        if state.isMac { return state.watching ? "Copie auto" : "En pause" }
        return "Manuel"
    }

    private var color: Color {
        if state.busy { return Theme.orange }
        if state.isMac { return state.watching ? Theme.green : Theme.muted }
        return Theme.cyan
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

// MARK: - Tournage : projet, source, type, date, jour

struct ShootPanel: View {
    @EnvironmentObject var state: AppState
    let askName: (NameRequest) -> Void

    var body: some View {
        Panel(title: "Tournage", icon: "film") {
            HStack(spacing: 6) {
                FieldLabel(text: "Projet").frame(width: 44, alignment: .leading)
                TextField("Nom du projet", text: $state.project)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.cream)
                    .fieldLook()
            }
            HStack(spacing: 6) {
                FieldLabel(text: "Date").frame(width: 44, alignment: .leading)
                DatePicker("", selection: $state.shootDate, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .controlSize(.small)
                if state.isToday {
                    Text("● Aujourd'hui")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.green)
                } else {
                    Button { state.shootDate = Date() } label: { Label("Revenir à aujourd'hui", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer(minLength: 0)
                DayBadge()
            }
            DayInfo()

            if !state.done.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Text("Faites :")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.muted)
                        ForEach(state.done, id: \.self) { s in
                            Text("✓ \(s)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.green.opacity(0.14)))
                        }
                    }
                }
            }

        }
    }
}

/// Numéro du jour de tournage, calculé automatiquement d'après la date
struct DayBadge: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Text(state.shootDay.map { "J\($0)" } ?? "J –")
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.orange)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.orange.opacity(0.14)))
            .help("Jour de tournage, numéroté automatiquement dans l'ordre des dates")
    }
}

/// Explication du J, ou alerte si la date est plus ancienne que des jours déjà copiés
struct DayInfo: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        let j = state.shootDay ?? 1
        if state.dayShift.isEmpty {
            Text(state.dayExisting ? "J\(j) : jour de tournage déjà commencé, les cartes s'y ajoutent."
                                   : (j == 1 ? "J1 : premier jour de tournage du projet." : "J\(j) : nouveau jour de tournage (après J\(j - 1))."))
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Label("Le \(Naming.shortDate(state.dateString)) est avant " +
                      state.dayShift.map { "J\($0.j) (\(Naming.shortDate($0.date)))" }.joined(separator: ", ") + ".",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                Text("Pour garder l'ordre, ce jour devient J\(j) et les jours suivants sont décalés sur tous les disques : " +
                     state.dayShift.map { "J\($0.j)→J\($0.j + 1)" }.joined(separator: ", ") + ".")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.cream)
                    .fixedSize(horizontal: false, vertical: true)
                Button { state.renumberFollowingDays() } label: { Label("Renuméroter les jours suivants", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(state.busy)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.orange.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.orange.opacity(0.5), lineWidth: 1))
        }
    }
}

/// Menu de choix avec « Autre… » pour ajouter, et « Retirer » pour enlever de la liste.
struct ChoiceMenu: View {
    let value: String
    let items: [String]
    let removable: Bool
    let onSelect: (String) -> Void
    let onOther: () -> Void
    let onRemove: (String) -> Void
    var extraTitle: String = ""
    var extraItems: [String] = []
    var extraLabel: (String) -> String = { $0 }
    var onSelectExtra: (String) -> Void = { _ in }

    var body: some View {
        Menu {
            // « Carte suivante » d'abord : c'est le choix le plus fréquent pendant un tournage
            if !extraItems.isEmpty {
                Section(extraTitle) {
                    ForEach(extraItems, id: \.self) { item in
                        Button { onSelectExtra(item) } label: { Label(extraLabel(item), systemImage: "plus.square.on.square") }
                    }
                }
                Divider()
            }
            ForEach(items, id: \.self) { item in
                Button {
                    onSelect(item)
                } label: {
                    if item == value { Label(item, systemImage: "checkmark") } else { Text(item) }
                }
            }
            Divider()
            Button { onOther() } label: { Label("Autre…", systemImage: "plus") }
            if removable && items.contains(value) {
                Button(role: .destructive) { onRemove(value) } label: {
                    Label("Retirer « \(value) » de la liste", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.muted)
            }
            .fieldLook()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

// MARK: - Source → Destinations

/// Carte source à gauche, disques de destination à droite (empilés si la fenêtre est étroite).
struct TransferPanel: View {
    @EnvironmentObject var state: AppState
    let onPickCard: () -> Void
    let onAddDestination: () -> Void
    let askName: (NameRequest) -> Void

    var body: some View {
        Panel(title: "Source → Destinations", icon: "arrow.left.arrow.right") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    SourceColumn(onPickCard: onPickCard, askName: askName).frame(maxWidth: .infinity)
                    flowArrow("arrow.right").padding(.top, 22)
                    DestinationsColumn(onAdd: onAddDestination).frame(maxWidth: .infinity)
                }
                .frame(minWidth: 400)
                VStack(spacing: 6) {
                    SourceColumn(onPickCard: onPickCard, askName: askName)
                    flowArrow("arrow.down")
                    DestinationsColumn(onAdd: onAddDestination)
                }
            }
        }
    }

    private func flowArrow(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(state.busy ? Theme.orange : Theme.muted)
            .frame(width: 20, height: 20)
            .background(Circle().fill((state.busy ? Theme.orange : Theme.muted).opacity(0.15)))
    }
}

struct ColumnTitle: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.cream)
    }
}

struct SourceColumn: View {
    @EnvironmentObject var state: AppState
    let onPickCard: () -> Void
    let askName: (NameRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ColumnTitle(title: "Source", icon: "sdcard.fill")
            if state.cards.isEmpty {
                Text(state.isMac ? "Branche une carte : elle apparaît ici." : "Aucune carte choisie.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            ForEach(state.cards) { card in
                CardRow(card: card, askName: askName)
            }
            Button(action: onPickCard) { Label("Choisir une carte…", systemImage: "folder") }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(state.busy)
        }
    }
}

struct CardRow: View {
    @EnvironmentObject var state: AppState
    let card: CardVolume
    let askName: (NameRequest) -> Void

    private var run: RunningCopy? { state.runningCopy(for: card) }
    private var isCopied: Bool { card.previous != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "sdcard.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(isCopied ? Theme.green : (card.isCamera ? Theme.orange : Theme.muted))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(card.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.cream)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(isCopied ? Theme.green : Theme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 2)
                if let run {
                    Text("\(Int(run.progress * 100)) %")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.orange)
                    Button { state.cancelCopy(of: card) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    .help("Annuler la copie de cette carte")
                } else {
                    #if os(macOS)
                    if card.ejectable {
                        Button { state.ejectCard(card) } label: {
                            Image(systemName: "eject.fill").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.cream)
                        .help("Éjecter la carte")
                    }
                    #else
                    Button { state.forgetCard(card) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    #endif
                }
            }

            if let run {
                ProgressView(value: run.progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.orange)
                Text("\(run.label) · \(run.text)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            } else if !isCopied {
                let source = state.sourceFor(card)
                let choices = state.sourceChoices(for: card)
                HStack(spacing: 5) {
                    ChoiceMenu(value: source,
                               items: choices.fresh,
                               removable: !Naming.defaultSources.contains(source),
                               onSelect: { state.assign($0, to: card) },
                               onOther: { askName(NameRequest(kind: .source, card: card)) },
                               onRemove: { state.removeSource($0) },
                               extraTitle: "Déjà copiées ce jour — carte suivante",
                               extraItems: choices.doneToday,
                               extraLabel: { "\($0) (carte suivante)" },
                               onSelectExtra: { state.assign($0, to: card) })
                    let isSound = Naming.isSound(Naming.label(source: source))
                    ChoiceMenu(value: isSound ? "—" : state.typeFor(source: source),
                               items: state.types,
                               removable: true,
                               onSelect: { state.setType($0, for: source) },
                               onOther: { askName(NameRequest(kind: .type, source: source)) },
                               onRemove: { state.removeType($0) })
                        .disabled(isSound || source == "—")
                        .opacity(isSound ? 0.45 : 1)
                        .help("Type de caméra")
                }
                if !state.previewFor(card).isEmpty {
                    Label(state.previewFor(card), systemImage: "folder.fill")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.cyan)
                        .lineLimit(1)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(run != nil ? Theme.orange : (isCopied ? Theme.green : Color.clear), lineWidth: 1.2))
    }

    private var subtitle: String {
        if run != nil { return "Copie en cours…" }
        if let p = card.previous { return "✓ Déjà copiée : \(p.short)" }
        if !card.isCamera { return "Pas une carte caméra" }
        return card.detail.isEmpty ? "Carte caméra" : card.detail
    }
}

// MARK: - Disques de destination

struct DestinationsColumn: View {
    @EnvironmentObject var state: AppState
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ColumnTitle(title: "Destinations", icon: "externaldrive.fill")
            ForEach(Array(state.destinations.enumerated()), id: \.element.id) { index, d in
                let ok = state.isReachable(d)
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(ok ? Theme.cyan : Theme.red)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill((ok ? Theme.cyan : Theme.red).opacity(0.15)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(d.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.cream)
                            .lineLimit(1)
                        Text(ok ? state.freeSpace(d) : "Introuvable — branche le disque")
                            .font(.system(size: 10))
                            .foregroundStyle(ok ? Theme.muted : Theme.red)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if state.busy {
                        Text("\(Int(state.progress * 100)) %")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.orange)
                    } else {
                        Button(role: .destructive) { state.removeDestination(d) } label: {
                            Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                        .buttonStyle(.plain)
                        .help("Retirer ce disque")
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            }
            Button(action: onAdd) { Label("Ajouter un disque", systemImage: "plus") }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(state.busy)
            if state.destinations.count < 2 {
                Text(state.destinations.isEmpty ? "Ajoute 2 disques : chaque carte y est copiée en même temps."
                                                : "⚠ Ajoute un 2e disque pour être en sécurité.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.orange)
            }
        }
    }
}

// MARK: - Copie

struct CopyPanel: View {
    @EnvironmentObject var state: AppState
    let onPickCard: () -> Void

    var body: some View {
        Panel(title: "Copie", icon: "sdcard.fill") {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(statusColor)
                Text(state.status)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(2)
            }
            if state.busy || state.lastSuccess != nil {
                ProgressView(value: min(1, max(0, state.progress)))
                    .progressViewStyle(.linear)
                    .tint(state.lastSuccess == true ? Theme.green : (state.lastSuccess == false ? Theme.red : Theme.orange))
                Text(state.busy ? "\(state.running.count) copie(s) en cours — détail sur chaque carte" : state.progressText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }

            if !state.parallelInfo.isEmpty {
                Label(state.parallelInfo, systemImage: "square.stack.3d.down.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Choisi automatiquement d'après tes disques. Chaque carte est toujours copiée en entier sur tous les disques.")
            }

            #if os(macOS)
            Button {
                state.watching ? state.stopCopy() : state.startCopy()
            } label: {
                Label(state.watching ? "Arrêter la copie automatique" : "Démarrer la copie",
                      systemImage: state.watching ? "stop.circle.fill" : "play.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle(color: state.watching ? Theme.red : Theme.orange))
            Text(state.watching ? "Chaque carte branchée est copiée, vérifiée puis éjectée."
                                : "Rien n'est copié tant que tu n'as pas cliqué « Démarrer la copie ».")
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                if state.busy {
                    Button(role: .destructive) { state.cancelCopy() } label: { Label(state.running.count > 1 ? "Tout annuler" : "Annuler", systemImage: "xmark.circle") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Toggle("Éjecter à la fin", isOn: $state.eject)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.cream)
                    .onChange(of: state.eject) { state.save() }
            }
            #else
            Button { state.startCopy() } label: {
                Label("Démarrer la copie", systemImage: "play.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state.busy || state.cards.isEmpty)
            if state.busy {
                Button(role: .destructive) { state.cancelCopy() } label: { Label(state.running.count > 1 ? "Tout annuler" : "Annuler", systemImage: "xmark.circle") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Text("Branche le lecteur et les disques (hub USB-C), choisis la carte, puis « Démarrer la copie ». Garde l'app ouverte.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
            #endif
        }
    }

    private var statusIcon: String {
        if state.busy { return "arrow.triangle.2.circlepath" }
        switch state.lastSuccess {
        case .some(true): return "checkmark.seal.fill"
        case .some(false): return "exclamationmark.octagon.fill"
        case .none: return "sdcard"
        }
    }

    private var statusColor: Color {
        if state.busy { return Theme.orange }
        switch state.lastSuccess {
        case .some(true): return Theme.green
        case .some(false): return Theme.red
        case .none: return Theme.muted
        }
    }
}

// MARK: - Journal (replié par défaut pour gagner de la place)

struct LogPanel: View {
    @EnvironmentObject var state: AppState
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("JOURNAL")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1)
                    if !expanded, let last = state.log.last {
                        Text(last.text)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(color(for: last.text))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.log.suffix(40).reversed()) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.time).foregroundStyle(Theme.muted.opacity(0.8))
                            Text(line.text)
                                .foregroundStyle(color(for: line.text))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 10, design: .monospaced))
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }

    private func color(for text: String) -> Color {
        if text.hasPrefix("✓") { return Theme.green }
        if text.hasPrefix("✗") || text.hasPrefix("⚠") { return Theme.red }
        if text.hasPrefix("→") || text.hasPrefix("Carte détectée") { return Theme.orange }
        return Theme.cream
    }
}
