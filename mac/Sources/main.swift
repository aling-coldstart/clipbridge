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
    private let panel = ProgressPanel()
    /// Size Windows announced (SENDING) for the next incoming file clip.
    private var expectedIncoming: Int64?

    init() { lastCount = pb.changeCount }

    func start() {
        watcher.onConnected = { DispatchQueue.main.async { self.connected() } }
        watcher.onDisconnected = { DispatchQueue.main.async { self.online = false } }
        watcher.onClip = { id in
            DispatchQueue.main.async {
                let expected = self.expectedIncoming
                self.expectedIncoming = nil
                self.io.async { self.receive(id, expectedBytes: expected) }
            }
        }
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
        let large = clip.bytes >= Config.notifyBytes
        if large {
            panel.begin("发送 \(clip.fileURLs.count) 个文件到 Windows", detail: "准备中…")
        }
        let progress: ((Int64) -> Void)? = large ? { sent in
            DispatchQueue.main.async { self.panel.update(done: sent, total: clip.bytes) }
        } : nil
        io.async {
            let ok = Remote.push(clip, progress: progress)
            if ok { log("mac -> win: \(clip.kind.rawValue) (\(clip.id))") }
            DispatchQueue.main.async {
                if large {
                    self.panel.finish(ok ? "已到 Windows，可以粘贴了" : "发送失败，连上后会重试", succeeded: ok)
                }
                if !ok, self.pending == nil { self.pending = clip }
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
        } else if parts.count == 3, parts[0] == "SENDING", let count = Int(parts[1]), let size = Int64(parts[2]) {
            log("windows is sending \(count) files, \(size) bytes")
            expectedIncoming = size
            panel.begin("从 Windows 接收 \(count) 个文件", detail: "Windows 准备中…（\(formatBytes(size))）")
            // If the clip never shows up (copy failed on Windows), don't spin forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + Config.incomingTimeout) {
                guard self.expectedIncoming == size else { return }
                self.expectedIncoming = nil
                self.panel.finish("Windows 没有发来文件，详见 Windows 日志", succeeded: false)
            }
        } else {
            log("windows notice: \(text)")
        }
    }

    /// Runs on `io`: download, then apply on the main thread. `expectedBytes` is set
    /// when Windows announced a large transfer; the panel then tracks the download.
    private func receive(_ id: String, expectedBytes: Int64?) {
        let progress: ((Int64) -> Void)? = expectedBytes.map { total in { landed in
            DispatchQueue.main.async { self.panel.update(done: landed, total: total) }
        } }
        guard let dir = Remote.fetch(id: id, progress: progress) else {
            if expectedBytes != nil {
                DispatchQueue.main.async { self.panel.finish("接收失败，详见日志", succeeded: false) }
            }
            return
        }
        DispatchQueue.main.async {
            do {
                let kind = try applyClip(at: dir, to: self.pb)
                self.ownCount = self.pb.changeCount
                self.lastCount = self.ownCount
                log("win -> mac: \(kind.rawValue) (\(id))")
                if expectedBytes != nil { self.panel.finish("已到 Mac，可以粘贴了", succeeded: true) }
            } catch {
                log("apply \(id) failed: \(error)")
                if expectedBytes != nil { self.panel.finish("放到剪贴板失败，详见日志", succeeded: false) }
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
signal(SIGPIPE, SIG_IGN)   // a dead ssh must fail the write, not kill the agent
// An accessory app: no Dock icon or menu bar, but it may show the progress panel.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let sync = ClipSync()
sync.start()
app.run()
