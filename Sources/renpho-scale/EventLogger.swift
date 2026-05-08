import Foundation
import CoreBluetooth
import RenphoBLE

final class EventLogger {

    private let consoleVerbose: Bool
    private let jsonlHandle: FileHandle?
    private let parser: FrameParser

    // Snapshot de metadata para enriquecer measurement_complete
    private(set) var metadataSnapshot: [MetadataField: Any] = [:]

    // Última measurement frame parseada (para fallback "incomplete")
    private(set) var lastMeasurement: (frame: Frame, rawHex: String)?

    init(verbose: Bool, outputPath: String?, parser: FrameParser) throws {
        self.consoleVerbose = verbose
        self.parser = parser
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

    /// Procesa un evento del cliente: imprime a consola + persiste a JSONL +
    /// si es rawNotification, la parsea y emite los eventos derivados (frame / frame_error).
    /// Devuelve la `Frame` parseada si la notification dió un frame válido,
    /// nil en cualquier otro caso (incluyendo errores de parseo).
    @discardableResult
    func handle(_ event: ScaleEvent) -> Frame? {
        switch event {
        case .scanStarted:
            consoleLine("[\(now())] scan started")
            writeJSONL(["type": "scan_started"])
        case .peripheralFound(let name, let id):
            consoleLine("[\(now())] found \(name) (\(String(id.uuidString.prefix(8))))")
            writeJSONL([
                "type": "peripheral_found",
                "name": name,
                "id": id.uuidString.lowercased()
            ])
        case .connecting:
            consoleLine("[\(now())] connecting...")
            writeJSONL(["type": "connecting"])
        case .connected:
            consoleLine("[\(now())] connected")
            writeJSONL(["type": "connected"])
        case .metadataRead(let field, let data):
            handleMetadataRead(field: field, data: data)
        case .metadataReadFailed(let field, let error):
            consoleLine("[\(now())] \(field.rawValue): <unavailable>")
            writeJSONL([
                "type": "metadata_failed",
                "field": fieldKey(field),
                "error": error.localizedDescription
            ])
        case .subscribed:
            consoleLine("[\(now())] subscribed — subite a la balanza")
            print("")
            writeJSONL(["type": "subscribed"])
        case .rawNotification(let value):
            return handleRawNotification(value)
        case .disconnected(let error):
            if let e = error {
                consoleLine("[\(now())] disconnected (error: \(e.localizedDescription))")
                writeJSONL(["type": "disconnected", "error": e.localizedDescription])
            } else {
                consoleLine("[\(now())] disconnected")
                writeJSONL(["type": "disconnected"])
            }
        }
        return nil
    }

    /// Loguea un measurement_complete a consola + JSONL. Llamado desde main.
    func logMeasurementComplete(_ m: MeasurementComplete) {
        let mark = m.incomplete ? "(incomplete)" : "✓ medición completa"
        let weightStr = String(format: "%.2f", m.weightKg)
        consoleLine("[\(now())] peso \(weightStr) kg | impedancia \(m.impedanceOhms) Ω \(mark)")
        print("")
        print("--- Resultado ---")
        print(String(format: "peso:        %.2f kg", m.weightKg))
        print("impedancia:  \(m.impedanceOhms) Ω")
        if let battery = metadataSnapshot[.batteryLevel] {
            print("batería:     \(battery)%")
        }
        if let firmware = metadataSnapshot[.firmwareRevision] as? String {
            print("firmware:    \(firmware)")
        }

        var dict: [String: Any] = [
            "type": "measurement_complete",
            "weight_kg": m.weightKg,
            "impedance_ohms": Int(m.impedanceOhms),
            "raw": m.rawHex,
            "incomplete": m.incomplete
        ]
        if let battery = metadataSnapshot[.batteryLevel] as? Int {
            dict["battery_level"] = battery
        }
        if let firmware = metadataSnapshot[.firmwareRevision] as? String {
            dict["firmware"] = firmware
        }
        writeJSONL(dict)
    }

    func close() {
        try? jsonlHandle?.close()
    }

    // MARK: - Private: notification → frame

    private func handleRawNotification(_ value: Data) -> Frame? {
        let rawHex = value.hex
        do {
            let frame = try parser.parse(value)
            // Save measurement frames for fallback
            if case .measurement = frame {
                lastMeasurement = (frame, rawHex)
            }
            // Console
            switch frame {
            case .idle(let status):
                if consoleVerbose {
                    consoleLine("[\(now())]   idle status=\(status) raw=\(rawHex)")
                }
            case .measurement(let flags, let weight, let impedance):
                let weightStr = String(format: "%.2f", weight)
                if let imp = impedance, (flags & 1) == 1 {
                    consoleLine("[\(now())] peso \(weightStr) kg | impedancia \(imp) Ω")
                } else {
                    consoleLine("[\(now())] peso \(weightStr) kg")
                }
                if consoleVerbose {
                    consoleLine("            flags=0x\(String(format: "%04x", flags)) raw=\(rawHex)")
                }
            }
            // JSONL
            writeJSONL(jsonDict(for: frame, rawHex: rawHex))
            return frame
        } catch let parseError as ParseError {
            // frame_error
            let (errKind, expected, calculated) = parseErrorParts(parseError)
            var dict: [String: Any] = [
                "type": "frame_error",
                "raw": rawHex,
                "error": errKind
            ]
            if let e = expected { dict["expected"] = e }
            if let c = calculated { dict["calculated"] = c }
            if consoleVerbose {
                consoleLine("[\(now())]   frame_error \(errKind) raw=\(rawHex)")
            }
            writeJSONL(dict)
            return nil
        } catch {
            return nil
        }
    }

    private func parseErrorParts(_ e: ParseError) -> (String, String?, String?) {
        switch e {
        case .tooShort:                       return ("tooShort", nil, nil)
        case .badSync:                        return ("badSync", nil, nil)
        case .unknownType(let t):             return ("unknownType_\(String(format: "%04x", t))", nil, nil)
        case .lengthMismatch(let d, let a):   return ("lengthMismatch", "\(d)", "\(a)")
        case .badChecksum(let exp, let calc): return ("badChecksum",
                                                       String(format: "%02x", exp),
                                                       String(format: "%02x", calc))
        }
    }

    private func jsonDict(for frame: Frame, rawHex: String) -> [String: Any] {
        var dict: [String: Any] = ["type": "frame", "raw": rawHex]
        switch frame {
        case .idle(let status):
            dict["kind"] = "idle"
            dict["status"] = Int(status)
        case .measurement(let flags, let weight, let impedance):
            dict["kind"] = "measurement"
            dict["flags"] = Int(flags)
            dict["weight_kg"] = weight
            if let imp = impedance {
                dict["impedance_ohms"] = Int(imp)
            }
        }
        return dict
    }

    // MARK: - Private: metadata

    private func handleMetadataRead(field: MetadataField, data: Data) {
        let humanValue: Any
        var jsonValue: Any
        switch field {
        case .manufacturerName, .modelNumber, .serialNumber,
             .firmwareRevision, .hardwareRevision, .softwareRevision:
            let str = String(data: data, encoding: .utf8) ?? data.hex
            humanValue = str
            jsonValue = str
        case .systemId:
            // 8 bytes; los primeros 6 son la MAC (en algunos chips little-endian).
            humanValue = data.hex
            jsonValue = data.hex
        case .batteryLevel:
            // 1 byte: 0..100
            let level = data.first.map { Int($0) } ?? 0
            humanValue = level
            jsonValue = level
        }
        metadataSnapshot[field] = jsonValue

        consoleLine("[\(now())] \(humanLabel(field)): \(humanValue)\(field == .batteryLevel ? "%" : "")")
        writeJSONL([
            "type": "metadata",
            "field": fieldKey(field),
            "value": jsonValue
        ])
    }

    private func humanLabel(_ field: MetadataField) -> String {
        switch field {
        case .manufacturerName:  return "manufacturer"
        case .modelNumber:       return "model"
        case .serialNumber:      return "serial"
        case .firmwareRevision:  return "firmware"
        case .hardwareRevision:  return "hardware"
        case .softwareRevision:  return "software"
        case .systemId:          return "system_id"
        case .batteryLevel:      return "battery"
        }
    }

    private func fieldKey(_ field: MetadataField) -> String {
        // snake_case para el JSONL, consistente con las convenciones de las fases anteriores
        switch field {
        case .manufacturerName:  return "manufacturer_name"
        case .modelNumber:       return "model_number"
        case .serialNumber:      return "serial_number"
        case .firmwareRevision:  return "firmware_revision"
        case .hardwareRevision:  return "hardware_revision"
        case .softwareRevision:  return "software_revision"
        case .systemId:          return "system_id"
        case .batteryLevel:      return "battery_level"
        }
    }

    // MARK: - Private: I/O helpers

    private func consoleLine(_ s: String) {
        print(s)
    }

    private func now() -> String {
        return ConsoleTime.string(from: Date())
    }

    private func writeJSONL(_ dict: [String: Any]) {
        guard let handle = jsonlHandle else { return }
        var withTs = dict
        withTs["ts"] = ISO8601DateFormatter.fractional.string(from: Date())
        guard let data = try? JSONSerialization.data(
            withJSONObject: withTs,
            options: [.sortedKeys]
        ) else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }
}

enum EventLoggerError: Error {
    case cannotOpen(path: String)
}

/// Time helper local (HH:mm:ss.SSS) — duplicado mínimo de renpho-explore;
/// no vale la pena subirlo a RenphoBLE por 8 líneas.
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
