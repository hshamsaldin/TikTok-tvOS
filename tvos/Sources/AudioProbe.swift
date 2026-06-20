import AVFoundation

/// TEMP DIAGNOSTIC: plays a continuous 440 Hz tone through AVAudioEngine — totally
/// independent of AVPlayer/AVPlayerViewController. It answers the one remaining
/// question: can this app output ANY audio at all?
///   • If you hear a steady beep → the app's audio OUTPUT works, so the silence is
///     specific to AVPlayer and I look there.
///   • If even this tone is silent → the app's whole audio path (session/route to
///     the speakers) is broken, and I look at the route, not the player.
/// Remove once the real cause is found.
final class AudioProbe {
    static let shared = AudioProbe()
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private(set) var running = false

    func start() {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try? session.setActive(true)

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(sampleRate)            // 1 second, looped
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            guard let data = buffer.floatChannelData?[channel] else { continue }
            for i in 0..<Int(frames) {
                data[i] = 0.2 * sinf(2.0 * Float.pi * 440.0 * Float(i) / Float(sampleRate))
            }
        }

        do {
            try engine.start()
            node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            node.play()
            running = true
        } catch {
            print("AudioProbe failed to start: \(error)")
        }
    }
}
