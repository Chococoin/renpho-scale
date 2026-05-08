import Foundation
import CoreBluetooth
import RenphoBLE

/// Loggea ExplorerEvent a consola y opcionalmente a JSONL.
/// Acumula contadores para el summary final.
final class EventLogger {

    private let consoleVerbose: Bool
    private let jsonlHandle: FileHandle?

    // Counters for summary
    private(set) var serviceCount = 0
    private(set) var charCounts: (read: Int, write: Int, notify: Int) = (0, 0, 0)
    private(set) var readsOk = 0
    private(set) var readsFailed = 0
    private(set) var notificationsByChar: [CBUUID: Int] = [:]

    init(verbose: Bool, outputPath: String?) throws {
        self.consoleVerbose = verbose
        if let outputPath = outputPath {
            let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: url) else {
                throw EventLoggerError.cannotOpen(path: outputPath)
            }
            try h.seekToEnd()
            self.jsonlHandle = h
        } else {
            self.jsonlHandle = nil
        }
    }

    func log(_ event: ExplorerEvent) {
        // Console
        let consoleLine = consoleString(for: event)
        print(consoleLine)

        // Counters
        updateCounters(for: event)

        // JSONL
        guard let handle = jsonlHandle else { return }
        let dict = jsonDict(for: event)
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    func close() {
        try? jsonlHandle?.close()
    }

    func printSummary() {
        print("")
        print("--- Summary ---")
        print("Services: \(serviceCount)")
        print("Characteristics: \(charCounts.read) read, \(charCounts.write) write, \(charCounts.notify) notify")
        print("Reads: \(readsOk) succeeded, \(readsFailed) failed")
        let totalNotifications = notificationsByChar.values.reduce(0, +)
        if totalNotifications > 0 {
            let breakdown = notificationsByChar
                .map { "\($0.key.uuidString.lowercased())=\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            print("Notifications: \(totalNotifications) total (\(breakdown))")
        } else {
            print("Notifications: 0")
        }
    }

    // MARK: - Console formatting

    private func consoleString(for event: ExplorerEvent) -> String {
        let ts = ConsoleTime.string(from: Date())
        switch event {
        case .scanStarted:
            return "[\(ts)] scan started"
        case .peripheralFound(let name, let id):
            return "[\(ts)] found \(name) (\(String(id.uuidString.prefix(8))))"
        case .connecting:
            return "[\(ts)] connecting..."
        case .connected:
            return "[\(ts)] connected"
        case .serviceDiscovered(let uuid):
            return "[\(ts)] service \(uuid.uuidString.lowercased())"
        case .characteristicDiscovered(let svc, let char, let props):
            return "[\(ts)]   char \(char.uuidString.lowercased()) [\(props.descriptors().joined(separator: ","))] (svc \(svc.uuidString.lowercased()))"
        case .readSucceeded(let char, let value):
            return "[\(ts)]   read \(char.uuidString.lowercased()) = \(consoleHex(value))"
        case .readFailed(let char, let error):
            return "[\(ts)]   read \(char.uuidString.lowercased()) FAILED: \(error.localizedDescription)"
        case .notifySubscribed(let char):
            return "[\(ts)]   subscribed \(char.uuidString.lowercased())"
        case .notification(let char, let value):
            return "[\(ts)]   notify \(char.uuidString.lowercased()) = \(consoleHex(value))"
        case .ready:
            return "\n--- Listening for notifications ---"
        case .disconnected(let error):
            if let e = error {
                return "[\(ts)] disconnected (error: \(e.localizedDescription))"
            } else {
                return "[\(ts)] disconnected"
            }
        }
    }

    // MARK: - JSON encoding

    private func jsonDict(for event: ExplorerEvent) -> [String: Any] {
        let ts = ISO8601DateFormatter.fractional.string(from: Date())
        var dict: [String: Any] = ["ts": ts]
        switch event {
        case .scanStarted:
            dict["type"] = "scan_started"
        case .peripheralFound(let name, let id):
            dict["type"] = "peripheral_found"
            dict["name"] = name
            dict["id"] = id.uuidString.lowercased()
        case .connecting:
            dict["type"] = "connecting"
        case .connected:
            dict["type"] = "connected"
        case .serviceDiscovered(let uuid):
            dict["type"] = "service_discovered"
            dict["service"] = uuid.uuidString.lowercased()
        case .characteristicDiscovered(let svc, let char, let props):
            dict["type"] = "char_discovered"
            dict["service"] = svc.uuidString.lowercased()
            dict["char"] = char.uuidString.lowercased()
            dict["props"] = props.descriptors()
        case .readSucceeded(let char, let value):
            dict["type"] = "read_ok"
            dict["char"] = char.uuidString.lowercased()
            dict["value"] = value.hex
        case .readFailed(let char, let error):
            dict["type"] = "read_failed"
            dict["char"] = char.uuidString.lowercased()
            dict["error"] = error.localizedDescription
        case .notifySubscribed(let char):
            dict["type"] = "notify_subscribed"
            dict["char"] = char.uuidString.lowercased()
        case .notification(let char, let value):
            dict["type"] = "notification"
            dict["char"] = char.uuidString.lowercased()
            dict["value"] = value.hex
        case .ready:
            dict["type"] = "ready"
        case .disconnected(let error):
            dict["type"] = "disconnected"
            if let e = error {
                dict["error"] = e.localizedDescription
            }
        }
        return dict
    }

    // MARK: - Counters

    private func updateCounters(for event: ExplorerEvent) {
        switch event {
        case .serviceDiscovered:
            serviceCount += 1
        case .characteristicDiscovered(_, _, let props):
            if props.contains(.read) { charCounts.read += 1 }
            if props.contains(.write) || props.contains(.writeWithoutResponse) { charCounts.write += 1 }
            if props.contains(.notify) { charCounts.notify += 1 }
        case .readSucceeded:
            readsOk += 1
        case .readFailed:
            readsFailed += 1
        case .notification(let char, _):
            notificationsByChar[char, default: 0] += 1
        default:
            break
        }
    }

    // MARK: - Utils

    /// Hex con truncación cuando `--verbose` no está activo (más de 8 bytes → primeros 8 + "...").
    /// JSONL siempre usa `data.hex` completo; esto solo se usa en console output.
    private func consoleHex(_ data: Data) -> String {
        if consoleVerbose || data.count <= 8 {
            return data.hex
        }
        return data.prefix(8).hex + "..."
    }
}

enum EventLoggerError: Error {
    case cannotOpen(path: String)
}

// MARK: - Time helpers

private enum ConsoleTime {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static func string(from date: Date) -> String {
        return formatter.string(from: date)
    }
}
