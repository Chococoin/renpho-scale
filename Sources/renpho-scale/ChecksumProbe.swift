import Foundation
import RenphoBLE

struct ChecksumProbe {

    enum ProbeError: Error {
        case fileNotReadable(path: String)
        case noFramesFound
    }

    /// Lee el JSONL en `path`, filtra notifications de la char `2a10`, y prueba
    /// todas las combinaciones (algoritmo, slice). Devuelve `ProbeResult` con
    /// candidatos ordenados por matches.
    func run(jsonlPath: String) throws -> ProbeResult {
        let url = URL(fileURLWithPath: (jsonlPath as NSString).expandingTildeInPath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw ProbeError.fileNotReadable(path: jsonlPath)
        }

        // Parse cada línea como JSON, quedarse con notifications del 2a10
        var frames: [Data] = []
        for line in content.split(separator: "\n") {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard let type = obj["type"] as? String, type == "notification" else { continue }
            guard let charField = obj["char"] as? String, charField == "2a10" else { continue }
            guard let valueHex = obj["value"] as? String,
                  let bytes = Data(hex: valueHex)
            else { continue }
            // Filtrar frames demasiado cortos (no son frames del protocolo)
            guard bytes.count >= 6 else { continue }
            // Filtrar por sync header válido para no contar ruido
            guard bytes[0] == 0x55 && bytes[1] == 0xaa else { continue }
            frames.append(bytes)
        }

        guard !frames.isEmpty else {
            throw ProbeError.noFramesFound
        }

        // Probar cada combinación
        // Skip Slice.fromTypeByte porque es alias de headerPlusPayload — evita duplicados
        let slicesToTry: [Slice] = [.payloadOnly, .headerPlusPayload, .fullFrameMinusCk]

        var candidates: [Candidate] = []
        for alg in ChecksumAlgorithm.allCases {
            for slice in slicesToTry {
                var matches = 0
                for frame in frames {
                    let region = slice.extract(from: frame)
                    let calculated = compute(region, with: alg)
                    let expected = frame[frame.count - 1]
                    if calculated == expected {
                        matches += 1
                    }
                }
                candidates.append(Candidate(algorithm: alg, slice: slice, matchCount: matches))
            }
        }

        candidates.sort { $0.matchCount > $1.matchCount }

        // Ganador único: exactamente uno con 100% match
        let perfectMatches = candidates.filter { $0.matchCount == frames.count }
        let winner: Candidate? = perfectMatches.count == 1 ? perfectMatches[0] : nil

        return ProbeResult(totalFrames: frames.count, candidates: candidates, winner: winner)
    }

    /// Implementación de cada algoritmo. Devuelve UInt8 (mod 256 implícito).
    func compute(_ region: Data, with algorithm: ChecksumAlgorithm) -> UInt8 {
        switch algorithm {
        case .xor:
            var x: UInt8 = 0
            for b in region { x ^= b }
            return x
        case .sumMod256:
            var sum: UInt = 0
            for b in region { sum &+= UInt(b) }
            return UInt8(sum & 0xFF)
        case .sumMod256Negated:
            var sum: UInt = 0
            for b in region { sum &+= UInt(b) }
            return UInt8(sum & 0xFF) ^ 0xFF
        case .twosComplement:
            var sum: UInt = 0
            for b in region { sum &+= UInt(b) }
            // Two's complement of the low byte
            let low = UInt8(sum & 0xFF)
            return (~low) &+ 1
        case .crc8Poly07:
            return crc8(region, poly: 0x07, init_: 0x00, reflectInput: false, reflectOutput: false, xorOutput: 0x00)
        case .crc8Maxim:
            return crc8(region, poly: 0x31, init_: 0x00, reflectInput: true, reflectOutput: true, xorOutput: 0x00)
        }
    }

    /// CRC-8 genérico parametrizable.
    private func crc8(_ data: Data, poly: UInt8, init_: UInt8,
                      reflectInput: Bool, reflectOutput: Bool, xorOutput: UInt8) -> UInt8 {
        var crc: UInt8 = init_
        for byte in data {
            let b = reflectInput ? reflect8(byte) : byte
            crc ^= b
            for _ in 0..<8 {
                if (crc & 0x80) != 0 {
                    crc = (crc << 1) ^ poly
                } else {
                    crc <<= 1
                }
            }
        }
        if reflectOutput { crc = reflect8(crc) }
        return crc ^ xorOutput
    }

    private func reflect8(_ b: UInt8) -> UInt8 {
        var r: UInt8 = 0
        for i in 0..<8 {
            if (b & (1 << i)) != 0 {
                r |= UInt8(1 << (7 - i))
            }
        }
        return r
    }
}
