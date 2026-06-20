import Foundation

@MainActor
final class FeedService: ObservableObject {
    @Published var items: [FeedItem] = []
    @Published var errorText: String?
    private var seen = Set<String>()

    private func fetch(_ path: String) async throws -> [FeedItem] {
        let url = Config.backendBaseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(Feed.self, from: data).items
    }

    func load() async {
        errorText = nil
        do {
            let fresh = try await fetch("api/feed")
            seen = Set(fresh.map { $0.id })
            items = fresh
        } catch {
            errorText = error.localizedDescription
        }
    }

    func loadMore() async -> [FeedItem] {
        do {
            return try await fetch("api/more").filter { seen.insert($0.id).inserted }
        } catch {
            return []
        }
    }
}
