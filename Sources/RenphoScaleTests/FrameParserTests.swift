import XCTest
import RenphoBLE
@testable import renpho_scale

final class FrameParserTests: XCTestCase {

    // Parser sin verificación de checksum (el algoritmo se hardcodea en Task 8;
    // hasta entonces los tests trabajan en modo no-verify).
    private var parser: FrameParser {
        var p = FrameParser()
        p.verifyChecksum = false
        return p
    }

    // MARK: - Idle frames

    func test_idleFramePrePesada() throws {
        // Frame real observado en gatt.jsonl de la fase 1.1
        let bytes = Data(hex: "55aa1100050101010921")!
        let frame = try parser.parse(bytes)
        XCTAssertEqual(frame, .idle(status: 0x01))
    }

    func test_idleFramePostPesada() throws {
        let bytes = Data(hex: "55aa1100050001010920")!
        let frame = try parser.parse(bytes)
        XCTAssertEqual(frame, .idle(status: 0x00))
    }

    // MARK: - Structural errors

    func test_tooShort() {
        let bytes = Data(hex: "55aa11")!
        XCTAssertThrowsError(try parser.parse(bytes)) { error in
            XCTAssertEqual(error as? ParseError, .tooShort)
        }
    }

    func test_badSync() {
        // Idle bytes con sync invertido: aa 55 en lugar de 55 aa
        let bytes = Data(hex: "aa551100050101010921")!
        XCTAssertThrowsError(try parser.parse(bytes)) { error in
            XCTAssertEqual(error as? ParseError, .badSync)
        }
    }

    func test_lengthMismatch() {
        // Idle con un byte extra al final (data.count = 11, len declarado = 5, 5+5=10 != 11)
        let bytes = Data(hex: "55aa110005010101092100")!
        XCTAssertThrowsError(try parser.parse(bytes)) { error in
            guard case .lengthMismatch(let declared, let actual) = error as? ParseError else {
                XCTFail("expected lengthMismatch, got \(error)")
                return
            }
            XCTAssertEqual(declared, 5)
            XCTAssertEqual(actual, 6)
        }
    }

    // MARK: - Measurement frames

    func test_measurementSinImpedancia() throws {
        // 75.00 kg = 7500 = 0x1D4C (BE: 1d 4c)
        // flags = 0x0000 → impedance debe ser nil
        // CK byte arbitrario porque verifyChecksum=false
        let bytes = Data(hex: "55aa14000700001d4c000099")!
        let frame = try parser.parse(bytes)

        guard case .measurement(let flags, let weight, let impedance) = frame else {
            XCTFail("expected measurement, got \(frame)")
            return
        }
        XCTAssertEqual(flags, 0x0000)
        XCTAssertEqual(weight, 75.00, accuracy: 0.001)
        XCTAssertNil(impedance)
    }

    func test_measurementConImpedancia() throws {
        // 75.40 kg = 7540 = 0x1D74; impedancia 500 = 0x01F4; flags LE 01 00 = 0x0001
        let bytes = Data(hex: "55aa14000701001d7401f499")!
        let frame = try parser.parse(bytes)

        guard case .measurement(let flags, let weight, let impedance) = frame else {
            XCTFail("expected measurement, got \(frame)")
            return
        }
        XCTAssertEqual(flags, 0x0001)
        XCTAssertEqual(weight, 75.40, accuracy: 0.001)
        XCTAssertEqual(impedance, 500)
    }

    // MARK: - Unknown type

    func test_unknownType() {
        // type 0x0099, len 0x01 (sólo cksum, sin datos útiles), 6 bytes total
        let bytes = Data(hex: "55aa99000100")!
        XCTAssertThrowsError(try parser.parse(bytes)) { error in
            guard case .unknownType(let t) = error as? ParseError else {
                XCTFail("expected unknownType, got \(error)")
                return
            }
            XCTAssertEqual(t, 0x0099)
        }
    }

    // MARK: - Checksum verification

    /// Helper: parser con verificación habilitada (default real)
    private var verifyingParser: FrameParser {
        return FrameParser()  // verifyChecksum=true por default
    }

    func test_checksumValidoPasaConVerificacion() throws {
        // Frame real de gatt.jsonl: idle pre-pesada, CK byte real (0x21 = SUM mod 256 of bytes 0..8)
        let bytes = Data(hex: "55aa1100050101010921")!
        let frame = try verifyingParser.parse(bytes)
        XCTAssertEqual(frame, .idle(status: 0x01))
    }

    func test_checksumCorruptoLanzaBadChecksum() {
        // Idle pre-pesada con el último byte alterado (de 0x21 a 0xff)
        let bytes = Data(hex: "55aa11000501010109ff")!
        XCTAssertThrowsError(try verifyingParser.parse(bytes)) { error in
            guard case .badChecksum(let expected, let calculated) = error as? ParseError else {
                XCTFail("expected badChecksum, got \(error)")
                return
            }
            XCTAssertEqual(expected, 0xff)
            XCTAssertEqual(calculated, 0x21)
        }
    }

    func test_checksumCorruptoBypassConFlag() throws {
        // Mismo frame corrupto, pero con verifyChecksum=false debe parsear OK
        let bytes = Data(hex: "55aa11000501010109ff")!
        let frame = try parser.parse(bytes)   // parser usa verifyChecksum=false
        XCTAssertEqual(frame, .idle(status: 0x01))
    }
}
