// Library.swift
// File locations and I/O, identical to inkwell.py so the two apps share one library.

import Foundation

/// An unsaved draft rescued from a previous (likely crashed) session.
struct RecoveredDraft {
    let id: String
    let mode: EditMode
    let paragraphs: [String]
}

enum Library {

    /// Your writing folder: ~/Documents/Inkwell, or wherever INKWELL_DIR points.
    static let writingDir: String = {
        let env = ProcessInfo.processInfo.environment["INKWELL_DIR"] ?? ""
        if !env.isEmpty { return (env as NSString).expandingTildeInPath }
        return (NSHomeDirectory() as NSString).appendingPathComponent("Documents/Inkwell")
    }()
    static var tagsDir: String { (writingDir as NSString).appendingPathComponent("Tags") }
    // Per-document recovery lives in its own folder so several open tabs never
    // clobber each other's rescue file. (Distinct from the Terminal app's single
    // .inkwell-recovery.md, which we leave alone.)
    static var recoveryDir: String { (writingDir as NSString).appendingPathComponent(".inkwell-recovery") }

    // Inkwell refuses to save anywhere outside these roots: your writing folder,
    // plus anything listed in INKWELL_ALLOWED_ROOTS (colon-separated).
    static let allowedRoots: [String] = {
        var roots = [writingDir]
        let extra = ProcessInfo.processInfo.environment["INKWELL_ALLOWED_ROOTS"] ?? ""
        for part in extra.split(separator: ":") where !part.isEmpty {
            roots.append((String(part) as NSString).expandingTildeInPath)
        }
        return roots
    }()

    static func withinAllowed(_ path: String) -> Bool {
        let full = (path as NSString).standardizingPath
        return allowedRoots.contains { full == $0 || full.hasPrefix($0 + "/") }
    }

    static func ensureWritingDir() {
        try? FileManager.default.createDirectory(atPath: writingDir, withIntermediateDirectories: true)
    }

    /// Files the Open panel should list (mirrors do_open in the Terminal app).
    static func libraryFiles() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: writingDir) else { return [] }
        return names.filter { n in
            let l = n.lowercased()
            return (l.hasSuffix(".md") || l.hasSuffix(".txt")) && !n.hasPrefix(".")
        }.sorted()
    }

    /// Write the clean prose plus (idempotently) every tag file. Returns the final path.
    @discardableResult
    static func save(paragraphs: [String], live: String, to path: String) throws -> String {
        ensureWritingDir()
        guard withinAllowed(path) else {
            throw NSError(domain: "Inkwell", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "can't save there — outside your writing folders"])
        }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let prose = TextLogic.renderExport(paragraphs, live: live)
        try prose.write(toFile: path, atomically: true, encoding: .utf8)
        writeTagFiles(paragraphs: paragraphs, sourceName: (path as NSString).lastPathComponent)
        return path
    }

    /// One .md per tag in the Tags folder; re-saving from the same source replaces
    /// that source's prior entries (tracked with hidden <!-- src:file --> markers).
    static func writeTagFiles(paragraphs: [String], sourceName: String) {
        let recs = TextLogic.extractTagRecords(paragraphs)
        guard !recs.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: tagsDir, withIntermediateDirectories: true)
        let stamp = stampNow()
        var byName: [String: [String]] = [:]
        for (name, scope) in recs { byName[name, default: []].append(scope) }
        for (name, scopes) in byName {
            let path = (tagsDir as NSString).appendingPathComponent(name + ".md")
            var existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let pattern = "<!-- src:" + NSRegularExpression.escapedPattern(for: sourceName) + " -->\\n(?:.*\\n)*?\\n"
            if let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                let ns = existing as NSString
                existing = re.stringByReplacingMatches(in: existing, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            }
            var blocks: [String]
            if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks = ["# " + name + "\n\n"]
            } else {
                blocks = [rstrip(existing) + "\n\n"]
            }
            for scope in scopes {
                blocks.append("<!-- src:" + sourceName + " -->\n**" + sourceName + "** · " + stamp + "\n\n" + scope + "\n\n")
            }
            try? blocks.joined().write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func recoveryPath(_ id: String) -> String {
        (recoveryDir as NSString).appendingPathComponent(id + ".md")
    }

    static func removeRecovery(id: String) {
        try? FileManager.default.removeItem(atPath: recoveryPath(id))
    }

    /// Write one document's rescue file. Stored faithfully (tags kept, in-progress
    /// live text appended) so nothing typed is lost — unlike the tag-stripping export.
    static func writeRecovery(id: String, mode: EditMode, paragraphs: [String], live: String) {
        try? FileManager.default.createDirectory(atPath: recoveryDir, withIntermediateDirectories: true)
        var paras = paragraphs
        let liveTrimmed = live.trimmingCharacters(in: .whitespaces)
        if !liveTrimmed.isEmpty { paras.append(live) }
        let body = paras
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\t" + $0 }
            .joined(separator: "\n\n")
        if body.isEmpty { removeRecovery(id: id); return }
        let header = "<!-- inkwell-mode: " + (mode == .ink ? "ink" : "free") + " -->\n"
        try? (header + body + "\n").write(toFile: recoveryPath(id), atomically: true, encoding: .utf8)
    }

    /// Every rescued draft still on disk (i.e. from a session that didn't close cleanly).
    static func pendingRecoveries() -> [RecoveredDraft] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: recoveryDir) else { return [] }
        var drafts: [RecoveredDraft] = []
        for name in names.sorted() where name.hasSuffix(".md") {
            let path = (recoveryDir as NSString).appendingPathComponent(name)
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var mode: EditMode = .ink
            var body = raw
            if raw.hasPrefix("<!-- inkwell-mode:") {
                if let nl = raw.firstIndex(of: "\n") {
                    let header = String(raw[..<nl])
                    if header.contains("free") { mode = .free }
                    body = String(raw[raw.index(after: nl)...])
                }
            }
            let paras = TextLogic.loadFrozenParagraphs(from: body)
            let nonEmpty = paras.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard nonEmpty else { continue }
            let id = (name as NSString).deletingPathExtension
            drafts.append(RecoveredDraft(id: id, mode: mode, paragraphs: paras))
        }
        return drafts
    }

    static func defaultFileName() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        return "inkwell-" + df.string(from: Date()) + ".md"
    }

    private static func stampNow() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df.string(from: Date())
    }

    private static func rstrip(_ s: String) -> String {
        var t = s
        while let last = t.last, last == "\n" || last == " " || last == "\t" { t.removeLast() }
        return t
    }
}
