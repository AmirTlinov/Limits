import AppKit
import LimitsCore
import Foundation

enum TrayStatusIconAsset {
    static func image(for provider: TrayStatusProvider) -> NSImage? {
        guard let url = resourceURL(for: provider) else { return nil }
        return templateImage(at: url)
    }

    /// The rail shows each provider's brand mark, where the menu bar deliberately keeps a
    /// plainer glyph that stays legible at status-item size.
    static func railImage(for provider: TrayStatusProvider) -> NSImage? {
        let resourceName = switch provider {
        case .codex: "openai"
        case .claude: "claude"
        }

        guard let url = resourceURL(named: resourceName, in: .main) else {
            return image(for: provider)
        }
        return templateImage(at: url)
    }

    private static func templateImage(at url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let templateImage = image.copy() as? NSImage ?? image
        templateImage.isTemplate = true
        return templateImage
    }

    static func resourceURL(for provider: TrayStatusProvider) -> URL? {
        let resourceName = switch provider {
        case .codex:
            "codex"
        case .claude:
            "claude"
        }

        if let url = resourceURL(named: resourceName, in: .main) {
            return url
        }

        return nil
    }

    private static func resourceURL(named resourceName: String, in bundle: Bundle) -> URL? {
        if let url = bundle.url(
            forResource: resourceName,
            withExtension: "svg",
            subdirectory: "TrayIcons"
        ) {
            return url
        }

        return bundle.url(forResource: resourceName, withExtension: "svg")
    }
}
