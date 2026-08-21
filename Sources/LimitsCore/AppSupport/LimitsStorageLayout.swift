import Foundation
import LimitsShared

public enum LimitsCredentialStorage: Hashable, Sendable {
    case systemKeychain
    case memoryOnly
}

public struct LimitsStorageLayout: Hashable, Sendable {
    public let isolatedRoot: URL?
    public let stateDirectory: URL
    public let codexHome: URL
    public let homeDirectory: URL
    public let widgetDirectory: URL?
    public let pricingFixtureDirectory: URL
    public let credentialStorage: LimitsCredentialStorage

    public var isIsolated: Bool { isolatedRoot != nil }
    public var codexAuthURL: URL { codexHome.appending(path: "auth.json") }
    public var claudeGlobalLockURL: URL { stateDirectory.appending(path: "global-claude.lock") }

    public static func production(fileManager: FileManager = .default) -> Self {
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let widgetDirectory = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: LimitsWidgetSnapshotStore.resolvedAppGroupIdentifier()
        )
        return Self(
            isolatedRoot: nil,
            stateDirectory: appSupport.appending(path: "Limits", directoryHint: .isDirectory),
            codexHome: home.appending(path: ".codex", directoryHint: .isDirectory),
            homeDirectory: home,
            widgetDirectory: widgetDirectory,
            pricingFixtureDirectory: appSupport.appending(path: "Limits/Pricing", directoryHint: .isDirectory),
            credentialStorage: .systemKeychain
        )
    }

    public static func isolated(root: URL) -> Self {
        let root = root.standardizedFileURL
        return Self(
            isolatedRoot: root,
            stateDirectory: root.appending(path: "Application Support/Limits", directoryHint: .isDirectory),
            codexHome: root.appending(path: "Codex", directoryHint: .isDirectory),
            homeDirectory: root.appending(path: "Home", directoryHint: .isDirectory),
            widgetDirectory: root.appending(path: "AppGroup", directoryHint: .isDirectory),
            pricingFixtureDirectory: root.appending(path: "Pricing", directoryHint: .isDirectory),
            credentialStorage: .memoryOnly
        )
    }

    public var writableFileURLs: [URL] {
        [
            stateDirectory.appending(path: "state.json"),
            stateDirectory.appending(path: "state.pre-v4.json"),
            stateDirectory.appending(path: "state.lock"),
            stateDirectory.appending(path: "usage.sqlite3"),
            stateDirectory.appending(path: "usage.sqlite3-wal"),
            stateDirectory.appending(path: "usage.sqlite3-shm"),
            stateDirectory.appending(path: "global-claude.lock"),
            stateDirectory.appending(path: "claude-statusline-bridge.sh"),
            stateDirectory.appending(path: "claude-statusline-snapshot.json"),
            stateDirectory.appending(path: "claude-statusline-original.bin"),
            codexAuthURL,
            codexHome.appending(path: ".limits-auth.lock"),
            homeDirectory.appending(path: ".claude/settings.json"),
            widgetDirectory?.appending(path: LimitsWidgetConstants.snapshotDirectoryName)
                .appending(path: LimitsWidgetConstants.snapshotFileName),
        ].compactMap { $0 }
    }

    public func containsEveryWritableFileInIsolatedRoot() -> Bool {
        guard let isolatedRoot else { return false }
        let rootPath = isolatedRoot.standardizedFileURL.path
        return writableFileURLs.allSatisfy { url in
            let path = url.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }
}
