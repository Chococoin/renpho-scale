import Foundation

public extension Data {
    var hex: String {
        return self.map { String(format: "%02x", $0) }.joined()
    }

    /// Inicializa Data desde un string hex. Ignora espacios. Devuelve nil si hay caracteres inválidos
    /// o longitud impar. Usado por fixtures de tests.
    init?(hex: String) {
        let trimmed = hex.replacingOccurrences(of: " ", with: "")
        guard trimmed.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
