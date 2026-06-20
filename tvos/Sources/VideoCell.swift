import UIKit
import AVFoundation
import AVKit

/// One full-screen video in the vertical feed: a blurred cover fills the screen,
/// a centered 9:16 "stage" holds the system player (AVPlayerViewController, which
/// owns audio-session + AirPlay routing), and the TikTok-style overlay sits on top.
final class VideoCell: UICollectionViewCell {

    var onEnded: (() -> Void)?            // clip finished → advance the feed
    var providePlayer: ((String) -> AVPlayer?)?   // pre-buffered player from the feed pool

    private let bgImage = AsyncImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let stage = UIView()          // centered 9:16 video frame
    private let playerVC = AVPlayerViewController()
    private let gradient = CAGradientLayer()
    private let safeMargin: CGFloat = 20
    private let railReserve: CGFloat = 220   // keep room on the right for the action rail

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var tcsObs: NSKeyValueObservation?
    private var presSizeObs: NSKeyValueObservation?
    private var stageAspect: NSLayoutConstraint!
    private var currentID: String?
    private var appMuted = false          // user's desired mute state
    private var isActive = false          // true only while this is the on-screen cell
    private var userPaused = false        // true only when the user deliberately paused
    private var retried = false           // allow one stream retry on failure

    // overlay
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

        playerVC.showsPlaybackControls = false          // we draw our own chrome
        playerVC.videoGravity = .resizeAspectFill       // fill the frame (TikTok-style), no black bars
        playerVC.view.isUserInteractionEnabled = false  // never steal the remote / focus
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

        loadingSpinner.color = .white
        loadingSpinner.hidesWhenStopped = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(loadingSpinner)
        NSLayoutConstraint.activate([
            loadingSpinner.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
        ])
    }

    // Resize the frame to the video's real aspect ratio (width:height).
    private func updateStageAspect(_ size: CGSize) {
        guard size.width > 0, size.height > 0, stageAspect != nil else { return }
        let aspect = size.width / size.height
        guard abs(stageAspect.multiplier - aspect) > 0.001 else { return }
        stageAspect.isActive = false
        stageAspect = stage.widthAnchor.constraint(equalTo: stage.heightAnchor, multiplier: aspect)
        stageAspect.isActive = true
        UIView.animate(withDuration: 0.2) { self.contentView.layoutIfNeeded() }
    }

    // Parent the player VC into the hosting controller so it fully manages playback.
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
        stage.addSubview(progressTrack)   // inside the rounded frame so ends are clipped

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
        retried = false
        teardownPlayer()
        openStream(for: item.id)
    }

    private func openStream(for id: String) {
        // Use a pre-buffered player from the feed's pool if one's ready (instant);
        // otherwise create a fresh one.
        let p: AVPlayer
        let playerItem: AVPlayerItem
        if let pooled = providePlayer?(id), let item = pooled.currentItem {
            p = pooled; playerItem = item
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

        // Reset the frame to 9:16 for the new clip, then snap it to the real video
        // shape once known so the video fills the frame with no black bars.
        updateStageAspect(CGSize(width: 9, height: 16))
        presSizeObs = playerItem.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            self?.updateStageAspect(item.presentationSize)
        }

        // Stop the spinner once it's truly rolling; gently resume if it ever drops
        // to paused mid-clip while it should be playing (transient interruptions).
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
                // The clip may still be downloading/transcoding — retry once before
                // skipping, so a transient backend delay doesn't drop the video.
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

    // MARK: playback control

    func play() {
        guard let player else { return }
        isActive = true
        userPaused = false
        Self.activateAudioSessionOnce()
        player.isMuted = appMuted
        fillWidth.constant = 0
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

    override var canBecomeFocused: Bool { false }   // the feed drives navigation

    /// Activate the shared audio session once, before the first play. `.longFormAudio`
    /// routes audio to the user's chosen output incl. AirPlay-2 speakers (e.g. Sonos);
    /// `.playback` is the fallback. Done once to avoid per-cell churn that interrupts
    /// (and pauses) an already-playing clip.
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

    // AVPlayer pauses when the audio session is interrupted; resume when it ends.
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
