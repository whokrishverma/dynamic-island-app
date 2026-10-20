//
//  NotchPanelController.swift
//  NotchLyrics
//
//  Borderless black panel on the MacBook notch. The window grows for the
//  music wings and again when the pointer hovers.
//

import AppKit
import Combine
import SwiftUI

/// Finds where the camera notch is on a screen.
private struct NotchMetrics {
    let screenFrame: NSRect
    /// Rectangle of the camera cutout, in Cocoa screen coordinates (origin at bottom-left).
    let notchFrame: NSRect

    var width: CGFloat { notchFrame.width }
    var height: CGFloat { notchFrame.height }
    var midX: CGFloat { notchFrame.midX }

    static func from(screen: NSScreen) -> NotchMetrics {
        let screenFrame = screen.frame

        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = max(screenFrame.width - left.width - right.width, 160)
            let height = max(screen.safeAreaInsets.top, left.height, right.height, 32)
            let notchFrame = NSRect(
                x: screenFrame.minX + left.width,
                y: screenFrame.maxY - height,
                width: width,
                height: height
            )
            return NotchMetrics(screenFrame: screenFrame, notchFrame: notchFrame)
        }

        let menuBarHeight = max(screenFrame.maxY - screen.visibleFrame.maxY, 32)
        let fakeWidth: CGFloat = 185
        let notchFrame = NSRect(
            x: screenFrame.midX - fakeWidth / 2,
            y: screenFrame.maxY - menuBarHeight,
            width: fakeWidth,
            height: menuBarHeight
        )
        return NotchMetrics(screenFrame: screenFrame, notchFrame: notchFrame)
    }
}

/// Borderless floating window that can sit over the menu bar / notch.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        makeKey()
        super.mouseDown(with: event)
    }
}

/// Hosts SwiftUI and reports hover even when the app is not the frontmost app.
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}

/// Owns the notch window, sizes it, and expands / collapses it.
@MainActor
final class NotchPanelController {
    private let model: NowPlayingModel
    private let panel: NotchPanel
    private let hostingView: HoverHostingView<NotchPanelView>
    private var collapseWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(model: NowPlayingModel) {
        self.model = model
        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level.statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.title = "NotchLyrics"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .utilityWindow

        hostingView = HoverHostingView(rootView: NotchPanelView(model: model))
        hostingView.safeAreaRegions = []
        panel.contentView = hostingView

        hostingView.onHoverChange = { [weak self] hovering in
            self?.handleHover(hovering)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyFrame(animated: false)
            }
        }

        model.$hasTrack
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.applyFrame(animated: true)
            }
            .store(in: &cancellables)
    }

    func show() {
        applyFrame(animated: false)
        panel.orderFrontRegardless()
    }

    private func handleHover(_ hovering: Bool) {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil

        if hovering {
            model.isExpanded = true
            applyFrame(animated: true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.model.isExpanded = false
                self.applyFrame(animated: true)
            }
            collapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    private func applyFrame(animated: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let metrics = NotchMetrics.from(screen: screen)
        model.notchSize = CGSize(width: metrics.width, height: metrics.height)
        let frame = targetFrame(metrics: metrics)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func targetFrame(metrics: NotchMetrics) -> NSRect {
        let width: CGFloat
        let height: CGFloat
        if model.isExpanded {
            width = max(NotchLayout.expandedWidth, metrics.width + 2 * NotchLayout.collapsedWing)
            height = NotchLayout.expandedHeight
        } else if model.hasTrack {
            width = metrics.width + 2 * NotchLayout.collapsedWing
            height = metrics.height + NotchLayout.collapsedLip
        } else {
            width = metrics.width
            height = metrics.height + NotchLayout.collapsedLip
        }
        let x = metrics.midX - width / 2
        let y = metrics.screenFrame.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
