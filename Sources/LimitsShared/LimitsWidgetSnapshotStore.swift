import Foundation

public enum LimitsWidgetConstants {
    public static let widgetKind = "LimitsCurrentLimitsWidget"
    public static let defaultAppGroupIdentifier = "M94V58FCVP.com.amir.Limits.shared"
    public static let appGroupInfoPlistKey = "LimitsAppGroupIdentifier"
    public static let snapshotDirectoryName = "Widget"
    public static let snapshotFileName = "current-limits.json"
    public static let openURL = URL(string: "limits://open")!
}

public enum LimitsWidgetSnapshotStoreError: LocalizedError, Equatable {
    case missingAppGroupContainer(String)

    public var errorDescription: String? {
        switch self {
        case .missingAppGroupContainer(let identifier):
            return "App Group container is unavailable: \(identifier)"
        }
    }
}

public struct LimitsWidgetSnapshotStore {
    public let appGroupIdentifier: String
    public let baseURL: URL?

    private let fileManager: FileManager

    public init(
        appGroupIdentifier: String = LimitsWidgetSnapshotStore.resolvedAppGroupIdentifier(),
        baseURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.baseURL = baseURL
        self.fileManager = fileManager
    }

    public static func resolvedAppGroupIdentifier(bundle: Bundle = .main) -> String {
        if let value = bundle.object(forInfoDictionaryKey: LimitsWidgetConstants.appGroupInfoPlistKey) as? String,
           !value.isEmpty {
            return value
        }

        return LimitsWidgetConstants.defaultAppGroupIdentifier
    }

    public func readSnapshot() throws -> LimitsWidgetSnapshot? {
        let url = try snapshotURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder.limitsWidget.decode(LimitsWidgetSnapshot.self, from: data)
    }

    public func writeSnapshot(_ snapshot: LimitsWidgetSnapshot) throws {
        let url = try snapshotURL()
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder.limitsWidget.encode(snapshot)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func snapshotURL() throws -> URL {
        let root: URL
        if let baseURL {
            root = baseURL
        } else if let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            root = containerURL
        } else {
            throw LimitsWidgetSnapshotStoreError.missingAppGroupContainer(appGroupIdentifier)
        }

        return root
            .appending(path: LimitsWidgetConstants.snapshotDirectoryName, directoryHint: .isDirectory)
            .appending(path: LimitsWidgetConstants.snapshotFileName)
    }
}

public extension JSONEncoder {
    static var limitsWidget: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var limitsWidget: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
