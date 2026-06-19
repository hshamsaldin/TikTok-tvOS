import Foundation

enum Config {
    /// ⚠️ CHANGE THIS to the LAN IP of the Windows PC running the backend.
    /// Find it with `ipconfig` (look for IPv4 Address), e.g. 192.168.1.50.
    /// The Apple TV and the PC must be on the same network.
    static let backendBaseURL = URL(string: "http://192.168.0.10:8787")!
}
