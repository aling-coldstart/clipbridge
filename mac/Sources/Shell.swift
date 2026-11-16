import Foundation

struct CommandResult {
    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
}

@discardableResult
func runTool(_ path: String, _ args: [String]) -> CommandResult {
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
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return CommandResult(status: process.terminationStatus, output: text)
}

@discardableResult
func ssh(_ remoteCommand: String) -> CommandResult {
    runTool("/usr/bin/ssh", Config.sshOptions + [Config.host, remoteCommand])
}

@discardableResult
func scp(_ args: [String]) -> CommandResult {
    runTool("/usr/bin/scp", Config.sshOptions + ["-q", "-r"] + args)
}

/// Run `producer | consumer` and return the combined result (fails if either fails).
func runPipeline(producer: (path: String, args: [String]),
                 consumer: (path: String, args: [String]),
                 environment: [String: String] = [:]) -> CommandResult {
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
    let link = Pipe()
    first.standardOutput = link
    second.standardInput = link
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
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errData = firstErr.fileHandleForReading.readDataToEndOfFile()
    first.waitUntilExit()
    second.waitUntilExit()
    let text = String(decoding: errData + data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let status = first.terminationStatus != 0 ? first.terminationStatus : second.terminationStatus
    return CommandResult(status: status, output: text)
}
