//
//  AppLauncher.swift
//  ETTraceRunner
//
//  Launches a target app on the iOS Simulator via `xcrun simctl` so the runner
//  can drive the full profiling session from a single command.
//

import Foundation

enum AppLauncherError: Error, CustomStringConvertible {
    case xcrunFailed(String)
    case noBootedSimulators
    case multipleBootedSimulators([String])
    case deviceNotFound(String)

    var description: String {
        switch self {
        case .xcrunFailed(let msg):
            return "xcrun failed: \(msg)"
        case .noBootedSimulators:
            return "No booted simulators found. Boot one with `xcrun simctl boot <udid>` or open Simulator.app."
        case .multipleBootedSimulators(let names):
            return "Multiple booted simulators found; pass --device <udid-or-name>. Booted: \(names.joined(separator: ", "))"
        case .deviceNotFound(let q):
            return "No booted simulator matched '\(q)'."
        }
    }
}

struct SimulatorInfo {
    let udid: String
    let name: String
}

enum AppLauncher {

    static func resolveSimulator(matching query: String?) throws -> SimulatorInfo {
        let booted = try bootedSimulators()
        if let query = query {
            if let match = booted.first(where: { $0.udid == query || $0.name == query }) {
                return match
            }
            throw AppLauncherError.deviceNotFound(query)
        }
        switch booted.count {
        case 0: throw AppLauncherError.noBootedSimulators
        case 1: return booted[0]
        default: throw AppLauncherError.multipleBootedSimulators(booted.map { "\($0.name) (\($0.udid))" })
        }
    }

    static func terminate(udid: String, bundleId: String) {
        // Best-effort: ignore failure (app may not be running).
        _ = try? runProcess(["xcrun", "simctl", "terminate", udid, bundleId])
    }

    static func launch(udid: String, bundleId: String, env: [String: String], verbose: Bool) throws {
        var processEnv = ProcessInfo.processInfo.environment
        for (key, value) in env {
            processEnv["SIMCTL_CHILD_\(key)"] = value
        }
        if verbose {
            print("Launching \(bundleId) on \(udid) with env: \(env)")
        }
        let result = try runProcess(
            ["xcrun", "simctl", "launch", "--terminate-running-process", udid, bundleId],
            env: processEnv
        )
        if verbose, !result.isEmpty {
            print(result.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Helpers

    private static func bootedSimulators() throws -> [SimulatorInfo] {
        let output = try runProcess(["xcrun", "simctl", "list", "devices", "booted", "-j"])
        guard let data = output.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: Any] else {
            return []
        }
        var result: [SimulatorInfo] = []
        for (_, value) in devicesByRuntime {
            guard let devices = value as? [[String: Any]] else { continue }
            for device in devices {
                guard let udid = device["udid"] as? String,
                      let name = device["name"] as? String,
                      (device["state"] as? String) == "Booted" else { continue }
                result.append(SimulatorInfo(udid: udid, name: name))
            }
        }
        return result
    }

    @discardableResult
    private static func runProcess(_ args: [String], env: [String: String]? = nil) throws -> String {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = args
        if let env = env {
            process.environment = env
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outString = String(data: outData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let errString = String(data: errData, encoding: .utf8) ?? ""
            throw AppLauncherError.xcrunFailed(errString.isEmpty ? outString : errString)
        }
        return outString
    }
}
