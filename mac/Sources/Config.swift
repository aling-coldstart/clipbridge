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
    static let maxFileBytes: Int64 = 200 * 1024 * 1024
    static let keepClips = 10
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

/// Keep only the newest `keep` entries of `dir`.
func pruneClips(in dir: URL, keep: Int = Config.keepClips) {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
    for old in items.sorted(by: { modified($0) > modified($1) }).dropFirst(keep) {
        try? fm.removeItem(at: old)
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
