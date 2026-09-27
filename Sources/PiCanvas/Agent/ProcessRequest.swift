import Foundation

/// Everything needed to launch a node's process.
struct ProcessRequest {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String
    var displayName: String
}
