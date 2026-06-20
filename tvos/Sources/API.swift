import Foundation

enum API {
    static func get<T: Decodable>(_ path: String, timeout: TimeInterval = 90) async throws -> T {
        let url = Config.backendBaseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func comments(_ id: String) async -> [CommentItem] {
        (try? await get("api/comments/\(id)", timeout: 60) as CommentsResponse)?.comments ?? []
    }

    static func profile(_ username: String) async -> ProfileResponse? {
        try? await get("api/profile/\(username)") as ProfileResponse
    }

    static func userVideos(_ username: String, start: Int) async -> [FeedItem] {
        (try? await get("api/user-videos/\(username)?start=\(start)&count=30") as VideosResponse)?.videos ?? []
    }
}
