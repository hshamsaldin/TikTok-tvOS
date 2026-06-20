import UIKit

final class ProfileViewController: UIViewController, UICollectionViewDataSource,
    UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {

    private let username: String
    private var videos: [FeedItem] = []
    private var user: ProfileUser?
    private var loadingMore = false

    private let avatar = AsyncImageView()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let bioLabel = UILabel()
    private let followingStat = StatView()
    private let followersStat = StatView()
    private let likesStat = StatView()
    private let videosTitle = UILabel()
    private let verifiedBadge = UIImageView()
    private let backChip = UIStackView()
    private var headerView: UIView!
    private let headerBg = UIView()   // opaque backdrop so the grid scrolls UNDER the header, not over it

    private var grid: UICollectionView!
    private let spinner = UIActivityIndicatorView(style: .large)

    private let gridColumns: CGFloat = 4
    // Base gap between cards. Sized so that even when a card grows under the
    // 1.05x focus zoom (~10pt per side) a clear, even gap to its neighbour remains.
    private let gridSpacing: CGFloat = 48
    private let sideInset: CGFloat = 110
    private var lastGridWidth: CGFloat = 0

    init(username: String) {
        self.username = username
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupBackdrop()
        setupBackHint()
        let header = setupHeader()
        headerView = header
        setupGrid(below: header)

        headerBg.backgroundColor = .black
        headerBg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBg)
        NSLayoutConstraint.activate([
            headerBg.topAnchor.constraint(equalTo: view.topAnchor),
            headerBg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerBg.bottomAnchor.constraint(equalTo: videosTitle.bottomAnchor, constant: 14),
        ])
        [header, videosTitle, backChip].forEach { view.bringSubviewToFront($0) }

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        focusFallback.backgroundColor = .clear
        focusFallback.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(focusFallback)
        NSLayoutConstraint.activate([
            focusFallback.topAnchor.constraint(equalTo: view.topAnchor),
            focusFallback.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            focusFallback.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            focusFallback.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        [headerView, videosTitle, grid].forEach { $0?.alpha = 0 }

        load()
    }

    private func setupBackdrop() {
        view.backgroundColor = .black
    }

    private func setupHeader() -> UIView {
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.layer.cornerRadius = 80
        avatar.clipsToBounds = true
        avatar.backgroundColor = UIColor(white: 0.18, alpha: 1)
        avatar.contentMode = .scaleAspectFill
        avatar.layer.borderWidth = 3
        avatar.layer.borderColor = UIColor(white: 1, alpha: 0.85).cgColor

        nameLabel.font = .app(ofSize: 42, weight: .bold)
        nameLabel.textColor = .white
        handleLabel.font = .app(ofSize: 26, weight: .medium)
        handleLabel.textColor = UIColor(white: 1, alpha: 0.65)
        bioLabel.font = .app(ofSize: 21)
        bioLabel.textColor = UIColor(white: 1, alpha: 0.85)
        bioLabel.numberOfLines = 2

        let stats = UIStackView(arrangedSubviews: [followersStat, followingStat, likesStat])
        stats.axis = .horizontal
        stats.spacing = 54
        stats.alignment = .leading

        verifiedBadge.image = UIImage(systemName: "checkmark.seal.fill")
        verifiedBadge.tintColor = UIColor(red: 0.13, green: 0.71, blue: 0.94, alpha: 1)
        verifiedBadge.contentMode = .scaleAspectFit
        verifiedBadge.setContentHuggingPriority(.required, for: .horizontal)
        verifiedBadge.widthAnchor.constraint(equalToConstant: 30).isActive = true
        verifiedBadge.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let divider = UILabel()
        divider.text = "|"
        divider.font = .app(ofSize: 24)
        divider.textColor = UIColor(white: 1, alpha: 0.35)

        let titleRow = UIStackView(arrangedSubviews: [nameLabel, divider, handleLabel, verifiedBadge])
        titleRow.axis = .horizontal
        titleRow.spacing = 12
        titleRow.alignment = .center

        let info = UIStackView(arrangedSubviews: [titleRow, stats, bioLabel])
        info.axis = .vertical
        info.spacing = 12
        info.alignment = .leading
        info.setCustomSpacing(20, after: titleRow)
        info.setCustomSpacing(20, after: stats)

        let header = UIStackView(arrangedSubviews: [avatar, info])
        header.axis = .horizontal
        header.spacing = 40
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 160),
            avatar.heightAnchor.constraint(equalToConstant: 160),

            header.topAnchor.constraint(equalTo: backChip.bottomAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: sideInset),
            header.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -sideInset),
        ])
        return header
    }

    private func setupGrid(below header: UIView) {
        videosTitle.text = "Videos"
        videosTitle.font = .app(ofSize: 30, weight: .semibold)
        videosTitle.textColor = .white
        videosTitle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videosTitle)

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = gridSpacing
        layout.minimumLineSpacing = gridSpacing
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        grid.backgroundColor = .clear
        grid.contentInsetAdjustmentBehavior = .never
        grid.showsVerticalScrollIndicator = false
        grid.dataSource = self
        grid.delegate = self
        grid.remembersLastFocusedIndexPath = true
        grid.register(GridCell.self, forCellWithReuseIdentifier: "g")

        // Let the 1.1x focus scale + shadow float over neighbours instead of
        // being clipped at the grid's edges.
        grid.clipsToBounds = false
        grid.contentInset = UIEdgeInsets(top: 40, left: sideInset, bottom: 60, right: sideInset)
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)

        NSLayoutConstraint.activate([
            videosTitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 28),
            videosTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: sideInset),
            grid.topAnchor.constraint(equalTo: videosTitle.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupBackHint() {
        backChip.axis = .horizontal
        backChip.spacing = 10
        backChip.alignment = .center
        backChip.isLayoutMarginsRelativeArrangement = true
        backChip.directionalLayoutMargins = .init(top: 10, leading: 18, bottom: 10, trailing: 22)
        backChip.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        backChip.layer.cornerRadius = 24
        backChip.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "chevron.backward",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)))
        icon.tintColor = .white
        let label = UILabel()
        label.text = "Back"
        label.font = .app(ofSize: 22, weight: .semibold)
        label.textColor = .white
        backChip.addArrangedSubview(icon)
        backChip.addArrangedSubview(label)
        view.addSubview(backChip)
        NSLayoutConstraint.activate([
            backChip.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            backChip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
        ])
    }

    private func load() {
        spinner.startAnimating()
        Task { @MainActor in
            let data = await API.profile(username)
            spinner.stopAnimating()
            guard let data else { return }
            user = data.user
            videos = data.videos
            applyHeader()
            grid.reloadData()
            setNeedsFocusUpdate()      // hand focus from the fallback to the first poster
            updateFocusIfNeeded()

            UIView.animate(withDuration: 0.25) {
                [self.headerView, self.videosTitle, self.grid].forEach { $0?.alpha = 1 }
            }
        }
    }

    private func applyHeader() {
        avatar.setImage(user?.avatar)
        nameLabel.text = user?.nickname ?? username
        handleLabel.text = user?.username ?? username
        verifiedBadge.isHidden = !(user?.verified ?? false)
        followersStat.set(Format.count(user?.followers), "Followers")
        followingStat.set(Format.count(user?.following), "Following")
        likesStat.set(Format.count(user?.likes), "Likes")
        bioLabel.text = user?.signature
        bioLabel.isHidden = (user?.signature?.isEmpty != false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if grid.bounds.width != lastGridWidth {
            lastGridWidth = grid.bounds.width
            grid.collectionViewLayout.invalidateLayout()
        }
    }

    // Size strictly by the cover's TRUE aspect ratio (9:16 — what our TikTok video-
    // frame covers actually are), matching how Apple's own MovieShelf sample sizes
    // posters: by the real ratio first, never distorted to force a row count. A
    // height cap here was squashing cards away from 9:16, which is what caused
    // letterboxing — not a Fit-vs-Fill problem. The "next row peeks in" effect
    // comes for free from the grid simply scrolling past the viewport edge, the
    // same way Apple's shelves work — no artificial shrinking needed.
    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = cv.bounds.width > 0 ? cv.bounds.width : 1920
        let usable = width - sideInset * 2 - gridSpacing * (gridColumns - 1)
        let w = floor(usable / gridColumns)
        return CGSize(width: w, height: w * 16.0 / 9.0)
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int { videos.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "g", for: ip) as! GridCell
        cell.configure(videos[ip.item])
        return cell
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        let feed = FeedViewController(items: videos, startIndex: ip.item)
        feed.modalPresentationStyle = .fullScreen
        present(feed, animated: true)
    }

    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt ip: IndexPath) {
        if ip.item >= videos.count - 6 { loadMore() }
    }

    private func loadMore() {
        guard !loadingMore else { return }
        loadingMore = true
        Task { @MainActor in
            let more = await API.userVideos(username, start: videos.count)
            if !more.isEmpty {
                let start = videos.count
                videos.append(contentsOf: more)
                grid.insertItems(at: (start..<videos.count).map { IndexPath(item: $0, section: 0) })
            }
            loadingMore = false
        }
    }

    // tvOS needs SOMETHING focusable to reliably deliver remote presses (incl.
    // Menu/Back). While the grid is still empty during the initial load, it has
    // no cells to focus — this invisible fallback keeps Back working immediately,
    // before the first video even arrives. The grid takes priority once populated.
    private let focusFallback = RemoteInputView()

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [grid, focusFallback] }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { dismiss(animated: true) }
        else { super.pressesBegan(presses, with: event) }
    }
}

final class StatView: UIView {
    private let value = UILabel()
    private let caption = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        value.font = .app(ofSize: 30, weight: .bold)
        value.textColor = .white
        caption.font = .app(ofSize: 18, weight: .medium)
        caption.textColor = UIColor(white: 1, alpha: 0.6)
        let s = UIStackView(arrangedSubviews: [value, caption])
        s.axis = .vertical
        s.spacing = 2
        s.alignment = .leading
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: topAnchor),
            s.bottomAnchor.constraint(equalTo: bottomAnchor),
            s.leadingAnchor.constraint(equalTo: leadingAnchor),
            s.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    func set(_ v: String, _ c: String) { value.text = v; caption.text = c }
}

final class GridCell: UICollectionViewCell {
    private let cover = AsyncImageView()
    private let gradient = CAGradientLayer()
    private let plays = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        contentView.backgroundColor = UIColor(white: 0.10, alpha: 1)

        // .fit, matching Apple's MovieShelf sample — now that the cell's own
        // frame is sized to the cover's true ratio, there's nothing to crop.
        cover.contentMode = .scaleAspectFit
        cover.clipsToBounds = true
        cover.frame = contentView.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(cover)

        gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.7).cgColor]
        gradient.opacity = 0
        contentView.layer.addSublayer(gradient)

        // Hidden until focused, like Apple's own MovieShelf/TVMusicShelf samples
        // (.visibleWhenFocused()) — declutters the grid; metadata reveals on focus.
        plays.font = .app(ofSize: 18, weight: .bold)
        plays.textColor = .white
        plays.alpha = 0
        plays.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(plays)
        NSLayoutConstraint.activate([
            plays.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            plays.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 12)
        layer.shadowRadius = 20
        layer.shadowOpacity = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = CGRect(x: 0, y: contentView.bounds.height - 120,
                                width: contentView.bounds.width, height: 120)
    }

    func configure(_ v: FeedItem) {
        cover.setImage(v.cover)
        plays.text = "▶ \(Format.count(v.plays))"
    }

    // Reused cells must not inherit the previous item's focus transform/shadow/
    // border — without this reset, a recycled cell can show a stale "focused"
    // look (scaled, shadowed, bordered) on a different video after scrolling.
    override func prepareForReuse() {
        super.prepareForReuse()
        transform = .identity
        layer.shadowOpacity = 0
        contentView.layer.borderWidth = 0
        gradient.opacity = 0
        plays.alpha = 0
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        coordinator.addCoordinatedAnimations({
            let focused = self.isFocused
            self.transform = focused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
            self.layer.shadowOpacity = focused ? 0.5 : 0
            self.contentView.layer.borderWidth = focused ? 3 : 0
            self.contentView.layer.borderColor = UIColor.white.cgColor
            self.gradient.opacity = focused ? 1 : 0
            self.plays.alpha = focused ? 1 : 0
        })
    }
}
