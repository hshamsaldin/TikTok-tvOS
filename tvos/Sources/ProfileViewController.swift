import UIKit

/// Channel profile, styled for the TV's landscape screen (like TikTok's desktop
/// profile): a cinematic blurred backdrop, an avatar + name + stats header on the
/// left, and a grid of rounded poster cards below. Select a poster to play that
/// channel's videos. The Menu/Back button closes it.
final class ProfileViewController: UIViewController, UICollectionViewDataSource,
    UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {

    private let username: String
    private var videos: [FeedItem] = []
    private var user: ProfileUser?
    private var loadingMore = false

    // Cinematic backdrop (blurred avatar) so the screen is never flat grey/black.
    private let backdrop = AsyncImageView()
    private let backdropBlur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let dim = UIView()

    // Header
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

    private var grid: UICollectionView!
    private let spinner = UIActivityIndicatorView(style: .large)

    private let gridSpacing: CGFloat = 22
    private let sideInset: CGFloat = 80
    private var lastGridHeight: CGFloat = 0

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
        setupBackHint()                 // build the Back chip first…
        let header = setupHeader()      // …so the header can sit below it
        headerView = header
        setupGrid(below: header)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        // Hide the header + grid until the data arrives, so we don't show an empty
        // avatar/“Videos” skeleton. Only the Back chip + spinner show while loading.
        [headerView, videosTitle, grid].forEach { $0?.alpha = 0 }

        load()
    }

    // MARK: setup

    private func setupBackdrop() {
        view.backgroundColor = .black   // plain black, like the icon's background
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

        // name · @username · verified, inline on one row
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
            // Sit below the Back chip so they never overlap in the top-left corner.
            header.topAnchor.constraint(equalTo: backChip.bottomAnchor, constant: 20),
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

        // One horizontal row of posters — scroll left/right; no second-row peeking.
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = gridSpacing
        layout.minimumLineSpacing = gridSpacing
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        grid.backgroundColor = .clear
        grid.contentInsetAdjustmentBehavior = .never
        grid.showsHorizontalScrollIndicator = false
        grid.dataSource = self
        grid.delegate = self
        grid.remembersLastFocusedIndexPath = true
        grid.register(GridCell.self, forCellWithReuseIdentifier: "g")
        grid.contentInset = UIEdgeInsets(top: 0, left: sideInset, bottom: 0, right: sideInset)
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)

        NSLayoutConstraint.activate([
            videosTitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            videosTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: sideInset),
            // single row that fills the space from under "Videos" down to the bottom
            // (taller posters, no empty band below).
            grid.topAnchor.constraint(equalTo: videosTitle.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
        ])
    }

    /// Subtle, native-looking back affordance top-left. Navigation itself is the
    /// remote's Menu/Back button (tvOS convention), this just signals it.
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

    // MARK: data

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
            // Reveal the now-populated header + grid together.
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

    // Re-query item size once the grid's real height settles.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if grid.bounds.height != lastGridHeight {
            lastGridHeight = grid.bounds.height
            grid.collectionViewLayout.invalidateLayout()
        }
    }

    // One row of 9:16 posters (matches the TikTok cover aspect, so covers fill the
    // cell with no cropping — "full video" thumbnails), as tall as the row.
    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let h = max(cv.bounds.height, 1)
        return CGSize(width: floor(h * 9.0 / 16.0), height: h)
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

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [grid] }

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

/// One stat column: big number over a small caption (TikTok-style).
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

/// Rounded poster card with a play-count overlay; lifts and shadows on focus.
final class GridCell: UICollectionViewCell {
    private let cover = AsyncImageView()
    private let gradient = CAGradientLayer()
    private let plays = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        contentView.backgroundColor = UIColor(white: 0.12, alpha: 1)

        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.frame = contentView.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(cover)

        gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.7).cgColor]
        contentView.layer.addSublayer(gradient)

        plays.font = .app(ofSize: 18, weight: .bold)
        plays.textColor = .white
        plays.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(plays)
        NSLayoutConstraint.activate([
            plays.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            plays.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])

        // Shadow lives on the (unclipped) cell layer so it shows when focused.
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

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        coordinator.addCoordinatedAnimations({
            let focused = self.isFocused
            self.transform = focused ? CGAffineTransform(scaleX: 1.1, y: 1.1) : .identity
            self.layer.shadowOpacity = focused ? 0.5 : 0
            self.contentView.layer.borderWidth = focused ? 3 : 0
            self.contentView.layer.borderColor = UIColor.white.cgColor
        })
    }
}
