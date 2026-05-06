import SwiftUI

// Custom colour palette designed for use in a dark observatory environment.
// Red light preserves dark-adapted vision, so the UI uses red as its primary
// accent rather than the default blue/white. Amber is used for active states
// (e.g. tracking enabled) because it is clearly distinct from red at a glance.
extension Color {
    // Deep red — primary accent for controls and interactive elements.
    static let astroRed   = Color(red: 0.85, green: 0.08, blue: 0.05)
    // Warm amber — for active/positive state indicators (tracking on, etc.).
    static let astroAmber = Color(red: 0.95, green: 0.55, blue: 0.0)
}
