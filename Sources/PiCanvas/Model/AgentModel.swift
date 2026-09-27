import Foundation
import CoreGraphics

/// What kind of process a node hosts.
enum NodeKind: String, Codable, CaseIterable {
    case shell
    case pi

    var displayName: String {
        switch self {
        case .shell: return "Terminal"
        case .pi: return "pi"
        }
    }

    /// Accent colour used for the node's status dot, as sRGB components.
    var accent: (Double, Double, Double) {
        switch self {
        case .shell: return (0.42, 0.68, 0.98)
        case .pi: return (0.65, 0.51, 0.98)
        }
    }
}

/// A node on the canvas. This is the persisted description: everything needed to
/// recreate the exact same node on next launch.
struct NodeSpec: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: NodeKind
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// Working directory the process is started in.
    var workingDirectory: String
    /// Resolved executable + argv. Stored so relaunch is deterministic.
    var executable: String
    var arguments: [String]
    /// Last title the terminal reported, restored so the canvas looks the same
    /// before the new process has had a chance to set one.
    var title: String?
    /// For `pi` nodes: the pi session this node owns. Passing it back to
    /// `pi --session-id` on relaunch resumes the same conversation, and keeping
    /// it per node means two agents in one directory never share a session.
    var sessionID: String?

    init(
        id: UUID = UUID(),
        kind: NodeKind,
        worldFrame: CGRect,
        workingDirectory: String,
        executable: String,
        arguments: [String],
        title: String? = nil,
        sessionID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.x = Double(worldFrame.origin.x)
        self.y = Double(worldFrame.origin.y)
        self.width = Double(worldFrame.size.width)
        self.height = Double(worldFrame.size.height)
        self.workingDirectory = workingDirectory
        self.executable = executable
        self.arguments = arguments
        self.title = title
        self.sessionID = sessionID
    }

    var worldFrame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = Double(newValue.origin.x)
            y = Double(newValue.origin.y)
            width = Double(newValue.size.width)
            height = Double(newValue.size.height)
        }
    }
}

/// The full persisted canvas state.
struct LayoutFile: Codable {
    static let currentVersion = 1

    var version: Int = LayoutFile.currentVersion
    var zoom: Double
    var panX: Double
    var panY: Double
    /// Directory used for new nodes when the user has not picked one.
    var lastWorkingDirectory: String
    var nodes: [NodeSpec]

    init(
        zoom: Double = 1,
        panX: Double = 0,
        panY: Double = 0,
        lastWorkingDirectory: String,
        nodes: [NodeSpec]
    ) {
        self.zoom = zoom
        self.panX = panX
        self.panY = panY
        self.lastWorkingDirectory = lastWorkingDirectory
        self.nodes = nodes
    }
}
