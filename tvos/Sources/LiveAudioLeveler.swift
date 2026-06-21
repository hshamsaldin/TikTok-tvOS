import AVFoundation
import MediaToolbox
import CoreAudio

/// Real-time loudness leveling for a video's audio track — no pre-measurement
/// pass, no backend round-trip. Apple's documented mechanism for this is
/// MTAudioProcessingTap (confirmed tvOS 9.0+): it hands you the actual PCM
/// samples as they play, in a tap callback, and you can modify them in place
/// before AVPlayer sends them to the system's normal audio output (HDMI/
/// AirPlay/whatever — this runs upstream of that, so output routing is
/// untouched). Hosting Apple's system Dynamics Processor Audio Unit through
/// this tap would need a second engine and output rerouting; a small limiter
/// written directly in the callback is simpler and avoids that entirely.
final class LiveAudioLeveler {
    /// Builds an AVMutableAudioMix with a live-leveling tap attached to the
    /// asset's audio track. Returns nil if there's no audio track or the tap
    /// fails to create (the clip just plays unleveled in that case).
    static func makeAudioMix(for item: AVPlayerItem, track: AVAssetTrack) -> AVMutableAudioMix? {
        let params = AVMutableAudioMixInputParameters(track: track)
        let leveler = LiveAudioLeveler()
        guard let tap = leveler.makeTap() else { return nil }
        params.audioTapProcessor = tap
        retainedLevelers.append(leveler)   // keep alive for the tap's lifetime
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    // Levelers are referenced only by the tap's clientInfo (an unretained C
    // pointer) — without this, ARC would deallocate them immediately. They
    // are removed again in the tap's `finalize` callback below, once the
    // tap itself is torn down (e.g. the AVPlayerItem is released when a clip
    // scrolls out of the watched-back cache and is evicted) — without that,
    // every clip ever played would leak one LiveAudioLeveler for the app's
    // entire lifetime.
    private static var retainedLevelers: [LiveAudioLeveler] = []
    private static func release(_ leveler: LiveAudioLeveler) {
        retainedLevelers.removeAll { $0 === leveler }
    }

    // MARK: - Limiter state (read/written only on the tap's processing thread)

    private var smoothedGain: Float = 1.0
    private var attackCoeff: Float = 0.4     // reacts fast when getting louder
    private var releaseCoeff: Float = 0.02   // recovers slowly when it quiets down
    private let targetPeak: Float = 0.7      // ~-3 dBFS — leaves headroom, no clipping

    // Confirmed (in `prepare`, below) by inspecting the tap's actual negotiated
    // AudioStreamBasicDescription, NOT assumed. Apple's docs for `prepare` say
    // the processingFormat AVFoundation hands back "usually" matches the
    // client format but can legitimately differ (e.g. channel-count fallback
    // for some decoders) — "If the data is not in a convenient format... the
    // client should convert." `process` below previously skipped this check
    // entirely and reinterpreted whatever raw bytes it got as packed Float32,
    // which corrupts (or silences) audio on any clip where that assumption is
    // wrong — the likely cause of leveling working on some clips and not
    // others. Defaults to false: an unconfirmed/non-float format plays
    // through untouched (unleveled) rather than getting its bytes mangled.
    private var isFloat32: Bool = false

    private func makeTap() -> MTAudioProcessingTap? {
        // Apple's docs explicitly warn: "On 64-bit architectures, this struct
        // contains misaligned function pointers. To avoid link-time issues,
        // fill its function pointer fields by using assignment statements,
        // rather than declaring them as global or static structs." So each
        // field is assigned individually below, not packed into one literal.
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: nil, init: nil, finalize: nil, prepare: nil, unprepare: nil,
            process: { _, _, _, _, _, _ in }
        )
        callbacks.clientInfo = Unmanaged.passUnretained(self).toOpaque()
        callbacks.`init` = { _, clientInfo, tapStorageOut in
            tapStorageOut.pointee = clientInfo
        }
        // Mirror image of `init`: drop our static keep-alive reference once the
        // tap is torn down, so the leveler can finally be deallocated.
        callbacks.finalize = { tap in
            let storage = MTAudioProcessingTapGetStorage(tap)
            let leveler = Unmanaged<LiveAudioLeveler>.fromOpaque(storage).takeUnretainedValue()
            LiveAudioLeveler.release(leveler)
        }
        // Apple's docs: "the preparation callback can potentially be called
        // multiple times over the lifetime of the tap" — so this re-checks
        // the format each time rather than caching a one-shot assumption.
        callbacks.prepare = { tap, _, formatPointer in
            let storage = MTAudioProcessingTapGetStorage(tap)
            let leveler = Unmanaged<LiveAudioLeveler>.fromOpaque(storage).takeUnretainedValue()
            let asbd = formatPointer.pointee
            leveler.isFloat32 =
                asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
                asbd.mFormatFlags & kAudioFormatFlagIsPacked != 0 &&
                asbd.mBitsPerChannel == 32
        }
        callbacks.process = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
            let status = MTAudioProcessingTapGetSourceAudio(
                tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
            guard status == noErr else { return }
            let storage = MTAudioProcessingTapGetStorage(tap)
            let leveler = Unmanaged<LiveAudioLeveler>.fromOpaque(storage).takeUnretainedValue()
            guard leveler.isFloat32 else { return }   // unconfirmed format: pass through untouched
            leveler.process(bufferListInOut)
        }

        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else { return nil }
        return tap.takeRetainedValue()
    }

    /// Runs once per audio buffer, on the audio render thread. Tracks a fast-
    /// attack/slow-release envelope of the loudest sample across all channels
    /// and applies a single smoothed gain to every sample — a standard peak
    /// limiter / automatic level control, reacting continuously instead of
    /// requiring any prior measurement of the clip.
    private func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in buffers {
            guard let raw = buffer.mData else { continue }
            let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0 else { continue }
            let samples = raw.assumingMemoryBound(to: Float.self)

            var peak: Float = 0
            for i in 0..<frameCount { peak = max(peak, abs(samples[i])) }

            let desiredGain: Float = peak > targetPeak ? targetPeak / peak : 1.0
            let coeff = desiredGain < smoothedGain ? attackCoeff : releaseCoeff
            smoothedGain += (desiredGain - smoothedGain) * coeff

            if smoothedGain < 0.999 {
                for i in 0..<frameCount { samples[i] *= smoothedGain }
            }
        }
    }
}
