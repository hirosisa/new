import Foundation

enum Formatters {

    /// `0:42`, `4:07`, `1:02:33`. Returns `"--:--"` for unknown / non-finite
    /// values, which is the common case for live streams and for items whose
    /// duration is not known until the player loads them.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }

        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60

        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Guards against the NaN that AVPlayer reports before an item is ready.
    /// Feeding NaN into a SwiftUI frame width crashes the render pass, so every
    /// progress calculation funnels through here.
    static func progress(current: TimeInterval, duration: TimeInterval) -> Double {
        guard duration.isFinite, duration > 0,
              current.isFinite, current >= 0 else { return 0 }
        return min(1, max(0, current / duration))
    }

    static func speedLabel(_ rate: Float) -> String {
        let trimmed = (rate * 100).rounded() / 100
        if trimmed == trimmed.rounded() {
            return String(format: "%.0f×", trimmed)
        }
        return String(format: "%.2g×", trimmed)
    }
}
