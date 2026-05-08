import Foundation

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

// Parse args
let argv = CommandLine.arguments
var probePath: String? = nil
var i = 1
while i < argv.count {
    let a = argv[i]
    switch a {
    case "--probe-checksum":
        i += 1
        guard i < argv.count else {
            writeError("error: --probe-checksum requires a path")
            exit(1)
        }
        probePath = argv[i]
    case "-h", "--help":
        printUsage()
        exit(0)
    default:
        // Otros flags se manejan en Task 12 cuando exista el modo medición.
        // Por ahora, sin --probe-checksum, exit 1 indicando que falta implementar.
        break
    }
    i += 1
}

if let probePath = probePath {
    let probe = ChecksumProbe()
    do {
        let result = try probe.run(jsonlPath: probePath)
        print("--- Checksum probe ---")
        print("Frames analyzed: \(result.totalFrames)")
        print("")
        func pad(_ s: String, _ width: Int) -> String {
            if s.count >= width { return s }
            return s + String(repeating: " ", count: width - s.count)
        }
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
        writeError("error: cannot read \(path)")
        exit(1)
    } catch ChecksumProbe.ProbeError.noFramesFound {
        writeError("error: no valid frames found in JSONL")
        exit(9)
    } catch {
        writeError("error: \(error)")
        exit(1)
    }
}

// Modo medición: stub hasta Task 12
writeError("error: measurement mode not yet implemented (will be added in Task 12)")
exit(1)
