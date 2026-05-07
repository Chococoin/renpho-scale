import Foundation

struct Args {
    var filter: String? = nil
    var duration: TimeInterval = 60
    var connectTimeout: TimeInterval = 10
    var verbose: Bool = false
    var out: String? = nil
}

func writeError(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
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
                writeError("error: --filter requires a value")
                exit(1)
            }
            args.filter = argv[i]
        case "--duration":
            i += 1
            guard i < argv.count, let d = Double(argv[i]), d > 0 else {
                writeError("error: --duration requires a positive number")
                exit(1)
            }
            args.duration = d
        case "--connect-timeout":
            i += 1
            guard i < argv.count, let d = Double(argv[i]), d > 0 else {
                writeError("error: --connect-timeout requires a positive number")
                exit(1)
            }
            args.connectTimeout = d
        case "--verbose":
            args.verbose = true
        case "--out":
            i += 1
            guard i < argv.count else {
                writeError("error: --out requires a path")
                exit(1)
            }
            args.out = argv[i]
        case "-h", "--help":
            print("usage: renpho-explore --filter <substring> [--duration <s>] [--connect-timeout <s>] [--verbose] [--out <path>]")
            exit(0)
        default:
            writeError("error: unknown arg \(a)")
            exit(1)
        }
        i += 1
    }
    return args
}

let args = parseArgs()

guard let filter = args.filter, !filter.isEmpty else {
    writeError("error: --filter is required")
    exit(1)
}

let logger: EventLogger
do {
    logger = try EventLogger(verbose: args.verbose, outputPath: args.out)
} catch {
    writeError("error: cannot open output file: \(error)")
    exit(4)
}
defer { logger.close() }

let explorer = BLEExplorer()
let stream: AsyncStream<ExplorerEvent>
do {
    stream = try await explorer.run(
        nameFilter: filter,
        scanTimeout: 15,
        connectTimeout: args.connectTimeout
    )
} catch ExplorerError.bluetoothUnauthorized {
    writeError("error: Bluetooth permission denied. Approve in System Settings → Privacy & Security → Bluetooth, then re-run.")
    exit(2)
} catch ExplorerError.bluetoothPoweredOff {
    writeError("error: Bluetooth is off. Please enable it.")
    exit(3)
} catch ExplorerError.bluetoothUnsupported {
    writeError("error: Bluetooth not supported on this Mac.")
    exit(3)
} catch ExplorerError.scanTimeoutNoMatch {
    writeError("error: scale not found within 15s. Is it active? Try waking it up.")
    exit(5)
} catch ExplorerError.connectFailed(let inner) {
    if let inner = inner {
        writeError("error: failed to connect: \(inner.localizedDescription)")
    } else {
        writeError("error: failed to connect: timeout after \(args.connectTimeout)s")
    }
    exit(6)
} catch {
    writeError("error: \(error)")
    exit(1)
}

// Listening: starts when we receive .ready; the duration timer also starts then.
var durationTimer: Task<Void, Never>?

for await event in stream {
    logger.log(event)
    if case .ready = event {
        durationTimer = Task { [duration = args.duration] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            explorer.stop()
        }
    }
}
durationTimer?.cancel()

logger.printSummary()
exit(0)
