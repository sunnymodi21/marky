import Foundation

/// Detection sensitivity. Higher sensitivity converts with fewer Markdown cues.
public enum Sensitivity: String, CaseIterable, Sendable, Codable {
    case low
    case normal
    case high

    /// Minimum detection score required before auto-converting.
    public var scoreThreshold: Int {
        switch self {
        case .low: 5
        case .normal: 3
        case .high: 2
        }
    }

    public var displayName: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }
}

public struct ConvertConfig: Sendable {
    public var sensitivity: Sensitivity
    /// Safety valve: skip auto-convert for clipboard blobs larger than this many lines.
    public var maxLines: Int

    public init(sensitivity: Sensitivity = .normal, maxLines: Int = 400) {
        self.sensitivity = sensitivity
        self.maxLines = maxLines
    }
}
