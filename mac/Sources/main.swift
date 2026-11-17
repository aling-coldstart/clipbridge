import AppKit

/// A counter shared with the io queue: each new copy bumps it, and a transfer that
/// started under an older value is cancelled.
final class Generation {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    func isCurrent(_ candidate: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return candidate == value
    }
}

/// Owns sync state. Everything here runs on the main thread; transfers run on `io`.
final class ClipSync {
    private let pb = NSPasteboard.general
    private let io = DispatchQueue(label: "clipbridge.io")
    private let watcher = Watcher()
    private let panel = ProgressPanel()
    private let outgoing = Generation()
    private let incoming = Generation()
    private var lastCount: Int
    private var ownCount = -1
    private var online = false
    private var pending: OutgoingClip?
    /// A large Windows copy that was announced (SENDING) and whose clip hasn't arrived.
    private var announced: (bytes: Int64, token: Int)?

    init() { lastCount = pb.changeCount }

    func start() {
        watcher.onConnected = { DispatchQueue.main.async { self.connected() } }
        watcher.onDisconnected = { DispatchQueue.main.async { self.online = false } }
        watcher.onClip = { id in DispatchQueue.main.async { self.clipArrived(id) } }
        watcher.onNotice = { text in DispatchQueue.main.async { self.remoteNotice(text) } }
        watcher.start()
        Timer.scheduledTimer(withTimeInterval: Config.pollInterval, repeats: true) { _ in self.poll() }
        Timer.scheduledTimer(withTimeInterval: Config.expiryCheckInterval, repeats: true) { _ in self.pruneAll() }
        pruneAll()
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

    private func pruneAll() {
        pruneClips(in: Config.outDir)
        pruneClips(in: Config.recvDir)
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
                // The latest copy on either machine wins: drop any download from Windows.
                _ = incoming.next()
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

    /// Push to Windows. A newer copy cancels this one, queued or in flight.
    private func send(_ clip: OutgoingClip) {
        let generation = outgoing.next()
        let large = clip.bytes >= Config.notifyBytes
        let token = large ? panel.begin("发送 \(clip.fileURLs.count) 个文件到 Windows", detail: "准备中…") : nil
        let progress: ((Int64) -> Void)? = token.map { token in { sent in
            DispatchQueue.main.async { self.panel.update(token, done: sent, total: clip.bytes) }
        } }
        io.async {
            guard self.outgoing.isCurrent(generation) else {
                log("push \(clip.id) skipped: newer copy")
                return
            }
            let result = Remote.push(clip, progress: progress, isCancelled: { !self.outgoing.isCurrent(generation) })
            if result.ok { log("mac -> win: \(clip.kind.rawValue) (\(clip.id))") }
            DispatchQueue.main.async {
                if let token {
                    let message = result.ok ? "已到 Windows，可以粘贴了"
                        : result.wasCancelled ? "已取消：复制了新内容" : "发送失败，连上后会重试"
                    self.panel.finish(token, message, succeeded: result.ok)
                }
                if !result.ok, !result.wasCancelled, self.pending == nil { self.pending = clip }
            }
        }
    }

    private func tooLarge(_ size: Int64, from side: String) {
        log("skip: \(side) files \(size) bytes > limit \(Config.maxFileBytes)")
        notify("\(side) 上复制的文件太大（\(formatBytes(size))，上限 \(formatBytes(Config.maxFileBytes))），未同步")
    }

    /// Windows reported something: "TOOLARGE <bytes>" or "SENDING <count> <bytes>".
    func remoteNotice(_ text: String) {
        let parts = text.split(separator: " ")
        if parts.count == 2, parts[0] == "TOOLARGE", let size = Int64(parts[1]) {
            tooLarge(size, from: "Windows")
        } else if parts.count == 3, parts[0] == "SENDING", let count = Int(parts[1]), let size = Int64(parts[2]) {
            log("windows is sending \(count) files, \(size) bytes")
            // A new Windows copy supersedes any transfer in flight, in either direction.
            _ = incoming.next()
            _ = outgoing.next()
            let token = panel.begin("从 Windows 接收 \(count) 个文件", detail: "Windows 准备中…（\(formatBytes(size))）")
            announced = (size, token)
            // If the clip never shows up (copy failed or replaced on Windows), don't spin forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + Config.incomingTimeout) {
                guard let waiting = self.announced, waiting.token == token else { return }
                self.announced = nil
                self.panel.finish(token, "Windows 没有发来文件，详见 Windows 日志", succeeded: false)
            }
        } else {
            log("windows notice: \(text)")
        }
    }

    private func clipArrived(_ id: String) {
        _ = outgoing.next()   // the latest copy on either machine wins
        let generation = incoming.next()
        let expected = announced
        announced = nil
        io.async { self.receive(id, generation: generation, expected: expected) }
    }

    /// Runs on `io`: download, then apply on the main thread. `expected` is set when
    /// Windows announced a large transfer; the panel then tracks the download.
    private func receive(_ id: String, generation: Int, expected: (bytes: Int64, token: Int)?) {
        let isCancelled = { !self.incoming.isCurrent(generation) }
        guard !isCancelled() else {
            log("fetch \(id) skipped: newer copy")
            return
        }
        let progress: ((Int64) -> Void)? = expected.map { expected in { landed in
            DispatchQueue.main.async { self.panel.update(expected.token, done: landed, total: expected.bytes) }
        } }
        guard let dir = Remote.fetch(id: id, progress: progress, isCancelled: isCancelled) else {
            if let expected {
                let message = isCancelled() ? "已取消：复制了新内容" : "接收失败，详见日志"
                DispatchQueue.main.async { self.panel.finish(expected.token, message, succeeded: false) }
            }
            return
        }
        DispatchQueue.main.async {
            guard !isCancelled() else {   // superseded while it finished; don't clobber the newer clip
                try? FileManager.default.removeItem(at: dir)
                return
            }
            do {
                let kind = try applyClip(at: dir, to: self.pb)
                self.ownCount = self.pb.changeCount
                self.lastCount = self.ownCount
                log("win -> mac: \(kind.rawValue) (\(id))")
                if let expected { self.panel.finish(expected.token, "已到 Mac，可以粘贴了", succeeded: true) }
            } catch {
                log("apply \(id) failed: \(error)")
                if let expected { self.panel.finish(expected.token, "放到剪贴板失败，详见日志", succeeded: false) }
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
