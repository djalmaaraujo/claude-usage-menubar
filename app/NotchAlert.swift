import SwiftUI
import AppKit

// A notch-having screen exposes non-nil auxiliary areas flanking the notch
// (the strips of menu bar to its left/right) - available since macOS 12.
// Screens without a notch (external displays, older MacBooks, iMac/mini)
// report nil for both, which is how we gate the whole feature off on them.
func notchScreen() -> NSScreen? {
    NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }
}
