import MediaPlayer

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
