import Foundation

// MARK: - Logging and time

let probeStart = ContinuousClock.now

/// Seconds since the probe started.
func elapsed() -> Double {
    seconds(probeStart.duration(to: .now))
}

func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

func fmt(_ value: Double, _ digits: Int = 2) -> String {
    String(format: "%.\(digits)f", value)
}

let logPrefix = ProcessInfo.processInfo.environment["LIFECYCLE_PROBE_LOG_PREFIX"] ?? ""

func log(_ line: String) {
    print("\(logPrefix)[\(fmt(elapsed(), 3))] \(line)")
}

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw ProbeFailure(message()) }
}

// MARK: - Child processes

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    let timedOut: Bool
}

/// Runs a command off the main actor (the controller's hotplug handling runs
/// there and must keep going), merging stdout and stderr.
func runCommand(
    _ executable: String,
    _ arguments: [String],
    timeout: TimeInterval = 30
) async -> CommandResult {
    await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "launch failed: \(error)", timedOut: false)
        }
        let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline {
                timedOut = true
                process.terminate()
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Not waitUntilExit(): on a cooperative thread it can spin its run
        // loop forever after the child has already exited (seen with adb).
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let data = await reader.value
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: timedOut
        )
    }.value
}

// MARK: - adb

struct Reenumeration: Sendable {
    let reset: CommandResult
    /// Probe time at which mtp was selected again after the phone came back
    /// without it; nil when the phone kept mtp.
    let mtpReselectedAt: Double?
}

enum ADB {
    static let executable: String = {
        if let path = ProcessInfo.processInfo.environment["ADB"], !path.isEmpty { return path }
        for candidate in ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Process does not search PATH: find adb there (on Linux it is
        // usually a user install, for example ~/.local/bin).
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/adb"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/adb"
    }()

    static func run(_ arguments: [String], timeout: TimeInterval = 20) async -> CommandResult {
        await runCommand(executable, arguments, timeout: timeout)
    }

    /// `svc usb getFunctions` prints to stderr on the phone; `2>&1` inside the
    /// shell command brings it back on stdout.
    static func functions() async -> String {
        let result = await run(["shell", "svc usb getFunctions 2>&1"], timeout: 10)
        return result.output
    }

    static func setFunctions(_ functions: String) async -> CommandResult {
        let argument = functions.isEmpty ? "''" : functions
        return await run(["shell", "svc usb setFunctions \(argument)"], timeout: 15)
    }

    /// Re-enumerates the phone with its functions unchanged: on this phone
    /// (HyperOS) `setFunctions mtp` while already in mtp is a no-op, so the
    /// gadget is reset instead. adb drops with it, so the call may time out.
    ///
    /// A locked phone comes back from the reset without MTP (charging and
    /// adb only), since Android applies File transfer only while unlocked;
    /// then mtp is selected again (a second re-enumeration), as the user
    /// would by unlocking and picking File transfer.
    static func reenumerate() async -> Reenumeration {
        let reset = await run(["shell", "svc usb resetUsbGadget"], timeout: 5)
        guard await waitReachable(timeout: 15) else {
            return Reenumeration(reset: reset, mtpReselectedAt: nil)
        }
        // Read twice: right after adb returns the functions may still settle.
        var functions = await functions()
        if !functions.contains("mtp") {
            try? await Task.sleep(for: .milliseconds(500))
            functions = await self.functions()
        }
        guard !functions.contains("mtp") else {
            return Reenumeration(reset: reset, mtpReselectedAt: nil)
        }
        let at = elapsed()
        log("the phone came back from the gadget reset without mtp (\(functions.isEmpty ? "none" : functions); locked?): selecting mtp again")
        _ = await setFunctions("mtp")
        return Reenumeration(reset: reset, mtpReselectedAt: at)
    }

    /// A harmless round trip that proves adb is reachable.
    static func reachable() async -> Bool {
        let result = await run(["shell", "echo art-probe-ok"], timeout: 5)
        return result.status == 0 && result.output.contains("art-probe-ok")
    }

    static func waitReachable(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await reachable() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Puts the phone back in File transfer, waking it first if needed.
    @discardableResult
    static func ensureMTP() async -> Bool {
        if await functions().contains("mtp") { return true }
        _ = await waitReachable(timeout: 20)
        _ = await setFunctions("mtp")
        try? await Task.sleep(for: .seconds(3))
        if await functions().contains("mtp") { return true }
        _ = await run(["shell", "input keyevent KEYCODE_WAKEUP"])
        _ = await setFunctions("mtp")
        try? await Task.sleep(for: .seconds(3))
        return await functions().contains("mtp")
    }
}
