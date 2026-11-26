import AppKit
import Combine
import SwiftUI

/// The "Meeting · 12:34" counter, shown while a meeting records. It sits in the top-right corner just under the
/// menu bar, next to the menu-bar icon and macOS's own microphone dot, because call apps (Meet, Zoom, Teams,
/// FaceTime) put their mic, camera and hang-up controls at the bottom centre, where the dictation pill lives.
@MainActor
final class MeetingBadgeController {
    nonisolated static let size = NSSize(width: 200, height: 34)
    nonisolated static let inset: CGFloat = 10

    private var panel: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []

    nonisolated init() {}

    func attach(_ state: AppState) {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .statusBar; p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: MeetingBadgeView().environmentObject(state))
        panel = p

        state.$meetingActive.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] active in self?.show(active) }
            .store(in: &subscriptions)
        // Follow the screen the user is working on when they switch apps or plug in a display.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.place() }
            .store(in: &subscriptions)
    }

    private func show(_ active: Bool) {
        guard let panel else { return }
        if active { place(); panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    private func place() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrameOrigin(Self.origin(in: screen.visibleFrame))
    }

    /// Top-right of the visible frame (below the menu bar, clear of the Dock), inset a little from the edges.
    nonisolated static func origin(in visible: NSRect) -> NSPoint {
        NSPoint(x: visible.maxX - size.width - inset, y: visible.maxY - size.height - inset)
    }
}

struct MeetingBadgeView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("Meeting · \(state.meetingClock)").monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Theme.ink.opacity(0.94)))
        .overlay(Capsule().strokeBorder(Theme.mint.opacity(0.55), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}
