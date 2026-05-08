import Foundation

// MARK: - Frames decoded by FrameParser

enum Frame: Equatable {
    case idle(status: UInt8)
    case measurement(flags: UInt16, weightKg: Double, impedanceOhms: UInt16?)
}

// MARK: - Final consolidated measurement, emitted by main.swift

struct MeasurementComplete {
    let timestamp: Date
    let weightKg: Double
    let impedanceOhms: UInt16
    let rawHex: String
    /// `true` si vino del fallback "disconnect sin flags[0]=1" (peso conocido pero impedancia 0).
    let incomplete: Bool
}

// MARK: - Parser errors

enum ParseError: Error, Equatable {
    case tooShort
    case badSync
    case unknownType(UInt16)
    case lengthMismatch(declared: Int, actual: Int)
    case badChecksum(expected: UInt8, calculated: UInt8)
}

// MARK: - Checksum probe types (used by ChecksumProbe)

enum ChecksumAlgorithm: String, CaseIterable {
    case xor = "XOR"
    case sumMod256 = "SUM mod 256"
    case sumMod256Negated = "(SUM mod 256) ^ 0xFF"
    case twosComplement = "two's complement of SUM"
    case crc8Poly07 = "CRC-8 poly 0x07"
    case crc8Maxim = "CRC-8/MAXIM (poly 0x31, refin/refout)"
}

enum Slice: String, CaseIterable {
    case payloadOnly       // data[5..<count-1]
    case headerPlusPayload // data[2..<count-1]  (type+len+payload)
    case fullFrameMinusCk  // data[0..<count-1]  (sync+type+len+payload)
    case fromTypeByte      // data[2..<count-1]  (alias of headerPlusPayload — kept distinct for documentation, but skip duplicates at runtime)

    /// Devuelve la sub-Data sobre la que se computa el checksum.
    func extract(from data: Data) -> Data {
        let endIndex = data.count - 1
        switch self {
        case .payloadOnly:
            return data.subdata(in: 5..<endIndex)
        case .headerPlusPayload, .fromTypeByte:
            return data.subdata(in: 2..<endIndex)
        case .fullFrameMinusCk:
            return data.subdata(in: 0..<endIndex)
        }
    }
}

struct Candidate {
    let algorithm: ChecksumAlgorithm
    let slice: Slice
    let matchCount: Int
}

struct ProbeResult {
    let totalFrames: Int
    let candidates: [Candidate]   // ordenado descendente por matchCount
    let winner: Candidate?
}
