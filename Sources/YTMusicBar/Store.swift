import AppKit
import Combine
import Foundation
import SwiftUI
import YTMusicCore

/// Catalog tabs shown inside the popover. "Results" only exists while there is a search query.
enum CatalogTab: String, CaseIterable, Identifiable {
    case queue, library, playlists, forYou, results

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: "Fila"
        case .library: "Biblioteca"
        case .playlists: "Playlists"
        case .forYou: "Para você"
        case .results: "Resultados"
        }
    }
}

/// Pages of the menu bar popover. Everything, including settings and access setup, lives here.
enum PanelPage: Hashable { case player, settings, auth }

/// Like state to show while the server round trip is still in flight.
struct PendingLike: Equatable {
    let id: String
    let liked: Bool
}

@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var snapshot: PlaybackSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var connectionMessage = "Verificando o player local…"
    @Published private(set) var actionMessage: String?
    @Published private(set) var searchResults: [MediaItem] = []
    @Published private(set) var librarySongs: [MediaItem] = []
    @Published private(set) var playlists: [MediaItem] = []
    @Published private(set) var homeSections: [HomeSection] = []
    @Published private(set) var queueItems: [MediaItem] = []
    @Published private(set) var isCatalogLoading = false
    @Published private(set) var catalogMessage: String?
    @Published private(set) var loadingItemID: String?
    /// Like state shown while the server round trip is in flight.
    @Published private(set) var pendingLike: PendingLike?
    /// True while the app is reloading YouTube Music in a web view to refresh the session cookies.
    @Published private(set) var isRenewingSession = false
    @Published private(set) var lastQuery = ""
    @Published private(set) var panelPage: PanelPage = .player
    /// True when the last navigation went deeper (player → settings → auth); drives the slide direction.
    @Published private(set) var navigatedForward = true

    @Published var catalogTab: CatalogTab = .library {
        didSet {
            if catalogTab != oldValue {
                // Leaving the tab drops back to the category menu, so it always opens the same way.
                if catalogTab != .forYou { forYouSectionID = nil }
                loadIfNeeded(catalogTab)
            }
        }
    }

    /// Title of the home row open in the "Para você" tab; nil shows the category menu.
    @Published private(set) var forYouSectionID: String?

    @Published var showTrackInMenuBar: Bool {
        didSet { defaults.set(showTrackInMenuBar, forKey: "showTrackInMenuBar") }
    }

    let player = LocalMusicPlayer()
    private let defaults: UserDefaults
    private var pollTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var actionMessageTask: Task<Void, Never>?
    private var likeToken: UUID?
    private var playerObservation: AnyCancellable?
    private var catalogLoadedAt: [CatalogTab: Date] = [:]
    /// Queue size we already tried to extend at, so a source with nothing left is not retried forever.
    private var extendedAtQueueCount = 0
    /// How close to the end of the queue triggers a top up.
    private let extendThreshold = 5
    /// Catalog data older than this is reloaded the next time the popover opens.
    private let catalogStaleAfter: TimeInterval = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showTrackInMenuBar = defaults.object(forKey: "showTrackInMenuBar") as? Bool ?? true
        player.loadIfNeeded()
        playerObservation = player.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Cmd-Q, "Sair" and system shutdown all go through applicationShouldTerminate,
        // which waits for this handler so the audio stops before the process ends.
        AppDelegate.terminationHandler = { [weak self] in await self?.player.stop() }
        startPolling()
    }

    deinit {
        pollTask?.cancel(); actionTask?.cancel(); actionMessageTask?.cancel()
    }

    /// Failures are transient, so the banner clears itself instead of sitting there until the next action.
    private func showAction(_ message: String) {
        actionMessage = message
        actionMessageTask?.cancel()
        actionMessageTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            actionMessage = nil
        }
    }

    var menuTitle: String {
        guard showTrackInMenuBar, let title = snapshot?.title, !title.isEmpty else { return "YT Music" }
        return title.count > 28 ? String(title.prefix(27)) + "…" : title
    }

    var isConnected: Bool { snapshot != nil }
    var isConfigured: Bool { player.isConfigured }
    var hasSearch: Bool { !lastQuery.isEmpty }

    /// Tabs currently available: the queue needs something loaded, results need a search.
    var availableTabs: [CatalogTab] {
        var tabs: [CatalogTab] = [.library, .playlists, .forYou]
        if snapshot != nil { tabs.insert(.queue, at: 0) }
        if hasSearch { tabs.append(.results) }
        return tabs
    }

    var visibleItems: [MediaItem] {
        switch catalogTab {
        case .queue: queueItems
        case .library: librarySongs
        case .playlists: playlists
        case .forYou: forYouOpenSection?.items ?? []
        case .results: searchResults
        }
    }

    /// The home row currently open, looked up by title so a refresh cannot leave a stale copy open.
    var forYouOpenSection: HomeSection? {
        guard let forYouSectionID else { return nil }
        return homeSections.first { $0.id == forYouSectionID }
    }

    func openForYouSection(_ section: HomeSection) { forYouSectionID = section.id }

    func closeForYouSection() { forYouSectionID = nil }

    func isCurrent(_ item: MediaItem) -> Bool {
        guard item.kind == .song, let id = snapshot?.videoID, !id.isEmpty else { return false }
        return id == item.remoteID
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await player.snapshot()
            connectionMessage = snapshot == nil ? player.statusMessage : (snapshot?.isPaused == true ? "Pausado" : "Reproduzindo")
        } catch { connectionMessage = error.localizedDescription }
        // The clicked row keeps its spinner until mpv actually starts producing audio.
        if snapshot?.isPreparing == false, loadingItemID != nil { loadingItemID = nil }
        // A radio or a mix never really ends, so top the queue up before it runs out. A source with
        // nothing left adds nothing, the count stays put, and this stops firing on its own.
        if let snapshot, snapshot.queueCount > extendedAtQueueCount,
           snapshot.queueCount - snapshot.queueIndex <= extendThreshold {
            extendedAtQueueCount = snapshot.queueCount
            extendQueue()
        }
        if snapshot == nil {
            queueItems = []
            if catalogTab == .queue { catalogTab = .library }
        } else if catalogTab == .queue, let snapshot, queueItems.count != snapshot.queueCount, !isCatalogLoading {
            loadQueue()
        }
    }

    func requestRefresh() { Task { await refresh() } }

    /// Called when the popover opens: loads the visible tab if it is empty or stale. Playback state polls on its own.
    func prepareCatalog() {
        player.loadIfNeeded()
        let loadedAt = catalogLoadedAt[catalogTab]
        let stale = loadedAt.map { Date().timeIntervalSince($0) > catalogStaleAfter } ?? true
        if visibleItems.isEmpty || stale { load(catalogTab) }
    }

    /// Reloads the visible tab ignoring the staleness window; used after the credentials change.
    func reloadCatalog() { load(catalogTab) }

    private func load(_ tab: CatalogTab) {
        switch tab {
        case .queue: loadQueue()
        case .library: loadLibrary()
        case .playlists: loadPlaylists()
        case .forYou: loadForYou()
        case .results: if hasSearch { search(lastQuery) }
        }
    }

    /// Row at `index` of the visible list is the track mpv is playing right now.
    func isCurrent(at index: Int, _ item: MediaItem) -> Bool {
        catalogTab == .queue ? index == snapshot?.queueIndex : isCurrent(item)
    }

    /// In the queue tab, rows before the current one were already played.
    func isPlayed(at index: Int) -> Bool {
        catalogTab == .queue && index < (snapshot?.queueIndex ?? 0)
    }

    func go(to page: PanelPage) {
        let depth: [PanelPage: Int] = [.player: 0, .settings: 1, .auth: 2]
        navigatedForward = (depth[page] ?? 0) >= (depth[panelPage] ?? 0)
        withAnimation(.snappy(duration: 0.3)) { panelPage = page }
    }

    func ensurePlayerLoaded() { player.loadIfNeeded() }
    func togglePlayback() { perform(.togglePlayback) }
    func previous() { perform(.previous) }
    func next() { perform(.next) }
    func toggleMute() { perform(.toggleMute) }
    func seek(to seconds: Double) { perform(.seek(to: max(0, seconds))) }
    func skip(_ seconds: Double) { if let snapshot { seek(to: snapshot.estimatedTime(at: Date()) + seconds) } }
    func setVolume(_ volume: Double) { perform(.setVolume(min(max(volume, 0), 1))) }
    func stopAndQuit() { NSApp.terminate(nil) }

    /// What the heart should show: the optimistic value wins until the server confirms it.
    func isLiked(_ snapshot: PlaybackSnapshot) -> Bool {
        if let pending = pendingLike, pending.id == snapshot.videoID { return pending.liked }
        return snapshot.isLiked == true
    }

    /// Flips the heart immediately and reverts if the request fails; the reply is idempotent.
    func toggleLike() {
        guard let snapshot, let id = snapshot.videoID, !id.isEmpty else { return }
        let target = !isLiked(snapshot)
        let token = UUID()
        likeToken = token
        pendingLike = PendingLike(id: id, liked: target)
        actionMessage = nil
        actionTask?.cancel()
        actionTask = Task {
            defer { if likeToken == token { pendingLike = nil } }
            do {
                try await player.setLiked(target, id: id)
                await refresh()
            } catch is CancellationError {
            } catch { showAction(error.localizedDescription) }
        }
    }

    func search(_ query: String) {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        lastQuery = cleaned
        catalogTab = .results
        loadCatalog({ try await self.player.search(cleaned) }) { self.searchResults = $0.items; self.catalogLoadedAt[.results] = Date() }
    }

    func clearSearch() {
        lastQuery = ""
        searchResults = []
        if catalogTab == .results { catalogTab = .library }
    }

    func loadQueue() { loadCatalog({ try await self.player.queue() }) { self.queueItems = $0.items; self.catalogLoadedAt[.queue] = Date() } }
    func loadLibrary() { loadCatalog({ try await self.player.library() }) { self.librarySongs = $0.items; self.catalogLoadedAt[.library] = Date() } }
    func loadPlaylists() { loadCatalog({ try await self.player.playlists() }) { self.playlists = $0.items; self.catalogLoadedAt[.playlists] = Date() } }

    func loadForYou() {
        loadSections({ try await self.player.home() }) { sections in
            self.homeSections = sections
            self.catalogLoadedAt[.forYou] = Date()
        }
    }

    /// Replaces the queue with the radio built from `item`, or from the track playing now when none is given.
    func startRadio(from item: MediaItem? = nil) {
        let id = item?.remoteID ?? snapshot?.videoID ?? ""
        guard !id.isEmpty else { return }
        let token = item?.id ?? id
        actionMessage = nil
        extendedAtQueueCount = 0
        loadingItemID = token
        actionTask?.cancel()
        actionTask = Task {
            do {
                try await player.playRadio(id: id)
                queueItems = []
                // A radio has no list of origin to keep in view, so show what it queued.
                catalogTab = .queue
                await refresh()
            } catch is CancellationError {
            } catch { showAction(error.localizedDescription) }
            if loadingItemID == token { loadingItemID = nil }
        }
    }

    /// Starts a playlist, or a song together with the list it was clicked in.
    /// Rapid clicks are serialized by the bridge; the last one wins.
    func play(_ item: MediaItem, in list: [MediaItem] = []) {
        actionMessage = nil
        extendedAtQueueCount = 0
        loadingItemID = item.id
        actionTask?.cancel()
        actionTask = Task {
            do {
                try await player.play(item, in: list)
                queueItems = []
                await refresh()
                // refresh() clears loadingItemID once mpv reports playback, not when the reply lands.
            } catch is CancellationError {
                if loadingItemID == item.id { loadingItemID = nil }
            } catch {
                showAction(error.localizedDescription)
                if loadingItemID == item.id { loadingItemID = nil }
            }
        }
    }

    private func perform(_ action: PlaybackAction) {
        actionTask?.cancel()
        actionMessage = nil
        actionTask = Task {
            do {
                try await player.perform(action, currentID: snapshot?.videoID)
                try? await Task.sleep(for: .milliseconds(180))
                await refresh()
            } catch is CancellationError {} catch { showAction(error.localizedDescription) }
        }
    }

    /// Jump to a row of the queue tab without rebuilding the queue.
    func jump(to index: Int) { perform(.jump(to: index)) }

    private func loadIfNeeded(_ tab: CatalogTab) {
        switch tab {
        case .queue:
            // The queue grows while it plays, so reload once the row count no longer matches.
            if queueItems.isEmpty || queueItems.count != (snapshot?.queueCount ?? 0) { loadQueue() }
        case .library where librarySongs.isEmpty: loadLibrary()
        case .playlists where playlists.isEmpty: loadPlaylists()
        case .forYou where homeSections.isEmpty: loadForYou()
        default: break
        }
    }

    /// Tops the queue up from its own source. The queue tab picks the new rows up on its own.
    private func extendQueue() {
        Task { _ = try? await player.extendQueue() }
    }

    private func loadCatalog(_ request: @escaping () async throws -> CatalogPage, _ assign: @escaping (CatalogPage) -> Void) {
        isCatalogLoading = true
        catalogMessage = nil
        Task {
            do {
                let page = try await request()
                assign(page)
                catalogMessage = page.items.isEmpty ? "Nenhum item encontrado." : nil
                await checkAccess(isEmpty: page.items.isEmpty)
            } catch { catalogMessage = error.localizedDescription }
            isCatalogLoading = false
        }
    }

    /// The "Para você" tab is a list of titled rows, so it cannot reuse `loadCatalog`.
    private func loadSections(_ request: @escaping () async throws -> [HomeSection], _ assign: @escaping ([HomeSection]) -> Void) {
        isCatalogLoading = true
        catalogMessage = nil
        Task {
            do {
                let sections = try await request()
                assign(sections)
                catalogMessage = sections.isEmpty ? "Nenhum item encontrado." : nil
                await checkAccess(isEmpty: sections.isEmpty)
            } catch { catalogMessage = error.localizedDescription }
            isCatalogLoading = false
        }
    }

    /// An empty library, playlist list or home is what a dropped session looks like, so ask the bridge.
    private func checkAccess(isEmpty: Bool) async {
        guard [.library, .playlists, .forYou].contains(catalogTab) else { return }
        if isEmpty { await verifyAccess() } else { player.clearAccessWarning() }
    }

    /// Checks the session and, when the stored copy went stale, tries to renew it from WebKit.
    /// Signing in lives in a web view the app owns, so the page can usually rotate the cookies
    /// itself and the app reconnects without asking anything.
    func verifyAccess() async {
        await player.verifyAccess()
        guard player.accessWarning != nil else { return }
        isRenewingSession = true
        defer { isRenewingSession = false }
        guard let header = await GoogleSignIn.shared.refreshedCookieHeader(),
              (try? await player.configure(rawHeaders: "cookie: \(header)")) != nil else { return }
        player.clearAccessWarning()
        reloadCatalog()
    }

    /// Adds or removes a playlist or album from the library, then refreshes the library list.
    func setInLibrary(_ item: MediaItem, saved: Bool) {
        guard !item.remoteID.isEmpty else { return }
        actionMessage = nil
        actionTask?.cancel()
        actionTask = Task {
            do {
                try await player.setInLibrary(id: item.remoteID, saved: saved)
                showAction(saved ? "Adicionado à biblioteca." : "Removido da biblioteca.")
                // The server takes a moment to reflect the change in the library list.
                try? await Task.sleep(for: .seconds(2))
                loadPlaylists()
            } catch is CancellationError {
            } catch { showAction(error.localizedDescription) }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // While yt-dlp resolves a stream nothing is playing, so poll fast enough that the
                // progress bar and the row spinner react the moment audio starts.
                let interval = self.snapshot?.isPreparing == true ? 0.4 : 2.0
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}
