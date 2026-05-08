import Foundation

struct FrameParser {
    var verifyChecksum: Bool = false   // default temporal hasta Task 8

    func parse(_ data: Data) throws -> Frame {
        // Mínimo: sync 2 + type 2 + len 1 + cksum 1 = 6 bytes
        guard data.count >= 6 else {
            throw ParseError.tooShort
        }

        // Sync header
        guard data[0] == 0x55, data[1] == 0xaa else {
            throw ParseError.badSync
        }

        // Length: cuenta los bytes desde data[5] hasta el final, incluyendo el cksum
        let len = Int(data[4])
        guard data.count == 5 + len else {
            throw ParseError.lengthMismatch(declared: len, actual: data.count - 5)
        }

        // (Verificación de checksum llega en Task 8.)

        let type = UInt16(data[2]) | (UInt16(data[3]) << 8)
        switch type {
        case 0x0011:
            // Idle: el primer byte de los datos útiles es el status
            return .idle(status: data[5])
        default:
            throw ParseError.unknownType(type)
        }
    }
}
