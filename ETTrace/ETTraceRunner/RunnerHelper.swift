//
//  RunnerHelper.swift
//  PerfAnalysisRunner
//
//  Created by Itay Brenner on 8/3/23.
//

import AppKit
import Foundation
import Peertalk
import CommunicationFrame
import Swifter
import JSONWrapper
import ETModels
import Symbolicator

class RunnerHelper {
    let dsyms: String?
    let launch: Bool
    let useSimulator: Bool
    let verbose: Bool
    let saveIntermediate: Bool
    let outputDirectory: String?
    let multiThread: Bool
    let sampleRate: UInt32
    let bundleId: String?
    let device: String?

    var server: HttpServer? = nil

    init(_ dsyms: String?, _ launch: Bool, _ simulator: Bool, _ verbose: Bool, _ saveIntermediate: Bool, _ outputDirectory: String?, _ multiThread: Bool, _ sampleRate: UInt32, _ bundleId: String?, _ device: String?) {
        self.dsyms = dsyms
        self.launch = launch
        self.useSimulator = simulator
        self.verbose = verbose
        self.saveIntermediate = saveIntermediate
        self.outputDirectory = outputDirectory
        self.multiThread = multiThread
        self.sampleRate = sampleRate
        self.bundleId = bundleId
        self.device = device
    }

    private func printMessageAndWait() {
      print("Please open the app on the \(useSimulator ? "simulator" : "device")")
      if !useSimulator {
          print("Re-run with `--simulator` to connect to the simulator.")
      }
      print("Press return when ready...")
      _ = readLine()
    }

    /// Wait until the user signals end-of-session via either Return or Ctrl-C.
    private func waitForStopSignal() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = ManagedAtomicFlag()

            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                if resumed.testAndSet() {
                    print("")
                    continuation.resume()
                }
            }
            // Ignore default SIGINT so DispatchSource receives it.
            signal(SIGINT, SIG_IGN)
            sigintSource.resume()

            DispatchQueue.global().async {
                _ = readLine()
                if resumed.testAndSet() {
                    continuation.resume()
                }
            }
        }
    }

    func start() async throws {
        // Launch-via-simctl flow.
        if let bundleId = bundleId {
            guard useSimulator else {
                throw AppLauncherError.xcrunFailed("--bundle-id requires --simulator")
            }
            let sim = try AppLauncher.resolveSimulator(matching: device)
            if verbose {
                print("Targeting simulator \(sim.name) (\(sim.udid))")
            }
            AppLauncher.terminate(udid: sim.udid, bundleId: bundleId)

            var env: [String: String] = ["ETTRACE_AUTO_START": "1"]
            if multiThread {
                env["ETTRACE_RECORD_ALL_THREADS"] = "1"
            }
            if sampleRate != 0 {
                env["ETTRACE_SAMPLE_RATE"] = String(sampleRate)
            }
            try AppLauncher.launch(udid: sim.udid, bundleId: bundleId, env: env, verbose: verbose)

            try await waitForListener()

            let deviceManager = SimulatorDeviceManager(verbose: verbose, relaunch: false)
            try await deviceManager.connect()

            print("Recording. Press Ctrl-C (or Return) to stop and view results.")
            await waitForStopSignal()

            try await collectAndProcess(deviceManager: deviceManager)
            return
        }

        // Legacy flow (manual app launch).
        while useSimulator && !isPortInUse(port: Int(PTPortNumber)) {
          let running = listRunningProcesses()
          if !running.isEmpty {
            print(running.count == 1 ? "1 app was found but it is not running" : "\(running.count) apps were found but they are not running")
            for p in running {
              if let bundleId = p.bundleID {
                print("\tBundle Id: \(bundleId) path: \(p.path)")
              } else {
                print("\tPath: \(p.path)")
              }
            }
          } else {
            print("No apps found running on the simulator")
          }

          printMessageAndWait()
        }

        if !useSimulator {
          printMessageAndWait()
        }

        if verbose {
          print("Connecting to device.")
        }

        let deviceManager: DeviceManager = useSimulator ? SimulatorDeviceManager(verbose: verbose, relaunch: launch) : PhysicalDevicemanager(verbose: verbose, relaunch: launch)

        try await deviceManager.connect()

        try await deviceManager.sendStartRecording(launch, multiThread, sampleRate)

        if launch {
            print("Re-launch the app to start recording, then press Ctrl-C (or Return) to exit")
        } else {
            print("Started recording, press Ctrl-C (or Return) to exit")
        }

        await waitForStopSignal()

        if launch {
            try await deviceManager.connect()
        }

        try await collectAndProcess(deviceManager: deviceManager)
    }

    /// Wait for the simulator-side Peertalk listener to come up after launch.
    private func waitForListener() async throws {
        let deadline = Date().addingTimeInterval(15)
        while !isPortInUse(port: Int(PTPortNumber)) {
            if Date() >= deadline {
                throw AppLauncherError.xcrunFailed("Timed out waiting for ETTrace listener on port \(PTPortNumber). Is ETTrace.framework linked into the app?")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func collectAndProcess(deviceManager: DeviceManager) async throws {
        if verbose {
          print("Waiting for report to be generated...");
        }

        let receivedData = try await deviceManager.getResults()

        if saveIntermediate {
          let outFolder = "\(NSTemporaryDirectory())/emerge-output"
          try FileManager.default.createDirectory(atPath: outFolder, withIntermediateDirectories: true)
          let outputPath = "\(outFolder)/output.json"
          if FileManager.default.fileExists(atPath: outputPath) {
            try FileManager.default.removeItem(atPath: outputPath)
          }
          FileManager.default.createFile(atPath: outputPath, contents: receivedData)
          print("Intermediate file saved to \(outputPath)")
        }

        if verbose {
          print("Stopped recording, symbolicating...")
        }

        let responseData = try JSONDecoder().decode(ResponseModel.self, from: receivedData)

        let isSimulator = responseData.isSimulator
        var arch = responseData.cpuType.lowercased()
        if arch == "arm64e" {
            arch = " arm64e"
        } else {
            arch = ""
        }
        var osBuild = responseData.osBuild
        osBuild.removeAll(where: { !$0.isLetter && !$0.isNumber })

        let threadIds = responseData.threads.keys
        let threads = threadIds.map { responseData.threads[$0]!.stacks }
        let symbolicator = StackSymbolicator(isSimulator: isSimulator, dSymsDir: dsyms, osBuild: osBuild, osVersion: responseData.osVersion, arch: arch, verbose: verbose)
        let flamegraphs = FlamegraphGenerator.generate(
          events: responseData.events,
          threads: threads,
          sampleRate: responseData.sampleRate,
          loadedLibraries: responseData.libraryInfo.loadedLibraries,
          symbolicator: symbolicator)
        let outputUrl = URL(fileURLWithPath: outputDirectory ?? FileManager.default.currentDirectoryPath)

        var mainThreadData: Data?
        for (threadId, symbolicationResult) in zip(threadIds, flamegraphs) {
            let thread = responseData.threads[threadId]!
            let flamegraph = createFlamegraphForThread(symbolicationResult.0, symbolicationResult.1, thread, responseData)

            let outJsonData = JSONWrapper.toData(flamegraph)!

            if thread.name == "Main Thread" {
                if verbose {
                    try symbolicationResult.2.write(toFile: "output.folded", atomically: true, encoding: .utf8)
                }
                mainThreadData = outJsonData
            }
            try saveFlamegraph(outJsonData, outputUrl, threadId)
        }

        guard let mainThreadData else {
            fatalError("No main thread flamegraphs generated")
        }

        // Serve Main Thread
        try startLocalServer(mainThreadData)

        let url = URL(string: "https://emergetools.com/ettrace")!
        NSWorkspace.shared.open(url)

        // Wait 4 seconds for results to be accessed from server, then exit
        sleep(4)
        print("Results saved to \(outputUrl)")
    }

  private func createFlamegraphForThread(_ flamegraphNodes: FlameNode, _ eventTimes: [Double], _ thread: Thread, _ responseData: ResponseModel) -> Flamegraph {
        let threadNode = ThreadNode(nodes: flamegraphNodes, threadName: thread.name)

        let events = zip(responseData.events, eventTimes).map { (event, t) in
            return FlamegraphEvent(name: event.span,
                                   type: event.type.rawValue,
                                   time: t)
        }

        let libraries = responseData.libraryInfo.loadedLibraries.reduce(into: [String:UInt64]()) { partialResult, library in
            partialResult[library.path] = library.loadAddress
        }

        return Flamegraph(osBuild: responseData.osBuild,
                          device: responseData.device,
                          isSimulator: responseData.isSimulator,
                          libraries: libraries,
                          events: events,
                          threadNodes: [threadNode])
    }

    func startLocalServer(_ data: Data) throws {
        server = HttpServer()

        let headers = [
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Headers": "baggage,sentry-trace"
        ]

        server?["/output.json"] = { a in
            if a.method == "OPTIONS" {
                return .raw(204, "No Content", [
                    "Access-Control-Allow-Methods": "GET",
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Headers": "baggage,sentry-trace"
                ], nil)
            }

            return .raw(200, "OK", headers, { writter in
                try? writter.write(data)
                exit(0)
            })
        }
        try server?.start(37577)
    }

    private func saveFlamegraph(_ outJsonData: Data, _ outputUrl: URL, _ threadId: String? = nil) throws {
        var saveUrl = outputUrl.appendingPathComponent("output.json")
        if let threadId = threadId {
            saveUrl = outputUrl.appendingPathComponent("output_\(threadId).json")
        }

        let jsonString = String(data: outJsonData, encoding: .utf8)!
        try jsonString.write(to: saveUrl, atomically: true, encoding: .utf8)
    }
}

/// Tiny atomic-flag shim so `waitForStopSignal` can resolve from either of two
/// concurrent paths (SIGINT handler / readLine) without resuming twice.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
