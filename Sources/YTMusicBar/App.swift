import AppKit
import Darwin
import SwiftUI
import YTMusicCore

enum AppTheme {
    static let accent = Color(red: 0.96, green: 0.23, blue: 0.20)
    /// The popover keeps one fixed size on every page so it never jumps when navigating.
    static let panelWidth: CGFloat = 420
    static let panelHeight: CGFloat = 680
    static let hover = Animation.easeOut(duration: 0.15)
    static let swap = Animation.easeInOut(duration: 0.3)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `PlayerStore`; awaited before the process exits so mpv is stopped on Cmd-Q, "Sair" and logout.
    @MainActor static var terminationHandler: (() async -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let handler = Self.terminationHandler else { return .terminateNow }
        Self.terminationHandler = nil
        Task { @MainActor in
            await handler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct YTMusicBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = PlayerStore()

    init() {
        guard ProcessInfo.processInfo.environment["YTMUSICBAR_VALIDATE_LOCAL"] == "1" else { return }
        if let error = LocalMusicPlayer.validationError() {
            FileHandle.standardError.write(Data("LocalPlayer: FAIL · \(error)\n".utf8)); Darwin.exit(1)
        }
        print("LocalPlayer: OK"); Darwin.exit(0)
    }

    /// The whole app is the menu bar popover: player, catalog, settings and access setup.
    var body: some Scene {
        MenuBarExtra {
            PlayerPanel(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.snapshot?.isPaused == false ? "waveform" : "music.note")
                Text(store.menuTitle).lineLimit(1)
            }
            .accessibilityLabel(store.menuTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - View-local state (this toolchain has no SwiftUI macro plugin, so no @State)

private final class TextDraft: ObservableObject { @Published var text = "" }
private final class HoverState: ObservableObject { @Published var isHovering = false }
private final class DragState: ObservableObject { @Published var value: Double? }
/// Drives the skeleton pulse. `@State` is a macro in this SDK and its plugin does not resolve under
/// SwiftPM here, so every piece of view state in this file is an `ObservableObject` instead.
private final class PulseState: ObservableObject { @Published var dim = false }
private final class AuthDraft: ObservableObject {
    @Published var headers = ""
    @Published var isSaving = false
    @Published var message: String?
    @Published var isError = false
    @Published var succeeded = false
}

// MARK: - Interaction primitives

/// Shrinks slightly while pressed; used by every button in the popover.
private struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.22), value: configuration.isPressed)
    }
}

// MARK: - Liquid Glass (macOS 26+)

/// On macOS 26 the controls adopt Liquid Glass; earlier systems keep the styles below.
private extension View {
    /// Standard glass button, falling back to the custom press style.
    @ViewBuilder
    func glassButton(fallback: PressScaleStyle = PressScaleStyle()) -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glass) } else { buttonStyle(fallback) }
    }

    /// Prominent glass button for primary actions, falling back to bordered prominent.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    /// The menu bar popover already draws Liquid Glass behind its content on macOS 26;
    /// painting a material on top would hide it (and stack glass on glass).
    @ViewBuilder
    func panelBackground() -> some View {
        if #available(macOS 26.0, *) { self } else { background(.regularMaterial) }
    }
}

/// Icon-only button with a circular hover highlight and press feedback.
private struct IconButton: View {
    let systemName: String
    var font: Font = .body
    var size: CGFloat = 28
    var tint: Color? = nil
    var isDisabled = false
    var help = ""
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(font)
                .foregroundStyle(tint ?? (hover.isHovering ? Color.primary : Color.secondary))
                .frame(width: size, height: size)
                .background(Color.primary.opacity(hover.isHovering && !isDisabled ? 0.08 : 0), in: Circle())
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .onHover { hover.isHovering = $0 }
        .animation(AppTheme.hover, value: hover.isHovering)
        .animation(AppTheme.hover, value: isDisabled)
        .help(help)
    }
}

// MARK: - Popover root

struct PlayerPanel: View {
    @ObservedObject var store: PlayerStore

    var body: some View {
        ZStack(alignment: .top) {
            switch store.panelPage {
            case .player: PlayerHome(store: store).transition(pageTransition)
            case .settings: SettingsPanel(store: store).transition(pageTransition)
            case .auth: AuthSetupView(store: store) { store.go(to: .player) }.transition(pageTransition)
            }
        }
        .padding(16)
        .frame(width: AppTheme.panelWidth, height: AppTheme.panelHeight, alignment: .top)
        .clipped()
        .panelBackground()
        .tint(AppTheme.accent)
        .onAppear { store.prepareCatalog(); store.requestRefresh() }
    }

    /// Forward navigation slides in from the right; going back slides in from the left.
    private var pageTransition: AnyTransition {
        let forward = store.navigatedForward
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }
}

private struct PanelHeader: View {
    let title: String
    let onBack: (() -> Void)?
    let trailing: AnyView

    var body: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Label("Voltar", systemImage: "chevron.left").padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(PressScaleStyle(scale: 0.96))
                .keyboardShortcut(.cancelAction)
            } else {
                Label(title, systemImage: "music.note.list").font(.headline)
            }
            Spacer()
            if onBack != nil { Text(title).font(.headline); Spacer() }
            trailing
        }
        .frame(height: 28)
    }
}

// MARK: - Player page

private struct PlayerHome: View {
    @ObservedObject var store: PlayerStore
    @StateObject private var draft = TextDraft()
    @StateObject private var searchHover = HoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "YTMusicBar", onBack: nil, trailing: AnyView(
                IconButton(systemName: "gearshape", font: .callout, help: "Ajustes") { store.go(to: .settings) }
            ))

            ZStack(alignment: .topLeading) {
                if let snapshot = store.snapshot {
                    VStack(alignment: .leading, spacing: 12) {
                        CompactNowPlaying(snapshot: snapshot, store: store)
                        ProgressLine(snapshot: snapshot, store: store)
                        HStack(spacing: 12) {
                            Transport(snapshot: snapshot, store: store)
                            Spacer()
                            VolumeControl(store: store).frame(width: 130)
                        }
                    }
                    .transition(.opacity)
                } else if store.isConfigured {
                    IdleNowPlaying(message: store.connectionMessage).transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Configure o acesso ao YouTube Music para buscar e reproduzir.").font(.callout).foregroundStyle(.secondary)
                        Button("Configurar acesso…") { store.go(to: .auth) }.glassProminentButton()
                    }
                    .transition(.opacity)
                }
            }
            .animation(AppTheme.swap, value: store.snapshot == nil)

            if let message = store.actionMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar músicas ou artistas", text: $draft.text)
                    .textFieldStyle(.plain)
                    .onSubmit { store.search(draft.text) }
                if !draft.text.isEmpty {
                    IconButton(systemName: "xmark.circle.fill", font: .caption, size: 20, help: "Limpar busca") {
                        draft.text = ""; store.clearSearch()
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary.opacity(searchHover.isHovering ? 0.7 : 0.5), in: RoundedRectangle(cornerRadius: 8))
            .onHover { searchHover.isHovering = $0 }
            .animation(AppTheme.hover, value: searchHover.isHovering)
            .animation(.snappy(duration: 0.2), value: draft.text.isEmpty)

            Picker("Seção", selection: $store.catalogTab) {
                ForEach(store.availableTabs) { tab in Text(tab.title).tag(tab) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .animation(.snappy(duration: 0.25), value: store.availableTabs.count)

            CatalogList(store: store)
                .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Text(footerText).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(AppTheme.swap, value: footerText)
                Spacer()
                Button("Sair") { store.stopAndQuit() }
                    .glassButton(fallback: PressScaleStyle(scale: 0.96)).keyboardShortcut("q").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.25), value: store.actionMessage == nil)
        .onChange(of: store.lastQuery) { _, query in if draft.text != query { draft.text = query } }
    }

    private var footerText: String {
        if store.isCatalogLoading { return "Carregando…" }
        if store.catalogTab == .forYou, store.forYouOpenSection == nil {
            let sections = store.homeSections.count
            return sections == 1 ? "1 categoria" : "\(sections) categorias"
        }
        let count = store.visibleItems.count
        guard count > 0 else { return store.connectionMessage }
        return count == 1 ? "1 item" : "\(count) itens"
    }
}

private struct IdleNowPlaying: View {
    let message: String

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(url: nil, cornerRadius: 8).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nada tocando").font(.headline).foregroundStyle(.secondary)
                Text(message).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer()
        }
    }
}

// MARK: - Catalog

private struct CatalogList: View {
    @ObservedObject var store: PlayerStore

    var body: some View {
        let items = store.visibleItems
        ZStack {
            if store.isCatalogLoading && items.isEmpty {
                SkeletonList(
                    rows: 7,
                    leading: store.catalogTab == .forYou ? 32 : 40,
                    showsChevron: store.catalogTab == .forYou
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
            } else if store.catalogTab == .forYou, store.forYouOpenSection == nil, !store.homeSections.isEmpty {
                categoryMenu
            } else if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: emptyIcon).font(.title2).foregroundStyle(.tertiary)
                    if store.isRenewingSession {
                        Text("Renovando a sessão…").font(.callout).foregroundStyle(.secondary)
                        Text("O app recarregou o YouTube Music para renovar os cookies.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else if store.player.accessWarning != nil {
                        Text("A sessão do YouTube Music expirou.").font(.callout).foregroundStyle(.orange)
                        Text("Reconecte para carregar a biblioteca.").font(.caption).foregroundStyle(.secondary)
                        Button("Reconectar") { store.go(to: .auth) }
                            .glassProminentButton().tint(AppTheme.accent).padding(.top, 2)
                    } else {
                        Text(store.catalogMessage ?? emptyHint).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                VStack(spacing: 2) {
                    if let section = store.forYouOpenSection {
                        SectionBackRow(title: section.title) { store.closeForYouSection() }
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                    row(item, in: items, index: index).id(index)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onAppear { scrollToCurrent(proxy, animated: false) }
                        .onChange(of: store.snapshot?.queueIndex) { _, _ in scrollToCurrent(proxy, animated: true) }
                    }
                }
                .id(store.catalogTab)
                .transition(.opacity)
            }
        }
        .animation(AppTheme.swap, value: store.catalogTab)
        .animation(AppTheme.swap, value: items.isEmpty)
        .animation(AppTheme.swap, value: store.forYouOpenSection)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The home rows as a compact index: the popover is too short to scroll through all of them.
    private var categoryMenu: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.homeSections) { section in
                    SectionRow(section: section) { store.openForYouSection(section) }
                }
            }
            .padding(.vertical, 2)
        }
        .transition(.opacity)
    }

    private func row(_ item: MediaItem, in list: [MediaItem], index: Int) -> some View {
        CatalogRow(
            item: item,
            isCurrent: store.isCurrent(at: index, item),
            isPlayed: store.isPlayed(at: index),
            isPlaying: store.snapshot?.isPaused == false,
            isLoading: store.loadingItemID == item.id,
            play: {
                if store.catalogTab == .queue { store.jump(to: index) } else { store.play(item, in: list) }
            },
            radio: { store.startRadio(from: item) },
            library: libraryAction(for: item)
        )
    }

    /// Only collections can be saved. The Playlists tab *is* the library, so there the action removes.
    private func libraryAction(for item: MediaItem) -> RowLibraryAction? {
        guard item.kind == .playlist || item.kind == .album, !item.remoteID.isEmpty else { return nil }
        if store.catalogTab == .playlists {
            return RowLibraryAction(title: "Remover da biblioteca") { store.setInLibrary(item, saved: false) }
        }
        return RowLibraryAction(title: "Adicionar à biblioteca") { store.setInLibrary(item, saved: true) }
    }

    /// Keeps the playing track in view on the queue tab.
    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard store.catalogTab == .queue, let index = store.snapshot?.queueIndex else { return }
        if animated { withAnimation(AppTheme.swap) { proxy.scrollTo(index, anchor: .center) } } else { proxy.scrollTo(index, anchor: .center) }
    }

    private var emptyIcon: String {
        if store.isRenewingSession { return "arrow.triangle.2.circlepath" }
        if store.player.accessWarning != nil { return "exclamationmark.triangle" }
        return store.catalogTab == .results ? "magnifyingglass" : "music.note.list"
    }

    private var emptyHint: String {
        switch store.catalogTab {
        case .queue: "Nada na fila."
        case .library: "Nenhuma música na biblioteca."
        case .playlists: "Nenhuma playlist na biblioteca."
        case .forYou: "Nada para você agora."
        case .results: "Nenhuma música encontrada para “\(store.lastQuery)”."
        }
    }
}

/// The library action a row offers in its context menu, when the row can be saved or removed.
private struct RowLibraryAction {
    let title: String
    let run: () -> Void
}

/// Placeholder rows shown while a catalog page loads, drawn like the rows that will replace them so
/// the panel keeps its shape instead of collapsing to a spinner.
private struct SkeletonList: View {
    var rows: Int = 7
    var leading: CGFloat = 40
    var showsChevron = false
    @StateObject private var pulse = PulseState()

    private static let titleWidths: [CGFloat] = [190, 150, 215, 170, 130, 200, 160]
    private static let subtitleWidths: [CGFloat] = [110, 90, 130, 100, 80, 120, 95]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { index in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(width: leading, height: leading)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .frame(width: Self.titleWidths[index % Self.titleWidths.count], height: 11)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .frame(width: Self.subtitleWidths[index % Self.subtitleWidths.count], height: 9)
                    }
                    Spacer(minLength: 8)
                    if showsChevron {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.quaternary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .opacity(pulse.dim ? 0.4 : 1)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse.dim = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Carregando")
    }
}

/// The home rows are dynamic, so the icon comes from the words YouTube uses, with a fallback.
private enum SectionIcon {
    private static let rules: [(String, String)] = [
        ("listen again", "clock.arrow.circlepath"),
        ("tocar de novo", "clock.arrow.circlepath"),
        ("mix", "sparkles"),
        ("quick pick", "wand.and.stars"),
        ("discover", "safari"),
        ("new release", "star.circle"),
        ("album", "square.stack"),
        ("recap", "calendar"),
        ("community", "person.2"),
        ("trending", "chart.line.uptrend.xyaxis"),
        ("chart", "chart.bar"),
        ("live", "dot.radiowaves.left.and.right"),
        ("video", "play.rectangle"),
        ("fresh", "leaf"),
        ("forgotten", "clock.badge.questionmark"),
        ("favorite", "heart"),
    ]

    static func name(for title: String) -> String {
        let name = title.lowercased()
        return rules.first { name.contains($0.0) }?.1 ?? "music.note.list"
    }
}

/// One row of the "Para você" index: icon, title and how much is inside.
private struct SectionRow: View {
    let section: HomeSection
    let open: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: SectionIcon.name(for: section.title))
                    .font(.callout)
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(.callout).lineLimit(1)
                    Text(section.items.count == 1 ? "1 item" : "\(section.items.count) itens")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(hover.isHovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.985))
        .padding(.horizontal, 4)
        .onHover { hover.isHovering = $0 }
        .animation(AppTheme.hover, value: hover.isHovering)
        .help("Abrir \(section.title)")
    }
}

/// Sits above the rows of an open category and returns to the index.
private struct SectionBackRow: View {
    let title: String
    let back: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: back) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                Text("Categorias").font(.caption)
                Spacer()
                Text(title).font(.caption.weight(.semibold)).lineLimit(1).foregroundStyle(.secondary)
            }
            .foregroundStyle(hover.isHovering ? Color.primary : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.99))
        .onHover { hover.isHovering = $0 }
        .animation(AppTheme.hover, value: hover.isHovering)
        .help("Voltar para as categorias")
    }
}

private struct CatalogRow: View {
    let item: MediaItem
    let isCurrent: Bool
    let isPlayed: Bool
    let isPlaying: Bool
    let isLoading: Bool
    let play: () -> Void
    let radio: () -> Void
    let library: RowLibraryAction?
    @StateObject private var hover = HoverState()

    var body: some View {
        if item.kind == .song, !item.remoteID.isEmpty {
            content.contextMenu {
                Button("Iniciar rádio a partir desta música") { radio() }
                if let library { Button(library.title) { library.run() } }
            }
        } else if let library {
            content.contextMenu { Button(library.title) { library.run() } }
        } else {
            content
        }
    }

    private var content: some View {
        Button(action: play) {
            HStack(spacing: 10) {
                ZStack {
                    ArtworkView(url: item.artworkURL, cornerRadius: 6)
                    if isLoading || hover.isHovering || isCurrent {
                        Color.black.opacity(0.4).clipShape(RoundedRectangle(cornerRadius: 6)).transition(.opacity)
                    }
                    if isLoading {
                        ProgressView().controlSize(.small).tint(.white).transition(.opacity)
                    } else if isCurrent {
                        Image(systemName: "waveform")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: isPlaying)
                            .transition(.scale.combined(with: .opacity))
                    } else if hover.isHovering {
                        Image(systemName: "play.fill").font(.caption).foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? AppTheme.accent : .primary)
                        .lineLimit(1)
                    Text(item.subtitle.isEmpty ? item.kind.displayName : item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if item.duration > 0 {
                    Text(DurationFormatting.clock(item.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if item.kind != .song {
                    Image(systemName: hover.isHovering ? "play.circle.fill" : "play.circle")
                        .foregroundStyle(hover.isHovering ? AppTheme.accent : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .opacity(isPlayed && !hover.isHovering ? 0.45 : 1)
            .background(hover.isHovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.985))
        .padding(.horizontal, 4)
        .onHover { hover.isHovering = $0 }
        .animation(AppTheme.hover, value: hover.isHovering)
        .animation(AppTheme.hover, value: isLoading)
        .animation(AppTheme.hover, value: isCurrent)
        .animation(AppTheme.hover, value: isPlayed)
        .help(item.kind == .song ? "Tocar" : "Tocar \(item.kind.displayName.lowercased())")
    }
}

// MARK: - Playback controls

private struct CompactNowPlaying: View {
    let snapshot: PlaybackSnapshot
    @ObservedObject var store: PlayerStore

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(url: snapshot.artworkURL, cornerRadius: 8)
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title).font(.headline).lineLimit(2)
                if !snapshot.artist.isEmpty {
                    Text(snapshot.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if snapshot.queueCount > 1 {
                    Text("Faixa \(snapshot.queueIndex + 1) de \(snapshot.queueCount)").font(.caption2).foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                } else if !snapshot.album.isEmpty {
                    Text(snapshot.album).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .id(snapshot.videoID ?? snapshot.title)
            .transition(.opacity.combined(with: .offset(y: 4)))
            Spacer()
            LikeButton(snapshot: snapshot, store: store)
        }
        .animation(AppTheme.swap, value: snapshot.videoID)
        .animation(AppTheme.swap, value: snapshot.queueIndex)
    }
}

private struct LikeButton: View {
    let snapshot: PlaybackSnapshot
    @ObservedObject var store: PlayerStore

    var body: some View {
        let liked = store.isLiked(snapshot)
        IconButton(
            systemName: liked ? "heart.fill" : "heart", font: .title3, size: 32,
            tint: liked ? AppTheme.accent : nil,
            help: liked ? "Remover curtida" : "Curtir",
            action: store.toggleLike
        )
        .symbolEffect(.bounce, value: liked)
    }
}

private struct ProgressLine: View {
    let snapshot: PlaybackSnapshot
    @ObservedObject var store: PlayerStore
    @StateObject private var drag = DragState()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let current = drag.value ?? snapshot.estimatedTime(at: context.date)
            HStack(spacing: 8) {
                Group {
                    if snapshot.isPreparing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(DurationFormatting.clock(current)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 36, alignment: .trailing)
                Slider(value: Binding(get: { current }, set: { drag.value = $0 }), in: 0...max(snapshot.duration, 1)) { editing in
                    if !editing, let value = drag.value { store.seek(to: value) }
                }
                .controlSize(.small)
                .disabled(snapshot.duration <= 0 || snapshot.isPreparing)
                Text(DurationFormatting.clock(snapshot.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            }
        }
        .onChange(of: snapshot.observedAt) { _, _ in drag.value = nil }
    }
}

private struct Transport: View {
    let snapshot: PlaybackSnapshot?
    @ObservedObject var store: PlayerStore
    @StateObject private var playHover = HoverState()

    var body: some View {
        HStack(spacing: 10) {
            IconButton(systemName: "backward.fill", size: 32, isDisabled: snapshot == nil, help: "Anterior", action: store.previous)
            playButton
            IconButton(systemName: "forward.fill", size: 32, isDisabled: snapshot?.hasNext != true, help: "Próxima", action: store.next)
            IconButton(
                systemName: "dot.radiowaves.left.and.right",
                size: 32,
                isDisabled: snapshot == nil,
                help: "Rádio a partir desta faixa",
                action: { store.startRadio() }
            )
        }
    }

    @ViewBuilder
    private var playButton: some View {
        if #available(macOS 26.0, *) {
            Button(action: store.togglePlayback) {
                Image(systemName: snapshot?.isPaused == false ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(AppTheme.accent)
            .disabled(snapshot == nil)
            .help(snapshot?.isPaused == false ? "Pausar" : "Reproduzir")
        } else {
            Button(action: store.togglePlayback) {
                Image(systemName: snapshot?.isPaused == false ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(snapshot == nil ? Color.secondary.opacity(0.35) : AppTheme.accent)
                            .brightness(playHover.isHovering ? 0.08 : 0)
                    )
                    .foregroundStyle(.white)
                    .scaleEffect(playHover.isHovering ? 1.06 : 1)
                    .shadow(color: AppTheme.accent.opacity(playHover.isHovering && snapshot != nil ? 0.35 : 0), radius: 8, y: 2)
            }
            .buttonStyle(PressScaleStyle(scale: 0.9))
            .disabled(snapshot == nil)
            .onHover { playHover.isHovering = $0 }
            .animation(AppTheme.hover, value: playHover.isHovering)
            .help(snapshot?.isPaused == false ? "Pausar" : "Reproduzir")
        }
    }
}

private struct VolumeControl: View {
    @ObservedObject var store: PlayerStore
    @StateObject private var drag = DragState()

    var body: some View {
        let snapshot = store.snapshot
        let volume = drag.value ?? snapshot?.volume ?? 1
        let muted = snapshot?.isMuted == true || volume == 0
        HStack(spacing: 4) {
            IconButton(systemName: muted ? "speaker.slash.fill" : "speaker.fill", font: .caption, size: 22, help: muted ? "Ativar som" : "Silenciar", action: store.toggleMute)
            Slider(value: Binding(get: { volume }, set: { drag.value = $0 }), in: 0...1) { editing in
                if !editing, let value = drag.value { store.setVolume(value) }
            }
            .controlSize(.mini)
            Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
        }
        .disabled(snapshot == nil)
        .onChange(of: snapshot?.volume) { _, _ in drag.value = nil }
    }
}

/// Artwork with a crossfade whenever the URL changes.
private struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note").foregroundStyle(.secondary)
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill().transition(.opacity)
                }
            }
            .id(url)
            .transition(.opacity)
        }
        .animation(AppTheme.swap, value: url)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Settings page

private struct SettingsPanel: View {
    @ObservedObject var store: PlayerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(title: "Ajustes", onBack: { store.go(to: .player) }, trailing: AnyView(Color.clear.frame(width: 60, height: 1)))
            GroupBox("Player local") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A reprodução usa mpv e yt-dlp. A interface não mantém o YouTube Music aberto em um navegador.").font(.caption).foregroundStyle(.secondary)
                    Text("Status: \(store.player.statusMessage)").font(.callout)
                }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Conta") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(accountStatus).font(.callout)
                        if let warning = store.player.accessWarning {
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Button(store.isConfigured ? "Reconfigurar…" : "Configurar acesso…") { store.go(to: .auth) }
                        .buttonStyle(PressScaleStyle(scale: 0.96))
                }.padding(4)
            }
            GroupBox("Barra de menus") {
                Toggle("Mostrar o nome da faixa", isOn: $store.showTrackInMenuBar).padding(4).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await store.verifyAccess() }
    }

    private var accountStatus: String {
        guard store.isConfigured else { return "Acesso ainda não configurado." }
        guard let name = store.player.accountName, !name.isEmpty else { return "Acesso configurado." }
        return "Conectado como \(name)."
    }
}

// MARK: - Access setup page

struct AuthSetupView: View {
    @ObservedObject var store: PlayerStore
    let onDone: () -> Void
    @StateObject private var draft = AuthDraft()
    @ObservedObject private var signIn = GoogleSignIn.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Conectar", onBack: onDone, trailing: AnyView(Color.clear.frame(width: 60, height: 1)))
            Text("O login acontece dentro do app. Depois disso, o app toca as músicas com mpv e não mantém o site aberto.")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("1. Entre com a conta Google") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Abre uma janela com a página de login. Os cookies ficam guardados pelo próprio WebKit, então não precisam ser copiados à mão.")
                        .font(.caption)
                    HStack {
                        Button(signIn.isPresenting ? "Janela de login aberta…" : "Entrar com o Google") {
                            signIn.present { header in saveFromSignIn(header) }
                        }
                        .glassProminentButton().tint(AppTheme.accent)
                        .disabled(draft.isSaving || signIn.isPresenting)
                        Spacer()
                    }
                }.padding(4)
            }
            GroupBox("2. Ou importe os headers manualmente") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No YouTube Music: pressione ⌘⌥I → Network → clique em Biblioteca → abra a requisição /browse → botão direito → Copy → Copy request headers.")
                        .font(.caption)
                    HStack(spacing: 8) {
                        Button("Importar da área de transferência") { importFromClipboard() }
                            .glassProminentButton().tint(AppTheme.accent)
                            .disabled(draft.isSaving)
                        Text("ou cole manualmente abaixo").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    TextEditor(text: $draft.headers)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 110, maxHeight: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        .accessibilityLabel("Headers copiados do YouTube Music")
                    Text("Os headers são credenciais temporárias. Não os compartilhe.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(4)
            }
            if let message = draft.message {
                Label(message, systemImage: draft.isError ? "exclamationmark.triangle.fill" : (draft.succeeded ? "checkmark.circle.fill" : "info.circle"))
                    .font(.callout)
                    .foregroundStyle(draft.isError ? Color.orange : (draft.succeeded ? Color.green : Color.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack {
                Spacer()
                if draft.succeeded {
                    Button("Concluir") { onDone() }
                        .glassProminentButton().tint(AppTheme.accent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(draft.isSaving ? "Salvando…" : "Salvar e testar") { save() }
                        .glassProminentButton().tint(AppTheme.accent)
                        .disabled(draft.isSaving || draft.headers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.25), value: draft.message == nil)
    }

    private func saveFromSignIn(_ header: String) {
        draft.headers = "cookie: \(header)"
        save()
    }

    private func importFromClipboard() {
        let clipboard = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clipboard.isEmpty else {
            draft.message = "A área de transferência está vazia. Copie os request headers no navegador primeiro."
            draft.isError = true
            return
        }
        draft.headers = clipboard
        save()
    }

    private func save() {
        draft.isSaving = true
        draft.message = nil
        draft.isError = false
        draft.succeeded = false
        Task {
            do {
                let account = try await store.player.configure(rawHeaders: draft.headers)
                draft.headers = ""
                draft.message = account.isEmpty ? "Acesso configurado." : "Conectado como \(account)."
                draft.succeeded = true
                draft.isSaving = false
                store.reloadCatalog()
            } catch {
                draft.message = error.localizedDescription
                draft.isError = true
                draft.succeeded = false
                draft.isSaving = false
            }
        }
    }
}
