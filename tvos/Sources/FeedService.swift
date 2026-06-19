import Foundation

@MainActor
final class FeedService: ObservableObject {
    @Published var items: [FeedItem] = []   // initial batch only; the feed VC grows itself
    @Published var errorText: String?
    private var seen = Set<String>()

    private func fetch(_ path: String) async throws -> [FeedItem] {
        let url = Config.backendBaseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.timeoutInterval = 120 // first build can be slow
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

    /// Fetch the next batch for infinite scroll; returns only previously-unseen items.
    func loadMore() async -> [FeedItem] {
        do {
            return try await fetch("api/more").filter { seen.insert($0.id).inserted }
        } catch {
            return []
        }
    }
}
