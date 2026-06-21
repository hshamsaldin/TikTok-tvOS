import UIKit
import AVFoundation
import AVKit

final class VideoCell: UICollectionViewCell {

    var onEnded: (() -> Void)?
    var providePlayer: ((String) -> AVPlayer?)?

    private let bgImage = AsyncImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let stage = UIView()
    private let stageShadow = UIView()   // casts the elevation shadow behind `stage`
    private let playerVC = AVPlayerViewController()
    private let gradient = CAGradientLayer()
    private let sheen = CAGradientLayer()   // soft top highlight
    private let safeMargin: CGFloat = 20
    private let railReserve: CGFloat = 220

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var tcsObs: NSKeyValueObservation?
    private var presSizeObs: NSKeyValueObservation?
    private var stageAspect: NSLayoutConstraint!
    private var currentID: String?
    private var appMuted = false
    private var isActive = false
    private var userPaused = false
    private var retried = false

    private let authorLabel = UILabel()
    private let captionLabel = UILabel()
    private let soundRow = UIStackView()
    private let soundLabel = UILabel()
    private let rail = UIStackView()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private var fillWidth: NSLayoutConstraint!
    private let muteIcon = UIImageView()
    private let loadingSpinner = UIActivityIndicatorView(style: .large)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        setupBackground()
        setupVideo()
        setupOverlay()
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    deinit { NotificationCenter.default.removeObserver(self) }

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
        // A separate, non-clipping sibling behind `stage` casts the elevation
        // shadow — `stage` itself has masksToBounds=true (needed for the video's
        // rounded corners), which would also clip away any shadow drawn on it.
        // This is the same "elevate to the foreground" language tvOS's HIG
        // describes for focused content (Images: "the system elevates it to the
        // foreground... applying illumination that makes the surface shine") —
        // our video isn't focusable, so we apply that same visual language
        // directly instead of relying on the system focus/parallax effect.
        stageShadow.backgroundColor = .clear
        stageShadow.layer.shadowColor = UIColor.black.cgColor
        stageShadow.layer.shadowOffset = CGSize(width: 0, height: 18)
        stageShadow.layer.shadowRadius = 32
        stageShadow.layer.shadowOpacity = 0.6
        contentView.addSubview(stageShadow)

        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.layer.cornerRadius = 18
        stage.layer.masksToBounds = true
        contentView.addSubview(stage)
        stageAspect = stage.widthAnchor.constraint(equalTo: stage.heightAnchor, multiplier: 9.0 / 16.0)
        let grow = stage.heightAnchor.constraint(equalTo: contentView.heightAnchor, constant: -2 * safeMargin)
        grow.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stage.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stage.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stage.heightAnchor.constraint(lessThanOrEqualTo: contentView.heightAnchor, constant: -2 * safeMargin),
            stage.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -(2 * safeMargin + railReserve)),
            grow, stageAspect,
        ])

        playerVC.showsPlaybackControls = false
        playerVC.videoGravity = .resizeAspectFill
        playerVC.view.isUserInteractionEnabled = false
        playerVC.view.backgroundColor = .clear
        playerVC.view.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(playerVC.view)
        NSLayoutConstraint.activate([
            playerVC.view.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            playerVC.view.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            playerVC.view.topAnchor.constraint(equalTo: stage.topAnchor),
            playerVC.view.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])

        gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.65).cgColor]
        stage.layer.addSublayer(gradient)

        // Subtle top "sheen" — a soft highlight along the top edge, echoing the
        // illumination tvOS applies to focused/elevated content.
        sheen.colors = [UIColor.white.withAlphaComponent(0.10).cgColor, UIColor.clear.cgColor]
        stage.layer.addSublayer(sheen)

        loadingSpinner.color = .white
        loadingSpinner.hidesWhenStopped = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(loadingSpinner)
        NSLayoutConstraint.activate([
            loadingSpinner.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
        ])
    }

    private func updateStageAspect(_ size: CGSize) {
        guard size.width > 0, size.height > 0, stageAspect != nil else { return }
        let aspect = size.width / size.height
        guard abs(stageAspect.multiplier - aspect) > 0.001 else { return }
        stageAspect.isActive = false
        stageAspect = stage.widthAnchor.constraint(equalTo: stage.heightAnchor, multiplier: aspect)
        stageAspect.isActive = true
        UIView.animate(withDuration: 0.2) { self.contentView.layoutIfNeeded() }
    }

    private var parentViewController: UIViewController? {
        var r: UIResponder? = next
        while let cur = r {
            if let vc = cur as? UIViewController { return vc }
            r = cur.next
        }
        return nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, playerVC.parent == nil, let host = parentViewController {
            host.addChild(playerVC)
            playerVC.didMove(toParent: host)
        }
    }

    private func setupOverlay() {
        authorLabel.font = .app(ofSize: 30, weight: .bold)
        authorLabel.textColor = .white
        captionLabel.font = .app(ofSize: 24)
        captionLabel.textColor = .white
        captionLabel.numberOfLines = 2

        let noteIcon = UIImageView(image: UIImage(systemName: "music.note"))
        noteIcon.tintColor = .white
        noteIcon.setContentHuggingPriority(.required, for: .horizontal)
        soundLabel.font = .app(ofSize: 22)
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

        rail.axis = .vertical
        rail.spacing = 22
        rail.alignment = .center
        rail.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rail)

        progressTrack.backgroundColor = UIColor(white: 1, alpha: 0.22)
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = .white
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        stage.addSubview(progressTrack)

        muteIcon.image = UIImage(systemName: "speaker.slash.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold))
        muteIcon.tintColor = .white
        muteIcon.isHidden = true
        muteIcon.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(muteIcon)

        fillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            muteIcon.topAnchor.constraint(equalTo: stage.topAnchor, constant: 16),
            muteIcon.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 16),

            progressTrack.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            progressTrack.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 5),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            fillWidth,

            meta.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 20),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: stage.trailingAnchor, constant: -20),
            meta.bottomAnchor.constraint(equalTo: progressTrack.topAnchor, constant: -16),

            rail.leadingAnchor.constraint(equalTo: stage.trailingAnchor, constant: 24),
            rail.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -10),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let g: CGFloat = 360
        gradient.frame = CGRect(x: 0, y: max(0, stage.bounds.height - g),
                                width: stage.bounds.width, height: g)
        sheen.frame = CGRect(x: 0, y: 0, width: stage.bounds.width, height: min(140, stage.bounds.height * 0.18))

        // Keep the shadow-casting view tracking `stage`'s exact frame/shape — it's
        // a separate sibling (see setupVideo) so it isn't clipped by stage's own
        // masksToBounds.
        stageShadow.frame = stage.frame
        stageShadow.layer.shadowPath = UIBezierPath(roundedRect: stageShadow.bounds, cornerRadius: 18).cgPath
    }

    func configure(with item: FeedItem) {
        bgImage.setImage(item.cover)
        authorLabel.text = item.displayName
        captionLabel.text = item.caption
        soundLabel.text = item.sound
        soundRow.isHidden = (item.sound?.isEmpty != false)
        buildRail(item)

        guard item.id != currentID else { return }
        currentID = item.id
        retried = false
        teardownPlayer()
        openStream(for: item.id)
    }

    private func openStream(for id: String) {
        let p: AVPlayer
        let playerItem: AVPlayerItem
        if let pooled = providePlayer?(id), let item = pooled.currentItem {
            p = pooled; playerItem = item
            playerItem.preferredForwardBufferDuration = 0   // lift the pool's idle buffer cap — this is the active video now
        } else {
            let url = Config.backendBaseURL.appendingPathComponent("api/hls/\(id)/index.m3u8")
            playerItem = AVPlayerItem(url: url)
            p = AVPlayer(playerItem: playerItem)
        }
        p.actionAtItemEnd = .pause
        p.isMuted = appMuted
        p.volume = 1.0
        p.allowsExternalPlayback = true
        player = p
        playerVC.player = p
        loadingSpinner.startAnimating()
        applyAudioGain(to: playerItem, id: id)

        updateStageAspect(CGSize(width: 9, height: 16))
        presSizeObs = playerItem.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            self?.updateStageAspect(item.presentationSize)
        }

        tcsObs = p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            if player.timeControlStatus == .playing { self.loadingSpinner.stopAnimating() }
            guard self.isActive, !self.userPaused,
                  player.timeControlStatus == .paused,
                  player.currentItem?.status == .readyToPlay else { return }
            let cur = CMTimeGetSeconds(player.currentTime())
            let dur = CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
            if !(dur.isFinite && dur > 0 && cur >= dur - 0.3) { player.play() }
        }

        statusObs = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                if self.isActive, !self.userPaused { self.player?.play() }
            case .failed:
                if let id = self.currentID, !self.retried {
                    self.retried = true
                    self.teardownPlayer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self, self.currentID == id else { return }
                        self.openStream(for: id)
                        if self.isActive { self.play() }
                    }
                } else if self.isActive {
                    self.onEnded?()
                }
            default:
                break
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
        ) { [weak self] _ in self?.onEnded?() }

        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.3, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            guard let self, let it = self.player?.currentItem else { return }
            let dur = CMTimeGetSeconds(it.duration)
            let cur = CMTimeGetSeconds(it.currentTime())
            guard dur.isFinite, dur > 0 else { return }
            self.fillWidth.constant = CGFloat(cur / dur) * self.progressTrack.bounds.width
        }
    }

    private func buildRail(_ item: FeedItem) {
        rail.arrangedSubviews.forEach { $0.removeFromSuperview() }

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
        plus.font = .app(ofSize: 20, weight: .bold)
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
        label.font = .app(ofSize: 20, weight: .semibold)
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

    /// Levels out TikTok's wildly inconsistent per-clip loudness using AVFoundation's
    /// native AVAudioMix — a per-asset volume correction applied on-device, computed
    /// once server-side by analysis only (no server re-encode, so streaming stays fast).
    private func applyAudioGain(to item: AVPlayerItem, id: String) {
        Task { [weak self] in
            let gainDb = await API.audioGain(id)
            guard let self, self.currentID == id, gainDb != 0 else { return }
            let asset = item.asset
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            // Apple's docs: setVolume's value "must be between 0.0 and 1.0" — there
            // is no API to boost above the track's native level this way. Clamp
            // defensively even though the backend should already only send <= 0 dB.
            let multiplier = min(1.0, Float(pow(10, gainDb / 20)))
            params.setVolume(multiplier, at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
    }

    func play() {
        guard let player else { return }
        isActive = true
        userPaused = false
        Self.activateAudioSessionOnce()
        player.isMuted = appMuted
        fillWidth.constant = 0
        // This only reset the BAR's visual width, never the player's actual
        // position — a revisited cell (currentID already matches, so configure()
        // skips reopening the stream) or a handed-off pooled player could already
        // be partway through, so it resumed from wherever it was instead of the
        // start, and the bar visibly snapped 0 -> real position on the next tick.
        // Every time a clip becomes the active video it must restart from 0.
        player.seek(to: .zero)
        player.play()
        NowPlayingCenter.activate()
        NowPlayingCenter.update(title: authorLabel.text, artist: captionLabel.text)
    }

    func pause() { isActive = false; player?.pause() }

    func resume() { isActive = true; userPaused = false; player?.play() }

    func setMuted(_ m: Bool) {
        appMuted = m
        player?.isMuted = m
        muteIcon.isHidden = !m
    }

    var isPlaying: Bool { (player?.rate ?? 0) > 0 }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying { userPaused = true; player.pause() }
        else { userPaused = false; player.play() }
    }

    override var canBecomeFocused: Bool { false }

    private static var audioSessionActivated = false
    private static func activateAudioSessionOnce() {
        guard !audioSessionActivated else { return }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
            try s.setActive(true)
        } catch {
            try? s.setCategory(.playback)
            try? s.setActive(true)
        }
        audioSessionActivated = true
    }

    @objc private func audioInterrupted(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        if isActive, !userPaused { player?.play() }
    }

    private func teardownPlayer() {
        isActive = false
        player?.pause()
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        statusObs?.invalidate(); statusObs = nil
        tcsObs?.invalidate(); tcsObs = nil
        presSizeObs?.invalidate(); presSizeObs = nil
        playerVC.player = nil
        player = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        teardownPlayer()
        currentID = nil
        fillWidth.constant = 0
        bgImage.image = nil
        muteIcon.isHidden = true
        loadingSpinner.stopAnimating()
    }
}
