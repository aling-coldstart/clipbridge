import Foundation

struct CommandResult {
    static let cancelledStatus: Int32 = -2
    static let cancelled = CommandResult(status: cancelledStatus, output: "cancelled")

    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
    var wasCancelled: Bool { status == Self.cancelledStatus }
}

/// How often transfers report progress.
let progressInterval: TimeInterval = 0.25

/// Run a tool to completion. With `whileRunning`, calls it every `progressInterval`
/// until the tool exits (used to report how much of a download has landed); if it
/// returns false the tool is stopped and the result is `.cancelled`.
@discardableResult
func runTool(_ path: String, _ args: [String], whileRunning: (() -> Bool)? = nil) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return CommandResult(status: -1, output: "launch failed: \(error)")
    }
    var data = Data()
    let reading = DispatchGroup()
    reading.enter()
    DispatchQueue.global(qos: .utility).async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        reading.leave()
    }
    var stopped = false
    if let tick = whileRunning {
        while process.isRunning {
            if !tick() {
                process.terminate()
                stopped = true
                break
            }
            Thread.sleep(forTimeInterval: progressInterval)
        }
    }
    reading.wait()
    process.waitUntilExit()
    if stopped { return .cancelled }
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return CommandResult(status: process.terminationStatus, output: text)
}

@discardableResult
func ssh(_ remoteCommand: String) -> CommandResult {
    runTool("/usr/bin/ssh", Config.sshOptions + [Config.host, remoteCommand])
}

@discardableResult
func scp(_ args: [String], whileRunning: (() -> Bool)? = nil) -> CommandResult {
    runTool("/usr/bin/scp", Config.sshOptions + ["-q", "-r"] + args, whileRunning: whileRunning)
}

/// Run `producer | consumer` and return the combined result (fails if either fails).
/// Bytes are relayed through this process so `progress` can report how many have
/// passed, at most every `progressInterval`. When `isCancelled` turns true both
/// processes are stopped and the result is `.cancelled`.
func runPipeline(producer: (path: String, args: [String]),
                 consumer: (path: String, args: [String]),
                 environment: [String: String] = [:],
                 progress: ((Int64) -> Void)? = nil,
                 isCancelled: (() -> Bool)? = nil) -> CommandResult {
    let first = Process()
    first.executableURL = URL(fileURLWithPath: producer.path)
    first.arguments = producer.args
    first.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    first.standardInput = FileHandle.nullDevice
    let firstErr = Pipe()
    first.standardError = firstErr

    let second = Process()
    second.executableURL = URL(fileURLWithPath: consumer.path)
    second.arguments = consumer.args
    let fromProducer = Pipe()
    let toConsumer = Pipe()
    first.standardOutput = fromProducer
    second.standardInput = toConsumer
    let output = Pipe()
    second.standardOutput = output
    second.standardError = output

    do {
        try first.run()
        try second.run()
    } catch {
        first.terminate()
        return CommandResult(status: -1, output: "launch failed: \(error)")
    }
    // Drop our copies of the children's pipe ends, so EOF and broken pipes propagate.
    try? fromProducer.fileHandleForWriting.close()
    try? toConsumer.fileHandleForReading.close()
    let relaying = DispatchGroup()
    relaying.enter()
    var stopped = false
    Thread.detachNewThread {
        stopped = relay(from: fromProducer.fileHandleForReading, to: toConsumer.fileHandleForWriting,
                        progress: progress, isCancelled: isCancelled)
        if stopped {
            first.terminate()
            second.terminate()
        }
        relaying.leave()
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    relaying.wait()
    let errData = firstErr.fileHandleForReading.readDataToEndOfFile()
    first.waitUntilExit()
    second.waitUntilExit()
    let text = String(decoding: errData + data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if stopped { return .cancelled }
    let status = first.terminationStatus != 0 ? first.terminationStatus : second.terminationStatus
    return CommandResult(status: status, output: text)
}

/// Copy until EOF (or until the reader goes away), then close the write end.
/// Returns true if it stopped because `isCancelled` said so.
private func relay(from source: FileHandle, to sink: FileHandle,
                   progress: ((Int64) -> Void)?, isCancelled: (() -> Bool)?) -> Bool {
    let chunk = 1 << 20
    var total: Int64 = 0
    var lastReport = Date.distantPast
    defer {
        try? sink.close()
        progress?(total)
    }
    while true {
        if isCancelled?() == true { return true }
        guard let data = try? source.read(upToCount: chunk), !data.isEmpty else { return false }
        do { try sink.write(contentsOf: data) } catch { return false }   // consumer exited
        total += Int64(data.count)
        if let report = progress, Date().timeIntervalSince(lastReport) >= progressInterval {
            lastReport = Date()
            report(total)
        }
    }
}
