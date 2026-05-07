import Foundation

/// Formatea AdvertisementFrames para impresión en consola.
/// Mantiene el último frame por dispositivo para resaltar bytes que cambiaron.
struct FrameFormatter {
    private var lastFrames: [UUID: AdvertisementFrame] = [:]

    static func hex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// Devuelve la representación hex de `data`, con los bytes que difieren de `previous`
    /// envueltos en escape ANSI rojo. Si `previous` es nil, no resalta nada.
    static func diffHex(_ data: Data, previous: Data?) -> String {
        guard let prev = previous else { return hex(data) }
        var out = ""
        for (i, byte) in data.enumerated() {
            let s = String(format: "%02x", byte)
            let prevByte: UInt8? = (i < prev.count) ? prev[prev.startIndex.advanced(by: i)] : nil
            if prevByte == byte {
                out += s
            } else {
                out += "\u{001B}[31m\(s)\u{001B}[0m"
            }
        }
        return out
    }

    /// Renderiza un frame. Si `verbose` es false y el contenido no cambió respecto al
    /// frame previo del mismo dispositivo, devuelve nil (no se imprime).
    mutating func format(_ frame: AdvertisementFrame, verbose: Bool) -> String? {
        let prev = lastFrames[frame.identifier]
        let changed = (prev?.manufacturerData != frame.manufacturerData)
            || (prev?.serviceData != frame.serviceData)
        defer { lastFrames[frame.identifier] = frame }
        if !verbose && !changed && prev != nil { return nil }

        let ts = ISO8601DateFormatter.fractional.string(from: frame.timestamp)
        let name = frame.name ?? "<unnamed>"
        let shortId = String(frame.identifier.uuidString.prefix(8))
        var lines = ["[\(ts)] \(name) (\(shortId)) rssi=\(frame.rssi)"]

        if let mfg = frame.manufacturerData {
            lines.append("  mfg: \(FrameFormatter.diffHex(mfg, previous: prev?.manufacturerData))")
        }
        if !frame.serviceUUIDs.isEmpty {
            let uuids = frame.serviceUUIDs.map { $0.uuidString.lowercased() }.joined(separator: ", ")
            lines.append("  services: \(uuids)")
        }
        for (uuid, data) in frame.serviceData {
            let prevData = prev?.serviceData[uuid]
            lines.append("  serviceData[\(uuid.uuidString.lowercased())]: \(FrameFormatter.diffHex(data, previous: prevData))")
        }
        return lines.joined(separator: "\n")
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
