import Foundation

extension String {
    /// Middle-ellipsizes to `limit` characters, keeping the head and tail.
    func ellipsized(limit: Int) -> String {
        guard limit >= 3, self.count > limit else { return self }
        let keep = limit - 1
        let headCount = keep / 2
        let tailCount = keep - headCount
        return "\(self.prefix(headCount))…\(self.suffix(tailCount))"
    }
}
