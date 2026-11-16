import Foundation

/// Keeps one long-lived SSH session running watch.ps1 on Windows. That session is
/// also the ControlMaster other ssh/scp calls multiplex over. Reconnects with
/// exponential backoff, so an unreachable host costs one attempt per minute at most.
final class Watcher {
    var onConnected: () -> Void = {}
    var onDisconnected: () -> Void = {}
    var onClip: (String) -> Void = { _ in }

    func start() {
        Thread.detachNewThread { [weak self] in self?.loop() }
    }

    private func loop() {
        var backoff = Config.minBackoff
        while true {
            let gotHello = runSession()
            onDisconnected()
            backoff = gotHello ? Config.minBackoff : min(backoff * 2, Config.maxBackoff)
            log("windows unreachable, retry in \(Int(backoff))s")
            Thread.sleep(forTimeInterval: backoff)
        }
    }

    /// Runs until the SSH session ends. Returns true if the remote side said HELLO.
    private func runSession() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=yes", "-o", "ControlPath=\(Config.controlPath)",
            Config.host,
            "powershell -NoProfile -ExecutionPolicy Bypass -File \(Config.remoteDir)\\watch.ps1",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { log("ssh launch failed: \(error)"); return false }

        var gotHello = false
        var buffer = Data()
        let reader = pipe.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.removeSubrange(...newline)
                if line == "HELLO" {
                    gotHello = true
                    log("connected to \(Config.host)")
                    onConnected()
                } else if line.hasPrefix("CLIP ") {
                    onClip(String(line.dropFirst(5)))
                }
            }
        }
        process.waitUntilExit()
        return gotHello
    }
}
