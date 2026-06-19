import UIKit
import AVFoundation

final class VideoCell: UICollectionViewCell {

    // Called when the clip finishes (drives autoscroll).
    var onEnded: (() -> Void)?

    private let bgImage = AsyncImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let videoContainer = UIView()
    private let playerLayer = AVPlayerLayer()
    private let gradient = CAGradientLayer()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var currentID: String?

    // overlay
    private let authorLabel = UILabel()
    private let captionLabel = UILabel()
    private let soundRow = UIStackView()
    private let soundLabel = UILabel()
    private let rail = UIStackView()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let muteIcon = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        setupBackground()
        setupVideo()
        setupOverlay()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: setup

    private func setupBackground() {
        bgImage.contentMode = .scaleAspectFill
        bgImage.clipsToBounds = true
        bgImage.frame = contentView.bounds
        bgImage.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(bgImage)

        blur.frame = contentView.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(blur)
    }

    private func setupVideo() {
        videoContainer.frame = contentView.bounds
        videoContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(videoContainer)
        playerLayer.videoGravity = .resizeAspect
        videoContainer.layer.addSublayer(playerLayer)

        gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.65).cgColor]
        videoContainer.layer.addSublayer(gradient)
    }

    private func setupOverlay() {
        // bottom-left: author + caption + sound
        authorLabel.font = .systemFont(ofSize: 30, weight: .bold)
        authorLabel.textColor = .white
        captionLabel.font = .systemFont(ofSize: 24)
        captionLabel.textColor = .white
        captionLabel.numberOfLines = 2

        let noteIcon = UIImageView(image: UIImage(systemName: "music.note"))
        noteIcon.tintColor = .white
        noteIcon.setContentHuggingPriority(.required, for: .horizontal)
        soundLabel.font = .systemFont(ofSize: 22)
        soundLabel.textColor = .white
        soundRow.axis = .horizontal
        soundRow.spacing = 8
        soundRow.alignment = .center
        soundRow.addArrangedSubview(noteIcon)
        soundRow.addArrangedSubview(soundLabel)

        let meta = UIStackView(arrangedSubviews: [authorLabel, captionLabel, soundRow])
        meta.axis = .vertical
        meta.spacing = 10
        meta.alignment = .leading
        meta.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(meta)

        // bottom-right: action rail
        rail.axis = .vertical
        rail.spacing = 22
        rail.alignment = .center
        rail.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rail)

        progress.progressTintColor = .white
        progress.trackTintColor = UIColor(white: 1, alpha: 0.25)
        progress.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progress)

        muteIcon.image = UIImage(systemName: "speaker.slash.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold))
        muteIcon.tintColor = .white
        muteIcon.isHidden = true
        muteIcon.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(muteIcon)

        NSLayoutConstraint.activate([
            muteIcon.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 30),
            muteIcon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 70),
            meta.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 70),
            meta.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -70),
            meta.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.55),

            rail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -70),
            rail.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -90),

            progress.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = videoContainer.bounds
        gradient.frame = CGRect(x: 0, y: contentView.bounds.height - 420,
                                width: contentView.bounds.width, height: 420)
    }

    // MARK: configure

    func configure(with item: FeedItem) {
        bgImage.setImage(item.cover)
        authorLabel.text = item.displayName
        captionLabel.text = item.caption
        soundLabel.text = item.sound
        soundRow.isHidden = (item.sound?.isEmpty != false)
        buildRail(item)

        guard item.id != currentID else { return }
        currentID = item.id
        teardownPlayer()

        let url = Config.backendBaseURL.appendingPathComponent("api/stream/\(item.id)")
        let playerItem = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: playerItem)
        p.actionAtItemEnd = .pause
        player = p
        playerLayer.player = p

        // Autoscroll: advance when *this* item finishes (scoped to avoid cross-cell fires).
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
        ) { [weak self] _ in self?.onEnded?() }

        // Progress bar updates.
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.3, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            guard let it = self?.player?.currentItem, it.duration.isNumeric else { return }
            let dur = CMTimeGetSeconds(it.duration)
            let cur = CMTimeGetSeconds(it.currentTime())
            if dur > 0 { self?.progress.progress = Float(cur / dur) }
        }
    }

    private func buildRail(_ item: FeedItem) {
        rail.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // avatar with follow badge
        let avatar = AsyncImageView()
        avatar.setImage(item.avatar)
        avatar.backgroundColor = UIColor(white: 0.2, alpha: 1)
        avatar.layer.cornerRadius = 32
        avatar.clipsToBounds = true
        avatar.contentMode = .scaleAspectFill
        let avWrap = UIView()
        avWrap.translatesAutoresizingMaskIntoConstraints = false
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avWrap.addSubview(avatar)
        let plus = UILabel()
        plus.text = "+"
        plus.textColor = .white
        plus.font = .systemFont(ofSize: 20, weight: .bold)
        plus.textAlignment = .center
        plus.backgroundColor = UIColor(red: 0.996, green: 0.173, blue: 0.333, alpha: 1)
        plus.layer.cornerRadius = 13
        plus.clipsToBounds = true
        plus.translatesAutoresizingMaskIntoConstraints = false
        avWrap.addSubview(plus)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 64),
            avatar.heightAnchor.constraint(equalToConstant: 64),
            avatar.topAnchor.constraint(equalTo: avWrap.topAnchor),
            avatar.centerXAnchor.constraint(equalTo: avWrap.centerXAnchor),
            avWrap.widthAnchor.constraint(equalToConstant: 64),
            avWrap.bottomAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 6),
            plus.widthAnchor.constraint(equalToConstant: 26),
            plus.heightAnchor.constraint(equalToConstant: 26),
            plus.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            plus.centerYAnchor.constraint(equalTo: avatar.bottomAnchor),
        ])
        rail.addArrangedSubview(avWrap)

        rail.addArrangedSubview(action("heart.fill", item.likes))
        rail.addArrangedSubview(action("message.fill", item.comments))
        rail.addArrangedSubview(action("bookmark.fill", item.saves))
        rail.addArrangedSubview(action("arrowshape.turn.up.right.fill", item.shares))

        if let cover = item.soundCover, !cover.isEmpty {
            let disc = AsyncImageView()
            disc.setImage(cover)
            disc.layer.cornerRadius = 24
            disc.clipsToBounds = true
            disc.contentMode = .scaleAspectFill
            disc.layer.borderWidth = 6
            disc.layer.borderColor = UIColor(white: 0.1, alpha: 1).cgColor
            disc.translatesAutoresizingMaskIntoConstraints = false
            disc.widthAnchor.constraint(equalToConstant: 48).isActive = true
            disc.heightAnchor.constraint(equalToConstant: 48).isActive = true
            rail.addArrangedSubview(disc)
        }
    }

    private func action(_ symbol: String, _ count: Int?) -> UIView {
        let chip = UIView()
        chip.backgroundColor = UIColor(white: 0.16, alpha: 0.85)
        chip.layer.cornerRadius = 32
        chip.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(icon)
        let label = UILabel()
        label.text = Format.count(count)
        label.textColor = .white
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        let stack = UIStackView(arrangedSubviews: [chip, label])
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .center
        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: 64),
            chip.heightAnchor.constraint(equalToConstant: 64),
            icon.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])
        return stack
    }

    // MARK: playback control

    func play() {
        guard let player else { return }
        player.seek(to: .zero)
        progress.progress = 0
        player.play()
    }

    func pause() { player?.pause() }

    func resume() { player?.play() }

    func setMuted(_ m: Bool) {
        player?.isMuted = m
        muteIcon.isHidden = !m
    }

    var isPlaying: Bool { (player?.rate ?? 0) > 0 }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
    }

    // We drive navigation with swipe gestures, so cells shouldn't grab focus.
    override var canBecomeFocused: Bool { false }

    private func teardownPlayer() {
        player?.pause()
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        playerLayer.player = nil
        player = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        teardownPlayer()
        currentID = nil
        progress.progress = 0
        bgImage.image = nil
        muteIcon.isHidden = true
    }
}
