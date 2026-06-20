import SwiftUI
import AVFoundation

@main
struct TikTokTVApp: App {
    init() {
        // Just set the category here. Activation happens once at the first play
        // (VideoCell.activateAudioSessionOnce) — setActive this early in launch
        // often fails silently, leaving an inactive session = video with no audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
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
            // Audio session is configured once in App.init; AVPlayer manages
            // activation itself. Don't re-poke it here — re-activating mid-playback
            // interrupts the active player and pauses it (the silence bug).
            await service.load()
        }
    }
}
