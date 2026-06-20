import SwiftUI
import AVFoundation

@main
struct TikTokTVApp: App {
    init() {

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
                LoadingView()
            }
        }
        .task {
            await service.load()
        }
    }
}

struct LoadingView: View {
    private let cyan = Color(red: 0.145, green: 0.957, blue: 0.933)
    private let red = Color(red: 0.996, green: 0.173, blue: 0.333)

    var body: some View {
        VStack(spacing: 28) {
            HStack(spacing: 14) {
                ZStack {
                    Image(systemName: "music.note").foregroundStyle(cyan).offset(x: -3)
                    Image(systemName: "music.note").foregroundStyle(red).offset(x: 3)
                    Image(systemName: "music.note").foregroundStyle(.white)
                }
                .font(.system(size: 70, weight: .bold))
                Text("TikTok")
                    .font(.app(70, .bold))
                    .foregroundStyle(.white)
            }
            ProgressView().tint(.white).scaleEffect(1.5)
            Text("Preparing your feed…")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}
