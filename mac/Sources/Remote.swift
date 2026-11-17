import Foundation

/// Transfers clips to/from the Windows host. All calls block; run them off the main thread.
enum Remote {
    /// Upload a Mac clip into %USERPROFILE%\\<remoteDir>\\inbox\\<id> and signal the listener,
    /// in one SSH round trip: `tar -c | ssh "mkdir && tar -x && signal"`.
    static func push(_ clip: OutgoingClip) -> Bool {
        do {
            try stageFileLinks(for: clip)
        } catch {
            log("push \(clip.id): staging failed: \(error)")
            return false
        }
        let id = clip.id
        let inbox = "\(Config.remoteDir)\\inbox"
        let remote = "mkdir \(inbox)\\\(id) && tar -xf - -C \(inbox)\\\(id)"
            + " && (echo \(id))>\(inbox)\\ready.tmp && move /y \(inbox)\\ready.tmp \(inbox)\\ready.txt>nul"
        let result = runPipeline(
            producer: ("/usr/bin/tar", ["-c", "-h", "-f", "-", "-C", clip.dir.path, "."]),
            consumer: ("/usr/bin/ssh", Config.sshOptions + [Config.host, remote]),
            environment: ["COPYFILE_DISABLE": "1"])
        if !result.ok { log("push \(id) failed (\(result.status)): \(result.output)") }
        return result.ok
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

    /// Download outbox\<id> into recv/<id>. Returns the local folder.
    static func fetch(id: String) -> URL? {
        guard id.range(of: #"^w\d+$"#, options: .regularExpression) != nil else {
            log("fetch: rejected id '\(id)'")
            return nil
        }
        let dest = Config.recvDir.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: dest)
        let result = scp(["\(Config.host):\(Config.remoteDir)/outbox/\(id)", dest.path])
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
