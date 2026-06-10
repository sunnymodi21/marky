import Foundation

public struct ConvertConfig: Sendable {
    /// Minimum detection score required before auto-converting.
    public var scoreThreshold: Int
    /// Safety valve: skip auto-convert for clipboard blobs larger than this many lines.
    public var maxLines: Int

    public init(scoreThreshold: Int = 3, maxLines: Int = 400) {
        self.scoreThreshold = scoreThreshold
        self.maxLines = maxLines
    }
}
