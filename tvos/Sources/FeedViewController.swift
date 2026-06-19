import UIKit

/// Full-screen vertical video feed driven by the Siri Remote:
///   swipe up/down = next/previous · click (select / play-pause) = play/pause.
final class FeedViewController: UIViewController,
    UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private var items: [FeedItem]
    var loadMore: (() async -> [FeedItem])?

    private var collectionView: UICollectionView!
    private let remoteView = RemoteInputView()   // focusable layer that captures the remote
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func update(items: [FeedItem]) {
        guard collectionView != nil else { self.items = items; return }
        let added = items.count - self.items.count
        self.items = items
        if added > 0 { collectionView.reloadData() }
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
        // (tvOS has no isPagingEnabled; we page programmatically via scrollToItem)
        // tvOS auto-insets scroll content for overscan — that shifts the video
        // off-center and breaks paging. Turn it off so cells fill exactly.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.backgroundColor = .black
        collectionView.showsVerticalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(VideoCell.self, forCellWithReuseIdentifier: Self.cellID)
        view.addSubview(collectionView)

        // Transparent focusable overlay on top — without something focusable,
        // tvOS doesn't route the remote's swipes/clicks to our recognizers.
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
        let right = UISwipeGestureRecognizer(target: self, action: #selector(openComments))
        right.direction = .right
        let left = UISwipeGestureRecognizer(target: self, action: #selector(openProfile))
        left.direction = .left
        [up, down, right, left].forEach { remoteView.addGestureRecognizer($0) }

        // App-level mute (with on-screen indicator) — the hardware mute button
        // mutes system audio but can't be detected by the app.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(toggleMute))
        remoteView.addGestureRecognizer(longPress)
    }

    // Directional CLICKS (and select/play-pause) — most reliable remote input on tvOS.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = true
        for press in presses {
            switch press.type {
            case .upArrow: goPrev()
            case .downArrow: goNext()
            case .leftArrow: openProfile()
            case .rightArrow: openComments()
            case .select, .playPause: togglePlay()
            case .menu:
                if let presented = presentedViewController {
                    presented.dismiss(animated: true)   // close comments/profile
                } else {
                    handled = false                     // at root → let tvOS go Home
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

    // Pause when covered (e.g. profile pushed on top); resume when back.
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); currentCell?.pause() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        currentCell?.resume()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private var currentItem: FeedItem? {
        let i = currentIndex
        return (i >= 0 && i < items.count) ? items[i] : nil
    }

    @objc private func openComments() {
        guard let item = currentItem else { return }
        present(CommentsViewController(videoID: item.id), animated: true)
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

    private func go(to index: Int) {
        guard index >= 0, index < items.count else { return }
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: true)
    }

    @objc private func goNext() { go(to: currentIndex + 1) }
    @objc private func goPrev() { go(to: currentIndex - 1) }
    @objc private func togglePlay() { currentCell?.togglePlayPause() }

    // MARK: data source

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: Self.cellID, for: indexPath) as! VideoCell
        cell.configure(with: items[indexPath.item])
        cell.onEnded = { [weak self] in self?.goNext() } // autoscroll
        return cell
    }

    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? VideoCell else { return }
        currentCell = cell
        cell.play()
        cell.setMuted(muted)
        maybeLoadMore(indexPath.item)
    }

    func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? VideoCell)?.pause()
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        cv.bounds.size
    }

    // MARK: infinite scroll

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

/// Transparent, focusable overlay so tvOS routes the Siri Remote to the feed.
final class RemoteInputView: UIView {
    override var canBecomeFocused: Bool { true }
}
