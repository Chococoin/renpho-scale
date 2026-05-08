import XCTest
import RenphoBLE
@testable import renpho_scale

final class FrameParserTests: XCTestCase {

    /// Parser con verificación de checksum deshabilitada — usado en los tests que
    /// se enfocan en estructura/decodificación sin preocuparse del CK byte.
    private var parser: FrameParser {
        var p = FrameParser()
        p.verifyChecksum = false
        return p
    }

    // MARK: - Idle frames (frames reales de gatt.jsonl, 11 bytes c/u)

    func test_idleFramePrePesada() throws {
        // Frame real observado en gatt.jsonl. Layout: 5 header + 5 payload + 1 cksum.
        let bytes = Data(hex: "55aa110005010101090021")!
        let frame = try parser.parse(bytes)
        XCTAssertEqual(frame, .idle(status: 0x01))
    }

    func test_idleFramePostPesada() throws {
        // status=0x00; sum 0..9 = 0x120 → cksum 0x20.
        let bytes = Data(hex: "55aa110005000101090020")!
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
        // Idle bytes con sync invertido: aa 55 en lugar de 55 aa.
        let bytes = Data(hex: "aa55110005010101090021")!
        XCTAssertThrowsError(try parser.parse(bytes)) { error in
            XCTAssertEqual(error as? ParseError, .badSync)
        }
    }

    func test_lengthMismatch() {
        // Idle válido (11 bytes) con un byte extra al final (12 bytes).
        // len=5, expected total = 6 + 5 = 11, actual = 12 → mismatch.
        let bytes = Data(hex: "55aa11000501010109002100")!
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

    /// 75.00 kg sin impedancia. Layout payload: flags(2 LE)=0000, reserved(1)=00,
    /// weight(2 BE)=0x1D4C=7500, impedance(2 BE)=0000. cksum arbitrario (verify=false).
    func test_measurementSinImpedancia() throws {
        let bytes = Data(hex: "55aa1400070000001d4c000099")!
        let frame = try parser.parse(bytes)

        guard case .measurement(let flags, let weight, let impedance) = frame else {
            XCTFail("expected measurement, got \(frame)")
            return
        }
        XCTAssertEqual(flags, 0x0000)
        XCTAssertEqual(weight, 75.00, accuracy: 0.001)
        XCTAssertNil(impedance)
    }

    /// 75.40 kg con impedancia 500 Ω. flags LE 01 00 = 0x0001 (bit 0 set).
    func test_measurementConImpedancia() throws {
        let bytes = Data(hex: "55aa1400070100001d7401f499")!
        let frame = try parser.parse(bytes)

        guard case .measurement(let flags, let weight, let impedance) = frame else {
            XCTFail("expected measurement, got \(frame)")
            return
        }
        XCTAssertEqual(flags, 0x0001)
        XCTAssertEqual(weight, 75.40, accuracy: 0.001)
        XCTAssertEqual(impedance, 500)
    }

    /// Frame real con impedancia desde gatt.jsonl. Pin del layout completo + cksum.
    func test_measurementRealConImpedancia() throws {
        // 55aa14000701 00 002b a2 01a5 8e
        // flags=0x0001, weight=0x2BA2=11170 → 111.70 kg, impedance=0x01A5=421 Ω.
        // SUM 0..11 = 0x18E → cksum 0x8E. Verifyingparser debe pasar.
        let bytes = Data(hex: "55aa1400070100002ba201a58e")!
        let frame = try verifyingParser.parse(bytes)

        guard case .measurement(let flags, let weight, let impedance) = frame else {
            XCTFail("expected measurement, got \(frame)")
            return
        }
        XCTAssertEqual(flags, 0x0001)
        XCTAssertEqual(weight, 111.70, accuracy: 0.001)
        XCTAssertEqual(impedance, 421)
    }

    // MARK: - Unknown type

    func test_unknownType() {
        // type 0x0099, len=0 (sin payload, sólo cksum), 6 bytes total.
        let bytes = Data(hex: "55aa99000099")!
        XCTAssertThrowsError(try parser.parse(bytes)) { error in
            guard case .unknownType(let t) = error as? ParseError else {
                XCTFail("expected unknownType, got \(error)")
                return
            }
            XCTAssertEqual(t, 0x0099)
        }
    }

    // MARK: - Checksum verification

    /// Helper: parser con verificación habilitada (default real).
    private var verifyingParser: FrameParser {
        return FrameParser()
    }

    func test_checksumValidoPasaConVerificacion() throws {
        // Frame real de gatt.jsonl. SUM 0..9 = 0x121 → cksum 0x21.
        let bytes = Data(hex: "55aa110005010101090021")!
        let frame = try verifyingParser.parse(bytes)
        XCTAssertEqual(frame, .idle(status: 0x01))
    }

    func test_checksumCorruptoLanzaBadChecksum() {
        // Idle pre-pesada con cksum alterado de 0x21 a 0xff.
        let bytes = Data(hex: "55aa1100050101010900ff")!
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
        let bytes = Data(hex: "55aa1100050101010900ff")!
        let frame = try parser.parse(bytes)   // parser usa verifyChecksum=false
        XCTAssertEqual(frame, .idle(status: 0x01))
    }
}
