// AppDelegate.swift
// Owns the set of open documents (each its own window/tab), the native menu bar,
// and the app-global Font/Color panels.
//
// Two rules keep this crash-free in full screen:
//   1. No app-modal NSAlert.runModal() in the normal flow. Every prompt is a window
//      *sheet* — an app-modal dialog raised over a native full-screen window renders
//      on the wrong Space and hangs the run loop (the "white screen" bug).
//   2. Font/Color panels are app-global and target the delegate (never a per-tab
//      controller), so closing a tab can't leave a shared panel pointing at a dead object.

import AppKit

enum ColorTarget { case text, background, tag }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var controllers: [DocumentWindowController] = []
    private var colorTarget: ColorTarget = .text
    private var appearancesMenu: NSMenu!

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        buildMenu()

        let drafts = Library.pendingRecoveries()
        if drafts.isEmpty {
            // Fresh document: open the window first, then ask the mode as a sheet.
            let wc = makeDocument(mode: .ink, recovered: nil, tabbedInto: nil)
            presentModeSheet(for: wc, allowCancel: false)
        } else {
            // Crash rescue: reopen every unsaved draft as its own tab, no prompts.
            var host: NSWindow?
            for d in drafts {
                let wc = makeDocument(mode: d.mode, recovered: d, tabbedInto: host)
                host = wc.window
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// On ⌘Q, review every document with unsaved changes before quitting, so work is
    /// never silently dropped and no draft is silently regenerated behind the user.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let pending = controllers.filter { $0.editor.hasUnsavedChanges }
        if pending.isEmpty { return .terminateNow }
        reviewUnsaved(pending, index: 0)
        return .terminateLater
    }

    private func reviewUnsaved(_ list: [DocumentWindowController], index: Int) {
        guard index < list.count else { NSApp.reply(toApplicationShouldTerminate: true); return }
        let wc = list[index]
        guard let window = wc.window else { reviewUnsaved(list, index: index + 1); return }
        window.makeKeyAndOrderFront(nil)
        wc.editor.confirmClose(window: window) { [weak self] decision in
            switch decision {
            case .cancel:
                NSApp.reply(toApplicationShouldTerminate: false)
            case .discard:
                wc.editor.discardChanges()
                self?.reviewUnsaved(list, index: index + 1)
            case .saved:
                self?.reviewUnsaved(list, index: index + 1)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let wc = makeDocument(mode: .ink, recovered: nil, tabbedInto: nil)
            presentModeSheet(for: wc, allowCancel: false)
        }
        return true
    }

    private var currentEditor: EditorViewController? {
        NSApp.keyWindow?.contentViewController as? EditorViewController
    }

    // MARK: - Document creation

    @discardableResult
    private func makeDocument(mode: EditMode, recovered: RecoveredDraft?, tabbedInto host: NSWindow?) -> DocumentWindowController {
        let wc = DocumentWindowController(mode: mode, recovered: recovered)
        wc.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(wc)

        if let host = host, let win = wc.window {
            // Prefer the modern tab-group API; it inserts correctly even in full screen.
            if let group = host.tabGroup {
                group.addWindow(win)
            } else {
                host.addTabbedWindow(win, ordered: .above)
            }
        }
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return wc
    }

    /// Ask Ink vs Free-write as a sheet on the freshly opened (empty) document.
    private func presentModeSheet(for wc: DocumentWindowController, allowCancel: Bool) {
        guard let window = wc.window else { return }
        let alert = NSAlert()
        alert.messageText = "New Inkwell document"
        alert.informativeText = """
        Choose how this document behaves. This can't be changed once you start.

        Ink — forward-only. You write inside a live bracket; finished sentences \
        freeze into ink and can't be edited.

        Free-write — edit anywhere, no brackets.
        """
        alert.addButton(withTitle: "Ink")
        alert.addButton(withTitle: "Free-write")
        if allowCancel { alert.addButton(withTitle: "Cancel") }
        alert.beginSheetModal(for: window) { [weak wc] response in
            switch response {
            case .alertFirstButtonReturn:  wc?.editor.commitMode(.ink)
            case .alertSecondButtonReturn: wc?.editor.commitMode(.free)
            default:                       wc?.window?.performClose(nil)   // Cancel closes the new tab
            }
        }
    }

    // MARK: - File ▸ New  &  the tab-bar "+" button

    @objc func newDocument(_ sender: Any?) {
        let wc = makeDocument(mode: .ink, recovered: nil, tabbedInto: NSApp.keyWindow)
        presentModeSheet(for: wc, allowCancel: true)
    }
    @objc func newWindowForTab(_ sender: Any?) { newDocument(sender) }

    // MARK: - Font (routed through the delegate, never a per-tab target)

    @objc func showFontPanel(_ sender: Any?) {
        NSFontManager.shared.target = self
        NSFontManager.shared.action = #selector(changeFont(_:))
        NSFontManager.shared.setSelectedFont(Appearance.shared.font, isMultiple: false)
        NSFontPanel.shared.orderFront(sender)
    }

    @objc func changeFont(_ sender: Any?) {
        Appearance.shared.font = NSFontManager.shared.convert(Appearance.shared.font)
        for wc in controllers { wc.editor.reapplyAppearance() }
    }

    // MARK: - Colors (shared panel targets the delegate, applies to every open doc)

    // MARK: - Appearance presets

    private func repaintAll() { for wc in controllers { wc.editor.reapplyAppearance() } }

    @objc func saveAsDefaultAppearance(_ sender: Any?) {
        Appearance.shared.saveAsDefault()
    }

    @objc func saveAppearanceAs(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Save Appearance"
        alert.informativeText = "Name this appearance so you can return to it later from Format ▸ Appearances."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Appearance name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != Appearance.shared.defaultName else { return }
            Appearance.shared.savePreset(name: name)
        }
    }

    @objc func loadDefaultAppearance(_ sender: Any?) {
        Appearance.shared.loadPreset(name: Appearance.shared.defaultName)
        repaintAll()
    }

    @objc func loadNamedAppearance(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Appearance.shared.loadPreset(name: name)
        repaintAll()
    }

    // Rebuild the Appearances submenu each time it opens so saved presets show up.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === appearancesMenu else { return }
        menu.removeAllItems()
        let def = menu.addItem(withTitle: "Default Appearance", action: #selector(loadDefaultAppearance(_:)), keyEquivalent: "")
        def.target = self
        let named = Appearance.shared.presetNames()
        if !named.isEmpty { menu.addItem(.separator()) }
        for name in named {
            let item = menu.addItem(withTitle: name, action: #selector(loadNamedAppearance(_:)), keyEquivalent: "")
            item.representedObject = name
            item.target = self
        }
    }

    @objc func chooseTextColor(_ sender: Any?)       { openColorPanel(.text, Appearance.shared.textColor) }
    @objc func chooseBackgroundColor(_ sender: Any?) { openColorPanel(.background, Appearance.shared.backgroundColor) }
    @objc func chooseTagColor(_ sender: Any?)        { openColorPanel(.tag, Appearance.shared.tagColor) }

    private func openColorPanel(_ target: ColorTarget, _ current: NSColor) {
        colorTarget = target
        let panel = NSColorPanel.shared
        panel.showsAlpha = false                 // opaque only — a translucent bg looked "broken"
        panel.setTarget(self)
        panel.setAction(#selector(changeColor(_:)))
        panel.color = current
        panel.orderFront(nil)
    }

    @objc func changeColor(_ sender: NSColorPanel?) {
        guard let raw = sender?.color else { return }
        let color = raw.usingColorSpace(.sRGB) ?? raw
        // Accept only changes that originate from the user working a color picker.
        // AppKit also force-sends this action when the first responder changes (e.g.
        // clicking into the text to type), echoing a stale color back and reverting
        // the user's pick — that path has no NSColorPicker in its call stack.
        let fromPicker = Thread.callStackSymbols.contains { $0.contains("NSColorPicker") }
        guard fromPicker else { return }
        switch colorTarget {
        case .text:       Appearance.shared.textColor = color
        case .background: Appearance.shared.backgroundColor = color.withAlphaComponent(1)
        case .tag:        Appearance.shared.tagColor = color
        }
        for wc in controllers { wc.editor.reapplyAppearance() }
    }

    // MARK: - Menu construction

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Inkwell", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Inkwell", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Inkwell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New", action: #selector(newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(EditorViewController.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(EditorViewController.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(EditorViewController.saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Rename…", action: #selector(EditorViewController.renameDocument(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Export…", action: #selector(EditorViewController.exportDocument(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Print…", action: #selector(EditorViewController.printDocument(_:)), keyEquivalent: "p")

        // Edit menu
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let copyClean = editMenu.addItem(withTitle: "Copy Clean Prose", action: #selector(EditorViewController.copyCleanProse(_:)), keyEquivalent: "c")
        copyClean.keyEquivalentModifierMask = [.command, .option]

        // Format menu
        let fmtItem = NSMenuItem(); mainMenu.addItem(fmtItem)
        let fmtMenu = NSMenu(title: "Format"); fmtItem.submenu = fmtMenu
        fmtMenu.addItem(withTitle: "Font…", action: #selector(showFontPanel(_:)), keyEquivalent: "t")
        fmtMenu.addItem(.separator())
        fmtMenu.addItem(withTitle: "Text Color…", action: #selector(chooseTextColor(_:)), keyEquivalent: "")
        fmtMenu.addItem(withTitle: "Background Color…", action: #selector(chooseBackgroundColor(_:)), keyEquivalent: "")
        fmtMenu.addItem(withTitle: "Tag Color…", action: #selector(chooseTagColor(_:)), keyEquivalent: "")
        fmtMenu.addItem(.separator())
        fmtMenu.addItem(withTitle: "Save as Default Appearance", action: #selector(saveAsDefaultAppearance(_:)), keyEquivalent: "")
        fmtMenu.addItem(withTitle: "Save Appearance…", action: #selector(saveAppearanceAs(_:)), keyEquivalent: "")
        appearancesMenu = NSMenu(title: "Appearances")
        appearancesMenu.delegate = self
        let appearancesItem = NSMenuItem(title: "Appearances", action: nil, keyEquivalent: "")
        appearancesItem.submenu = appearancesMenu
        fmtMenu.addItem(appearancesItem)

        // View menu
        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View"); viewItem.submenu = viewMenu
        let fs = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]

        // Window menu (system injects tab commands: Show Tab Bar, Show All Tabs, etc.)
        let winItem = NSMenuItem(); mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Window"); winItem.submenu = winMenu
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = winMenu

        // Help menu
        let helpItem = NSMenuItem(); mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help"); helpItem.submenu = helpMenu
        // The selector must NOT be showHelp: — that is AppKit's own Apple Help action,
        // implemented by NSApplication, which the responder chain reaches before this
        // delegate. With no help book registered it answers "Help isn't available for
        // Inkwell" and our help is never shown. Setting the target keeps it ours.
        let helpEntry = helpMenu.addItem(withTitle: "Inkwell Help", action: #selector(showInkwellHelp(_:)), keyEquivalent: "?")
        helpEntry.target = self
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showInkwellHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Inkwell"
        alert.informativeText = """
        Each document has one fixed mode, chosen when you create it:

        • Ink — forward-only. You type inside a live [bracket]. End a sentence \
        with . ? or ! then two spaces and the words freeze into ink; a fresh \
        bracket opens so your prose flows on. Press Return on an empty bracket \
        to start a new indented paragraph. Frozen ink can't be edited.

        • Free-write — plain typing, no brackets, edit anywhere.

        Tabs: File ▸ New (⌘N) opens another document as a tab in the same window, \
        just like a new tab in a terminal. Drag tabs out to split them into \
        separate windows. Right-click a tab to rename its file, or use File ▸ Rename.

        Tags: wrap text in #hashes#. Tags show while you write but are stripped \
        from saved prose and the clipboard; each tag also gets its own file in \
        the Tags folder on save.

        Files live in ~/Documents/Inkwell (set INKWELL_DIR to move that) and \
        are fully shared with the Terminal version of Inkwell.

        Appearance: Format ▸ Font, Text Color, Background Color, Tag Color.
        Full screen: View ▸ Enter Full Screen (⌃⌘F).
        """
        if let w = NSApp.keyWindow {
            alert.beginSheetModal(for: w)
        } else {
            alert.runModal()
        }
    }
}
