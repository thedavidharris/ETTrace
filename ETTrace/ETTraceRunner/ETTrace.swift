//
//  ETTrace.swift
//  PerfAnalysisRunner
//
//  Created by Itay Brenner on 6/3/23.
//

import Foundation
import ArgumentParser

struct ETTrace: ParsableCommand {
    @Option(name: .shortAndLong, help: "Directory with dSYMs")
    var dsyms: String? = nil

    @Flag(name: .shortAndLong, help: "Relaunch app with profiling from startup. Ignored when --bundle-id is provided (launching always profiles from start).")
    var launch = false

    @Flag(name: .shortAndLong, help: "Use simulator")
    var simulator: Bool = false

    @Flag(name: .shortAndLong, help: "Verbose logging")
    var verbose: Bool = false

    @Flag(name: .long, help: "Save intermediate files directly from the phone before processing them.")
    var saveIntermediate: Bool = false

    @Option(name: .shortAndLong, help: "Directory for output files")
    var output: String? = nil

    @Flag(name: .shortAndLong, help: "Record all threads")
    var multiThread: Bool = false

    @Option(name: .long, help: "Sample rate")
    var sampleRate: UInt32 = 0

    @Option(name: .long, help: "Bundle identifier of the app to launch and profile (simulator only). When set, ETTrace launches the app itself and profiles from main().")
    var bundleId: String? = nil

    @Option(name: .long, help: "Simulator UDID or device name to target. Required only when more than one simulator is booted.")
    var device: String? = nil

    mutating func run() throws {
      if let dsym = dsyms, dsym.hasSuffix(".dSYM") {
        ETTrace.exit(withError: ValidationError("The dsym argument should be set to a folder containing your dSYM files, not the dSYM itself"))
      }

      if bundleId != nil && !simulator {
        ETTrace.exit(withError: ValidationError("--bundle-id is currently only supported with --simulator"))
      }

      if bundleId != nil && launch {
        print("Note: --launch is implied when --bundle-id is set; ignoring --launch.")
      }

        let helper = RunnerHelper(dsyms, launch, simulator, verbose, saveIntermediate, output, multiThread, sampleRate, bundleId, device)
        Task {
            do {
                try await helper.start()
            } catch let error {
                print("ETTrace error: \(error)")
            }
          ETTrace.exit()
        }

        RunLoop.main.run()
    }
}
