import SwiftUI
import AVFoundation

@main
struct TikTokTVApp: App {
    init() {
        // Use the .longFormVideo route-sharing policy so audio routes to the AirPlay-2
        // output the user selected (e.g. a Sonos), not the local HDMI route. Activation
        // happens once at the first play (VideoCell.activateAudioSessionOnce).
        try? AVAudioSession.sharedInstance()
            .setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var service = FeedService()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !service.items.isEmpty {
                VerticalFeedView(items: service.items,
                                 loadMore: { await service.loadMore() })
                    .ignoresSafeArea()
            } else if let err = service.errorText {
                VStack(spacing: 16) {
                    Text("Couldn't load feed").font(.title2).bold()
                    Text(err).font(.callout).foregroundStyle(.secondary)
                    Text("Check Config.backendBaseURL and that the backend is running.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(80)
            } else {
                ProgressView().tint(.white).scaleEffect(2)
            }
        }
        .task {
            await service.load()
        }
    }
}
