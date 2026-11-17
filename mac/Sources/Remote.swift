import Foundation

/// Transfers clips to/from the Windows host. All calls block; run them off the main thread.
enum Remote {
    /// Upload a Mac clip into %USERPROFILE%\\<remoteDir>\\inbox\\<id> and signal the listener,
    /// in one SSH round trip: `tar -c | ssh "mkdir && tar -x && signal"`.
    /// `progress` gets the bytes sent so far (tar stream, so slightly over `clip.bytes`).
    /// A cancelled push deletes its partial inbox folder (never signalled, so unused).
    static func push(_ clip: OutgoingClip, progress: ((Int64) -> Void)? = nil,
                     isCancelled: (() -> Bool)? = nil) -> CommandResult {
        do {
            try stageFileLinks(for: clip)
        } catch {
            log("push \(clip.id): staging failed: \(error)")
            return CommandResult(status: -1, output: "staging failed: \(error)")
        }
        let id = clip.id
        let inbox = "\(Config.remoteDir)\\inbox"
        let remote = "mkdir \(inbox)\\\(id) && tar -xf - -C \(inbox)\\\(id)"
            + " && (echo \(id))>\(inbox)\\ready.tmp && move /y \(inbox)\\ready.tmp \(inbox)\\ready.txt>nul"
        let result = runPipeline(
            producer: ("/usr/bin/tar", ["-c", "-h", "-f", "-", "-C", clip.dir.path, "."]),
            consumer: ("/usr/bin/ssh", Config.sshOptions + [Config.host, remote]),
            environment: ["COPYFILE_DISABLE": "1"],
            progress: progress,
            isCancelled: isCancelled)
        if result.wasCancelled {
            log("push \(id) cancelled: newer copy")
            // Best effort: the partial folder was never signalled, so nothing uses it.
            ssh("if exist \(inbox)\\\(id) rmdir /s /q \(inbox)\\\(id)")
        } else if !result.ok {
            log("push \(id) failed (\(result.status)): \(result.output)")
        }
        return result
    }

    /// For file clips, put symlinks under dir/files so `tar -h` archives the real files there.
    private static func stageFileLinks(for clip: OutgoingClip) throws {
        guard !clip.fileURLs.isEmpty else { return }
        let fm = FileManager.default
        let filesDir = clip.dir.appendingPathComponent("files")
        try? fm.removeItem(at: filesDir)
        try fm.createDirectory(at: filesDir, withIntermediateDirectories: true)
        var used = Set<String>()
        for url in clip.fileURLs {
            var name = url.lastPathComponent
            var n = 2
            while used.contains(name) {
                name = "\(url.deletingPathExtension().lastPathComponent) (\(n))" + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")
                n += 1
            }
            used.insert(name)
            try fm.createSymbolicLink(at: filesDir.appendingPathComponent(name), withDestinationURL: url)
        }
    }

    /// Download outbox\<id> into recv/<id>. Returns the local folder. `progress` gets
    /// the bytes that have landed so far, while the download runs; when `isCancelled`
    /// turns true the download stops and its partial folder is removed.
    static func fetch(id: String, progress: ((Int64) -> Void)? = nil,
                      isCancelled: @escaping () -> Bool = { false }) -> URL? {
        guard id.range(of: #"^w\d+$"#, options: .regularExpression) != nil else {
            log("fetch: rejected id '\(id)'")
            return nil
        }
        let dest = Config.recvDir.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: dest)
        let tick: () -> Bool = {
            if isCancelled() { return false }
            progress?(diskSize(of: dest))
            return true
        }
        let result = scp(["\(Config.host):\(Config.remoteDir)/outbox/\(id)", dest.path], whileRunning: tick)
        if result.wasCancelled {
            log("fetch \(id) cancelled: newer copy")
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        guard result.ok else { log("fetch \(id) failed: \(result.output)"); return nil }
        normalizePermissions(under: dest)
        return dest
    }

    /// scp carries over modes derived from Windows ACLs (e.g. rw----r-x); give pasted
    /// files ordinary ones: folders 755, files 644.
    private static func normalizePermissions(under root: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            try? fm.setAttributes([.posixPermissions: isDir ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
    }

    /// Make sure the desktop listener is running (the scheduled task is single-instance).
    static func ensureListener() {
        let result = ssh("schtasks /Run /TN \(Config.windowsTask)>nul")
        if !result.ok { log("could not start Windows listener: \(result.output)") }
    }
}
