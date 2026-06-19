import UIKit

private let imageCache = NSCache<NSURL, UIImage>()

/// UIImageView that loads a remote image (avatar / cover), with caching and
/// safe reuse (ignores a late response if the view was reassigned a new URL).
final class AsyncImageView: UIImageView {
    private var currentURL: String?

    func setImage(_ urlString: String?) {
        image = nil
        currentURL = urlString
        guard let s = urlString, !s.isEmpty, let url = URL(string: s) else { return }
        if let cached = imageCache.object(forKey: url as NSURL) {
            image = cached
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            imageCache.setObject(img, forKey: url as NSURL)
            DispatchQueue.main.async {
                if self?.currentURL == s { self?.image = img }
            }
        }.resume()
    }
}
