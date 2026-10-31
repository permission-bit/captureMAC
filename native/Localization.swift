import Foundation
import SwiftUI

/// Native .lproj resources with an explicit English fallback. Accessed on the
/// main thread by the UI; no network translation or downloaded language packs.
enum Localization {
    struct Language: Identifiable {
        let id: String
        let name: String
    }
    static let languages: [Language] = [
        .init(id: "en", name: "English"), .init(id: "de", name: "Deutsch"),
        .init(id: "es", name: "Español"), .init(id: "fr", name: "Français"),
        .init(id: "it", name: "Italiano"), .init(id: "pt-BR", name: "Português (Brasil)"),
        .init(id: "nl", name: "Nederlands"), .init(id: "pl", name: "Polski"),
        .init(id: "ru", name: "Русский"), .init(id: "uk", name: "Українська"),
        .init(id: "tr", name: "Türkçe"), .init(id: "ar", name: "العربية"),
        .init(id: "hi", name: "हिन्दी"), .init(id: "zh-Hans", name: "简体中文"),
        .init(id: "zh-Hant", name: "繁體中文"), .init(id: "ja", name: "日本語"),
        .init(id: "ko", name: "한국어"), .init(id: "id", name: "Bahasa Indonesia")
    ]
    static var resourceURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL {
        didSet { bundles.removeAll() }
    }
    private static var bundles: [String: Bundle] = [:]
    static private(set) var preference = "system"
    static var identifier: String { resolve(preference, preferredLanguages: Locale.preferredLanguages) }
    static var locale: Locale { Locale(identifier: identifier) }
    static var direction: LayoutDirection { identifier == "ar" ? .rightToLeft : .leftToRight }
    static func resolve(_ preference: String, preferredLanguages: [String]) -> String {
        let codes = languages.map(\.id)
        if codes.contains(preference) { return preference }
        return Bundle.preferredLocalizations(from: codes, forPreferences: preferredLanguages).first ?? "en"
    }
    static func select(_ value: String) {
        preference = value == "system" || languages.contains(where: { $0.id == value }) ? value : "system"
    }
    static func bundle(for identifier: String) -> Bundle? {
        if let cached = bundles[identifier] { return cached }
        guard let bundle = Bundle(url: resourceURL.appendingPathComponent("\(identifier).lproj", isDirectory: true)) else { return nil }
        bundles[identifier] = bundle
        return bundle
    }
    static func text(_ key: String) -> String {
        let fallback = bundle(for: "en")?.localizedString(forKey: key, value: key, table: nil) ?? key
        return bundle(for: identifier)?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
    }
    static func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(locale))
    }
}

func L(_ key: String) -> String { Localization.text(key) }
func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Localization.locale, arguments: arguments)
}
