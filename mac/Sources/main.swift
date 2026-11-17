import AppKit

/// Owns sync state. Everything here runs on the main thread; transfers run on `io`.
final class ClipSync {
    private let pb = NSPasteboard.general
    private let io = DispatchQueue(label: "clipbridge.io")
    private let watcher = Watcher()
    private var lastCount: Int
    private var ownCount = -1
    private var online = false
    private var pending: OutgoingClip?

    init() { lastCount = pb.changeCount }

    func start() {
        watcher.onConnected = { DispatchQueue.main.async { self.connected() } }
        watcher.onDisconnected = { DispatchQueue.main.async { self.online = false } }
        watcher.onClip = { id in self.io.async { self.receive(id) } }
        watcher.onNotice = { text in DispatchQueue.main.async { self.remoteNotice(text) } }
        watcher.start()
        Timer.scheduledTimer(withTimeInterval: Config.pollInterval, repeats: true) { _ in self.poll() }
        log("clipbridge started, host \(Config.host)")
    }

    private func connected() {
        online = true
        io.async { Remote.ensureListener() }
        if let clip = pending {
            pending = nil
            send(clip)
        }
    }

    private func poll() {
        let count = pb.changeCount
        guard count != lastCount else { return }
        lastCount = count
        guard count != ownCount else { return }   // change we made ourselves
        do {
            switch try captureClip(from: pb) {
            case .skipped(let reason):
                log("skip: \(reason)")
            case .tooLarge(let size):
                tooLarge(size, from: "Mac")
            case .clip(let clip):
                if online {
                    send(clip)
                } else {
                    pending = clip
                    log("offline: holding \(clip.kind.rawValue) clip until reconnect")
                }
                pruneClips(in: Config.outDir)
            }
        } catch {
            log("capture failed: \(error)")
        }
    }

    private func send(_ clip: OutgoingClip) {
        io.async {
            if Remote.push(clip) {
                log("mac -> win: \(clip.kind.rawValue) (\(clip.id))")
            } else {
                DispatchQueue.main.async { if self.pending == nil { self.pending = clip } }
            }
        }
    }

    private func tooLarge(_ size: Int64, from side: String) {
        log("skip: \(side) files \(size) bytes > limit \(Config.maxFileBytes)")
        notify("\(side) 上复制的文件太大（\(formatBytes(size))，上限 \(formatBytes(Config.maxFileBytes))），未同步")
    }

    /// Windows reported something it could not sync, e.g. "TOOLARGE <bytes>".
    func remoteNotice(_ text: String) {
        let parts = text.split(separator: " ")
        if parts.count == 2, parts[0] == "TOOLARGE", let size = Int64(parts[1]) {
            tooLarge(size, from: "Windows")
        } else {
            log("windows notice: \(text)")
        }
    }

    /// Runs on `io`: download, then apply on the main thread.
    private func receive(_ id: String) {
        guard let dir = Remote.fetch(id: id) else { return }
        DispatchQueue.main.async {
            do {
                let kind = try applyClip(at: dir, to: self.pb)
                self.ownCount = self.pb.changeCount
                self.lastCount = self.ownCount
                log("win -> mac: \(kind.rawValue) (\(id))")
            } catch {
                log("apply \(id) failed: \(error)")
            }
            pruneClips(in: Config.recvDir)
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
truncateLogIfLarge()
_ = Config.host  // fail fast when not configured
for dir in [Config.outDir, Config.recvDir] {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}
// Remove control sockets left by instances that are no longer running.
let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
for name in (try? FileManager.default.contentsOfDirectory(atPath: sshDir.path)) ?? [] where name.hasPrefix("clipbridge-") {
    let parts = name.split(separator: "-")
    let ownerAlive = parts.count >= 3 && Int32(parts[1]).map { kill($0, 0) == 0 } == true
    if !ownerAlive { try? FileManager.default.removeItem(at: sshDir.appendingPathComponent(name)) }
}
let sync = ClipSync()
sync.start()
RunLoop.main.run()
