import Foundation

public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// ~/Library/Application Support/Goldie (created on first use).
    public static var supportDir: URL {
        let dir = home.appendingPathComponent("Library/Application Support/Goldie", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Append-only log written by `goldiectl hook` (one JSON object per line).
    public static var hookEventsFile: URL { supportDir.appendingPathComponent("cursor-hook-events.jsonl") }

    public static var configFile: URL { home.appendingPathComponent(".config/goldie/config.json") }

    /// Cursor's global state DB (VS Code-style SQLite). Composer threads live in table `cursorDiskKV`.
    public static var cursorStateDB: URL {
        home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    public static var cursorHooksFile: URL { home.appendingPathComponent(".cursor/hooks.json") }
}
