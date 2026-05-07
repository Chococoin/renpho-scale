import Foundation

enum RecorderError: Error {
    case cannotOpen(path: String)
}

/// Escribe AdvertisementFrames como JSONL. Si se construye con path nil, no hace nada.
final class Recorder {
    private let handle: FileHandle?

    init(path: String?) throws {
        guard let path = path else {
            self.handle = nil
            return
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw RecorderError.cannotOpen(path: path)
        }
        try h.seekToEnd()
        self.handle = h
    }

    func record(_ frame: AdvertisementFrame) {
        guard let handle = handle else { return }
        var dict: [String: Any] = [
            "ts": ISO8601DateFormatter.fractional.string(from: frame.timestamp),
            "id": frame.identifier.uuidString,
            "rssi": frame.rssi
        ]
        if let name = frame.name {
            dict["name"] = name
        }
        if let mfg = frame.manufacturerData {
            dict["mfg"] = FrameFormatter.hex(mfg)
        }
        if !frame.serviceUUIDs.isEmpty {
            dict["services"] = frame.serviceUUIDs.map { $0.uuidString.lowercased() }
        }
        if !frame.serviceData.isEmpty {
            let pairs = frame.serviceData.map { (key, value) in
                (key.uuidString.lowercased(), FrameFormatter.hex(value))
            }
            dict["serviceData"] = Dictionary(uniqueKeysWithValues: pairs)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        ) else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    func close() {
        try? handle?.close()
    }
}
