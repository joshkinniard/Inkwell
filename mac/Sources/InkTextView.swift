// InkTextView.swift
// One NSTextView, two behaviors:
//   .ink  — forward-only: a live [bracket], commit on ender + two spaces, locked ink.
//   .free — plain editing, no brackets, edit anywhere (WriteRoom-style).
// The native thin insertion-point caret is used in both modes.

import AppKit

enum EditMode { case ink, free }

final class InkTextView: NSTextView {

    // Ink-mode model (mirrors inkwell.py: paragraphs + live bracket + caret).
    private(set) var paragraphs: [String] = [""]
    private(set) var live = ""
    private var caret = 0

    var mode: EditMode = .ink
    var dirty = false
    var onChange: (() -> Void)?

    private let enders: Set<Character> = [".", "?", "!"]
    private let tagRegex = try! NSRegularExpression(pattern: "#[^#\\n]*#")

    // MARK: - Setup

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        insertionPointColor = Appearance.shared.textColor
        // The text view paints its own background. With drawsBackground = false a
        // layer-backed NSTextView shows a white layer on top of everything, which
        // was the "screen goes white on typing" bug. Let it draw the real color.
        drawsBackground = true
        backgroundColor = Appearance.shared.backgroundColor
        isEditable = true
        isSelectable = true
    }

    // MARK: - Public content access

    /// Snapshot for saving. In free mode we first pull paragraphs out of the text.
    func documentParagraphs() -> [String] {
        if mode == .free { return paragraphsFromFreeText() }
        return paragraphs
    }

    func documentLive() -> String {
        return mode == .free ? "" : live
    }

    /// True when nothing has been written yet (safe to switch modes). Check the model,
    /// not `string` — in Ink mode the rendered string always contains the "[]" brackets,
    /// which previously made this return false and blocked the switch to Free-write.
    var isEmptyDocument: Bool {
        if !live.isEmpty { return false }
        if mode == .free {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return paragraphs.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func loadParagraphs(_ paras: [String]) {
        paragraphs = paras.isEmpty ? [""] : paras
        live = ""; caret = 0
        dirty = false
        if mode == .free {
            // Seed the editable text from the frozen paragraphs, then render plainly.
            string = paragraphs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            renderFree()
        } else {
            renderInk()
        }
    }

    func applyAppearance() {
        insertionPointColor = Appearance.shared.textColor
        backgroundColor = Appearance.shared.backgroundColor
        typingAttributes = baseAttributes()
        refresh()
    }

    // MARK: - Mode switching

    func setMode(_ newMode: EditMode) {
        guard newMode != mode else { return }
        if newMode == .free {
            // ink -> free: fold the live bracket into the last paragraph, show plain text.
            if !live.isEmpty {
                if var last = paragraphs.last {
                    if !last.isEmpty && !last.hasSuffix(" ") { last += " " }
                    paragraphs[paragraphs.count - 1] = last + live
                }
                live = ""; caret = 0
            }
            mode = .free
            // Rebuild the editable text from the model. Using the current `string` would
            // carry the Ink render's "[]" brackets into Free mode as literal characters.
            string = paragraphs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            renderFree()
        } else {
            // free -> ink: split the edited text back into frozen paragraphs.
            paragraphs = paragraphsFromFreeText()
            live = ""; caret = 0
            mode = .ink
            refresh()
        }
    }

    private func paragraphsFromFreeText() -> [String] {
        let blocks = string.components(separatedBy: "\n\n")
        var result: [String] = []
        for b in blocks {
            let t = b.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { result.append(t + "  ") }
        }
        return result.isEmpty ? [""] : result
    }

    // MARK: - Rendering

    func refresh() {
        if mode == .ink { renderInk() } else { renderFree() }
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        let ap = Appearance.shared
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = ap.font.pointSize * 2.0     // paragraph indent
        para.paragraphSpacing = ap.font.pointSize * 0.9        // gap between paragraphs
        para.lineSpacing = ap.font.pointSize * 0.15
        return [.font: ap.font, .foregroundColor: ap.textColor, .paragraphStyle: para]
    }

    private func renderFree() {
        let attr = NSMutableAttributedString(string: string, attributes: baseAttributes())
        colorTags(in: attr)
        let sel = selectedRange()
        textStorage?.setAttributedString(attr)
        typingAttributes = baseAttributes()
        setSelectedRange(NSRange(location: min(sel.location, string.count), length: 0))
    }

    private func renderInk() {
        let ap = Appearance.shared
        // Build: earlier paragraphs joined by newline, then last paragraph + [live].
        var head = ""
        if paragraphs.count > 1 {
            head = paragraphs[0..<(paragraphs.count - 1)].joined(separator: "\n") + "\n"
        }
        let lastPara = paragraphs.last ?? ""
        let openBracketOffset = head.count + lastPara.count
        let full = head + lastPara + "[" + live + "]"
        let liveStart = openBracketOffset + 1
        let caretIndex = liveStart + caret

        let attr = NSMutableAttributedString(string: full, attributes: baseAttributes())
        colorTags(in: attr)
        // Brackets subtle.
        let ns = full as NSString
        if openBracketOffset < ns.length {
            attr.addAttribute(.foregroundColor, value: ap.bracketColor, range: NSRange(location: openBracketOffset, length: 1))
        }
        let closeOffset = liveStart + live.count
        if closeOffset < ns.length {
            attr.addAttribute(.foregroundColor, value: ap.bracketColor, range: NSRange(location: closeOffset, length: 1))
        }
        textStorage?.setAttributedString(attr)
        typingAttributes = baseAttributes()
        let idx = min(caretIndex, full.count)
        setSelectedRange(NSRange(location: idx, length: 0))
    }

    private func colorTags(in attr: NSMutableAttributedString) {
        let s = attr.string
        let ns = s as NSString
        for m in tagRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            attr.addAttribute(.foregroundColor, value: Appearance.shared.tagColor, range: m.range)
        }
    }

    // MARK: - Input (ink mode owns it; free mode uses native behavior)

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard mode == .ink else { super.insertText(insertString, replacementRange: replacementRange); return }
        let s = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        for ch in s { typeChar(ch) }
        renderInk(); changed()
    }

    override func deleteBackward(_ sender: Any?) {
        guard mode == .ink else { super.deleteBackward(sender); return }
        if caret > 0 {
            var l = Array(live)
            l.remove(at: caret - 1)
            live = String(l)
            caret -= 1
            dirty = true
        }
        renderInk(); changed()
    }

    override func deleteForward(_ sender: Any?) {
        guard mode == .ink else { super.deleteForward(sender); return }
        if caret < live.count {
            var l = Array(live)
            l.remove(at: caret)
            live = String(l)
            dirty = true
        }
        renderInk(); changed()
    }

    override func insertNewline(_ sender: Any?) {
        guard mode == .ink else { super.insertNewline(sender); return }
        if !live.trimmingCharacters(in: .whitespaces).isEmpty { return }   // does nothing mid-bracket
        if let last = paragraphs.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
            paragraphs[paragraphs.count - 1] = rstrip(last) + "  "
            paragraphs.append("")
            live = ""; caret = 0
            dirty = true
        }
        renderInk(); changed()
    }

    override func insertParagraphSeparator(_ sender: Any?) { insertNewline(sender) }

    override func moveLeft(_ sender: Any?) {
        guard mode == .ink else { super.moveLeft(sender); return }
        caret = max(0, caret - 1); renderInk()
    }
    override func moveRight(_ sender: Any?) {
        guard mode == .ink else { super.moveRight(sender); return }
        caret = min(live.count, caret + 1); renderInk()
    }
    override func moveToBeginningOfLine(_ sender: Any?) {
        guard mode == .ink else { super.moveToBeginningOfLine(sender); return }
        caret = 0; renderInk()
    }
    override func moveToEndOfLine(_ sender: Any?) {
        guard mode == .ink else { super.moveToEndOfLine(sender); return }
        caret = live.count; renderInk()
    }

    // Text color is a global appearance setting (Format ▸ Text Color), not a
    // per-selection attribute. Ignore the color panel here so dragging it never
    // recolors glyphs or echoes a stale color back through the shared panel.
    override func changeColor(_ sender: Any?) { /* intentionally no-op */ }

    override func paste(_ sender: Any?) {
        guard mode == .ink else { super.paste(sender); return }
        if let s = NSPasteboard.general.string(forType: .string) {
            for ch in s where ch != "\n" && ch != "\r" { typeChar(ch) }
            renderInk(); changed()
        }
    }

    // Keep the caret pinned inside the live bracket; block clicks into frozen ink.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if mode == .ink {
            let idx = liveCaretIndex()
            super.setSelectedRanges([NSValue(range: NSRange(location: idx, length: 0))], affinity: affinity, stillSelecting: false)
            return
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    private func liveCaretIndex() -> Int {
        var head = 0
        if paragraphs.count > 1 {
            head = (paragraphs[0..<(paragraphs.count - 1)].joined(separator: "\n") + "\n").count
        }
        let lastPara = (paragraphs.last ?? "").count
        return head + lastPara + 1 + caret
    }

    // MARK: - Ink typing model (faithful to inkwell.py)

    private func typeChar(_ ch: Character) {
        let insideTag = liveInsideTag()
        var l = Array(live)
        l.insert(ch, at: caret)
        live = String(l)
        caret += 1
        dirty = true

        // commit gesture: ender + two trailing spaces, at the end, not inside a tag
        if ch == " " && !insideTag && caret == live.count {
            let a = Array(live)
            if a.count >= 3 && a[a.count - 1] == " " && a[a.count - 2] == " " && enders.contains(a[a.count - 3]) {
                if var last = paragraphs.last {
                    if !last.isEmpty && !last.hasSuffix(" ") { last += "  " }
                    last += live
                    paragraphs[paragraphs.count - 1] = last
                }
                live = ""; caret = 0
            }
        }
    }

    private func liveInsideTag() -> Bool {
        let prefix = Array(live)[0..<caret]
        return prefix.filter { $0 == "#" }.count % 2 == 1
    }

    private func rstrip(_ s: String) -> String {
        var t = s
        while let last = t.last, last == " " || last == "\t" || last == "\n" { t.removeLast() }
        return t
    }

    private func changed() {
        onChange?()
    }

    // MARK: - Word count (for the status line)

    func wordCount() -> Int {
        let joined = TextLogic.clean(documentParagraphs().joined(separator: " ") + " " + documentLive())
        return joined.split(whereSeparator: { $0 == " " || $0 == "\n" }).filter { !$0.isEmpty }.count
    }
}
