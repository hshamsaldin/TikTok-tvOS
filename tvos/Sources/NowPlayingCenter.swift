import MediaPlayer

/// Registers the app as the system "Now Playing" media app. tvOS binds the remote's
/// volume buttons (and AirPlay-2 volume) to the active Now Playing app — apps that
/// don't register (like ours did) can play audio but the volume buttons do nothing,
/// while apps that do (YouTube, TV app) get full volume control.
enum NowPlayingCenter {
    private static var configured = false

    static func activate() {
        guard !configured else { return }
        configured = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.playCommand.addTarget { _ in .success }
        c.pauseCommand.addTarget { _ in .success }
        c.togglePlayPauseCommand.addTarget { _ in .success }
    }

    static func update(title: String?, artist: String?) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: (title?.isEmpty == false ? title! : "TikTok"),
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        if let artist, !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
