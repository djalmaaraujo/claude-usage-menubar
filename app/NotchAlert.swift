import SwiftUI
import AppKit
import QuartzCore

// A notch-having screen exposes non-nil auxiliary areas flanking the notch
// (the strips of menu bar to its left/right) - available since macOS 12.
// Screens without a notch (external displays, older MacBooks, iMac/mini)
// report nil for both, which is how we gate the whole feature off on them.
func notchScreen() -> NSScreen? {
    NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }
}

struct NotchAlertView: View {
    let percent: Int
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.yellow)
            Text("\(percent)% · \(label)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color.black)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            NotchAlertController.shared.handleClick()
        }
    }
}

@MainActor
final class NotchAlertController {
    static let shared = NotchAlertController()

    private static let collapsedWidth: CGFloat = 40
    private static let panelHeight: CGFloat = 32
    private static let visibleDuration: TimeInterval = 5

    private(set) var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    func show(percent: Int, label: String) {
        guard let screen = notchScreen(),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return }

        dismissWorkItem?.cancel()
        panel?.orderOut(nil)

        let centerX = (left.maxX + right.minX) / 2
        let originY = screen.frame.maxY - Self.panelHeight - 2
        let collapsedFrame = NSRect(x: centerX - Self.collapsedWidth / 2, y: originY, width: Self.collapsedWidth, height: Self.panelHeight)

        // Size the expanded panel to the content's actual rendered width so
        // longer labels don't get clipped mid-word. Clamp to roughly a third
        // of the screen so a pathologically long label can't produce an
        // absurd panel (the view's own .lineLimit(1) truncates gracefully
        // if the clamp kicks in).
        let hostingView = NSHostingView(rootView: NotchAlertView(percent: percent, label: label))
        let maxExpandedWidth = screen.frame.width / 3
        let expandedWidth = min(max(hostingView.fittingSize.width, Self.collapsedWidth), maxExpandedWidth)
        let expandedFrame = NSRect(x: centerX - expandedWidth / 2, y: originY, width: expandedWidth, height: Self.panelHeight)
        hostingView.frame = NSRect(origin: .zero, size: expandedFrame.size)

        let newPanel = NSPanel(
            contentRect: collapsedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.level = .statusBar
        newPanel.hasShadow = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.contentView = hostingView
        newPanel.alphaValue = 0

        newPanel.orderFrontRegardless()
        panel = newPanel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
            newPanel.animator().setFrame(expandedFrame, display: true)
        }

        scheduleDismiss()
    }

    private func scheduleDismiss() {
        let workItem = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: workItem)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        guard let panel else { return }
        let collapsedFrame = NSRect(
            x: panel.frame.midX - Self.collapsedWidth / 2,
            y: panel.frame.origin.y,
            width: Self.collapsedWidth,
            height: Self.panelHeight
        )
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(collapsedFrame, display: true)
        }, completionHandler: { [weak self] in
            // Wrapping in DispatchQueue.main.async (rather than touching
            // `panel`/`self` directly in this completion closure) is what
            // makes the compiler recognize main-actor isolation here - this
            // closure runs on the main thread either way, so there's no
            // functional change, just satisfying Swift's Sendable checking.
            DispatchQueue.main.async {
                panel.orderOut(nil)
                if self?.panel === panel { self?.panel = nil }
            }
        })
    }

    func handleClick() {
        dismiss()
        openMainPopover()
    }

    private func openMainPopover() {
        guard let statusBarWindow = NSApp.windows.first(where: {
            String(describing: type(of: $0)) == "NSStatusBarWindow"
        }), let statusItem = statusBarWindow.value(forKey: "statusItem") as? NSStatusItem
        else { return }
        statusItem.button?.performClick(nil)
    }
}
