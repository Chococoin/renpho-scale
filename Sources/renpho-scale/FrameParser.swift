import Foundation

struct FrameParser {
    var verifyChecksum: Bool = true   // default real ahora que tenemos algoritmo

    func parse(_ data: Data) throws -> Frame {
        guard data.count >= 6 else {
            throw ParseError.tooShort
        }

        guard data[0] == 0x55, data[1] == 0xaa else {
            throw ParseError.badSync
        }

        let len = Int(data[4])
        guard data.count == 5 + len else {
            throw ParseError.lengthMismatch(declared: len, actual: data.count - 5)
        }

        if verifyChecksum {
            let expected = data[data.count - 1]
            let calculated = Self.computeChecksum(data)
            guard calculated == expected else {
                throw ParseError.badChecksum(expected: expected, calculated: calculated)
            }
        }

        let type = UInt16(data[2]) | (UInt16(data[3]) << 8)
        switch type {
        case 0x0011:
            return .idle(status: data[5])
        case 0x0014:
            // Datos útiles esperados: 6 bytes (FL FL WW WW II II), len=7 incluyendo cksum
            // flags LE para que `& 1` matchee la convención bit-0 de la nota 1.1
            let flags = UInt16(data[5]) | (UInt16(data[6]) << 8)
            // Peso: BE
            let weightRaw = (UInt16(data[7]) << 8) | UInt16(data[8])
            let weight = Double(weightRaw) * 0.01
            // Impedancia: BE, sólo si bit 0 está set
            let impedance: UInt16?
            if (flags & 1) == 1 {
                let imp = (UInt16(data[9]) << 8) | UInt16(data[10])
                impedance = imp
            } else {
                impedance = nil
            }
            return .measurement(flags: flags, weightKg: weight, impedanceOhms: impedance)
        default:
            throw ParseError.unknownType(type)
        }
    }

    /// Algoritmo de checksum identificado por --probe-checksum contra gatt.jsonl 2026-05-07.
    /// Algoritmo: SUM mod 256 sobre el slice fullFrameMinusCk (bytes 0..count-2 inclusive).
    /// Detalles en docs/superpowers/notes/2026-05-08-checksum-discovery.md.
    static func computeChecksum(_ frame: Data) -> UInt8 {
        var sum: UInt = 0
        for i in 0..<(frame.count - 1) {
            sum &+= UInt(frame[i])
        }
        return UInt8(sum & 0xFF)
    }
}
