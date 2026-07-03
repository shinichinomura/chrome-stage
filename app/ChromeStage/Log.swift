import OSLog

// ログ基盤。
// 方針(CLAUDE.md): URL やページタイトルなど契約先の機密になり得る情報はログに出さない。
// ウィンドウはタイトルではなく windowId / slot 名で識別して記録する。
enum Log {
    private static let subsystem = "com.shinichinomura.ChromeStage"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    static let ax = Logger(subsystem: subsystem, category: "ax")
    static let stage = Logger(subsystem: subsystem, category: "stage")
    static let recovery = Logger(subsystem: subsystem, category: "recovery")
}
