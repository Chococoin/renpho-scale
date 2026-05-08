import Foundation
import RenphoBLE

// MARK: - Args

struct Args {
    var filter: String? = nil
    var out: String? = nil
    var connectTimeout: TimeInterval = 10
    var timeout: TimeInterval = 60
    var verbose: Bool = false
    var noVerifyChecksum: Bool = false
    var probeChecksumPath: String? = nil
}

func writeError(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func printUsage() {
    print("""
    usage: renpho-scale --filter <substring> [--out <path>] [--connect-timeout <s>]
                        [--timeout <s>] [--no-verify-checksum] [--verbose]
           renpho-scale --probe-checksum <jsonl-path>
    """)
}

func parseArgs() -> Args {
    var args = Args()
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--filter":
            i += 1
            guard i < argv.count else {
                writeError("error: --filter requires a value"); exit(1)
            }
            args.filter = argv[i]
        case "--out":
            i += 1
            guard i < argv.count else {
                writeError("error: --out requires a path"); exit(1)
            }
            args.out = argv[i]
        case "--connect-timeout":
            i += 1
            guard i < argv.count, let d = Double(argv[i]), d > 0 else {
                writeError("error: --connect-timeout requires a positive number"); exit(1)
            }
            args.connectTimeout = d
        case "--timeout":
            i += 1
            guard i < argv.count, let d = Double(argv[i]), d > 0 else {
                writeError("error: --timeout requires a positive number"); exit(1)
            }
            args.timeout = d
        case "--verbose":
            args.verbose = true
        case "--no-verify-checksum":
            args.noVerifyChecksum = true
        case "--probe-checksum":
            i += 1
            guard i < argv.count else {
                writeError("error: --probe-checksum requires a path"); exit(1)
            }
            args.probeChecksumPath = argv[i]
        case "-h", "--help":
            printUsage(); exit(0)
        default:
            writeError("error: unknown arg \(a)"); exit(1)
        }
        i += 1
    }
    return args
}

// Padding helper for the probe table (Swift's String(format:"%s") crashes on Swift String).
func pad(_ s: String, _ width: Int) -> String {
    if s.count >= width { return s }
    return s + String(repeating: " ", count: width - s.count)
}

let args = parseArgs()

// MARK: - Probe mode

if let probePath = args.probeChecksumPath {
    let probe = ChecksumProbe()
    do {
        let result = try probe.run(jsonlPath: probePath)
        print("--- Checksum probe ---")
        print("Frames analyzed: \(result.totalFrames)")
        print("")
        print("\(pad("Algorithm", 40))\(pad("Slice", 22))Matches")
        for c in result.candidates {
            let mark = c.matchCount == result.totalFrames ? " ✓" : ""
            print("\(pad(c.algorithm.rawValue, 40))\(pad(c.slice.rawValue, 22))\(c.matchCount)/\(result.totalFrames)\(mark)")
        }
        print("")
        if let w = result.winner {
            print("Winner: \(w.algorithm.rawValue) over \(w.slice.rawValue) — \(w.matchCount)/\(result.totalFrames) frames")
            exit(0)
        } else {
            writeError("error: no unique algorithm matched all frames")
            exit(9)
        }
    } catch ChecksumProbe.ProbeError.fileNotReadable(let path) {
        writeError("error: cannot read \(path)"); exit(1)
    } catch ChecksumProbe.ProbeError.noFramesFound {
        writeError("error: no valid frames found in JSONL"); exit(9)
    } catch {
        writeError("error: \(error)"); exit(1)
    }
}

// MARK: - Measurement mode

guard let filter = args.filter, !filter.isEmpty else {
    writeError("error: --filter is required"); exit(1)
}

var parser = FrameParser()
parser.verifyChecksum = !args.noVerifyChecksum

let logger: EventLogger
do {
    logger = try EventLogger(verbose: args.verbose, outputPath: args.out, parser: parser)
} catch {
    writeError("error: cannot open output file: \(error)"); exit(4)
}
defer { logger.close() }

let client = ScaleClient()
let stream: AsyncStream<ScaleEvent>
do {
    stream = try await client.run(
        nameFilter: filter,
        scanTimeout: 15,
        connectTimeout: args.connectTimeout
    )
} catch BLEPowerError.unauthorized {
    writeError("error: Bluetooth permission denied. Approve in System Settings → Privacy & Security → Bluetooth, then re-run.")
    exit(2)
} catch BLEPowerError.poweredOff {
    writeError("error: Bluetooth is off. Please enable it."); exit(3)
} catch BLEPowerError.unsupported {
    writeError("error: Bluetooth not supported on this Mac."); exit(3)
} catch ScaleClientError.scanTimeoutNoMatch {
    writeError("error: scale not found within 15s. Is it active? Try waking it up."); exit(5)
} catch ScaleClientError.connectFailed(let inner) {
    if let inner = inner {
        writeError("error: failed to connect: \(inner.localizedDescription)")
    } else {
        writeError("error: failed to connect: timeout after \(args.connectTimeout)s")
    }
    exit(6)
} catch {
    writeError("error: \(error)"); exit(1)
}

// State for measurement detection + watchdog
var watchdogTask: Task<Void, Never>?
var didEmitComplete = false
var didTimeoutWatchdog = false

for await event in stream {
    let frame = logger.handle(event)

    // Start watchdog when we receive .subscribed
    if case .subscribed = event {
        watchdogTask = Task { [timeout = args.timeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            didTimeoutWatchdog = true
            client.stop()
        }
    }

    // Detect "measurement complete": flags[0]=1 with non-zero impedance
    if let frame = frame,
       case .measurement(let flags, let weight, let impedance) = frame,
       (flags & 1) == 1,
       let imp = impedance, imp > 0,
       !didEmitComplete {
        didEmitComplete = true
        logger.logMeasurementComplete(MeasurementComplete(
            timestamp: Date(),
            weightKg: weight,
            impedanceOhms: imp,
            rawHex: logger.lastMeasurement?.rawHex ?? "",
            incomplete: false
        ))
        client.stop()
    }
}

watchdogTask?.cancel()

// Stream finished. Decide exit code.
if didEmitComplete {
    exit(0)
}

// Watchdog fired without measurement
if didTimeoutWatchdog {
    writeError("error: watchdog timeout — no measurement received within \(Int(args.timeout))s")
    exit(7)
}

// Disconnect without flags[0]=1 — try fallback "incomplete" if we have a last measurement
if let last = logger.lastMeasurement,
   case .measurement(_, let weight, _) = last.frame,
   weight > 0 {
    logger.logMeasurementComplete(MeasurementComplete(
        timestamp: Date(),
        weightKg: weight,
        impedanceOhms: 0,
        rawHex: last.rawHex,
        incomplete: true
    ))
    exit(0)
}

writeError("error: disconnected without any usable frame")
exit(8)
