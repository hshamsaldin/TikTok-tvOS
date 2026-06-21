import UIKit
import AVFoundation

final class FeedViewController: UIViewController,
    UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private var items: [FeedItem]
    var loadMore: (() async -> [FeedItem])?

    private var pool: [String: AVPlayer] = [:]
    private var poolOrder: [String] = []
    private let poolMax = 5

    private var collectionView: UICollectionView!
    private let remoteView = RemoteInputView()
    private weak var currentCell: VideoCell?
    private var isLoadingMore = false
    private var muted = false
    private let startIndex: Int
    private var didInitialScroll = false
    private static let cellID = "VideoCell"

    init(items: [FeedItem], startIndex: Int = 0) {
        self.items = items
        self.startIndex = startIndex
        super.init(nibName: nil, bundle: nil)
        // Stop audio the moment the user exits to the Home Screen — YouTube's tvOS
        // app behaves this way too (it declares no background-audio capability at
        // all). Pausing explicitly here is the reliable fix regardless of what the
        // app's background-mode entitlement otherwise permits.
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func appDidEnterBackground() { currentCell?.pause() }
    @objc private func appWillEnterForeground() {
        guard presentedViewController == nil else { return }   // stay paused behind profile/comments
        currentCell?.resume()
    }

    func update(items: [FeedItem]) {
        if collectionView == nil { self.items = items }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.backgroundColor = .black
        collectionView.showsVerticalScrollIndicator = false

        collectionView.isPrefetchingEnabled = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(VideoCell.self, forCellWithReuseIdentifier: Self.cellID)
        view.addSubview(collectionView)

        remoteView.frame = view.bounds
        remoteView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        remoteView.backgroundColor = .clear
        view.addSubview(remoteView)

        addRemoteGestures()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [remoteView] }

    private func addRemoteGestures() {
        let up = UISwipeGestureRecognizer(target: self, action: #selector(goNext))
        up.direction = .up
        let down = UISwipeGestureRecognizer(target: self, action: #selector(goPrev))
        down.direction = .down
        let right = UISwipeGestureRecognizer(target: self, action: #selector(openProfile))
        right.direction = .right
        [up, down, right].forEach { remoteView.addGestureRecognizer($0) }

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(toggleMute))
        remoteView.addGestureRecognizer(longPress)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = true
        for press in presses {
            switch press.type {
            case .upArrow: goPrev()
            case .downArrow: goNext()
            case .rightArrow: openProfile()
            case .select, .playPause: togglePlay()
            case .menu:
                if let presented = presentedViewController {
                    presented.dismiss(animated: true)
                } else {
                    handled = false
                }
            default: handled = false
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didInitialScroll, startIndex > 0, startIndex < items.count, collectionView.bounds.height > 0 {
            didInitialScroll = true
            collectionView.scrollToItem(at: IndexPath(item: startIndex, section: 0), at: .top, animated: false)
        }
    }

    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); currentCell?.pause() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        currentCell?.resume()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private var currentItem: FeedItem? {
        let i = targetIndex ?? currentIndex
        return (i >= 0 && i < items.count) ? items[i] : nil
    }

    @objc private func openProfile() {
        guard let item = currentItem, !item.handle.isEmpty else { return }
        present(ProfileViewController(username: item.handle), animated: true)
    }

    @objc private func toggleMute(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        muted.toggle()
        currentCell?.setMuted(muted)
    }

    private var currentIndex: Int {
        let h = max(collectionView.bounds.height, 1)
        return Int((collectionView.contentOffset.y / h).rounded())
    }

    // Track the intended page rather than reading contentOffset (which lags mid-
    // animation). Without this, a quick double-press during the scroll animation
    // re-targets the SAME page the first press already started — feels laggy and
    // unresponsive compared to native tvOS paging, which always honors fast input.
    private var targetIndex: Int?

    private func go(to index: Int) {
        guard index >= 0, index < items.count else { return }
        targetIndex = index
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: true)
    }

    @objc private func goNext() { go(to: (targetIndex ?? currentIndex) + 1) }
    @objc private func goPrev() { go(to: (targetIndex ?? currentIndex) - 1) }
    @objc private func togglePlay() { currentCell?.togglePlayPause() }

    func takePlayer(for id: String) -> AVPlayer? {
        guard let p = pool[id] else { return nil }
        pool[id] = nil
        poolOrder.removeAll { $0 == id }
        return p
    }

    private func preload(_ id: String) {
        guard pool[id] == nil else { return }
        let url = Config.backendBaseURL.appendingPathComponent("api/hls/\(id)/index.m3u8")
        let item = AVPlayerItem(url: url)
        // Pooled players sit idle, never playing, while waiting their turn — up to
        // poolMax (5) can exist at once. Without a cap each buffers as much as it
        // can indefinitely, competing for bandwidth with the video actually
        // playing right now. A few seconds is enough for an instant start once it
        // becomes active; VideoCell.openStream lifts the cap when that happens.
        item.preferredForwardBufferDuration = 5
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.allowsExternalPlayback = true
        pool[id] = p
        poolOrder.append(id)
        while poolOrder.count > poolMax {
            let old = poolOrder.removeFirst()
            pool[old]?.replaceCurrentItem(with: nil)
            pool[old] = nil
        }
    }

    private func preloadAround(_ index: Int) {
        for i in [index + 1, index + 2, index + 3] where i >= 0 && i < items.count {
            preload(items[i].id)
        }
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: Self.cellID, for: indexPath) as! VideoCell
        cell.providePlayer = { [weak self] id in self?.takePlayer(for: id) }
        cell.configure(with: items[indexPath.item])
        cell.onEnded = { [weak self] in self?.goNext() }
        return cell
    }

    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? VideoCell else { return }
        currentCell = cell
        cell.play()
        cell.setMuted(muted)
        preloadAround(indexPath.item)
        maybeLoadMore(indexPath.item)
    }

    func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? VideoCell)?.pause()
    }

    // Once a scroll settles, fall back to reading the real offset again.
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { targetIndex = nil }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        cv.bounds.size
    }

    private func maybeLoadMore(_ index: Int) {
        guard !isLoadingMore, let loadMore, index >= items.count - 5 else { return }
        isLoadingMore = true
        Task { @MainActor in
            let new = await loadMore()
            if !new.isEmpty {
                let start = items.count
                items.append(contentsOf: new)
                let paths = (start..<items.count).map { IndexPath(item: $0, section: 0) }
                collectionView.insertItems(at: paths)
            }
            isLoadingMore = false
        }
    }
}

final class RemoteInputView: UIView {
    override var canBecomeFocused: Bool { true }
}
