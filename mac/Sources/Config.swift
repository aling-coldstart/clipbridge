import Foundation

enum Config {
    /// `user@host` of the Windows machine, from the CLIPBRIDGE_HOST environment variable
    /// (set by install.sh in the launchd agent).
    static let host: String = {
        guard let value = ProcessInfo.processInfo.environment["CLIPBRIDGE_HOST"], !value.isEmpty else {
            FileHandle.standardError.write(Data("CLIPBRIDGE_HOST is not set (expected user@windows-host)\n".utf8))
            exit(64)
        }
        return value
    }()

    static let pollInterval: TimeInterval = 0.5
    static let minBackoff: TimeInterval = 2
    static let maxBackoff: TimeInterval = 60
    /// Largest clip we sync, from CLIPBRIDGE_MAX_MB (default 2048). Also caps how much
    /// older clips may keep on disk; the newest clip is always kept.
    static let maxFileBytes: Int64 = {
        let raw = ProcessInfo.processInfo.environment["CLIPBRIDGE_MAX_MB"] ?? ""
        let mb = Int64(raw).flatMap { $0 > 0 ? $0 : nil } ?? 2048
        return mb * 1024 * 1024
    }()
    static let keepClips = 10
    /// File copies at least this big get "transferring" / "ready to paste" notifications.
    static let notifyBytes: Int64 = 20 * 1024 * 1024
    static let maxLogBytes: UInt64 = 5 * 1024 * 1024

    /// Folder name under %USERPROFILE% on Windows, and the scheduled task that runs the listener.
    static let remoteDir = "clipbridge"
    static let windowsTask = "ClipBridge"

    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let dataDir = home.appendingPathComponent(".local/share/clipbridge")
    static let outDir = dataDir.appendingPathComponent("out")
    static let recvDir = dataDir.appendingPathComponent("recv")
    static let logFile = home.appendingPathComponent("Library/Logs/clipbridge.log")

    /// Per-process socket so a second instance never clobbers a running one.
    static let controlPath = "~/.ssh/clipbridge-\(getpid())-%C"

    /// Options for one-shot ssh/scp calls: reuse the watcher's connection when it exists.
    static let sshOptions = [
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
        "-o", "ControlMaster=no", "-o", "ControlPath=\(controlPath)",
    ]
}

private let stampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    print("\(stampFormatter.string(from: Date())) \(message)")
    fflush(stdout)
}

func newClipID(prefix: String) -> String {
    "\(prefix)\(Int(Date().timeIntervalSince1970 * 1000))"
}

/// Keep the newest entry of `dir` (the pasteboard may still point at its files), plus
/// older ones while there are at most `keep` and they total no more than `maxBytes`.
func pruneClips(in dir: URL, keep: Int = Config.keepClips, maxBytes: Int64 = Config.maxFileBytes) {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
    var total: Int64 = 0
    for (index, item) in items.sorted(by: { modified($0) > modified($1) }).enumerated() {
        total += diskSize(of: item)
        if index > 0 && (index >= keep || total > maxBytes) {
            try? fm.removeItem(at: item)
        }
    }
}

/// Bytes used by a file or folder; symlinks count as themselves, not their targets.
func diskSize(of url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
    guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in walker {
        guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
        total += Int64(values.fileSize ?? 0)
    }
    return total
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Show a macOS notification. Text goes in as an argument, never into the script source.
func notify(_ message: String) {
    let script = "on run argv\ndisplay notification (item 1 of argv) with title \"ClipBridge\"\nend run"
    DispatchQueue.global(qos: .utility).async {
        let result = runTool("/usr/bin/osascript", ["-e", script, message])
        if !result.ok { log("notification failed: \(result.output)") }
    }
}

/// launchd appends to the log forever; start fresh once it passes the size cap.
func truncateLogIfLarge() {
    let path = Config.logFile.path
    guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64,
          size > Config.maxLogBytes,
          let handle = FileHandle(forWritingAtPath: path) else { return }
    try? handle.truncate(atOffset: 0)
    try? handle.close()
}
