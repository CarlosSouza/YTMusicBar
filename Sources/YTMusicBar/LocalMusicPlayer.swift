import AppKit
import Darwin
import Foundation
import YTMusicCore

@MainActor
final class LocalMusicPlayer: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isReady = false
    @Published private(set) var isConfigured = false
    @Published private(set) var accountName: String?
    @Published private(set) var accessWarning: String?
    @Published private(set) var statusMessage = "Verificando o player local…"
    @Published private(set) var lastError: String?

    private let bridge = LocalMusicBridge()

    nonisolated static func validationError() -> String? {
        guard FileManager.default.fileExists(atPath: "/opt/homebrew/bin/mpv"),
              FileManager.default.fileExists(atPath: "/opt/homebrew/bin/yt-dlp") else {
            return "mpv e yt-dlp precisam estar instalados."
        }
        return nil
    }

    func loadIfNeeded() {
        guard !isLoading else { return }
        refreshStatus()
    }

    func refreshStatus() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let reply = try await bridge.request(["command": "status"])
                isConfigured = reply.configured
                isReady = reply.mpv && reply.ytdlp
                statusMessage = !isReady ? "Instale mpv e yt-dlp" : (isConfigured ? "Player local pronto" : "Configure o acesso ao YouTube Music")
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                statusMessage = error.localizedDescription
            }
        }
    }

    /// Stores the credentials and returns the account name; the bridge only saves them after a signed-in probe.
    func configure(rawHeaders: String) async throws -> String {
        let reply = try await bridge.request(["command": "configure", "headers": rawHeaders])
        accountName = reply.account
        accessWarning = nil
        refreshStatus()
        return reply.account ?? ""
    }

    func verifyAccess() async {
        do {
            let reply = try await bridge.request(["command": "verify"])
            isConfigured = reply.configured
            accountName = reply.authenticated ? reply.account : nil
            accessWarning = reply.authenticated ? nil : reply.error
        } catch {
            accessWarning = error.localizedDescription
        }
    }

    /// A successful catalog load proves the session is alive again.
    func clearAccessWarning() { accessWarning = nil }

    func openYouTubeMusic() {
        NSWorkspace.shared.open(YouTubeMusicURL.home)
    }

    func stop() async {
        _ = try? await bridge.request(["command": "stop"])
    }

    func snapshot() async throws -> PlaybackSnapshot? {
        let reply = try await bridge.request(["command": "status"])
        guard let raw = reply.snapshot, raw.idle != true, let title = raw.title, !title.isEmpty else { return nil }
        return PlaybackSnapshot(
            title: title,
            artist: raw.artist ?? "",
            album: raw.album ?? "",
            artworkURL: raw.artwork.flatMap(URL.init(string:)),
            currentTime: raw.currentTime ?? 0,
            duration: raw.duration ?? 0,
            isPaused: raw.paused ?? true,
            volume: raw.volume ?? 1,
            isMuted: raw.muted ?? false,
            isLiked: raw.liked,
            pageURL: raw.url.flatMap(URL.init(string:)),
            queueIndex: raw.queueIndex ?? 0,
            queueCount: raw.queueCount ?? 1
        )
    }

    func search(_ query: String) async throws -> CatalogPage { try await catalog(["command": "search", "query": query], title: "Resultados") }
    func library() async throws -> CatalogPage { try await catalog(["command": "library"], title: "Biblioteca") }
    func playlists() async throws -> CatalogPage { try await catalog(["command": "playlists"], title: "Playlists") }
    /// The whole mpv queue in order, with the metadata saved when it was built.
    func queue() async throws -> CatalogPage { try await catalog(["command": "queue"], title: "Fila") }

    /// The YouTube Music home rows, with the generated playlists and mixes, for the "Para você" tab.
    func home() async throws -> [HomeSection] {
        let reply = try await bridge.request(["command": "home"])
        return reply.sections.map { HomeSection(title: $0.title, items: $0.items.map(Self.mediaItem)) }
    }

    /// Replaces the queue with the endless radio built from one song.
    func playRadio(id: String) async throws {
        _ = try await bridge.request(["command": "play", "kind": "radio", "id": id])
    }

    private static func mediaItem(_ raw: LocalMusicBridge.RawItem) -> MediaItem {
        MediaItem(
            title: raw.title,
            subtitle: raw.subtitle,
            album: raw.album,
            artworkURL: raw.artwork.isEmpty ? nil : URL(string: raw.artwork),
            destinationURL: URL(string: raw.url) ?? YouTubeMusicURL.home,
            kind: MediaKind(rawValue: raw.kind) ?? .song,
            duration: raw.duration,
            isLiked: raw.liked
        )
    }

    /// Playlists are expanded by the bridge. A song is queued together with the list it was clicked in,
    /// starting at that song, so previous/next move through the list like Apple Music.
    func play(_ item: MediaItem, in list: [MediaItem] = []) async throws {
        var request: [String: Any] = [
            "command": "play", "kind": item.kind.rawValue, "id": item.remoteID,
            "title": item.title, "artist": item.subtitle, "album": item.album, "artwork": item.artworkURL?.absoluteString ?? "",
            "duration": item.duration,
        ]
        if let liked = item.isLiked { request["liked"] = liked }
        if item.kind == .song {
            request["queue"] = list.filter { $0.kind == .song && !$0.remoteID.isEmpty }.map { song -> [String: Any] in
                var raw: [String: Any] = [
                    "id": song.remoteID, "title": song.title, "artist": song.subtitle, "album": song.album,
                    "artwork": song.artworkURL?.absoluteString ?? "", "duration": song.duration,
                ]
                if let liked = song.isLiked { raw["liked"] = liked }
                return raw
            }
        }
        _ = try await bridge.request(request)
    }

    func perform(_ action: PlaybackAction, currentID: String? = nil) async throws {
        var request: [String: Any] = ["command": "action"]
        switch action {
        case .togglePlayback: request["action"] = "togglePlayback"
        case .previous: request["action"] = "previous"
        case .next: request["action"] = "next"
        case .toggleMute: request["action"] = "toggleMute"
        case .seek(let value): request["action"] = "seek"; request["value"] = value
        case .setVolume(let value): request["action"] = "volume"; request["value"] = value
        case .toggleLike: request["action"] = "like"; request["id"] = currentID ?? ""
        case .jump(let index): request["action"] = "jump"; request["value"] = index
        }
        _ = try await bridge.request(request)
    }

    private func catalog(_ request: [String: Any], title: String) async throws -> CatalogPage {
        let reply = try await bridge.request(request)
        return CatalogPage(title: title, items: reply.items.map(Self.mediaItem))
    }
}

private struct LocalMusicBridge {
    struct Reply: Decodable {
        let ok: Bool
        let error: String?
        let configured: Bool
        let authenticated: Bool
        let account: String?
        let mpv: Bool
        let ytdlp: Bool
        let items: [RawItem]
        let sections: [RawSection]
        let snapshot: RawSnapshot?

        enum CodingKeys: String, CodingKey { case ok, error, configured, authenticated, account, mpv, ytdlp, items, sections, snapshot }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
            error = try c.decodeIfPresent(String.self, forKey: .error)
            configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
            authenticated = try c.decodeIfPresent(Bool.self, forKey: .authenticated) ?? false
            account = try c.decodeIfPresent(String.self, forKey: .account)
            mpv = try c.decodeIfPresent(Bool.self, forKey: .mpv) ?? false
            ytdlp = try c.decodeIfPresent(Bool.self, forKey: .ytdlp) ?? false
            items = try c.decodeIfPresent([RawItem].self, forKey: .items) ?? []
            sections = try c.decodeIfPresent([RawSection].self, forKey: .sections) ?? []
            snapshot = try c.decodeIfPresent(RawSnapshot.self, forKey: .snapshot)
        }
    }

    struct RawSection: Decodable {
        let title: String
        let items: [RawItem]
    }

    struct RawItem: Decodable {
        let title: String
        let subtitle: String
        let album: String
        let artwork: String
        let duration: Double
        let kind: String
        let url: String
        let liked: Bool?
    }

    struct RawSnapshot: Decodable {
        let idle: Bool?
        let title: String?
        let artist: String?
        let album: String?
        let artwork: String?
        let currentTime: Double?
        let duration: Double?
        let paused: Bool?
        let volume: Double?
        let muted: Bool?
        let liked: Bool?
        let queueIndex: Int?
        let queueCount: Int?
        let url: String?
    }

    func request(_ request: [String: Any]) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try Self.perform(request)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Runs the bridge on a GCD thread, never on the cooperative pool: the watchdog has to block.
    private static func perform(_ request: [String: Any]) throws -> Reply {
        // Bundled by build-app.sh; when running from `swift run`, fall back to the repo's scripts folder.
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("ytmusic_bridge.py")
        let script = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil }
            ?? ProcessInfo.processInfo.environment["YTMUSICBAR_BRIDGE"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("scripts/ytmusic_bridge.py").path
        let bundledPythonPath = Bundle.main.resourceURL?.appendingPathComponent(".ytmusic-venv/bin/python").path
        let bundledPython = bundledPythonPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let python = ProcessInfo.processInfo.environment["YTMUSICBAR_PYTHON"] ?? bundledPython ?? "/opt/homebrew/bin/python3"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script]
        var environment = ProcessInfo.processInfo.environment
        if let bundledPackages = Bundle.main.resourceURL?.appendingPathComponent("ytmusic-site-packages").path {
            environment["PYTHONPATH"] = bundledPackages + (environment["PYTHONPATH"].map { ":\($0)" } ?? "")
        }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try JSONSerialization.data(withJSONObject: request)
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data("\n".utf8))
        try input.fileHandleForWriting.close()
        // Read before waiting. A reply larger than the pipe buffer (~64KB, and a radio queue is
        // about 72KB) blocks the child on write while we block on exit, and neither ever moves.
        // The read runs on its own thread so the watchdog can still fire on a hung network call,
        // which the bridge cannot time out on its own.
        let capture = PipeCapture()
        let read = DispatchGroup()
        read.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            capture.store(output.fileHandleForReading.readDataToEndOfFile())
            read.leave()
        }
        guard read.wait(timeout: .now() + timeout) == .success else {
            terminate(process)
            throw LocalMusicError.timedOut(Int(timeout))
        }
        process.waitUntilExit()
        guard let line = String(data: capture.data, encoding: .utf8)?.split(separator: "\n").first,
              let json = line.data(using: .utf8) else { throw LocalMusicError.noReply }
        let reply = try JSONDecoder().decode(Reply.self, from: json)
        guard reply.ok else { throw LocalMusicError.failed(reply.error ?? "O backend local recusou o comando.") }
        return reply
    }

    /// Longest we wait for one bridge command. The slowest measured is a playlist load at about 2.5s,
    /// so this only fires on a request that is genuinely stuck.
    private static let timeout: TimeInterval = 20

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        if !waitForExit(process, seconds: 1) {
            kill(process.processIdentifier, SIGKILL)
            _ = waitForExit(process, seconds: 1)
        }
    }

    private static func waitForExit(_ process: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        return !process.isRunning
    }
}

/// Thread-safe box for the pipe read, which finishes on a different thread than the one that reads it.
private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func store(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private enum LocalMusicError: LocalizedError {
    case noReply
    case failed(String)
    case timedOut(Int)

    var errorDescription: String? {
        switch self {
        case .noReply: "O backend local não retornou uma resposta."
        case .failed(let message): message
        case .timedOut(let seconds): "O backend local não respondeu em \(seconds) segundos."
        }
    }
}
