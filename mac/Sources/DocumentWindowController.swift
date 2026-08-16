// DocumentWindowController.swift
// One window == one document == one tab. Windows share a tabbingIdentifier so
// macOS groups them into native tabs (iTerm2-style). Mode is fixed at creation.

import AppKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate {

    let editor: EditorViewController
    var onClose: ((DocumentWindowController) -> Void)?

    init(mode: EditMode, recovered: RecoveredDraft?) {
        editor = EditorViewController(mode: mode, recovered: recovered)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Untitled"
        window.tabbingIdentifier = "InkwellDocument"
        window.tabbingMode = .preferred
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Don't let macOS restore into a stale full-screen Space on relaunch — that
        // restoration path is where an early prompt used to white-out the window.
        window.isRestorable = false
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 900, height: 700))
        window.contentMinSize = NSSize(width: 440, height: 340)
        window.backgroundColor = Appearance.shared.backgroundColor
        // Let the titlebar/tab-bar strip take the window background color instead of
        // the default gray material, so it blends into the page. Title/subtitle text
        // and traffic lights stay visible (titleVisibility left at .visible).
        window.titlebarAppearsTransparent = true

        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private var forceClose = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if forceClose { return true }
        guard editor.hasUnsavedChanges else { return true }
        editor.confirmClose(window: sender) { [weak self, weak sender] decision in
            switch decision {
            case .cancel:  break
            case .discard: self?.editor.discardChanges(); self?.forceClose = true; sender?.close()
            case .saved:   self?.forceClose = true; sender?.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        editor.finalizeOnClose()
        onClose?(self)
    }

    // MARK: - Full screen tab-bar auto-hide

    // In full screen the native tab bar otherwise stays pinned across the top. Let it auto-hide
    // with the title bar (reveal by moving the cursor to the top edge) — Josh's preferred look
    // on all Macs. The tab bar is a system-created NSTitlebarAccessoryViewController; its
    // `fullScreenMinHeight` is how much stays pinned when the titlebar collapses; 0 lets it hide.
    func windowDidEnterFullScreen(_ notification: Notification) {
        collapseTabBarInFullScreen()
    }

    private func collapseTabBarInFullScreen() {
        guard let window = window else { return }
        // We add no accessories of our own, so zeroing all of them targets the tab bar.
        for vc in window.titlebarAccessoryViewControllers {
            vc.fullScreenMinHeight = 0
        }
    }
}
