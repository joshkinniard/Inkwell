// Appearance.swift
// The *live* appearance (font + colors) shown right now, plus a store of named
// appearance presets. Live edits (Format ▸ Font/Colors) change the current session
// only; they persist to disk when saved as the Default or as a named appearance.
// On launch the Default preset is loaded (or the built-in look if none is saved).

import AppKit

/// A serializable snapshot of an appearance (colors as sRGB [r,g,b]).
struct AppearanceSpec: Codable {
    var fontName: String
    var fontSize: Double
    var text: [Double]
    var bg: [Double]
    var tag: [Double]
}

final class Appearance {
    static let shared = Appearance()

    private let d = UserDefaults.standard
    private let presetsKey = "appearancePresets"
    let defaultName = "Default"

    // Live values (in memory; not persisted until saved as a preset).
    var font: NSFont
    var textColor: NSColor
    var backgroundColor: NSColor
    var tagColor: NSColor

    /// Bracket color derives from the text color; convert to sRGB first since a
    /// catalog/pattern color can't take an alpha component.
    var bracketColor: NSColor {
        (textColor.usingColorSpace(.sRGB) ?? textColor).withAlphaComponent(0.4)
    }

    private init() {
        // Prefer a saved Default preset; otherwise fall back to the user's pre-preset
        // colors (migrated from the old keys) so an existing look isn't lost; else built-in.
        let spec = Appearance.storedPresets()[defaultName] ?? Appearance.migrateLegacy() ?? Appearance.builtIn
        font = Appearance.makeFont(spec)
        textColor = Appearance.color(spec.text)
        backgroundColor = Appearance.color(spec.bg)
        tagColor = Appearance.color(spec.tag)
    }

    /// Read the appearance saved before the preset system existed (individual keys),
    /// so a user who had customized colors keeps them. Returns nil if none were saved.
    private static func migrateLegacy() -> AppearanceSpec? {
        let d = UserDefaults.standard
        guard d.data(forKey: "bgColor") != nil || d.data(forKey: "textColor") != nil || d.string(forKey: "fontName") != nil else {
            return nil
        }
        func legacyColor(_ key: String) -> [Double]? {
            guard let data = d.data(forKey: key),
                  let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data),
                  let s = c.usingColorSpace(.sRGB) else { return nil }
            return [Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent)]
        }
        let base = builtIn
        return AppearanceSpec(
            fontName: d.string(forKey: "fontName") ?? base.fontName,
            fontSize: d.double(forKey: "fontSize") > 0 ? d.double(forKey: "fontSize") : base.fontSize,
            text: legacyColor("textColor") ?? base.text,
            bg:   legacyColor("bgColor") ?? base.bg,
            tag:  legacyColor("tagColor") ?? base.tag)
    }

    // MARK: - Built-in defaults

    static var builtIn: AppearanceSpec {
        AppearanceSpec(fontName: "Iowan Old Style", fontSize: 22,
                       text: [0.82, 0.82, 0.82],
                       bg:   [0.09, 0.09, 0.09],
                       tag:  comps(.systemPurple))
    }

    // MARK: - Presets

    /// Named presets, excluding the special "Default", sorted for the menu.
    func presetNames() -> [String] {
        presets().keys.filter { $0 != defaultName }.sorted()
    }

    func hasDefault() -> Bool { presets()[defaultName] != nil }

    /// Snapshot the current live appearance under `name`.
    func savePreset(name: String) {
        var all = presets()
        all[name] = currentSpec()
        persist(all)
    }

    func saveAsDefault() { savePreset(name: defaultName) }

    /// Make `name` the live appearance ("Default" falls back to built-in if unsaved).
    func loadPreset(name: String) {
        if name == defaultName {
            apply(presets()[defaultName] ?? Appearance.builtIn)
        } else if let spec = presets()[name] {
            apply(spec)
        }
    }

    func deletePreset(name: String) {
        guard name != defaultName else { return }
        var all = presets()
        all.removeValue(forKey: name)
        persist(all)
    }

    // MARK: - Spec <-> live

    private func currentSpec() -> AppearanceSpec {
        AppearanceSpec(fontName: font.fontName, fontSize: Double(font.pointSize),
                       text: Appearance.comps(textColor),
                       bg:   Appearance.comps(backgroundColor),
                       tag:  Appearance.comps(tagColor))
    }

    private func apply(_ spec: AppearanceSpec) {
        font = Appearance.makeFont(spec)
        textColor = Appearance.color(spec.text)
        backgroundColor = Appearance.color(spec.bg)
        tagColor = Appearance.color(spec.tag)
    }

    // MARK: - Storage

    private func presets() -> [String: AppearanceSpec] { Appearance.storedPresets() }

    private func persist(_ dict: [String: AppearanceSpec]) {
        if let data = try? JSONEncoder().encode(dict) { d.set(data, forKey: presetsKey) }
    }

    private static func storedPresets() -> [String: AppearanceSpec] {
        guard let data = UserDefaults.standard.data(forKey: "appearancePresets"),
              let dict = try? JSONDecoder().decode([String: AppearanceSpec].self, from: data) else { return [:] }
        return dict
    }

    // MARK: - Color helpers

    private static func comps(_ c: NSColor) -> [Double] {
        let s = c.usingColorSpace(.sRGB) ?? NSColor(calibratedWhite: 0.5, alpha: 1)
        return [Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent)]
    }

    private static func color(_ a: [Double]) -> NSColor {
        let v = a.count == 3 ? a : [0.5, 0.5, 0.5]
        return NSColor(srgbRed: CGFloat(v[0]), green: CGFloat(v[1]), blue: CGFloat(v[2]), alpha: 1)
    }

    private static func makeFont(_ spec: AppearanceSpec) -> NSFont {
        NSFont(name: spec.fontName, size: CGFloat(spec.fontSize)) ?? NSFont.systemFont(ofSize: CGFloat(spec.fontSize))
    }
}
