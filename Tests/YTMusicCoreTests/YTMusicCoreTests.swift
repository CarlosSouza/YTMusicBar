import Foundation
import YTMusicCore

struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
enum YTMusicCoreChecks {
    static func main() throws {
        let url = try require(YouTubeMusicURL.search(query: "  música & café  "), "A busca válida não gerou URL.")
        let components = try require(URLComponents(url: url, resolvingAgainstBaseURL: false), "A URL de busca é inválida.")
        try expect(components.host == "music.youtube.com", "Host de busca incorreto.")
        try expect(components.path == "/search", "Caminho de busca incorreto.")
        try expect(components.queryItems == [URLQueryItem(name: "q", value: "música & café")], "Query não foi codificada com URLQueryItem.")
        try expect(YouTubeMusicURL.search(query: "  \n ") == nil, "Busca vazia deveria ser ignorada.")
        try expect(YouTubeMusicURL.library.absoluteString == "https://music.youtube.com/library/songs", "URL da biblioteca incorreta.")
        try expect(YouTubeMusicURL.playlists.absoluteString == "https://music.youtube.com/library/playlists", "URL de playlists incorreta.")

        let observed = Date(timeIntervalSince1970: 1_000)
        let playing = PlaybackSnapshot(
            title: "Song", artist: "Artist", album: "Album", artworkURL: nil,
            currentTime: 20, duration: 30, isPaused: false, volume: 0.5,
            isMuted: false, pageURL: nil, observedAt: observed
        )
        try expect(playing.estimatedTime(at: observed.addingTimeInterval(4)) == 24, "O progresso não avançou.")
        try expect(playing.estimatedTime(at: observed.addingTimeInterval(50)) == 30, "O progresso ultrapassou a duração.")

        let paused = PlaybackSnapshot(
            title: "Song", artist: "Artist", album: "", artworkURL: nil,
            currentTime: 12, duration: 200, isPaused: true, volume: 1,
            isMuted: false, pageURL: nil, observedAt: observed
        )
        try expect(paused.estimatedTime(at: observed.addingTimeInterval(20)) == 12, "Uma faixa pausada avançou.")
        try expect(DurationFormatting.clock(0) == "0:00", "Formato de zero incorreto.")
        try expect(DurationFormatting.clock(65.9) == "1:05", "Formato em minutos incorreto.")
        try expect(DurationFormatting.clock(3_661) == "1:01:01", "Formato em horas incorreto.")

        let queued = PlaybackSnapshot(
            title: "Song", artist: "", album: "", artworkURL: nil, currentTime: 0, duration: 10, isPaused: true,
            volume: 1, isMuted: false, pageURL: URL(string: "https://music.youtube.com/watch?v=abc123"),
            queueIndex: 1, queueCount: 3, observedAt: observed
        )
        try expect(queued.videoID == "abc123", "videoID não foi extraído da URL.")
        try expect(queued.hasNext, "Faixa no meio da fila deveria ter próxima.")
        try expect(!playing.hasNext, "Faixa única não deveria ter próxima.")

        let song = MediaItem(title: "S", subtitle: "", artworkURL: nil, destinationURL: URL(string: "https://music.youtube.com/watch?v=vid42")!)
        let playlist = MediaItem(title: "P", subtitle: "", artworkURL: nil, destinationURL: URL(string: "https://music.youtube.com/playlist?list=PL99")!, kind: .playlist)
        let album = MediaItem(title: "A", subtitle: "", artworkURL: nil, destinationURL: URL(string: "https://music.youtube.com/playlist?list=MPREb_abc")!, kind: .album)
        try expect(song.remoteID == "vid42", "remoteID da música incorreto.")
        try expect(playlist.remoteID == "PL99", "remoteID da playlist incorreto.")
        try expect(album.remoteID == "MPREb_abc", "remoteID do álbum incorreto.")

        print("YTMusicCoreChecks: OK")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(message: message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CheckFailure(message: message) }
        return value
    }
}
