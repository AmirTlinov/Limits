import OSLog

enum RuntimeLog {
    static let subsystem = "com.amir.Limits"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let tray = Logger(subsystem: subsystem, category: "tray")
    static let window = Logger(subsystem: subsystem, category: "window")
}
