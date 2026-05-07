import Foundation

struct Args {
    var duration: TimeInterval = 30
    var filter: String? = nil
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
        case "--duration":
            i += 1
            guard i < argv.count, let d = Double(argv[i]), d > 0 else {
                writeError("error: --duration requires a positive number")
                exit(1)
            }
            args.duration = d
        case "--filter":
            i += 1
            guard i < argv.count else {
                writeError("error: --filter requires a value")
                exit(1)
            }
            args.filter = argv[i]
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
            print("usage: renpho-recon [--duration <seconds>] [--filter <substring>] [--verbose] [--out <path>]")
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

let recorder: Recorder
do {
    recorder = try Recorder(path: args.out)
} catch {
    writeError("error: cannot open output file: \(error)")
    exit(4)
}
defer { recorder.close() }

let scanner = BLEScanner()
let stream: AsyncStream<AdvertisementFrame>
do {
    stream = try await scanner.start()
} catch ScannerError.bluetoothUnauthorized {
    writeError("error: Bluetooth permission denied. Approve in System Settings → Privacy & Security → Bluetooth, then re-run.")
    exit(2)
} catch ScannerError.bluetoothPoweredOff {
    writeError("error: Bluetooth is off. Please enable it.")
    exit(3)
} catch {
    writeError("error: \(error)")
    exit(1)
}

var formatter = FrameFormatter()
var counts: [UUID: (name: String?, count: Int)] = [:]

let durationNanos = UInt64(args.duration * 1_000_000_000)
let timerTask = Task {
    try? await Task.sleep(nanoseconds: durationNanos)
    scanner.stop()
}

for await frame in stream {
    if let filter = args.filter {
        let name = frame.name ?? ""
        if !name.lowercased().contains(filter.lowercased()) { continue }
    }
    let entry = counts[frame.identifier] ?? (frame.name, 0)
    counts[frame.identifier] = (frame.name ?? entry.name, entry.count + 1)

    if let line = formatter.format(frame, verbose: args.verbose) {
        print(line)
    }
    recorder.record(frame)
}
timerTask.cancel()

if counts.isEmpty {
    print("\nNo devices detected. Is the scale active?")
} else {
    print("\n--- Summary ---")
    let sorted = counts.sorted { $0.value.count > $1.value.count }
    for (id, info) in sorted {
        let shortId = String(id.uuidString.prefix(8))
        print("\(info.name ?? "<unnamed>") (\(shortId)): \(info.count) frames")
    }
}
exit(0)
