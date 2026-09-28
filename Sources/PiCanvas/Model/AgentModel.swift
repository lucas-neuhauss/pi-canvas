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
    /// Which workspace this node belongs to. Optional because layouts written
    /// before workspaces existed have no such field; those are adopted into the
    /// default workspace when they are loaded.
    var workspaceID: UUID?

    /// Last title the terminal reported, restored so the canvas looks the same
    /// before the new process has had a chance to set one.
    var title: String?
    /// A name the user gave this node. When set it wins over the terminal's own
    /// title, and survives the terminal renaming itself.
    var customTitle: String?
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
        customTitle: String? = nil,
        sessionID: String? = nil,
        workspaceID: UUID? = nil
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
        self.customTitle = customTitle
        self.sessionID = sessionID
        self.workspaceID = workspaceID
    }

    /// What the node should show: your name if you gave it one, else whatever the
    /// terminal last called itself.
    var displayTitle: String {
        customTitle ?? title ?? kind.displayName
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

    /// Tolerant decoding: a layout written by an older build is missing fields we
    /// have since added, and losing a canvas to a decode failure is not acceptable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? LayoutFile.currentVersion
        zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        panX = try container.decodeIfPresent(Double.self, forKey: .panX) ?? 0
        panY = try container.decodeIfPresent(Double.self, forKey: .panY) ?? 0
        lastWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .lastWorkingDirectory)
            ?? NSHomeDirectory()
        nodes = try container.decodeIfPresent([NodeSpec].self, forKey: .nodes) ?? []
    }
}

/// One named canvas. Switching workspaces swaps which set of nodes is on screen
/// without stopping anything: the agents in the other ones keep running.
struct WorkspaceFile: Codable {
    static let currentVersion = 1

    var version: Int = WorkspaceFile.currentVersion
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    /// Monotonic counter of the last time this workspace was opened.
    ///
    /// Wall-clock timestamps cannot order two workspaces switched between within
    /// the same millisecond, which is exactly what cycling through them does, so
    /// the ordering is kept on its own counter.
    var useOrder: Int = 0
    var layout: LayoutFile

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        useOrder: Int = 0,
        layout: LayoutFile
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.useOrder = useOrder
        self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? WorkspaceFile.currentVersion
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        useOrder = try container.decodeIfPresent(Int.self, forKey: .useOrder) ?? 0
        layout = try container.decode(LayoutFile.self, forKey: .layout)
    }
}
