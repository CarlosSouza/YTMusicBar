import Foundation

public struct PlaybackSnapshot: Codable, Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let artworkURL: URL?
    public let currentTime: Double
    public let duration: Double
    public let isPaused: Bool
    public let volume: Double
    public let isMuted: Bool
    public let isLiked: Bool?
    /// True while mpv holds the track but has not started producing audio yet, which is how long
    /// yt-dlp takes to resolve the stream. Nothing is playing, so the position must not advance.
    public let isPreparing: Bool
    public let pageURL: URL?
    public let queueIndex: Int
    public let queueCount: Int
    public let observedAt: Date

    public init(
        title: String,
        artist: String,
        album: String,
        artworkURL: URL?,
        currentTime: Double,
        duration: Double,
        isPaused: Bool,
        volume: Double,
        isMuted: Bool,
        isLiked: Bool? = nil,
        isPreparing: Bool = false,
        pageURL: URL?,
        queueIndex: Int = 0,
        queueCount: Int = 1,
        observedAt: Date = Date()
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.currentTime = currentTime.isFinite ? max(0, currentTime) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.isPaused = isPaused
        self.volume = volume.isFinite ? min(max(volume, 0), 1) : 0
        self.isMuted = isMuted
        self.isLiked = isLiked
        self.isPreparing = isPreparing
        self.pageURL = pageURL
        self.queueIndex = max(0, queueIndex)
        self.queueCount = max(1, queueCount)
        self.observedAt = observedAt
    }

    /// YouTube video id of the current track, taken from the `v` query item of `pageURL`.
    public var videoID: String? { pageURL.flatMap { YouTubeMusicURL.queryValue("v", in: $0) } }

    /// Whether mpv still has a queued track after the current one.
    public var hasNext: Bool { queueIndex < queueCount - 1 }

    public func estimatedTime(at date: Date) -> Double {
        guard !isPaused, !isPreparing, duration > 0 else { return min(currentTime, duration) }
        return min(max(0, currentTime + max(0, date.timeIntervalSince(observedAt))), duration)
    }
}

public enum PlaybackAction: Equatable, Sendable {
    case togglePlayback
    case previous
    case next
    case seek(to: Double)
    case setVolume(Double)
    case toggleMute
    /// Jump to a position of the current queue.
    case jump(to: Int)
}

public enum MediaKind: String, Codable, Sendable {
    case song, playlist, album, artist, collection

    public var displayName: String {
        switch self {
        case .song: "Música"
        case .playlist: "Playlist"
        case .album: "Álbum"
        case .artist: "Artista"
        case .collection: "Coleção"
        }
    }
}

public struct MediaItem: Codable, Identifiable, Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let album: String
    public let artworkURL: URL?
    public let destinationURL: URL
    public let kind: MediaKind
    public let duration: Double
    public let isLiked: Bool?

    public var id: String { destinationURL.absoluteString }

    /// Identifier the bridge needs to play the item: the video id for songs, the `list` id for playlists and albums.
    public var remoteID: String {
        let key = kind == .song ? "v" : "list"
        return YouTubeMusicURL.queryValue(key, in: destinationURL) ?? ""
    }

    public init(title: String, subtitle: String, album: String = "", artworkURL: URL?, destinationURL: URL, kind: MediaKind = .song, duration: Double = 0, isLiked: Bool? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.album = album
        self.artworkURL = artworkURL
        self.destinationURL = destinationURL
        self.kind = kind
        self.duration = duration
        self.isLiked = isLiked
    }
}

public struct CatalogPage: Codable, Equatable, Sendable {
    public let title: String
    public let items: [MediaItem]

    public init(title: String, items: [MediaItem]) {
        self.title = title
        self.items = items
    }
}

/// One titled row of the YouTube Music home, as shown in the "Para você" tab.
public struct HomeSection: Codable, Identifiable, Equatable, Sendable {
    public let title: String
    public let items: [MediaItem]

    public var id: String { title }

    public init(title: String, items: [MediaItem]) {
        self.title = title
        self.items = items
    }
}

public enum YouTubeMusicURL {
    public static let home = URL(string: "https://music.youtube.com/")!
    public static let library = URL(string: "https://music.youtube.com/library/songs")!
    public static let playlists = URL(string: "https://music.youtube.com/library/playlists")!

    public static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value
    }

    public static func search(query: String) -> URL? {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        var components = URLComponents(string: "https://music.youtube.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: cleaned)]
        return components?.url
    }
}

public enum DurationFormatting {
    public static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
