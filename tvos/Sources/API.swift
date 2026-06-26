import Foundation

enum API {
    static func get<T: Decodable>(_ path: String, timeout: TimeInterval = 90) async throws -> T {
        let url = Config.backendBaseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Header-only fetch (name/avatar/bio/stats) — backed by a slow cold-start
    /// Playwright scrape, so it gets a tighter timeout than the default 90s:
    /// the profile screen renders its video grid from `userVideos` first and
    /// fills the header in whenever this resolves, so a timeout here just means
    /// a blank header rather than a stuck spinner.
    static func profile(_ username: String, timeout: TimeInterval = 20) async -> ProfileResponse? {
        try? await get("api/profile/\(username)", timeout: timeout) as ProfileResponse
    }

    static func userVideos(_ username: String, start: Int) async -> [FeedItem] {
        (try? await get("api/user-videos/\(username)?start=\(start)&count=30") as VideosResponse)?.videos ?? []
    }

    /// Per-clip loudness correction in dB (see backend analyzeGain) — applied
    /// on-device via AVAudioMix so every clip plays at a consistent level without
    /// any server-side audio re-encoding.
    static func audioGain(_ id: String) async -> Double {
        (try? await get("api/audiogain/\(id)") as AudioGainResponse)?.gain ?? 0
    }
}

struct AudioGainResponse: Decodable { let gain: Double }
