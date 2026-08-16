// TextLogic.swift
// Faithful Swift port of the pure text logic in inkwell.py.
// No AppKit here so it stays testable and byte-compatible with the Terminal app.

import Foundation

enum TextLogic {

    static let enders = ".?!"

    // Match a #tag#: hashes around text that has no hash or newline inside.
    private static let tagRegex = try! NSRegularExpression(pattern: "#([^#\\n]*)#")

    /// True if the text contains an actual letter or digit (not just spaces/punctuation).
    static func hasWords(_ text: String) -> Bool {
        return text.range(of: "[A-Za-z0-9]", options: .regularExpression) != nil
    }

    /// Strip tags, squeeze runs of spaces, drop spaces before punctuation.
    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "#[^#\\n]*#", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+([.,?!;:])", with: "$1", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split a committed paragraph into sentence units.
    /// A unit ends at a run of sentence-enders followed by two spaces (the commit
    /// gesture). Each returned unit keeps its ender and trailing spaces.
    static func splitSentences(_ paragraph: String) -> [String] {
        let chars = Array(paragraph)
        let n = chars.count
        var units: [String] = []
        var start = 0
        var i = 0
        while i < n {
            if enders.contains(chars[i]) {
                var j = i
                while j < n && enders.contains(chars[j]) { j += 1 }   // consume e.g. "..."
                if j + 1 < n && chars[j] == " " && chars[j + 1] == " " {   // "  " -> commit
                    units.append(String(chars[start..<(j + 2)]))
                    start = j + 2
                    i = j + 2
                    continue
                }
                i = j
            } else {
                i += 1
            }
        }
        if start < n {
            units.append(String(chars[start..<n]))
        }
        return units
    }

    /// True if no sentence in the paragraph carries any actual words.
    static func paragraphIsTagOnly(_ units: [String]) -> Bool {
        return !units.isEmpty && units.allSatisfy { !hasWords(clean($0)) }
    }

    private struct TagMatch { let name: String; let start: Int; let end: Int }

    /// Find #tag# matches in a unit, returning name plus character offsets.
    private static func tagMatches(in unit: String) -> [TagMatch] {
        let ns = unit as NSString
        let matches = tagRegex.matches(in: unit, range: NSRange(location: 0, length: ns.length))
        return matches.map { m in
            let name = ns.substring(with: m.range(at: 1))
            // Convert utf16 offsets to Character offsets so slicing matches Python.
            let startChar = characterOffset(in: unit, utf16Offset: m.range.location)
            let endChar = characterOffset(in: unit, utf16Offset: m.range.location + m.range.length)
            return TagMatch(name: name, start: startChar, end: endChar)
        }
    }

    private static func characterOffset(in s: String, utf16Offset: Int) -> Int {
        let idx = s.utf16.index(s.utf16.startIndex, offsetBy: utf16Offset)
        return s.distance(from: s.startIndex, to: idx.samePosition(in: s) ?? s.startIndex)
    }

    /// Walk committed paragraphs and return (tagName, referencedText) pairs.
    /// Scope ladder:
    ///   1. mid-sentence tag    -> the text before it in that sentence
    ///   2. end-of-sentence tag -> that + every earlier sentence in the paragraph
    ///   3. tag-only sentence   -> every earlier sentence in the paragraph
    ///   4. tag-only paragraph  -> all text in every earlier paragraph
    static func extractTagRecords(_ paragraphs: [String]) -> [(name: String, scope: String)] {
        var records: [(String, String)] = []
        for (pIdx, para) in paragraphs.enumerated() {
            let units = splitSentences(para)
            let tagOnlyPara = paragraphIsTagOnly(units)
            for (sIdx, unit) in units.enumerated() {
                let unitChars = Array(unit)
                for m in tagMatches(in: unit) {
                    let name = m.name.trimmingCharacters(in: .whitespaces)
                    if name.isEmpty { continue }
                    let before = String(unitChars[0..<m.start])
                    let after = String(unitChars[m.end..<unitChars.count])
                    let earlier = units[0..<sIdx].joined(separator: " ")
                    let scope: String
                    if hasWords(after) {                        // 1: mid-sentence
                        scope = clean(before)
                    } else if hasWords(before) {                // 2: end of sentence
                        scope = clean(earlier + " " + before)
                    } else if tagOnlyPara {                     // 4: tag-only paragraph
                        scope = clean(paragraphs[0..<pIdx].joined(separator: " "))
                    } else {                                    // 3: tag-only sentence
                        scope = clean(earlier)
                    }
                    records.append((name.lowercased(), scope))
                }
            }
        }
        return records
    }

    /// The clean, printable document: tags stripped, tag-only bits removed.
    static func renderExport(_ paragraphs: [String], live: String = "") -> String {
        var out: [String] = []
        for para in paragraphs {
            var kept: [String] = []
            for unit in splitSentences(para) {
                let c = clean(unit)
                if hasWords(c) { kept.append(c) }
            }
            if !kept.isEmpty {
                out.append("\t" + kept.joined(separator: "  "))
            }
        }
        if !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let c = clean(live)
            if hasWords(c) {
                if !out.isEmpty {
                    out[out.count - 1] = out[out.count - 1] + "  " + c
                } else {
                    out.append("\t" + c)
                }
            }
        }
        return out.joined(separator: "\n\n") + (out.isEmpty ? "" : "\n")
    }

    /// Tag names present in the current document (lowercased).
    static func collectTagNames(_ paragraphs: [String], live: String) -> Set<String> {
        var names = Set<String>()
        for chunk in paragraphs + [live] {
            let ns = chunk as NSString
            for m in tagRegex.matches(in: chunk, range: NSRange(location: 0, length: ns.length)) {
                let n = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
                if !n.isEmpty { names.insert(n) }
            }
        }
        return names
    }

    /// Parse a saved .md/.txt file the way the Terminal app does: split on blank
    /// lines, strip the leading tab, and return frozen ink paragraphs (each with a
    /// trailing two spaces, ready to write on from).
    static func loadFrozenParagraphs(from raw: String) -> [String] {
        var loaded: [String] = []
        for block in raw.components(separatedBy: "\n\n") {
            var b = block.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            while b.hasPrefix("\t") { b.removeFirst() }
            b = b.trimmingCharacters(in: .whitespacesAndNewlines)
            if !b.isEmpty {
                loaded.append(b + "  ")
            }
        }
        return loaded.isEmpty ? [""] : loaded
    }
}
