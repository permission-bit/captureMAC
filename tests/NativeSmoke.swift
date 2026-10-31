import AppKit
import SwiftUI

@main
struct NativeSmoke {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        Localization.resourceURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        precondition(Localization.languages.count == 18)
        precondition(Localization.resolve("system", preferredLanguages: ["fr-CA"]) == "fr")
        precondition(Localization.resolve("system", preferredLanguages: ["en-US"]) == "en")
        precondition(Localization.resolve("system", preferredLanguages: ["zh-CN"]) == "zh-Hans")
        precondition(Localization.resolve("system", preferredLanguages: ["zh-TW"]) == "zh-Hant")
        precondition(Localization.resolve("system", preferredLanguages: ["zz-ZZ"]) == "en")
        let root = output.appendingPathComponent("smoke-data", isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = CaptureModel(previewMode: true, rootURL: root)
        precondition(!model.hasPermission && !model.active)
        model.change(\.fps, 60)
        precondition(model.settings.fps == 60)
        model.change(\.fps, 30)
        let raw = model.takeString(still_library(model.core))!
        precondition(raw == "[]")
        let originalLanguage = model.language
        for language in Localization.languages {
            model.setLanguage(language.id)
            precondition(model.language == language.id)
            precondition(L("capture.record") != "capture.record")
            precondition(Localization.direction == (language.id == "ar" ? .rightToLeft : .leftToRight))
            precondition(!LF("library.count", 3, "1 MB").contains("%@"))
            precondition(!still_started(model.core))
            precondition(model.coreError() == L("error.state"))
        }
        let reopened = CaptureModel(previewMode: true, rootURL: root)
        precondition(reopened.language == model.language)
        model.setLanguage("en")
        model.preflighting = true
        model.setLanguage("de")
        precondition(model.language == "en")
        model.preflighting = false
        model.setLanguage("not-a-language")
        precondition(model.language == "en")
        // Capture only this off-screen view, never the desktop. No TCC access.
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 980, height: 740), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let host = NSHostingView(rootView: ContentView(model: model))
        window.contentView = host
        window.orderFront(nil)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for page in [0, 1] {
                model.page = page
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw CaptureError.message("Native view rendering unavailable")
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let path = output.appendingPathComponent("\(page == 0 ? "capture" : "library")-\(dark ? "dark" : "light").png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: path)
            }
        }
        // Render a minimum-size recording page in every shipped language.
        window.appearance = NSAppearance(named: .aqua)
        model.page = 0
        for language in Localization.languages {
            model.setLanguage(language.id)
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw CaptureError.message("Localized view rendering unavailable")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("capture-\(language.id).png"))
        }
        model.setLanguage(originalLanguage)
        window.orderOut(nil)
        try FileManager.default.removeItem(at: root)
        print("Native smoke passed: Swift ↔ Rust, 18 locales, language persistence, fallback, RTL, translated core errors, light/dark rendering; no screen capture requested.")
    }
}
