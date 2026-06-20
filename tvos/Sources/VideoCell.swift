import UIKit
import AVFoundation

final class VideoCell: UICollectionViewCell {

    // Called when the clip finishes (drives autoscroll).
    var onEnded: (() -> Void)?

    private let bgImage = AsyncImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let stage = UIView()          // centered 9:16 video frame
    private let playerLayer = AVPlayerLayer()
    private let gradient = CAGradientLayer()
    private let safeMargin: CGFloat = 20  // minimal top/bottom inset (video as tall as safely possible)

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var tcsObs: NSKeyValueObservation?
    private var currentID: String?
    private var appMuted = false          // user's desired mute state
    private var isActive = false          // true only while this is the on-screen cell
    private var userPaused = false        // true only when the user deliberately paused

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

    // Temporary on-screen audio diagnostic (remove once sound is confirmed).
    static let showAudioDebug = true
    static var livePlayers = 0          // tvOS silently drops audio with too many alive
    private let debugLabel = UILabel()
    private var sessionErr = "—"
    private var retried = false

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
        // Centered 9:16 "phone frame", full screen height. The blurred bg fills
        // the rest of the screen behind it; overlays anchor to this frame.
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.layer.cornerRadius = 18
        stage.layer.masksToBounds = true
        contentView.addSubview(stage)
        NSLayoutConstraint.activate([
            // inset top/bottom by the overscan margin so the frame + rounded
            // corners are fully visible and never clipped by the TV bezel.
            stage.topAnchor.constraint(equalTo: contentView.topAnchor, constant: safeMargin),
            stage.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -safeMargin),
            stage.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stage.widthAnchor.constraint(equalTo: stage.heightAnchor, multiplier: 9.0 / 16.0),
        ])

        playerLayer.videoGravity = .resizeAspect
        stage.layer.addSublayer(playerLayer)

        gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.65).cgColor]
        stage.layer.addSublayer(gradient)
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

        debugLabel.numberOfLines = 0
        debugLabel.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        debugLabel.textColor = .systemYellow
        debugLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        debugLabel.isHidden = true
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(debugLabel)

        fillWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            muteIcon.topAnchor.constraint(equalTo: stage.topAnchor, constant: 16),
            muteIcon.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 16),
            debugLabel.topAnchor.constraint(equalTo: stage.topAnchor, constant: 16),
            debugLabel.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -16),

            // thin progress bar along the very bottom edge of the video
            progressTrack.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            progressTrack.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 5),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            fillWidth,

            // caption/sound at the video's bottom-left
            meta.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 20),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: stage.trailingAnchor, constant: -20),
            meta.bottomAnchor.constraint(equalTo: progressTrack.topAnchor, constant: -16),

            // rail just outside the video's right edge
            rail.leadingAnchor.constraint(equalTo: stage.trailingAnchor, constant: 24),
            rail.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -10),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = stage.bounds
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
        let url = Config.backendBaseURL.appendingPathComponent("api/stream/\(id)")
        let playerItem = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: playerItem)
        p.actionAtItemEnd = .pause
        p.isMuted = false
        p.volume = 1.0
        p.automaticallyWaitsToMinimizeStalling = false   // start now, don't sit paused buffering
        player = p
        Self.livePlayers += 1
        playerLayer.player = p

        // Self-heal: if the player drops to paused while it should be running (the
        // real bug behind the silence — tcs:0 = paused, so no audio), nudge it back
        // to playing. Also refreshes the on-screen diagnostic on every transition.
        tcsObs = p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            self.updateDebug()
            guard self.isActive, !self.userPaused,
                  player.timeControlStatus == .paused,
                  player.currentItem?.status == .readyToPlay else { return }
            let cur = CMTimeGetSeconds(player.currentTime())
            let dur = CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
            if !(dur.isFinite && dur > 0 && cur >= dur - 0.3) { player.play() } // not at the end
        }

        // React to the item becoming playable (or failing).
        statusObs = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            switch item.status {
            case .readyToPlay:
                self.activateAudioSession()
                if self.isActive, !self.userPaused { self.player?.play() }  // make sure it runs
                self.kickAudio()                       // ensure unmuted, audio attached
                self.updateDebug()
            case .failed:
                self.sessionErr = String("\(item.error.map { "\($0)" } ?? "fail")".prefix(40))
                self.updateDebug()
                // The first clip can still be downloading/transcoding — retry once
                // (instead of instantly skipping, which caused the "first video
                // blurred then jumps" behavior) before giving up.
                if let id = self.currentID, !self.retried {
                    self.retried = true
                    self.teardownPlayer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self, self.currentID == id else { return }
                        self.openStream(for: id)
                        if self.isActive { self.play() }
                    }
                } else if self.isActive {
                    self.onEnded?()                    // give up: skip a dead clip
                }
            default:
                break
            }
        }

        // Autoscroll: advance when *this* item finishes (scoped to avoid cross-cell fires).
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
        ) { [weak self] _ in self?.onEnded?() }

        // Progress bar updates.
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.3, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            guard let self, let it = self.player?.currentItem else { return }
            let dur = CMTimeGetSeconds(it.duration)
            let cur = CMTimeGetSeconds(it.currentTime())
            guard dur.isFinite, dur > 0 else { return }
            self.fillWidth.constant = CGFloat(cur / dur) * self.progressTrack.bounds.width
            self.updateDebug()
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
        isActive = true
        userPaused = false
        activateAudioSession()
        player.isMuted = appMuted
        player.seek(to: .zero)
        fillWidth.constant = 0
        player.play()
        // If the item is already ready (reused/prewarmed), kick audio now too.
        if player.currentItem?.status == .readyToPlay { kickAudio() }
    }

    func pause() { isActive = false; player?.pause() }

    func resume() { isActive = true; userPaused = false; player?.play() }

    func setMuted(_ m: Bool) {
        appMuted = m
        player?.isMuted = m
        muteIcon.isHidden = !m
    }

    /// tvOS needs an active `.playback`/`.moviePlayback` session for AVPlayer audio.
    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            sessionErr = "ok"
        } catch {
            sessionErr = String("\(error)".prefix(40))
        }
    }

    /// Force the player to re-attach to the (now active) audio route. Mirrors the
    /// manual fix (mute→unmute starts silent clips). The real human delay matters,
    /// so we unmute ~0.4s later, not on the same runloop. Also force-enable the
    /// audio track in case AVPlayer left it disabled.
    private func kickAudio() {
        guard let player else { return }
        enableAudioTracks()
        player.isMuted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let player = self.player else { return }
            self.enableAudioTracks()
            player.isMuted = self.appMuted
            player.volume = 1.0
            self.updateDebug()
        }
    }

    private func enableAudioTracks() {
        player?.currentItem?.tracks.forEach {
            if $0.assetTrack?.mediaType == .audio { $0.isEnabled = true }
        }
    }

    private func updateDebug() {
        guard Self.showAudioDebug else { return }
        let session = AVAudioSession.sharedInstance()
        let audio = player?.currentItem?.tracks.filter { $0.assetTrack?.mediaType == .audio } ?? []
        let on = audio.filter { $0.isEnabled }.count
        let cat = session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        let st = player?.currentItem?.status.rawValue ?? -9
        let tcs = player?.timeControlStatus.rawValue ?? -9   // 0=paused 1=waiting 2=playing
        let route = session.currentRoute.outputs.map {
            $0.portType.rawValue.replacingOccurrences(of: "AVAudioSessionPort", with: "")
        }.joined(separator: ",")
        debugLabel.text = "audioTrk:\(audio.count) on:\(on)  players:\(Self.livePlayers)\n"
            + "muted:\(player?.isMuted ?? false) vol:\(player?.volume ?? 0)\n"
            + "cat:\(cat) sess:\(sessionErr) other:\(session.isOtherAudioPlaying)\n"
            + "status:\(st) tcs:\(tcs)\n"
            + "route:\(route.isEmpty ? "none" : route)"
        debugLabel.isHidden = false
    }

    var isPlaying: Bool { (player?.rate ?? 0) > 0 }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying { userPaused = true; player.pause() }
        else { userPaused = false; player.play() }
    }

    // We drive navigation with swipe gestures, so cells shouldn't grab focus.
    override var canBecomeFocused: Bool { false }

    private func teardownPlayer() {
        isActive = false
        player?.pause()
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        statusObs?.invalidate(); statusObs = nil
        tcsObs?.invalidate(); tcsObs = nil
        playerLayer.player = nil
        if player != nil { Self.livePlayers = max(0, Self.livePlayers - 1) }
        player = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        teardownPlayer()
        currentID = nil
        fillWidth.constant = 0
        bgImage.image = nil
        muteIcon.isHidden = true
        debugLabel.isHidden = true
    }
}
