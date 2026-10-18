//
//  ContentView.swift — C-SAFE
//  Écran principal (Mac, iPad, iPhone) — version compacte, à garder dans un coin du bureau.
//

import SwiftUI
import UniformTypeIdentifiers

private enum ImportTarget { case destination, card }
enum NameRequest: Identifiable {
    case source, type
    var id: Int { self == .source ? 0 : 1 }
    var title: String { self == .source ? "Nouvelle source" : "Nouveau type de caméra" }
    var hint: String { self == .source ? "Ex. Drone, GoPro-Casque, Plateau" : "Ex. FX6, Mavic 3, Alexa" }
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
            ScrollView {
                VStack(spacing: 8) {
                    HeaderView()
                    ShootPanel(askName: { nameRequest = $0; newName = "" })
                    TransferPanel(onPickCard: { open(.card) }, onAddDestination: { open(.destination) })
                    CopyPanel(onPickCard: { open(.card) })
                    LogPanel()
                }
                .padding(10)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .alert(nameRequest?.title ?? "", isPresented: Binding(get: { nameRequest != nil }, set: { if !$0 { nameRequest = nil } })) {
                TextField(nameRequest?.hint ?? "", text: $newName)
                Button("Ajouter") {
                    if nameRequest == .source { state.addSource(newName) } else { state.addType(newName) }
                    nameRequest = nil
                }
                Button("Annuler", role: .cancel) { nameRequest = nil }
            } message: {
                Text("Il restera dans la liste pour les prochaines fois.")
            }
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
        .onChange(of: state.extraCard) { state.refresh() }
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
                FieldLabel(text: "Source").frame(width: 44, alignment: .leading)
                ChoiceMenu(value: state.extraCard ? "\(state.source) · carte suiv." : state.source,
                           items: state.availableSources,
                           removable: !Naming.defaultSources.contains(state.source),
                           onSelect: { state.extraCard = false; state.selectSource($0) },
                           onOther: { askName(.source) },
                           onRemove: { state.removeSource($0) },
                           extraTitle: "Déjà copiées — carte suivante",
                           extraItems: state.done,
                           extraLabel: { state.nextCardLabel(for: $0) },
                           onSelectExtra: { state.selectNextCard(of: $0) })
                ChoiceMenu(value: state.isSoundSource ? "—" : state.type,
                           items: state.types,
                           removable: true,
                           onSelect: { state.selectType($0) },
                           onOther: { askName(.type) },
                           onRemove: { state.removeType($0) })
                    .disabled(state.isSoundSource)
                    .opacity(state.isSoundSource ? 0.45 : 1)
                    .help("Type de caméra")
            }
            HStack(spacing: 6) {
                FieldLabel(text: "Date").frame(width: 44, alignment: .leading)
                DatePicker("", selection: $state.shootDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .controlSize(.small)
                Button("Aujourd'hui") { state.shootDate = Date() }
                    .buttonStyle(SecondaryButtonStyle())
                ShootDayMenu()
                Spacer(minLength: 0)
            }

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

            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                Text(state.nextPreview)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
            }
            .foregroundStyle(Theme.cyan)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.cyan.opacity(0.10)))
        }
    }
}

/// Jour de tournage J1, J2… — les jours déjà utilisés sont signalés et bloqués.
struct ShootDayMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Menu {
            Button {
                state.selectShootDay(nil)
            } label: {
                if state.shootDay == nil { Label("Sans numéro de jour", systemImage: "checkmark") } else { Text("Sans numéro de jour") }
            }
            Divider()
            ForEach(state.shootDayChoices, id: \.self) { j in
                let used = state.usedDays[j]
                let isToday = used == state.dateString
                Button {
                    state.selectShootDay(j)
                } label: {
                    if state.shootDay == j {
                        Label(isToday ? "J\(j) · ce jour" : "J\(j)", systemImage: "checkmark")
                    } else if let used, !isToday {
                        Label("J\(j) · déjà utilisé le \(Naming.shortDate(used))", systemImage: "lock.fill")
                    } else {
                        Text("J\(j)")
                    }
                }
                .disabled(used != nil && !isToday)
            }
        } label: {
            HStack(spacing: 4) {
                Text(state.shootDay.map { "J\($0)" } ?? "J –")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.orange)
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
        .fixedSize()
        .help("Jour de tournage")
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
            ForEach(items, id: \.self) { item in
                Button {
                    onSelect(item)
                } label: {
                    if item == value { Label(item, systemImage: "checkmark") } else { Text(item) }
                }
            }
            if !extraItems.isEmpty {
                Divider()
                Section(extraTitle) {
                    ForEach(extraItems, id: \.self) { item in
                        Button { onSelectExtra(item) } label: { Label(extraLabel(item), systemImage: "plus.square.on.square") }
                    }
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

    var body: some View {
        Panel(title: "Source → Destinations", icon: "arrow.left.arrow.right") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    SourceColumn(onPickCard: onPickCard).frame(maxWidth: .infinity)
                    flowArrow("arrow.right").padding(.top, 22)
                    DestinationsColumn(onAdd: onAddDestination).frame(maxWidth: .infinity)
                }
                .frame(minWidth: 400)
                VStack(spacing: 6) {
                    SourceColumn(onPickCard: onPickCard)
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
                CardRow(card: card)
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

    private var isActive: Bool { state.activeCard?.path == card.url.path }
    private var isCopied: Bool { state.copiedCards.contains(card.url.path) }

    var body: some View {
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
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if isActive {
                Text("\(Int(state.progress * 100)) %")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.orange)
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
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isActive ? Theme.orange : (isCopied ? Theme.green : Color.clear), lineWidth: 1.2))
    }

    private var subtitle: String {
        if isActive { return "Copie en cours…" }
        if isCopied { return state.isMac ? "✓ Copiée et vérifiée — éjectable" : "✓ Copiée et vérifiée" }
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
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                    .tint(state.lastSuccess == true ? Theme.green : (state.lastSuccess == false ? Theme.red : Theme.orange))
                Text(state.progressText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
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
                    Button(role: .destructive) { state.cancelCopy() } label: { Label("Annuler", systemImage: "xmark.circle") }
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
                Button(role: .destructive) { state.cancelCopy() } label: { Label("Annuler", systemImage: "xmark.circle") }
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
