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
}
