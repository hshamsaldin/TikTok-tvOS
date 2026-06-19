import UIKit

/// Channel profile: header (avatar, name, stats, bio) + a grid of videos.
/// Select a thumbnail to play that channel's videos. Menu closes it.
final class ProfileViewController: UIViewController, UICollectionViewDataSource,
    UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    private let username: String
    private var videos: [FeedItem] = []
    private var user: ProfileUser?
    private var loadingMore = false

    private let avatar = AsyncImageView()
    private let nameLabel = UILabel()
    private let statsLabel = UILabel()
    private let bioLabel = UILabel()
    private var grid: UICollectionView!
    private let spinner = UIActivityIndicatorView(style: .large)
    private let gridColumns: CGFloat = 6
    private let gridSpacing: CGFloat = 16
    private let gridInset: CGFloat = 40
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

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.layer.cornerRadius = 60
        avatar.clipsToBounds = true
        avatar.backgroundColor = UIColor(white: 0.2, alpha: 1)
        avatar.contentMode = .scaleAspectFill

        nameLabel.font = .systemFont(ofSize: 34, weight: .bold)
        nameLabel.textColor = .white
        statsLabel.font = .systemFont(ofSize: 20)
        statsLabel.textColor = UIColor(white: 1, alpha: 0.85)
        bioLabel.font = .systemFont(ofSize: 18)
        bioLabel.textColor = UIColor(white: 1, alpha: 0.8)
        bioLabel.numberOfLines = 3

        let info = UIStackView(arrangedSubviews: [nameLabel, statsLabel, bioLabel])
        info.axis = .vertical
        info.spacing = 8
        info.alignment = .leading
        let header = UIStackView(arrangedSubviews: [avatar, info])
        header.axis = .horizontal
        header.spacing = 28
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = gridSpacing
        layout.minimumLineSpacing = gridSpacing
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        grid.backgroundColor = .clear
        grid.contentInsetAdjustmentBehavior = .never        // don't let overscan eat the width
        grid.dataSource = self
        grid.delegate = self
        grid.register(GridCell.self, forCellWithReuseIdentifier: "g")
        grid.contentInset = UIEdgeInsets(top: 10, left: gridInset, bottom: 40, right: gridInset)
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 120),
            avatar.heightAnchor.constraint(equalToConstant: 120),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 80),
            header.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -80),
            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 26),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        load()
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
        }
    }

    // The flow layout can be first queried before the grid knows its real width
    // (it ends up showing too few columns). Re-query once the width settles.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if grid.bounds.width != lastGridWidth {
            lastGridWidth = grid.bounds.width
            grid.collectionViewLayout.invalidateLayout()
        }
    }

    // Guarantee a fixed number of columns regardless of inset/overscan quirks.
    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = cv.bounds.width > 0 ? cv.bounds.width : 1920
        let usable = width - gridInset * 2 - gridSpacing * (gridColumns - 1)
        let w = floor(usable / gridColumns)
        return CGSize(width: w, height: w * 16.0 / 9.0)
    }

    private func applyHeader() {
        avatar.setImage(user?.avatar)
        nameLabel.text = user?.nickname ?? "@\(username)"
        statsLabel.text = "\(Format.count(user?.following)) Following    "
            + "\(Format.count(user?.followers)) Followers    "
            + "\(Format.count(user?.likes)) Likes"
        bioLabel.text = user?.signature
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

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { dismiss(animated: true) }
        else { super.pressesBegan(presses, with: event) }
    }
}

final class GridCell: UICollectionViewCell {
    private let cover = AsyncImageView()
    private let plays = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.frame = contentView.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(cover)
        contentView.layer.cornerRadius = 8
        contentView.clipsToBounds = true

        plays.font = .systemFont(ofSize: 16, weight: .semibold)
        plays.textColor = .white
        plays.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(plays)
        NSLayoutConstraint.activate([
            plays.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            plays.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(_ v: FeedItem) {
        cover.setImage(v.cover)
        plays.text = "▶ \(Format.count(v.plays))"
    }

    // Grow when focused, like tvOS posters.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        coordinator.addCoordinatedAnimations({
            self.transform = self.isFocused ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
        })
    }
}
