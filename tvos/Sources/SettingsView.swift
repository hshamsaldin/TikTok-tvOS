import SwiftUI

/// Lets the user point the app at a backend server without recompiling —
/// shown on first launch (no server configured yet) and reachable again from
/// the feed's error screen if the configured one stops responding.
struct SettingsView: View {
    @State private var address: String
    @FocusState private var fieldFocused: Bool
    var onSave: (String) -> Void

    init(onSave: @escaping (String) -> Void) {
        _address = State(initialValue: Self.displayValue(Config.backendBaseURLString))
        self.onSave = onSave
    }

    private static func displayValue(_ s: String) -> String {
        s.replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    var body: some View {
        VStack(spacing: 28) {
            Image("LogoMark")
                .resizable()
                .scaledToFit()
                .frame(width: 90, height: 90)
            Text("Connect to Server")
                .font(.title2).bold()
            Text("Enter the backend server's address and port, e.g. 192.168.0.100:8787")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("192.168.0.100:8787", text: $address)
                .frame(maxWidth: 640)
                .focused($fieldFocused)
            Button("Connect") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(80)
        .foregroundStyle(.white)
        .onAppear { fieldFocused = true }
    }

    private func save() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let full = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        onSave(full)
    }
}
