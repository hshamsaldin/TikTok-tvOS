import SwiftUI

/// Bridges the UIKit feed controller into SwiftUI.
struct VerticalFeedView: UIViewControllerRepresentable {
    let items: [FeedItem]
    var loadMore: (() async -> [FeedItem])?

    func makeUIViewController(context: Context) -> FeedViewController {
        let vc = FeedViewController(items: items)
        vc.loadMore = loadMore
        return vc
    }

    func updateUIViewController(_ vc: FeedViewController, context: Context) {
        vc.loadMore = loadMore
        vc.update(items: items)
    }
}
