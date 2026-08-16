// EditorViewController.swift
// Hosts one InkTextView in a centered column, owns this document's file operations,
// per-tab autosave/recovery, and status line. The document's mode is fixed once
// chosen (via a sheet, not an app-modal dialog — see AppDelegate). Font/color panels
// are owned by the app delegate so a closing tab can't leave a shared panel dangling.

import AppKit

enum CloseDecision { case saved, discard, cancel }

final class EditorViewController: NSViewController, NSTextViewDelegate {

    private var scrollView: NSScrollView!
    private var textView: InkTextView!
    private var currentFilePath: String?
    private var autosaveTimer: Timer?

    private let initialMode: EditMode
    private let recoveryID: String
    private let seedParagraphs: [String]?

    private let maxColumnWidth: CGFloat = 825   // centered column width

    init(mode: EditMode, recovered: RecoveredDraft? = nil) {
        self.initialMode = recovered?.mode ?? mode
        self.recoveryID = recovered?.id ?? UUID().uuidString
        self.seedParagraphs = recovered?.paragraphs
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    var mode: EditMode { textView?.mode ?? initialMode }

    // MARK: - View

    override func loadView() {
        let container = BackgroundView()
        container.autoresizingMask = [.width, .height]
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        self.view = container

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false   // clip view stays transparent
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Build the text system explicitly so we can pass a container to InkTextView.
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let tv = InkTextView(frame: .zero, textContainer: textContainer)
        tv.mode = initialMode
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.delegate = self
        tv.onChange = { [weak self] in self?.updateStatus() }
        self.textView = tv

        scrollView.documentView = tv
        container.addSubview(scrollView)
        // Pin the scroll view to every edge so the background always fills the
        // window — including zoom and full screen (no black margins).
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        if let seed = seedParagraphs {
            tv.loadParagraphs(seed)
            tv.dirty = true          // recovered text is unsaved until the user saves it
        } else {
            tv.loadParagraphs([""])
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyBackground()
        textView.applyAppearance()
        updateStatus()
        view.window?.makeFirstResponder(textView)
        startAutosave()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Center the text column: pad the sides so the column never exceeds maxColumnWidth.
        let w = scrollView.contentSize.width
        let side = max(24, (w - maxColumnWidth) / 2)
        let topPad: CGFloat = 60
        textView.textContainerInset = NSSize(width: side, height: topPad)
        textView.frame.size.width = w
        textView.textContainer?.containerSize = NSSize(width: w - side * 2, height: CGFloat.greatestFiniteMagnitude)
    }

    private func applyBackground() {
        let bg = Appearance.shared.backgroundColor
        (view as? BackgroundView)?.fill = bg
        view.window?.backgroundColor = bg
        // The transparent titlebar shows this bg color, so match the window
        // appearance to the bg brightness — otherwise the kept title/word-count
        // text and traffic lights could render dark-on-dark (or light-on-light).
        let s = bg.usingColorSpace(.sRGB) ?? bg
        let lum = 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
        view.window?.appearance = NSAppearance(named: lum < 0.5 ? .darkAqua : .aqua)
    }

    /// Repaint after a Font/Color change (called by the app delegate).
    func reapplyAppearance() {
        applyBackground()
        textView.applyAppearance()
    }

    /// Lock the document into a mode. Safe only while the document is still empty
    /// (used by the mode-chooser sheet right after the tab opens).
    func commitMode(_ newMode: EditMode) {
        guard textView.isEmptyDocument else { return }
        textView.setMode(newMode)
        updateStatus()
        view.window?.makeFirstResponder(textView)
    }

    // MARK: - Status line (window title + subtitle)

    private func updateStatus() {
        let name = currentFilePath.map { ($0 as NSString).lastPathComponent } ?? "Untitled"
        view.window?.title = name
        // Keep the title bar quiet: just the filename, plus an unsaved marker.
        // (Word count and Ink/Free-write mode were too much info up here.)
        view.window?.subtitle = textView.dirty ? "unsaved" : ""
    }

    // MARK: - Autosave / recovery

    private func startAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.autosave()
        }
    }

    private func autosave() {
        guard textView.dirty else { return }
        if let path = currentFilePath {
            _ = try? Library.save(paragraphs: textView.documentParagraphs(), live: textView.documentLive(), to: path)
            Library.removeRecovery(id: recoveryID)
            textView.dirty = false
            updateStatus()
        } else {
            Library.writeRecovery(id: recoveryID, mode: textView.mode,
                                  paragraphs: textView.documentParagraphs(), live: textView.documentLive())
        }
    }

    /// Called from the window delegate as the tab/window closes. A *clean* close
    /// never leaves a rescue file (only a crash, which skips this path, does). Any
    /// unsaved-work decision has already been made by the close/quit prompt; a named
    /// doc with pending edits is saved silently as a convenience.
    func finalizeOnClose() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        if textView.dirty, let path = currentFilePath {
            _ = try? Library.save(paragraphs: textView.documentParagraphs(), live: textView.documentLive(), to: path)
        }
        Library.removeRecovery(id: recoveryID)
    }

    // MARK: - Closing

    var hasUnsavedChanges: Bool { textView.dirty }

    /// Explicit close (⌘W / clicking the tab's ×) with unsaved work: standard prompt.
    func confirmClose(window: NSWindow, completion: @escaping (CloseDecision) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to this document?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { completion(.cancel); return }
            switch response {
            case .alertFirstButtonReturn:  self.saveForClose(window: window, completion: completion)
            case .alertSecondButtonReturn: completion(.discard)
            default:                       completion(.cancel)
            }
        }
    }

    private func saveForClose(window: NSWindow, completion: @escaping (CloseDecision) -> Void) {
        if let path = currentFilePath {
            do {
                let saved = try Library.save(paragraphs: textView.documentParagraphs(), live: textView.documentLive(), to: path)
                setFilePath(saved); Library.removeRecovery(id: recoveryID); textView.dirty = false
                completion(.saved)
            } catch { completion(.cancel) }
            return
        }
        let panel = NSSavePanel()
        panel.directoryURL = URL(fileURLWithPath: Library.writingDir)
        panel.nameFieldStringValue = Library.defaultFileName()
        panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self = self else { completion(.cancel); return }
            guard resp == .OK, var p = panel.url?.path else { completion(.cancel); return }
            if !(p.lowercased().hasSuffix(".md") || p.lowercased().hasSuffix(".txt")) { p += ".md" }
            do {
                let saved = try Library.save(paragraphs: self.textView.documentParagraphs(), live: self.textView.documentLive(), to: p)
                self.setFilePath(saved); Library.removeRecovery(id: self.recoveryID); self.textView.dirty = false
                completion(.saved)
            } catch { completion(.cancel) }
        }
    }

    /// User chose "Don't Save": drop the draft so nothing lingers to recover.
    func discardChanges() {
        textView.dirty = false
        Library.removeRecovery(id: recoveryID)
    }

    // MARK: - File menu actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: Library.writingDir)
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        textView.loadParagraphs(TextLogic.loadFrozenParagraphs(from: raw))
        setFilePath(url.path)
        updateStatus()
    }

    @objc func saveDocument(_ sender: Any?) {
        if let path = currentFilePath {
            performSave(to: path)
        } else {
            saveDocumentAs(sender)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.directoryURL = URL(fileURLWithPath: Library.writingDir)
        panel.nameFieldStringValue = currentFilePath.map { ($0 as NSString).lastPathComponent } ?? Library.defaultFileName()
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, var path = panel.url?.path else { return }
        if !(path.lowercased().hasSuffix(".md") || path.lowercased().hasSuffix(".txt")) { path += ".md" }
        performSave(to: path)
    }

    private func performSave(to path: String) {
        do {
            let saved = try Library.save(paragraphs: textView.documentParagraphs(), live: textView.documentLive(), to: path)
            setFilePath(saved)
            Library.removeRecovery(id: recoveryID)
            textView.dirty = false
            updateStatus()
        } catch {
            let alert = NSAlert(error: error)
            if let w = view.window { alert.beginSheetModal(for: w) }
            else { alert.runModal() }
        }
    }

    private func setFilePath(_ path: String) {
        currentFilePath = path
        view.window?.representedURL = URL(fileURLWithPath: path)   // enables title-bar rename popover
    }

    // MARK: - Rename

    /// Rename lets you pick a new name AND a new location (via the Save panel), then
    /// moves the document there. For an unsaved doc it's simply the first save.
    @objc func renameDocument(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        let startDir = currentFilePath.map { ($0 as NSString).deletingLastPathComponent } ?? Library.writingDir
        panel.directoryURL = URL(fileURLWithPath: startDir)
        panel.nameFieldStringValue = currentFilePath.map { ($0 as NSString).lastPathComponent } ?? Library.defaultFileName()
        panel.allowsOtherFileTypes = true
        panel.prompt = "Rename"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard let self = self, resp == .OK, var newPath = panel.url?.path else { return }
            if !(newPath.lowercased().hasSuffix(".md") || newPath.lowercased().hasSuffix(".txt")) { newPath += ".md" }
            self.moveDocument(to: newPath, window: window)
        }
    }

    private func moveDocument(to newPath: String, window: NSWindow) {
        let oldPath = currentFilePath
        do {
            let saved = try Library.save(paragraphs: textView.documentParagraphs(), live: textView.documentLive(), to: newPath)
            // Move semantics: drop the old file if we saved it somewhere new.
            if let oldPath = oldPath, oldPath != saved, FileManager.default.fileExists(atPath: oldPath) {
                try? FileManager.default.removeItem(atPath: oldPath)
            }
            setFilePath(saved)
            Library.removeRecovery(id: recoveryID)
            textView.dirty = false
            updateStatus()
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    @objc func exportDocument(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.directoryURL = URL(fileURLWithPath: Library.writingDir)
        panel.nameFieldStringValue = "export.txt"
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        let prose = TextLogic.renderExport(textView.documentParagraphs(), live: textView.documentLive())
        try? prose.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @objc func copyCleanProse(_ sender: Any?) {
        let prose = TextLogic.renderExport(textView.documentParagraphs(), live: textView.documentLive())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prose, forType: .string)
    }

    @objc func printDocument(_ sender: Any?) {
        let prose = TextLogic.renderExport(textView.documentParagraphs(), live: textView.documentLive())
        let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        printView.string = prose
        printView.font = Appearance.shared.font
        let op = NSPrintOperation(view: printView)
        op.run()
    }

    // MARK: - Text delegate

    func textDidChange(_ notification: Notification) {
        if textView.mode == .free { textView.dirty = true }
        updateStatus()
    }
}

/// A plain view that fills with the chosen background color.
///
/// It sets its *layer* background color, not just draw(_:). In full screen macOS
/// force-enables layer backing; a partial redraw (e.g. one keystroke) would then
/// leave the rest of the surface showing the layer's default (white). Driving the
/// layer color keeps the whole background solid no matter how little is redrawn.
final class BackgroundView: NSView {
    var fill: NSColor = .black {
        didSet {
            wantsLayer = true
            layer?.backgroundColor = fill.cgColor
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
    }
    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
    }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        dirtyRect.fill()
    }
}
