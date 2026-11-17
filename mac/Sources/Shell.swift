import Foundation

struct CommandResult {
    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
}

/// How often transfers report progress.
let progressInterval: TimeInterval = 0.25

/// Run a tool to completion. With `whileRunning`, calls it every `progressInterval`
/// until the tool exits (used to report how much of a download has landed).
@discardableResult
func runTool(_ path: String, _ args: [String], whileRunning: (() -> Void)? = nil) -> CommandResult {
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
    if let tick = whileRunning {
        while process.isRunning {
            tick()
            Thread.sleep(forTimeInterval: progressInterval)
        }
    }
    reading.wait()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return CommandResult(status: process.terminationStatus, output: text)
}

@discardableResult
func ssh(_ remoteCommand: String) -> CommandResult {
    runTool("/usr/bin/ssh", Config.sshOptions + [Config.host, remoteCommand])
}

@discardableResult
func scp(_ args: [String], whileRunning: (() -> Void)? = nil) -> CommandResult {
    runTool("/usr/bin/scp", Config.sshOptions + ["-q", "-r"] + args, whileRunning: whileRunning)
}

/// Run `producer | consumer` and return the combined result (fails if either fails).
/// Bytes are relayed through this process so `progress` can report how many have
/// passed, at most every `progressInterval`.
func runPipeline(producer: (path: String, args: [String]),
                 consumer: (path: String, args: [String]),
                 environment: [String: String] = [:],
                 progress: ((Int64) -> Void)? = nil) -> CommandResult {
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
    Thread.detachNewThread {
        relay(from: fromProducer.fileHandleForReading, to: toConsumer.fileHandleForWriting, progress: progress)
        relaying.leave()
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    relaying.wait()
    let errData = firstErr.fileHandleForReading.readDataToEndOfFile()
    first.waitUntilExit()
    second.waitUntilExit()
    let text = String(decoding: errData + data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let status = first.terminationStatus != 0 ? first.terminationStatus : second.terminationStatus
    return CommandResult(status: status, output: text)
}

/// Copy until EOF (or until the reader goes away), then close the write end.
private func relay(from source: FileHandle, to sink: FileHandle, progress: ((Int64) -> Void)?) {
    let chunk = 1 << 20
    var total: Int64 = 0
    var lastReport = Date.distantPast
    defer {
        try? sink.close()
        progress?(total)
    }
    while true {
        guard let data = try? source.read(upToCount: chunk), !data.isEmpty else { return }
        do { try sink.write(contentsOf: data) } catch { return }   // consumer exited
        total += Int64(data.count)
        if let report = progress, Date().timeIntervalSince(lastReport) >= progressInterval {
            lastReport = Date()
            report(total)
        }
    }
}
