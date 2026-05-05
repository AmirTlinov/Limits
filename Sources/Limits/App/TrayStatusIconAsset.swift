import AppKit
import Foundation

enum TrayStatusIconAsset {
    static func image(for provider: TrayStatusProvider) -> NSImage? {
        guard
            let url = resourceURL(for: provider),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }

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

        for bundle in [Bundle.main, Bundle.module] {
            if let url = bundle.url(
                forResource: resourceName,
                withExtension: "svg",
                subdirectory: "TrayIcons"
            ) {
                return url
            }

            if let url = bundle.url(forResource: resourceName, withExtension: "svg") {
                return url
            }
        }

        return nil
    }
}
