//
//  ContentView.swift — C-SAFE
//  Écran principal, le même sur Mac, iPad et iPhone.
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
                VStack(spacing: 16) {
                    HeaderView()
                    ShootPanel(askName: { nameRequest = $0; newName = "" })
                    TransferPanel(onPickCard: { open(.card) }, onAddDestination: { open(.destination) })
                    CopyPanel(onPickCard: { open(.card) })
                    LogPanel()
                    Text("C-SAFE 1.0 · C-FOCUS · Etienne Chopin")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted.opacity(0.7))
                        .padding(.bottom, 8)
                }
                .padding(16)
                .frame(maxWidth: 780)
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
            case .destination:
                state.addDestination(url)
            case .card:
                state.pickCard(url)
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
        .overlay(
            Color.clear
                .allowsHitTesting(false)
                .alert("Cartes déjà branchées",
                       isPresented: Binding(get: { !state.alreadyMounted.isEmpty }, set: { if !$0 { state.alreadyMounted = [] } })) {
                    #if os(macOS)
                    Button("Tout décharger") { state.offloadAlreadyMounted() }
                    #endif
                    Button("Ignorer", role: .cancel) { state.alreadyMounted = [] }
                } message: {
                    Text(state.alreadyMounted.map(\.lastPathComponent).joined(separator: ", "))
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
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.cream, lineWidth: 2))
                .shadow(color: Theme.orange.opacity(0.35), radius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("C-SAFE")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.cream)
                Text("Déchargement sécurisé · par C-FOCUS")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.orange)
            }
            Spacer(minLength: 8)
            StatusPill()
        }
        .padding(.top, 4)
    }
}

struct StatusPill: View {
    @EnvironmentObject var state: AppState

    private var text: String {
        if state.busy { return "Copie" }
        if state.isMac { return state.watching ? "Surveillance" : "En pause" }
        return "Manuel"
    }

    private var color: Color {
        if state.busy { return Theme.orange }
        if state.isMac { return state.watching ? Theme.green : Theme.muted }
        return Theme.cyan
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

// MARK: - Tournage : projet, date, source, type

struct ShootPanel: View {
    @EnvironmentObject var state: AppState
    let askName: (NameRequest) -> Void

    var body: some View {
        Panel(title: "Tournage", icon: "film") {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Projet")
                TextField("Nom du projet", text: $state.project)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.cream)
                    .fieldLook()
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { sourcePicker; typePicker; datePicker }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) { sourcePicker; typePicker }
                    datePicker
                }
            }

            if !state.done.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Déjà copiées :")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                        ForEach(state.done, id: \.self) { s in
                            Label(s, systemImage: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Theme.green.opacity(0.14)))
                        }
                    }
                }
            }

            Toggle(isOn: $state.extraCard) {
                Text("Carte supplémentaire (2e, 3e…) pour une source déjà faite")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.cream)
            }
            .toggleStyle(.switch)
            .tint(Theme.orange)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Theme.cyan)
                Text(state.nextPreview)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.cyan)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cyan.opacity(0.10)))
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Source")
            ChoiceMenu(value: state.source,
                       items: state.availableSources,
                       removable: !Naming.defaultSources.contains(state.source),
                       onSelect: { state.selectSource($0) },
                       onOther: { askName(.source) },
                       onRemove: { state.removeSource($0) })
        }
        .frame(minWidth: 140)
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Type de caméra")
            ChoiceMenu(value: state.isSoundSource ? "—" : state.type,
                       items: state.types,
                       removable: true,
                       onSelect: { state.selectType($0) },
                       onOther: { askName(.type) },
                       onRemove: { state.removeType($0) })
                .disabled(state.isSoundSource)
                .opacity(state.isSoundSource ? 0.45 : 1)
        }
        .frame(minWidth: 140)
    }

    private var datePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Date de tournage")
            HStack(spacing: 8) {
                DatePicker("", selection: $state.shootDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Button("Aujourd'hui") { state.shootDate = Date() }
                    .buttonStyle(SecondaryButtonStyle())
                ShootDayMenu()
            }
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
            HStack(spacing: 6) {
                Text(state.shootDay.map { "J\($0)" } ?? "J –")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.orange)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.muted)
            }
            .fieldLook()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
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

    var body: some View {
        Menu {
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
            HStack {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold))
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

/// Carte source à gauche, disques de destination à droite (empilés sur iPhone).
struct TransferPanel: View {
    @EnvironmentObject var state: AppState
    let onPickCard: () -> Void
    let onAddDestination: () -> Void

    var body: some View {
        Panel(title: "Source → Destinations", icon: "arrow.left.arrow.right") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    SourceColumn(onPickCard: onPickCard).frame(maxWidth: .infinity)
                    flowArrow(systemName: "arrow.right")
                        .padding(.top, 40)
                    DestinationsColumn(onAdd: onAddDestination).frame(maxWidth: .infinity)
                }
                .frame(minWidth: 600)
                VStack(spacing: 10) {
                    SourceColumn(onPickCard: onPickCard)
                    flowArrow(systemName: "arrow.down")
                    DestinationsColumn(onAdd: onAddDestination)
                }
            }
        }
    }

    private func flowArrow(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .heavy))
            .foregroundStyle(state.busy ? Theme.orange : Theme.muted)
            .frame(width: 34, height: 34)
            .background(Circle().fill((state.busy ? Theme.orange : Theme.muted).opacity(0.15)))
    }
}

struct ColumnTitle: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.cream)
    }
}

struct SourceColumn: View {
    @EnvironmentObject var state: AppState
    let onPickCard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ColumnTitle(title: "Source (carte)", icon: "sdcard.fill")
            if state.cards.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.isMac ? "Branche une carte : elle apparaît ici avec son nom du Finder."
                                     : "Aucune carte choisie.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                    Button(action: onPickCard) { Label("Choisir une carte…", systemImage: "folder") }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(state.busy)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            ForEach(state.cards) { card in
                CardRow(card: card)
            }
        }
    }
}

struct CardRow: View {
    @EnvironmentObject var state: AppState
    let card: CardVolume

    private var isActive: Bool { state.activeCard?.path == card.url.path }
    private var isCopied: Bool { state.copiedCards.contains(card.url.path) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sdcard.fill")
                .font(.system(size: 20))
                .foregroundStyle(isCopied ? Theme.green : (card.isCamera ? Theme.orange : Theme.muted))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(isCopied ? Theme.green : Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if isActive {
                Text("\(Int(state.progress * 100)) %")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.orange)
            } else {
                if !state.busy && !isCopied && (!state.watching || !card.isCamera) {
                    Button { state.copyCard(card) } label: {
                        Image(systemName: "arrow.right.circle.fill").font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.orange)
                    .help("Copier cette carte")
                }
                #if os(macOS)
                if card.ejectable {
                    Button { state.ejectCard(card) } label: {
                        Image(systemName: "eject.fill").font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.cream)
                    .help("Éjecter la carte")
                }
                #else
                Button { state.forgetCard(card) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                #endif
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isActive ? Theme.orange : (isCopied ? Theme.green : Color.clear), lineWidth: 1.5))
    }

    private var subtitle: String {
        if isActive { return "Copie en cours…" }
        if isCopied { return state.isMac ? "✓ Copiée et vérifiée — tu peux éjecter" : "✓ Copiée et vérifiée — tu peux la retirer" }
        if !card.isCamera { return "Pas reconnue comme carte caméra" + (card.detail.isEmpty ? "" : " · \(card.detail)") }
        return card.detail.isEmpty ? "Carte caméra" : card.detail
    }
}

// MARK: - Disques de destination

struct DestinationsColumn: View {
    @EnvironmentObject var state: AppState
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ColumnTitle(title: "Destinations (disques)", icon: "externaldrive.fill")
            if state.destinations.isEmpty {
                Text("Aucun disque. Ajoute au moins 2 disques : chaque carte y sera copiée en même temps.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            ForEach(Array(state.destinations.enumerated()), id: \.element.id) { index, d in
                let ok = state.isReachable(d)
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill((ok ? Theme.cyan : Theme.red).opacity(0.15)).frame(width: 38, height: 38)
                        Text("\(index + 1)")
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(ok ? Theme.cyan : Theme.red)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.cream)
                            .lineLimit(1)
                        Text(ok ? state.freeSpace(d) : "Introuvable — branche le disque")
                            .font(.system(size: 12))
                            .foregroundStyle(ok ? Theme.muted : Theme.red)
                    }
                    Spacer()
                    if state.busy {
                        Text("\(Int(state.progress * 100)) %")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.orange)
                    } else {
                        Button(role: .destructive) { state.removeDestination(d) } label: {
                            Image(systemName: "trash").foregroundStyle(Theme.muted)
                        }
                        .buttonStyle(.plain)
                        .help("Retirer ce disque")
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.field))
            }
            Button(action: onAdd) {
                Label("Ajouter un disque", systemImage: "plus.circle.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.busy)
            if state.destinations.count == 1 {
                Label("Un seul disque : ajoute un 2e disque pour être en sécurité.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
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
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 22))
                    .foregroundStyle(statusColor)
                Text(state.status)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.cream)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.busy || state.lastSuccess != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: state.progress)
                        .progressViewStyle(.linear)
                        .tint(state.lastSuccess == true ? Theme.green : (state.lastSuccess == false ? Theme.red : Theme.orange))
                    Text(state.progressText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
            }

            #if os(macOS)
            Button {
                state.toggleWatching()
            } label: {
                Label(state.watching ? "Arrêter la surveillance" : "Démarrer la surveillance",
                      systemImage: state.watching ? "stop.circle.fill" : "play.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle(color: state.watching ? Theme.red : Theme.orange))
            Text(state.watching ? "Branche une carte : elle sera copiée, vérifiée puis éjectée toute seule."
                                : "Démarre la surveillance puis branche tes cartes les unes après les autres.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                Button(action: onPickCard) { Label("Choisir une carte…", systemImage: "folder") }
                    .buttonStyle(SecondaryButtonStyle())
                if state.busy {
                    Button(role: .destructive) { state.cancelCopy() } label: { Label("Annuler la copie", systemImage: "xmark.circle") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Toggle("Éjecter la carte à la fin", isOn: $state.eject)
                    .toggleStyle(.switch)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.cream)
                    .onChange(of: state.eject) { state.save() }
            }
            #else
            Button(action: onPickCard) {
                Label("Choisir la carte à copier", systemImage: "sdcard")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(state.busy)
            if state.busy {
                Button(role: .destructive) { state.cancelCopy() } label: { Label("Annuler la copie", systemImage: "xmark.circle") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Text("Branche le lecteur de carte et les disques (hub USB-C), puis choisis la carte dans Fichiers. Garde l'app ouverte pendant la copie.")
                .font(.system(size: 12))
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

// MARK: - Journal

struct LogPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Panel(title: "Journal", icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.log.suffix(80).reversed()) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(line.time)
                            .foregroundStyle(Theme.muted.opacity(0.8))
                        Text(line.text)
                            .foregroundStyle(color(for: line.text))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            }
            .textSelection(.enabled)
        }
    }

    private func color(for text: String) -> Color {
        if text.hasPrefix("✓") { return Theme.green }
        if text.hasPrefix("✗") || text.hasPrefix("⚠") { return Theme.red }
        if text.hasPrefix("→") || text.hasPrefix("Carte détectée") { return Theme.orange }
        return Theme.cream
    }
}
