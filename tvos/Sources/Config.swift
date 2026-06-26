import Foundation

enum Config {
    private static let key = "backendBaseURLString"
    private static let defaultURLString = "http://192.168.0.100:8787"

    /// True once the user has entered a server address — until then, the app
    /// is using the placeholder default and should prompt for one rather than
    /// silently failing to connect.
    static var hasCustomServer: Bool {
        UserDefaults.standard.string(forKey: key) != nil
    }

    static var backendBaseURLString: String {
        UserDefaults.standard.string(forKey: key) ?? defaultURLString
    }

    static var backendBaseURL: URL {
        URL(string: backendBaseURLString) ?? URL(string: defaultURLString)!
    }

    static func setBackendBaseURL(_ string: String) {
        UserDefaults.standard.set(string, forKey: key)
    }
}
