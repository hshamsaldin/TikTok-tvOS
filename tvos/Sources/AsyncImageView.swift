import UIKit

private let memoryCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.totalCostLimit = 64 * 1024 * 1024   // ~64MB of decoded pixel data
    return c
}()

private let diskCacheDir: URL = {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ImageCache", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

private func diskPath(for key: String) -> URL {
    // Filenames can't contain arbitrary URL characters; hash to a safe name.
    diskCacheDir.appendingPathComponent("\(abs(key.hashValue)).jpg")
}

final class AsyncImageView: UIImageView {
    private var currentURL: String?
    private var task: URLSessionDataTask?

    func setImage(_ urlString: String?) {
        task?.cancel()
        task = nil
        image = nil
        currentURL = urlString
        guard let s = urlString, !s.isEmpty, let url = URL(string: s) else { return }

        let targetSize = bounds.size.width > 0 ? bounds.size : CGSize(width: 270, height: 480)
        let key = s as NSString

        if let cached = memoryCache.object(forKey: key) {
            image = cached
            return
        }

        let scale = UIScreen.main.scale
        let pixelSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diskURL = diskPath(for: s)
            if let data = try? Data(contentsOf: diskURL),
               let img = Self.downsample(data: data, to: pixelSize) {
                memoryCache.setObject(img, forKey: key, cost: Self.cost(of: img))
                DispatchQueue.main.async {
                    if self?.currentURL == s { self?.image = img }
                }
                return
            }

            let dataTask = URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let img = Self.downsample(data: data, to: pixelSize) else { return }
                memoryCache.setObject(img, forKey: key, cost: Self.cost(of: img))
                try? data.write(to: diskURL)
                DispatchQueue.main.async {
                    if self?.currentURL == s { self?.image = img }
                }
            }
            DispatchQueue.main.async {
                guard self?.currentURL == s else { dataTask.cancel(); return }
                self?.task = dataTask
            }
            dataTask.resume()
        }
    }

    /// Call from a reusable cell's `prepareForReuse()` to stop an in-flight
    /// download for an image that's about to scroll off-screen.
    func cancel() {
        task?.cancel()
        task = nil
        currentURL = nil
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }

    private static func downsample(data: Data, to pointSize: CGSize) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let maxDimensionInPixels = max(pointSize.width, pointSize.height)
        guard maxDimensionInPixels > 0 else { return nil }
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
