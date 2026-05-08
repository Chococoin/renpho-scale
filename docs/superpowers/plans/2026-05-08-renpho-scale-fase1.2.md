# Renpho Scale Fase 1.2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Construir `renpho-scale`, un cliente productivo que conecta vía GATT al Renpho Elis 1C, parsea los frames del char `2A10`, identifica la medición completa (peso + impedancia) y la persiste a JSONL — más una librería interna `RenphoBLE` con utilidades compartidas y un sub-modo `--probe-checksum` para identificar el algoritmo de checksum desde una captura.

**Architecture:** Tres ejecutables (`renpho-recon` sin tocar, `renpho-explore` refactorizado, `renpho-scale` nuevo) + library interna `RenphoBLE` (utilidades puras: hex, ISO8601 formatter, props→strings, UUIDs, errores comunes) + test target `RenphoScaleTests` cubriendo el parser puro. El cliente productivo hace discovery dirigido por UUIDs (más rápido que el Explorer), parser separado de la capa BLE para testeo aislado.

**Tech Stack:** Swift 5.9+, CoreBluetooth, Foundation, XCTest. macOS 11+. Sin dependencias externas.

**Spec de referencia:** `docs/superpowers/specs/2026-05-08-renpho-scale-fase1.2-design.md`

---

## File Structure

| Archivo | Estado | Responsabilidad |
|---------|--------|-----------------|
| `Package.swift` | Modify | Agregar library `RenphoBLE`, executable `renpho-scale`, test target `RenphoScaleTests`. Las deps de `renpho-explore` ahora incluyen `RenphoBLE`. |
| `Sources/RenphoBLE/Hex.swift` | Create | `Data.hex` y `Data(hex:)` (parser para fixtures). |
| `Sources/RenphoBLE/ISO8601+Fractional.swift` | Create | `extension ISO8601DateFormatter { static let fractional }` con fractional seconds. |
| `Sources/RenphoBLE/CBProperties+Strings.swift` | Create | `extension CBCharacteristicProperties { func descriptors() -> [String] }`. |
| `Sources/RenphoBLE/RenphoUUIDs.swift` | Create | Constantes `CBUUID`: services y characteristics que usamos. |
| `Sources/RenphoBLE/BLEErrors.swift` | Create | `BLEPowerError` y `BLEScanError` compartidos. |
| `Sources/renpho-explore/Explorer.swift` | Modify | Importar `RenphoBLE`, reemplazar errores de power state por `BLEPowerError`. |
| `Sources/renpho-explore/EventLogger.swift` | Modify | Importar `RenphoBLE`, borrar copias locales de `hex`, `ISO8601+Fractional`, `propsToArray`. |
| `Sources/renpho-scale/main.swift` | Create | Parseo args, orquestación, exit codes, dispatcher (medición vs `--probe-checksum`). |
| `Sources/renpho-scale/ScaleClient.swift` | Create | Delegate `CBCentralManager` + `CBPeripheral` enfocado: scan, connect, discovery dirigido, subscribe, metadata reads. |
| `Sources/renpho-scale/FrameParser.swift` | Create | Parser puro `55 aa…` con verificación de checksum hardcodeado. |
| `Sources/renpho-scale/Measurement.swift` | Create | Tipos: `Frame`, `MeasurementComplete`, `ParseError`, `ChecksumAlgorithm`, `Slice`. |
| `Sources/renpho-scale/ChecksumProbe.swift` | Create | Modo `--probe-checksum`: lee JSONL, prueba algoritmos × slices, identifica ganador. |
| `Sources/renpho-scale/EventLogger.swift` | Create | Console + JSONL para `ScaleEvent`, parseo de frames sobre la marcha, summary. |
| `Sources/RenphoScaleTests/FrameParserTests.swift` | Create | Tests del parser con `@testable import renpho_scale`. |
| `docs/superpowers/notes/2026-05-08-checksum-discovery.md` | Create | Salida de `--probe-checksum` + algoritmo identificado. |

---

## Task 1: Library `RenphoBLE` con utilidades extraídas

**Files:**
- Modify: `~/Projects/renpho-scale/Package.swift`
- Create: `~/Projects/renpho-scale/Sources/RenphoBLE/Hex.swift`
- Create: `~/Projects/renpho-scale/Sources/RenphoBLE/ISO8601+Fractional.swift`
- Create: `~/Projects/renpho-scale/Sources/RenphoBLE/CBProperties+Strings.swift`
- Create: `~/Projects/renpho-scale/Sources/RenphoBLE/RenphoUUIDs.swift`
- Create: `~/Projects/renpho-scale/Sources/RenphoBLE/BLEErrors.swift`

- [ ] **Step 1: Reemplazar `Package.swift` agregando el library target**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "renpho-scale",
    platforms: [.macOS(.v11)],
    targets: [
        .target(
            name: "RenphoBLE",
            path: "Sources/RenphoBLE"
        ),
        .executableTarget(
            name: "renpho-recon",
            path: "Sources/renpho-recon",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "renpho-explore",
            dependencies: ["RenphoBLE"],
            path: "Sources/renpho-explore",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        )
    ]
)
```

- [ ] **Step 2: Crear `Sources/RenphoBLE/Hex.swift`**

```swift
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
```

- [ ] **Step 3: Crear `Sources/RenphoBLE/ISO8601+Fractional.swift`**

```swift
import Foundation

public extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
```

- [ ] **Step 4: Crear `Sources/RenphoBLE/CBProperties+Strings.swift`**

```swift
import CoreBluetooth

public extension CBCharacteristicProperties {
    /// Convierte cada bit set a su nombre lowercase. Útil para JSONL/console.
    func descriptors() -> [String] {
        var out: [String] = []
        if contains(.read) { out.append("read") }
        if contains(.write) { out.append("write") }
        if contains(.writeWithoutResponse) { out.append("writeWithoutResponse") }
        if contains(.notify) { out.append("notify") }
        if contains(.indicate) { out.append("indicate") }
        if contains(.broadcast) { out.append("broadcast") }
        if contains(.notifyEncryptionRequired) { out.append("notifyEncryptionRequired") }
        if contains(.indicateEncryptionRequired) { out.append("indicateEncryptionRequired") }
        if contains(.extendedProperties) { out.append("extendedProperties") }
        if contains(.authenticatedSignedWrites) { out.append("authenticatedSignedWrites") }
        return out
    }
}
```

- [ ] **Step 5: Crear `Sources/RenphoBLE/RenphoUUIDs.swift`**

```swift
import CoreBluetooth

public enum RenphoUUIDs {
    // Renpho-proprietary measurement service
    public static let measurementService = CBUUID(string: "1A10")
    public static let measurementChar = CBUUID(string: "2A10")
    public static let writeChar = CBUUID(string: "2A11")  // unused for now

    // Device Information Service (standard SIG)
    public static let dis = CBUUID(string: "180A")
    public static let manufacturerName = CBUUID(string: "2A29")
    public static let modelNumber = CBUUID(string: "2A24")
    public static let serialNumber = CBUUID(string: "2A25")
    public static let hardwareRevision = CBUUID(string: "2A27")
    public static let firmwareRevision = CBUUID(string: "2A28")
    public static let softwareRevision = CBUUID(string: "2A26")
    public static let systemId = CBUUID(string: "2A23")

    // Battery Service (standard SIG)
    public static let battery = CBUUID(string: "180F")
    public static let batteryLevel = CBUUID(string: "2A19")
}
```

- [ ] **Step 6: Crear `Sources/RenphoBLE/BLEErrors.swift`**

```swift
import Foundation

/// Errores compartidos sobre el estado del adaptador Bluetooth y el scan.
/// Errores específicos del flujo de cada cliente (connectFailed, etc.) viven en
/// el módulo del cliente, no acá.
public enum BLEPowerError: Error {
    case unauthorized
    case poweredOff
    case unsupported
}

public enum BLEScanError: Error {
    case timeoutNoMatch
}
```

- [ ] **Step 7: Verificar que ambos targets siguen compilando**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds. `RenphoBLE` se compila como library, `renpho-recon` y `renpho-explore` siguen compilando (todavía no importan `RenphoBLE` — esto se hace en Task 2).

- [ ] **Step 8: Commit**

```bash
cd ~/Projects/renpho-scale
git add Package.swift Sources/RenphoBLE/
git commit -m "feat: extraer library RenphoBLE con utilidades compartidas

Hex, ISO8601 fractional formatter, CBCharacteristicProperties.descriptors(),
constantes de UUIDs Renpho/DIS/Battery, y errores BLEPowerError/BLEScanError
para que renpho-explore y el futuro renpho-scale los compartan."
```

---

## Task 2: Refactor `renpho-explore` para usar `RenphoBLE`

**Files:**
- Modify: `~/Projects/renpho-scale/Sources/renpho-explore/Explorer.swift`
- Modify: `~/Projects/renpho-scale/Sources/renpho-explore/EventLogger.swift`

- [ ] **Step 1: Modificar `Explorer.swift` para usar `BLEPowerError`**

Importar `RenphoBLE` y reemplazar los casos de power state del `ExplorerError` por re-throws de `BLEPowerError`. Los otros casos (`scanTimeoutNoMatch`, `connectFailed`) se quedan locales porque tienen forma específica.

Edit en la parte superior del archivo:

```swift
import Foundation
import CoreBluetooth
import RenphoBLE
```

Edit en `enum ExplorerError`: reemplazar los tres casos de power state por nada — los borramos. El enum queda con solo los casos específicos:

```swift
enum ExplorerError: Error {
    case scanTimeoutNoMatch
    case connectFailed(Error?)
}
```

Edit en `centralManagerDidUpdateState(_:)`: reemplazar los `cont.resume(throwing: ExplorerError.bluetooth*)` por los equivalentes `BLEPowerError.*`:

```swift
func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard let cont = powerOnContinuation else { return }
    powerOnContinuation = nil
    switch central.state {
    case .poweredOn:
        cont.resume()
    case .unauthorized:
        cont.resume(throwing: BLEPowerError.unauthorized)
    case .poweredOff:
        cont.resume(throwing: BLEPowerError.poweredOff)
    case .unsupported:
        cont.resume(throwing: BLEPowerError.unsupported)
    default:
        cont.resume(throwing: BLEPowerError.unsupported)
    }
}
```

- [ ] **Step 2: Modificar `main.swift` de `renpho-explore` para capturar `BLEPowerError`**

Edit en `Sources/renpho-explore/main.swift`:

Agregar el import al principio:

```swift
import Foundation
import RenphoBLE
```

Reemplazar los catch blocks de los errores de power:

```swift
} catch BLEPowerError.unauthorized {
    writeError("error: Bluetooth permission denied. Approve in System Settings → Privacy & Security → Bluetooth, then re-run.")
    exit(2)
} catch BLEPowerError.poweredOff {
    writeError("error: Bluetooth is off. Please enable it.")
    exit(3)
} catch BLEPowerError.unsupported {
    writeError("error: Bluetooth not supported on this Mac.")
    exit(3)
} catch ExplorerError.scanTimeoutNoMatch {
    writeError("error: scale not found within 15s. Is it active? Try waking it up.")
    exit(5)
} catch ExplorerError.connectFailed(let inner) {
    if let inner = inner {
        writeError("error: failed to connect: \(inner.localizedDescription)")
    } else {
        writeError("error: failed to connect: timeout after \(args.connectTimeout)s")
    }
    exit(6)
}
```

(Los catch existentes para los `ExplorerError.bluetooth*` se borran porque esos casos ya no existen.)

- [ ] **Step 3: Modificar `EventLogger.swift` para importar `RenphoBLE` y borrar duplicados**

Edit al principio:

```swift
import Foundation
import CoreBluetooth
import RenphoBLE
```

Borrar el método privado `private func hex(_ data: Data) -> String` — ahora `value.hex` viene de `RenphoBLE`. Reemplazar las llamadas internas:

En `consoleString(for:)`: cambiar `consoleHex(value)` se queda como está (usa `consoleHex` que es local; ese método interno usa `hex(_:)` que ahora hay que reemplazar). Editar `consoleHex(_:)`:

```swift
/// Hex con truncación cuando `--verbose` no está activo (más de 8 bytes → primeros 8 + "...").
/// JSONL siempre usa el `.hex` completo; esto solo se usa en console output.
private func consoleHex(_ data: Data) -> String {
    if consoleVerbose || data.count <= 8 {
        return data.hex
    }
    return data.prefix(8).hex + "..."
}
```

En `jsonDict(for:)`: reemplazar `dict["value"] = hex(value)` por `dict["value"] = value.hex`.

Borrar `private func propsToString(_ props:)` y `private func propsToArray(_ props:)`. Reemplazar las llamadas:
- `propsToString(props)` → `props.descriptors().joined(separator: ",")`
- `propsToArray(props)` → `props.descriptors()`

Borrar al final del archivo el bloque `extension ISO8601DateFormatter { static let fractional: ... }` — ahora viene de `RenphoBLE`.

- [ ] **Step 4: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: ambos targets (`renpho-recon`, `renpho-explore`) más library (`RenphoBLE`) compilan sin warnings sobre código del proyecto.

- [ ] **Step 5: Smoke test del binario refactorizado**

Run: `cd ~/Projects/renpho-scale && swift run renpho-explore --help`
Expected: imprime `usage: renpho-explore --filter <substring> [--duration <s>] [--connect-timeout <s>] [--verbose] [--out <path>]` y exit 0.

Run: `cd ~/Projects/renpho-scale && swift run renpho-explore; echo "exit=$?"`
Expected: stderr `error: --filter is required`, `exit=1`.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-explore/
git commit -m "refactor(renpho-explore): consumir utilidades de RenphoBLE

Borra copias locales de Data.hex, ISO8601 fractional formatter, propsToArray.
Reemplaza ExplorerError.bluetooth* por BLEPowerError.* compartido.
Sin cambios de comportamiento observable."
```

---

## Task 3: Crear target ejecutable `renpho-scale` + stub

**Files:**
- Modify: `~/Projects/renpho-scale/Package.swift`
- Create: `~/Projects/renpho-scale/Sources/renpho-scale/main.swift` (stub)

- [ ] **Step 1: Editar `Package.swift` para agregar el target ejecutable**

Edit el array de `targets:`. Después del bloque de `renpho-explore` (antes del cierre `]`), agregar:

```swift
,
.executableTarget(
    name: "renpho-scale",
    dependencies: ["RenphoBLE"],
    path: "Sources/renpho-scale",
    linkerSettings: [
        .unsafeFlags([
            "-Xlinker", "-sectcreate",
            "-Xlinker", "__TEXT",
            "-Xlinker", "__info_plist",
            "-Xlinker", "Resources/Info.plist"
        ])
    ]
)
```

- [ ] **Step 2: Crear stub `Sources/renpho-scale/main.swift`**

```swift
import Foundation

print("renpho-scale stub")
```

- [ ] **Step 3: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds. Tres binarios: `.build/debug/renpho-recon`, `.build/debug/renpho-explore`, `.build/debug/renpho-scale`.

- [ ] **Step 4: Verificar Info.plist embebido**

Run: `otool -s __TEXT __info_plist .build/debug/renpho-scale | tail -10`
Expected: hex dump no vacío, contiene `NSBluetoothAlwaysUsageDescription`.

- [ ] **Step 5: Smoke test del stub**

Run: `cd ~/Projects/renpho-scale && swift run renpho-scale`
Expected: imprime `renpho-scale stub`, exit 0.

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/renpho-scale
git add Package.swift Sources/renpho-scale/
git commit -m "feat: agregar target ejecutable renpho-scale (stub)"
```

---

## Task 4: Tipos en `Measurement.swift`

**Files:**
- Create: `~/Projects/renpho-scale/Sources/renpho-scale/Measurement.swift`

- [ ] **Step 1: Crear `Measurement.swift` completo**

```swift
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
```

- [ ] **Step 2: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-scale/Measurement.swift
git commit -m "feat: tipos del parser y del probe de checksum"
```

---

## Task 5: TDD — `FrameParser` esqueleto + idle frames

**Files:**
- Modify: `~/Projects/renpho-scale/Package.swift`
- Create: `~/Projects/renpho-scale/Sources/RenphoScaleTests/FrameParserTests.swift`
- Create: `~/Projects/renpho-scale/Sources/renpho-scale/FrameParser.swift`

- [ ] **Step 1: Agregar test target a `Package.swift`**

Edit el array de `targets:`. Después del bloque de `renpho-scale`, agregar:

```swift
,
.testTarget(
    name: "RenphoScaleTests",
    dependencies: ["renpho-scale", "RenphoBLE"],
    path: "Sources/RenphoScaleTests"
)
```

- [ ] **Step 2: Crear `FrameParserTests.swift` con primeros tests fallando (idle frames + errores básicos)**

```swift
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
```

- [ ] **Step 3: Crear stub `FrameParser.swift`**

```swift
import Foundation

struct FrameParser {
    var verifyChecksum: Bool = false   // default temporal hasta Task 8

    func parse(_ data: Data) throws -> Frame {
        // Stub: los tests deben fallar primero
        throw ParseError.tooShort
    }
}
```

- [ ] **Step 4: Correr tests para verificar que fallan**

Run: `cd ~/Projects/renpho-scale && swift test`
Expected: 4 tests fallan, 1 pasa.
- `test_tooShort` pasa por casualidad (el stub siempre tira `.tooShort`, que es lo que el test espera).
- `test_idleFramePrePesada` y `test_idleFramePostPesada` fallan porque esperan `.idle(...)` y el stub tira error.
- `test_badSync` falla porque espera `.badSync` y el stub tira `.tooShort`.
- `test_lengthMismatch` falla por la misma razón.

Lo importante es ver que XCTest corre y los tests están conectados al parser; los detalles del fallo (4/5 vs 5/5) pueden variar y no afectan la siguiente etapa.

- [ ] **Step 5: Implementar parser con manejo de sync, length, type idle**

Reemplazar el contenido de `FrameParser.swift`:

```swift
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
```

- [ ] **Step 6: Correr tests para verificar que pasan**

Run: `cd ~/Projects/renpho-scale && swift test`
Expected: 4/4 tests pasan.

- [ ] **Step 7: Commit**

```bash
cd ~/Projects/renpho-scale
git add Package.swift Sources/renpho-scale/FrameParser.swift Sources/RenphoScaleTests/
git commit -m "feat: FrameParser con sync/length checks + idle frames + tests"
```

---

## Task 6: TDD — measurement frames + unknownType

**Files:**
- Modify: `~/Projects/renpho-scale/Sources/RenphoScaleTests/FrameParserTests.swift`
- Modify: `~/Projects/renpho-scale/Sources/renpho-scale/FrameParser.swift`

- [ ] **Step 1: Agregar tests de measurement y unknownType al final de la clase `FrameParserTests`**

Edit `FrameParserTests.swift`. Antes del último `}` que cierra la clase, agregar:

```swift
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
        // type 0x0099, len 0 (sólo sync+type+len+cksum), sin datos útiles, cksum 0x00
        let bytes = Data(hex: "55aa99000100")!
        XCTAssertThrowsError(try parser.parse(bytes)) { error in
            guard case .unknownType(let t) = error as? ParseError else {
                XCTFail("expected unknownType, got \(error)")
                return
            }
            XCTAssertEqual(t, 0x0099)
        }
    }
```

- [ ] **Step 2: Correr tests, verificar que fallan los 3 nuevos**

Run: `cd ~/Projects/renpho-scale && swift test`
Expected: 4 pasan (los anteriores), 3 fallan (el branch `0x0014` no está implementado, tira `unknownType(0x0014)`; el test `unknownType(0x0099)` técnicamente puede fallar en lengthMismatch antes — verificá el error).

Nota: el test `test_unknownType` con `len=1` y `data.count=6`: la regla es `data.count == 5 + len` → `6 == 5 + 1` ✓. Length OK, debería caer al switch del type.

- [ ] **Step 3: Extender el switch en `FrameParser.parse(_:)` para manejar measurement**

Reemplazar el bloque `switch type` en `FrameParser.swift`:

```swift
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
```

- [ ] **Step 4: Correr tests, verificar que todos pasan**

Run: `cd ~/Projects/renpho-scale && swift test`
Expected: 7/7 tests pasan.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-scale/FrameParser.swift Sources/RenphoScaleTests/FrameParserTests.swift
git commit -m "feat: parser de measurement frames con flags LE + tests"
```

---

## Task 7: `ChecksumProbe` + modo `--probe-checksum`

**Files:**
- Create: `~/Projects/renpho-scale/Sources/renpho-scale/ChecksumProbe.swift`
- Modify: `~/Projects/renpho-scale/Sources/renpho-scale/main.swift`
- Create: `~/Projects/renpho-scale/docs/superpowers/notes/2026-05-08-checksum-discovery.md`

- [ ] **Step 1: Crear `ChecksumProbe.swift`**

```swift
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
```

- [ ] **Step 2: Reemplazar `main.swift` con dispatcher para los dos modos**

Reemplazar `Sources/renpho-scale/main.swift`:

```swift
import Foundation

func writeError(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func printUsage() {
    print("""
    usage: renpho-scale --filter <substring> [--out <path>] [--connect-timeout <s>]
                        [--timeout <s>] [--no-verify-checksum] [--verbose]
           renpho-scale --probe-checksum <jsonl-path>
    """)
}

// Parse args
let argv = CommandLine.arguments
var probePath: String? = nil
var i = 1
while i < argv.count {
    let a = argv[i]
    switch a {
    case "--probe-checksum":
        i += 1
        guard i < argv.count else {
            writeError("error: --probe-checksum requires a path")
            exit(1)
        }
        probePath = argv[i]
    case "-h", "--help":
        printUsage()
        exit(0)
    default:
        // Otros flags se manejan en Task 12 cuando exista el modo medición.
        // Por ahora, sin --probe-checksum, exit 1 indicando que falta implementar.
        break
    }
    i += 1
}

if let probePath = probePath {
    let probe = ChecksumProbe()
    do {
        let result = try probe.run(jsonlPath: probePath)
        print("--- Checksum probe ---")
        print("Frames analyzed: \(result.totalFrames)")
        print("")
        print(String(format: "%-40s %-22s %s", "Algorithm", "Slice", "Matches"))
        for c in result.candidates {
            let mark = c.matchCount == result.totalFrames ? " ✓" : ""
            print(String(format: "%-40s %-22s %d/%d%@",
                         c.algorithm.rawValue,
                         c.slice.rawValue,
                         c.matchCount,
                         result.totalFrames,
                         mark))
        }
        print("")
        if let w = result.winner {
            print("Winner: \(w.algorithm.rawValue) over \(w.slice.rawValue) — \(w.matchCount)/\(result.totalFrames) frames")
            exit(0)
        } else {
            writeError("error: no unique algorithm matched all frames")
            exit(9)
        }
    } catch ChecksumProbe.ProbeError.fileNotReadable(let path) {
        writeError("error: cannot read \(path)")
        exit(1)
    } catch ChecksumProbe.ProbeError.noFramesFound {
        writeError("error: no valid frames found in JSONL")
        exit(9)
    } catch {
        writeError("error: \(error)")
        exit(1)
    }
}

// Modo medición: stub hasta Task 12
writeError("error: measurement mode not yet implemented (will be added in Task 12)")
exit(1)
```

- [ ] **Step 3: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds.

- [ ] **Step 4: Verificar `--help`**

Run: `cd ~/Projects/renpho-scale && swift run renpho-scale --help`
Expected: imprime usage en dos líneas, exit 0.

- [ ] **Step 5: Correr `--probe-checksum` contra el JSONL existente**

Run: `cd ~/Projects/renpho-scale && swift run renpho-scale --probe-checksum gatt.jsonl 2>&1 | tee probe-output.txt`

Expected: tabla de algoritmos vs slices con matches, una línea con el ganador (idealmente "Winner: <algorithm> over <slice> — 28/28 frames" o similar). Exit 0 si hay ganador único, exit 9 si no.

**Si exit es 0 (ganador único)**: capturar el output `probe-output.txt` e identificar el ganador. Usarlo en el siguiente paso.

**Si exit es 9 (sin ganador único)**: leer la tabla. Si hay múltiples 100%, los algoritmos son ambiguos con sólo 28 frames — habría que capturar más datos. Si ninguno llega a 100%, puede ser un algoritmo no incluido en `ChecksumAlgorithm`. En cualquiera de los dos casos, abrir un GitHub issue / nota TODO y proceder con `verifyChecksum=false` por default — la implementación queda igual, solo Task 8 se vuelve trivial.

- [ ] **Step 6: Crear nota técnica con la salida**

Crear `~/Projects/renpho-scale/docs/superpowers/notes/2026-05-08-checksum-discovery.md` con esta estructura, llenando los datos reales del probe:

```markdown
# Renpho Elis 1C — Descubrimiento del checksum

**Fecha:** 2026-05-08
**Captura usada:** `gatt.jsonl` de la sesión 2026-05-07 (28 frames del char `2a10`).
**Comando:** `swift run renpho-scale --probe-checksum gatt.jsonl`

## Resultado

**Algoritmo identificado:** `<algorithm>` sobre slice `<slice>` con `<N>/<N>` matches.

## Tabla completa

```
<pegar tabla del output del comando>
```

## Implicaciones

El algoritmo queda hardcodeado en `FrameParser.swift::computeChecksum(_:)`. El sub-comando `--probe-checksum` queda disponible para validar contra futuras capturas (firmware nuevo, otro modelo Renpho).

## Reproducibilidad

Para validar contra una nueva captura:
```
swift run renpho-explore --filter "R-A033" --duration 90 --verbose --out gatt-new.jsonl
swift run renpho-scale --probe-checksum gatt-new.jsonl
```
```

- [ ] **Step 7: Limpiar el archivo temporal y commit**

```bash
cd ~/Projects/renpho-scale
rm -f probe-output.txt
git add Sources/renpho-scale/ChecksumProbe.swift \
        Sources/renpho-scale/main.swift \
        docs/superpowers/notes/2026-05-08-checksum-discovery.md
git commit -m "feat: ChecksumProbe + sub-modo --probe-checksum

Identifica el algoritmo de checksum desde una captura JSONL del Explorer.
Disponible en el binario productivo como capacidad de validación a futuro.

Algoritmo identificado contra gatt.jsonl 2026-05-07 documentado en
docs/superpowers/notes/2026-05-08-checksum-discovery.md."
```

---

## Task 8: Hardcodear algoritmo en `FrameParser` + tests de checksum

**Files:**
- Modify: `~/Projects/renpho-scale/Sources/renpho-scale/FrameParser.swift`
- Modify: `~/Projects/renpho-scale/Sources/RenphoScaleTests/FrameParserTests.swift`

**Pre-condición:** Task 7 produjo un algoritmo identificado (winner = `<alg>` × `<slice>`). En los pasos abajo, sustituir `<ALGO>` y `<SLICE>` por los valores concretos del probe.

- [ ] **Step 1: Reemplazar `FrameParser.swift` con la lógica de checksum hardcodeada**

```swift
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
            let flags = UInt16(data[5]) | (UInt16(data[6]) << 8)
            let weightRaw = (UInt16(data[7]) << 8) | UInt16(data[8])
            let weight = Double(weightRaw) * 0.01
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
    /// Detalles en docs/superpowers/notes/2026-05-08-checksum-discovery.md.
    /// SUSTITUIR el cuerpo de esta función según el algoritmo y slice ganadores.
    static func computeChecksum(_ frame: Data) -> UInt8 {
        // Slice ganadora: <SLICE>. Reemplazar el slice si la ganadora fue otra:
        //   .payloadOnly       → frame[5..<frame.count-1]
        //   .headerPlusPayload → frame[2..<frame.count-1]
        //   .fullFrameMinusCk  → frame[0..<frame.count-1]
        let region = frame[5..<frame.count - 1]   // ← cambiar slice si corresponde

        // Algoritmo ganador: <ALGO>. Implementación según ChecksumProbe.compute(_:with:):
        //   .xor              → fold con XOR
        //   .sumMod256        → suma mod 256
        //   .sumMod256Negated → (suma mod 256) ^ 0xFF
        //   .twosComplement   → (~suma + 1) mod 256
        //   .crc8Poly07       → CRC-8 poly 0x07, no reflect
        //   .crc8Maxim        → CRC-8/MAXIM (reflect in/out, poly 0x31)
        // Reemplazar el cuerpo de abajo según el algoritmo:
        var x: UInt8 = 0   // ← este es el cuerpo de XOR; cambiar si fue otro
        for b in region { x ^= b }
        return x
    }
}
```

> **Nota para el implementador:** este step requiere editar dos cosas concretas según el resultado del probe (Task 7):
> 1. La línea del `region` para usar el slice correcto.
> 2. El cuerpo del cómputo para usar el algoritmo correcto.
>
> El bloque está armado para que sólo cambies esas dos cosas. Si el algoritmo es CRC-8, copiar el helper privado `crc8(...)` de `ChecksumProbe.swift` a `FrameParser.swift` (o factorizarlo a una extension en `RenphoBLE` — preferible si el otro consumidor también lo querrá).

- [ ] **Step 2: Verificar que los tests pre-existentes pasan con `verifyChecksum=false`**

(Los tests de Task 5/6 usan `verifyChecksum=false`, así que deberían seguir pasando incluso si el cuerpo de `computeChecksum` no es el correcto todavía.)

Run: `cd ~/Projects/renpho-scale && swift test`
Expected: 7/7 tests pasan.

- [ ] **Step 3: Agregar tests de checksum a `FrameParserTests.swift`**

Edit `FrameParserTests.swift`. Antes del último `}` que cierra la clase, agregar:

```swift
    // MARK: - Checksum verification

    /// Helper: parser con verificación habilitada (default real)
    private var verifyingParser: FrameParser {
        return FrameParser()  // verifyChecksum=true por default
    }

    func test_checksumValidoPasaConVerificacion() throws {
        // Frame real de gatt.jsonl: idle pre-pesada, CK byte real
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
            XCTAssertNotEqual(calculated, 0xff)
        }
    }

    func test_checksumCorruptoBypassConFlag() throws {
        // Mismo frame corrupto, pero con verifyChecksum=false debe parsear OK
        let bytes = Data(hex: "55aa11000501010109ff")!
        let frame = try parser.parse(bytes)   // parser usa verifyChecksum=false
        XCTAssertEqual(frame, .idle(status: 0x01))
    }
```

- [ ] **Step 4: Correr tests, verificar 10/10 pasan**

Run: `cd ~/Projects/renpho-scale && swift test`
Expected: 10/10 tests pasan.

**Si `test_checksumValidoPasaConVerificacion` falla**: significa que el algoritmo hardcodeado en `computeChecksum` no es correcto. Re-ejecutar Task 7 step 5 para confirmar el ganador y revisar la edición de `computeChecksum` en step 1 de esta task.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-scale/FrameParser.swift Sources/RenphoScaleTests/FrameParserTests.swift
git commit -m "feat: hardcodear algoritmo de checksum identificado + tests de verificación"
```

---

## Task 9: `ScaleClient` — scan + connect

**Files:**
- Create: `~/Projects/renpho-scale/Sources/renpho-scale/ScaleClient.swift`

- [ ] **Step 1: Crear `ScaleClient.swift` con tipos y delegate skeleton**

```swift
import Foundation
import CoreBluetooth
import RenphoBLE

// MARK: - Public types

enum ScaleEvent {
    case scanStarted
    case peripheralFound(name: String, identifier: UUID)
    case connecting
    case connected
    case metadataRead(field: MetadataField, data: Data)
    case metadataReadFailed(field: MetadataField, error: Error)
    case subscribed
    case rawNotification(value: Data)
    case disconnected(error: Error?)
}

enum MetadataField: String {
    case manufacturerName, modelNumber, serialNumber
    case firmwareRevision, hardwareRevision, softwareRevision
    case systemId
    case batteryLevel
}

enum ScaleClientError: Error {
    case scanTimeoutNoMatch
    case connectFailed(Error?)
}

// MARK: - ScaleClient

final class ScaleClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var nameFilter: String = ""

    private var continuation: AsyncStream<ScaleEvent>.Continuation?

    // One-shot continuations per phase
    private var powerOnContinuation: CheckedContinuation<Void, Error>?
    private var foundContinuation: CheckedContinuation<CBPeripheral, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?

    // Tracking pending operations to know when to emit .subscribed
    private var pendingMetadataReads: Set<CBUUID> = []
    private var hasSubscribed = false

    func run(
        nameFilter: String,
        scanTimeout: TimeInterval = 15,
        connectTimeout: TimeInterval = 10
    ) async throws -> AsyncStream<ScaleEvent> {
        self.nameFilter = nameFilter

        let (stream, cont) = AsyncStream<ScaleEvent>.makeStream()
        self.continuation = cont

        // Phase A: power state
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.powerOnContinuation = c
            self.central = CBCentralManager(delegate: self, queue: nil)
        }

        // Phase B: scan
        cont.yield(.scanStarted)
        let p: CBPeripheral = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CBPeripheral, Error>) in
            self.foundContinuation = c
            self.central.scanForPeripherals(withServices: nil, options: nil)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(scanTimeout * 1_000_000_000))
                guard let self else { return }
                guard let cont = self.foundContinuation else { return }
                self.foundContinuation = nil
                self.central?.stopScan()
                cont.resume(throwing: ScaleClientError.scanTimeoutNoMatch)
            }
        }
        self.peripheral = p
        p.delegate = self
        cont.yield(.peripheralFound(name: p.name ?? "<unnamed>", identifier: p.identifier))

        // Phase C: connect
        cont.yield(.connecting)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.connectContinuation = c
            self.central.connect(p, options: nil)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(connectTimeout * 1_000_000_000))
                guard let self else { return }
                guard let cont = self.connectContinuation else { return }
                self.connectContinuation = nil
                self.central?.cancelPeripheralConnection(p)
                cont.resume(throwing: ScaleClientError.connectFailed(nil))
            }
        }
        cont.yield(.connected)

        // Phase D: discovery (Task 10 hook — by now this is a stub: peripheral disconnects soon)
        // For now, just kick off discoverServices(nil) so the peripheral doesn't immediately drop.
        // Task 10 swaps this for directed discovery.
        p.discoverServices([RenphoUUIDs.measurementService, RenphoUUIDs.dis, RenphoUUIDs.battery])

        return stream
    }

    func stop() {
        if let p = peripheral {
            central?.cancelPeripheralConnection(p)
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let cont = powerOnContinuation else { return }
        powerOnContinuation = nil
        switch central.state {
        case .poweredOn:
            cont.resume()
        case .unauthorized:
            cont.resume(throwing: BLEPowerError.unauthorized)
        case .poweredOff:
            cont.resume(throwing: BLEPowerError.poweredOff)
        case .unsupported:
            cont.resume(throwing: BLEPowerError.unsupported)
        default:
            cont.resume(throwing: BLEPowerError.unsupported)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        guard !name.isEmpty,
              name.lowercased().contains(nameFilter.lowercased()) else { return }
        guard let cont = foundContinuation else { return }
        foundContinuation = nil
        central.stopScan()
        cont.resume(returning: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let cont = connectContinuation else { return }
        connectContinuation = nil
        cont.resume()
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard let cont = connectContinuation else { return }
        connectContinuation = nil
        cont.resume(throwing: ScaleClientError.connectFailed(error))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        continuation?.yield(.disconnected(error: error))
        continuation?.finish()
        continuation = nil
    }

    // MARK: - CBPeripheralDelegate (rest in Task 10)
}
```

- [ ] **Step 2: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds (sin warnings de proyecto).

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-scale/ScaleClient.swift
git commit -m "feat: ScaleClient skeleton — scan, connect, power state"
```

---

## Task 10: `ScaleClient` — discovery dirigido + subscribe + metadata

**Files:**
- Modify: `~/Projects/renpho-scale/Sources/renpho-scale/ScaleClient.swift`

- [ ] **Step 1: Agregar handlers de `CBPeripheralDelegate` al final de `ScaleClient`**

Edit `ScaleClient.swift`. Antes del último `}` que cierra la clase, agregar:

```swift
    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }

        // Map service UUID → expected characteristics list
        let charsForService: [CBUUID: [CBUUID]] = [
            RenphoUUIDs.measurementService: [RenphoUUIDs.measurementChar],
            RenphoUUIDs.dis: [
                RenphoUUIDs.manufacturerName,
                RenphoUUIDs.modelNumber,
                RenphoUUIDs.serialNumber,
                RenphoUUIDs.hardwareRevision,
                RenphoUUIDs.firmwareRevision,
                RenphoUUIDs.softwareRevision,
                RenphoUUIDs.systemId
            ],
            RenphoUUIDs.battery: [RenphoUUIDs.batteryLevel]
        ]

        for service in services {
            if let expected = charsForService[service.uuid] {
                peripheral.discoverCharacteristics(expected, for: service)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let chars = service.characteristics else { return }

        for char in chars {
            // Subscribe a la char de measurement
            if char.uuid == RenphoUUIDs.measurementChar {
                peripheral.setNotifyValue(true, for: char)
                continue
            }

            // Reads de metadata (DIS + Battery)
            if let field = metadataField(for: char.uuid) {
                pendingMetadataReads.insert(char.uuid)
                peripheral.readValue(for: char)
                _ = field   // referenced when the read returns
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Notification del char de measurement
        if characteristic.uuid == RenphoUUIDs.measurementChar
           && pendingMetadataReads.contains(characteristic.uuid) == false {
            // Es notification — sólo emit si ya nos subscribimos (puede llegar valor inicial pre-subscribe)
            if let value = characteristic.value, error == nil {
                continuation?.yield(.rawNotification(value: value))
            }
            return
        }

        // Read response de metadata
        if pendingMetadataReads.contains(characteristic.uuid),
           let field = metadataField(for: characteristic.uuid) {
            pendingMetadataReads.remove(characteristic.uuid)
            if let error = error {
                continuation?.yield(.metadataReadFailed(field: field, error: error))
            } else if let value = characteristic.value {
                continuation?.yield(.metadataRead(field: field, data: value))
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == RenphoUUIDs.measurementChar else { return }
        if error == nil && characteristic.isNotifying && !hasSubscribed {
            hasSubscribed = true
            continuation?.yield(.subscribed)
        }
    }

    // MARK: - Helpers

    private func metadataField(for uuid: CBUUID) -> MetadataField? {
        switch uuid {
        case RenphoUUIDs.manufacturerName: return .manufacturerName
        case RenphoUUIDs.modelNumber:      return .modelNumber
        case RenphoUUIDs.serialNumber:     return .serialNumber
        case RenphoUUIDs.firmwareRevision: return .firmwareRevision
        case RenphoUUIDs.hardwareRevision: return .hardwareRevision
        case RenphoUUIDs.softwareRevision: return .softwareRevision
        case RenphoUUIDs.systemId:         return .systemId
        case RenphoUUIDs.batteryLevel:     return .batteryLevel
        default:                            return nil
        }
    }
```

- [ ] **Step 2: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-scale/ScaleClient.swift
git commit -m "feat: ScaleClient — directed discovery, subscribe a 2A10, metadata reads"
```

---

## Task 11: `EventLogger` para `renpho-scale`

**Files:**
- Create: `~/Projects/renpho-scale/Sources/renpho-scale/EventLogger.swift`

- [ ] **Step 1: Crear `EventLogger.swift`**

```swift
import Foundation
import CoreBluetooth
import RenphoBLE

final class EventLogger {

    private let consoleVerbose: Bool
    private let jsonlHandle: FileHandle?
    private let parser: FrameParser

    // Snapshot de metadata para enriquecer measurement_complete
    private(set) var metadataSnapshot: [MetadataField: Any] = [:]

    // Última measurement frame parseada (para fallback "incomplete")
    private(set) var lastMeasurement: (frame: Frame, rawHex: String)?

    init(verbose: Bool, outputPath: String?, parser: FrameParser) throws {
        self.consoleVerbose = verbose
        self.parser = parser
        if let outputPath = outputPath {
            let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let h = try? FileHandle(forWritingTo: url) else {
                throw EventLoggerError.cannotOpen(path: outputPath)
            }
            try h.seekToEnd()
            self.jsonlHandle = h
        } else {
            self.jsonlHandle = nil
        }
    }

    /// Procesa un evento del cliente: imprime a consola + persiste a JSONL +
    /// si es rawNotification, la parsea y emite los eventos derivados (frame / frame_error).
    /// Devuelve la `Frame` parseada si la notification dió un frame válido,
    /// nil en cualquier otro caso (incluyendo errores de parseo).
    @discardableResult
    func handle(_ event: ScaleEvent) -> Frame? {
        switch event {
        case .scanStarted:
            consoleLine("[\(now())] scan started")
            writeJSONL(["type": "scan_started"])
        case .peripheralFound(let name, let id):
            consoleLine("[\(now())] found \(name) (\(String(id.uuidString.prefix(8))))")
            writeJSONL([
                "type": "peripheral_found",
                "name": name,
                "id": id.uuidString.lowercased()
            ])
        case .connecting:
            consoleLine("[\(now())] connecting...")
            writeJSONL(["type": "connecting"])
        case .connected:
            consoleLine("[\(now())] connected")
            writeJSONL(["type": "connected"])
        case .metadataRead(let field, let data):
            handleMetadataRead(field: field, data: data)
        case .metadataReadFailed(let field, let error):
            consoleLine("[\(now())] \(field.rawValue): <unavailable>")
            writeJSONL([
                "type": "metadata_failed",
                "field": fieldKey(field),
                "error": error.localizedDescription
            ])
        case .subscribed:
            consoleLine("[\(now())] subscribed — subite a la balanza")
            print("")
            writeJSONL(["type": "subscribed"])
        case .rawNotification(let value):
            return handleRawNotification(value)
        case .disconnected(let error):
            if let e = error {
                consoleLine("[\(now())] disconnected (error: \(e.localizedDescription))")
                writeJSONL(["type": "disconnected", "error": e.localizedDescription])
            } else {
                consoleLine("[\(now())] disconnected")
                writeJSONL(["type": "disconnected"])
            }
        }
        return nil
    }

    /// Loguea un measurement_complete a consola + JSONL. Llamado desde main.
    func logMeasurementComplete(_ m: MeasurementComplete) {
        let mark = m.incomplete ? "(incomplete)" : "✓ medición completa"
        let weightStr = String(format: "%.2f", m.weightKg)
        consoleLine("[\(now())] peso \(weightStr) kg | impedancia \(m.impedanceOhms) Ω \(mark)")
        print("")
        print("--- Resultado ---")
        print(String(format: "peso:        %.2f kg", m.weightKg))
        print("impedancia:  \(m.impedanceOhms) Ω")
        if let battery = metadataSnapshot[.batteryLevel] {
            print("batería:     \(battery)%")
        }
        if let firmware = metadataSnapshot[.firmwareRevision] as? String {
            print("firmware:    \(firmware)")
        }

        var dict: [String: Any] = [
            "type": "measurement_complete",
            "weight_kg": m.weightKg,
            "impedance_ohms": Int(m.impedanceOhms),
            "raw": m.rawHex,
            "incomplete": m.incomplete
        ]
        if let battery = metadataSnapshot[.batteryLevel] as? Int {
            dict["battery_level"] = battery
        }
        if let firmware = metadataSnapshot[.firmwareRevision] as? String {
            dict["firmware"] = firmware
        }
        writeJSONL(dict)
    }

    func close() {
        try? jsonlHandle?.close()
    }

    // MARK: - Private: notification → frame

    private func handleRawNotification(_ value: Data) -> Frame? {
        let rawHex = value.hex
        do {
            let frame = try parser.parse(value)
            // Save measurement frames for fallback
            if case .measurement = frame {
                lastMeasurement = (frame, rawHex)
            }
            // Console
            switch frame {
            case .idle(let status):
                if consoleVerbose {
                    consoleLine("[\(now())]   idle status=\(status) raw=\(rawHex)")
                }
            case .measurement(let flags, let weight, let impedance):
                let weightStr = String(format: "%.2f", weight)
                if let imp = impedance, (flags & 1) == 1 {
                    consoleLine("[\(now())] peso \(weightStr) kg | impedancia \(imp) Ω")
                } else {
                    consoleLine("[\(now())] peso \(weightStr) kg")
                }
                if consoleVerbose {
                    consoleLine("            flags=0x\(String(format: "%04x", flags)) raw=\(rawHex)")
                }
            }
            // JSONL
            writeJSONL(jsonDict(for: frame, rawHex: rawHex))
            return frame
        } catch let parseError as ParseError {
            // frame_error
            let (errKind, expected, calculated) = parseErrorParts(parseError)
            var dict: [String: Any] = [
                "type": "frame_error",
                "raw": rawHex,
                "error": errKind
            ]
            if let e = expected { dict["expected"] = e }
            if let c = calculated { dict["calculated"] = c }
            if consoleVerbose {
                consoleLine("[\(now())]   frame_error \(errKind) raw=\(rawHex)")
            }
            writeJSONL(dict)
            return nil
        } catch {
            return nil
        }
    }

    private func parseErrorParts(_ e: ParseError) -> (String, String?, String?) {
        switch e {
        case .tooShort:                       return ("tooShort", nil, nil)
        case .badSync:                        return ("badSync", nil, nil)
        case .unknownType(let t):             return ("unknownType_\(String(format: "%04x", t))", nil, nil)
        case .lengthMismatch(let d, let a):   return ("lengthMismatch", "\(d)", "\(a)")
        case .badChecksum(let exp, let calc): return ("badChecksum",
                                                       String(format: "%02x", exp),
                                                       String(format: "%02x", calc))
        }
    }

    private func jsonDict(for frame: Frame, rawHex: String) -> [String: Any] {
        var dict: [String: Any] = ["type": "frame", "raw": rawHex]
        switch frame {
        case .idle(let status):
            dict["kind"] = "idle"
            dict["status"] = Int(status)
        case .measurement(let flags, let weight, let impedance):
            dict["kind"] = "measurement"
            dict["flags"] = Int(flags)
            dict["weight_kg"] = weight
            if let imp = impedance {
                dict["impedance_ohms"] = Int(imp)
            }
        }
        return dict
    }

    // MARK: - Private: metadata

    private func handleMetadataRead(field: MetadataField, data: Data) {
        let humanValue: Any
        var jsonValue: Any
        switch field {
        case .manufacturerName, .modelNumber, .serialNumber,
             .firmwareRevision, .hardwareRevision, .softwareRevision:
            let str = String(data: data, encoding: .utf8) ?? data.hex
            humanValue = str
            jsonValue = str
        case .systemId:
            // 8 bytes; los primeros 6 son la MAC (en algunos chips little-endian).
            humanValue = data.hex
            jsonValue = data.hex
        case .batteryLevel:
            // 1 byte: 0..100
            let level = data.first.map { Int($0) } ?? 0
            humanValue = level
            jsonValue = level
        }
        metadataSnapshot[field] = jsonValue

        consoleLine("[\(now())] \(humanLabel(field)): \(humanValue)\(field == .batteryLevel ? "%" : "")")
        writeJSONL([
            "type": "metadata",
            "field": fieldKey(field),
            "value": jsonValue
        ])
    }

    private func humanLabel(_ field: MetadataField) -> String {
        switch field {
        case .manufacturerName:  return "manufacturer"
        case .modelNumber:       return "model"
        case .serialNumber:      return "serial"
        case .firmwareRevision:  return "firmware"
        case .hardwareRevision:  return "hardware"
        case .softwareRevision:  return "software"
        case .systemId:          return "system_id"
        case .batteryLevel:      return "battery"
        }
    }

    private func fieldKey(_ field: MetadataField) -> String {
        // snake_case para el JSONL, consistente con las convenciones de las fases anteriores
        switch field {
        case .manufacturerName:  return "manufacturer_name"
        case .modelNumber:       return "model_number"
        case .serialNumber:      return "serial_number"
        case .firmwareRevision:  return "firmware_revision"
        case .hardwareRevision:  return "hardware_revision"
        case .softwareRevision:  return "software_revision"
        case .systemId:          return "system_id"
        case .batteryLevel:      return "battery_level"
        }
    }

    // MARK: - Private: I/O helpers

    private func consoleLine(_ s: String) {
        print(s)
    }

    private func now() -> String {
        return ConsoleTime.string(from: Date())
    }

    private func writeJSONL(_ dict: [String: Any]) {
        guard let handle = jsonlHandle else { return }
        var withTs = dict
        withTs["ts"] = ISO8601DateFormatter.fractional.string(from: Date())
        guard let data = try? JSONSerialization.data(
            withJSONObject: withTs,
            options: [.sortedKeys]
        ) else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }
}

enum EventLoggerError: Error {
    case cannotOpen(path: String)
}

/// Time helper local (HH:mm:ss.SSS) — duplicado mínimo de renpho-explore;
/// no vale la pena subirlo a RenphoBLE por 8 líneas.
private enum ConsoleTime {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static func string(from date: Date) -> String {
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 2: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-scale/EventLogger.swift
git commit -m "feat: EventLogger para renpho-scale (consola + JSONL + parser inline)"
```

---

## Task 12: `main.swift` — orquestación completa

**Files:**
- Modify: `~/Projects/renpho-scale/Sources/renpho-scale/main.swift`

- [ ] **Step 1: Reemplazar `main.swift` con la implementación completa**

```swift
import Foundation
import RenphoBLE

// MARK: - Args

struct Args {
    var filter: String? = nil
    var out: String? = nil
    var connectTimeout: TimeInterval = 10
    var timeout: TimeInterval = 60
    var verbose: Bool = false
    var noVerifyChecksum: Bool = false
    var probeChecksumPath: String? = nil
}

func writeError(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func printUsage() {
    print("""
    usage: renpho-scale --filter <substring> [--out <path>] [--connect-timeout <s>]
                        [--timeout <s>] [--no-verify-checksum] [--verbose]
           renpho-scale --probe-checksum <jsonl-path>
    """)
}

func parseArgs() -> Args {
    var args = Args()
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--filter":
            i += 1
            guard i < argv.count else {
                writeError("error: --filter requires a value"); exit(1)
            }
            args.filter = argv[i]
        case "--out":
            i += 1
            guard i < argv.count else {
                writeError("error: --out requires a path"); exit(1)
            }
            args.out = argv[i]
        case "--connect-timeout":
            i += 1
            guard i < argv.count, let d = Double(argv[i]), d > 0 else {
                writeError("error: --connect-timeout requires a positive number"); exit(1)
            }
            args.connectTimeout = d
        case "--timeout":
            i += 1
            guard i < argv.count, let d = Double(argv[i]), d > 0 else {
                writeError("error: --timeout requires a positive number"); exit(1)
            }
            args.timeout = d
        case "--verbose":
            args.verbose = true
        case "--no-verify-checksum":
            args.noVerifyChecksum = true
        case "--probe-checksum":
            i += 1
            guard i < argv.count else {
                writeError("error: --probe-checksum requires a path"); exit(1)
            }
            args.probeChecksumPath = argv[i]
        case "-h", "--help":
            printUsage(); exit(0)
        default:
            writeError("error: unknown arg \(a)"); exit(1)
        }
        i += 1
    }
    return args
}

let args = parseArgs()

// MARK: - Probe mode

if let probePath = args.probeChecksumPath {
    let probe = ChecksumProbe()
    do {
        let result = try probe.run(jsonlPath: probePath)
        print("--- Checksum probe ---")
        print("Frames analyzed: \(result.totalFrames)")
        print("")
        print(String(format: "%-40s %-22s %s", "Algorithm", "Slice", "Matches"))
        for c in result.candidates {
            let mark = c.matchCount == result.totalFrames ? " ✓" : ""
            print(String(format: "%-40s %-22s %d/%d%@",
                         c.algorithm.rawValue,
                         c.slice.rawValue,
                         c.matchCount,
                         result.totalFrames,
                         mark))
        }
        print("")
        if let w = result.winner {
            print("Winner: \(w.algorithm.rawValue) over \(w.slice.rawValue) — \(w.matchCount)/\(result.totalFrames) frames")
            exit(0)
        } else {
            writeError("error: no unique algorithm matched all frames")
            exit(9)
        }
    } catch ChecksumProbe.ProbeError.fileNotReadable(let path) {
        writeError("error: cannot read \(path)"); exit(1)
    } catch ChecksumProbe.ProbeError.noFramesFound {
        writeError("error: no valid frames found in JSONL"); exit(9)
    } catch {
        writeError("error: \(error)"); exit(1)
    }
}

// MARK: - Measurement mode

guard let filter = args.filter, !filter.isEmpty else {
    writeError("error: --filter is required"); exit(1)
}

var parser = FrameParser()
parser.verifyChecksum = !args.noVerifyChecksum

let logger: EventLogger
do {
    logger = try EventLogger(verbose: args.verbose, outputPath: args.out, parser: parser)
} catch {
    writeError("error: cannot open output file: \(error)"); exit(4)
}
defer { logger.close() }

let client = ScaleClient()
let stream: AsyncStream<ScaleEvent>
do {
    stream = try await client.run(
        nameFilter: filter,
        scanTimeout: 15,
        connectTimeout: args.connectTimeout
    )
} catch BLEPowerError.unauthorized {
    writeError("error: Bluetooth permission denied. Approve in System Settings → Privacy & Security → Bluetooth, then re-run.")
    exit(2)
} catch BLEPowerError.poweredOff {
    writeError("error: Bluetooth is off. Please enable it."); exit(3)
} catch BLEPowerError.unsupported {
    writeError("error: Bluetooth not supported on this Mac."); exit(3)
} catch ScaleClientError.scanTimeoutNoMatch {
    writeError("error: scale not found within 15s. Is it active? Try waking it up."); exit(5)
} catch ScaleClientError.connectFailed(let inner) {
    if let inner = inner {
        writeError("error: failed to connect: \(inner.localizedDescription)")
    } else {
        writeError("error: failed to connect: timeout after \(args.connectTimeout)s")
    }
    exit(6)
} catch {
    writeError("error: \(error)"); exit(1)
}

// State for measurement detection + watchdog
var watchdogTask: Task<Void, Never>?
var didEmitComplete = false
var didTimeoutWatchdog = false

for await event in stream {
    let frame = logger.handle(event)

    // Start watchdog when we receive .subscribed
    if case .subscribed = event {
        watchdogTask = Task { [timeout = args.timeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            didTimeoutWatchdog = true
            client.stop()
        }
    }

    // Detect "measurement complete": flags[0]=1 with non-zero impedance
    if let frame = frame,
       case .measurement(let flags, let weight, let impedance) = frame,
       (flags & 1) == 1,
       let imp = impedance, imp > 0,
       !didEmitComplete {
        didEmitComplete = true
        logger.logMeasurementComplete(MeasurementComplete(
            timestamp: Date(),
            weightKg: weight,
            impedanceOhms: imp,
            rawHex: logger.lastMeasurement?.rawHex ?? "",
            incomplete: false
        ))
        client.stop()
    }
}

watchdogTask?.cancel()

// Stream finished. Decide exit code.
if didEmitComplete {
    exit(0)
}

// Watchdog fired without measurement
if didTimeoutWatchdog {
    writeError("error: watchdog timeout — no measurement received within \(Int(args.timeout))s")
    exit(7)
}

// Disconnect without flags[0]=1 — try fallback "incomplete" if we have a last measurement
if let last = logger.lastMeasurement,
   case .measurement(_, let weight, _) = last.frame,
   weight > 0 {
    logger.logMeasurementComplete(MeasurementComplete(
        timestamp: Date(),
        weightKg: weight,
        impedanceOhms: 0,
        rawHex: last.rawHex,
        incomplete: true
    ))
    exit(0)
}

writeError("error: disconnected without any usable frame")
exit(8)
```

- [ ] **Step 2: Verificar build**

Run: `cd ~/Projects/renpho-scale && swift build`
Expected: build succeeds. Sin warnings de proyecto.

- [ ] **Step 3: Verificar `--help`**

Run: `cd ~/Projects/renpho-scale && swift run renpho-scale --help`
Expected: imprime el usage de dos líneas, exit 0.

- [ ] **Step 4: Verificar `--filter` ausente**

Run: `cd ~/Projects/renpho-scale && swift run renpho-scale; echo "exit=$?"`
Expected: stderr `error: --filter is required`, `exit=1`.

- [ ] **Step 5: Verificar `--probe-checksum` sigue funcionando**

Run: `cd ~/Projects/renpho-scale && swift run renpho-scale --probe-checksum gatt.jsonl 2>&1 | head -20`
Expected: tabla del probe + winner (si existe). Sigue funcionando como en Task 7.

- [ ] **Step 6: Verificar argumentos inválidos**

Run: `cd ~/Projects/renpho-scale && swift run renpho-scale --filter foo --timeout -3; echo "exit=$?"`
Expected: stderr `error: --timeout requires a positive number`, `exit=1`.

- [ ] **Step 7: Commit**

```bash
cd ~/Projects/renpho-scale
git add Sources/renpho-scale/main.swift
git commit -m "feat: orquestación completa de renpho-scale con watchdog y exit codes"
```

---

## Task 13: Captura real con la balanza + DoD final

Tarea manual con el usuario presente.

**Files:** ninguno (verificación end-to-end + posible commit de README).

- [ ] **Step 1: Confirmar estado limpio del repo**

Run: `cd ~/Projects/renpho-scale && git status`
Expected: `nothing to commit, working tree clean`. Si hay cambios, decidir antes de avanzar.

- [ ] **Step 2: Build limpio + tests**

Run: `cd ~/Projects/renpho-scale && swift build && swift test`
Expected: build OK. Todos los tests pasan (10/10 si fueron implementados sin extras).

- [ ] **Step 3: Smoke test post-refactor de `renpho-explore`**

Activar la balanza brevemente. Inmediatamente:

Run: `cd ~/Projects/renpho-scale && swift run renpho-explore --filter "R-A033" --duration 5`
Expected: el flujo arranca, conecta al `R-A033`, descubre services y characteristics, imprime el árbol GATT. Después de 5s (o cuando la balanza desconecte sola), exit 0. **No hace falta una pesada completa** — sólo verificar que el refactor no rompió la herramienta del fase 1.1.

- [ ] **Step 4: Captura real con `renpho-scale` (la pesada de hoy)**

Activar la balanza. Inmediatamente:

Run: `cd ~/Projects/renpho-scale && swift run renpho-scale --filter "R-A033" --out medida.jsonl --verbose`

Cuando aparezca en consola la línea `subscribed — subite a la balanza`:

1. Subite descalzo a la balanza.
2. Quedate quieto hasta ver el peso final en la pantalla.
3. Esperá ~5-10 segundos más (medición de impedancia).
4. Bajate.

El binario debe:
- Imprimir `peso XX.XX kg` cada vez que recibe una notification con measurement.
- Imprimir `peso XX.XX kg | impedancia YYY Ω ✓ medición completa` cuando llegue el frame con `flags=01`.
- Imprimir el bloque `--- Resultado ---` con peso, impedancia, batería, firmware.
- Salir con exit 0.

Verificar:
```
cd ~/Projects/renpho-scale && echo "exit=$?"
```
Expected: `exit=0`.

- [ ] **Step 5: Verificar `medida.jsonl`**

Run: `cd ~/Projects/renpho-scale && jq -c . medida.jsonl > /dev/null && echo "JSONL valid"`
Expected: `JSONL valid` (sin errores de parsing).

Run:
```
cd ~/Projects/renpho-scale && \
echo "--- Tipos de eventos ---" && \
jq -r '.type' medida.jsonl | sort | uniq -c | sort -rn && \
echo "--- Measurement complete ---" && \
jq 'select(.type == "measurement_complete")' medida.jsonl
```

Expected:
- Conteos: `scan_started`, `peripheral_found`, `connecting`, `connected`, varios `metadata`, `subscribed`, varios `frame` (kind measurement), 1 `measurement_complete`, 1 `disconnected`. Sin `frame_error` (o muy pocos — si hay muchos, hay bug en el checksum).
- El `measurement_complete` muestra `weight_kg` y `impedance_ohms` coherentes con la pantalla de la balanza (peso ±0.05 kg, impedancia > 0).

- [ ] **Step 6: Verificar que `medida.jsonl` no se commitea accidentalmente**

Run: `cd ~/Projects/renpho-scale && git status`
Expected: `medida.jsonl` no aparece (`*.jsonl` ya está en `.gitignore` desde la 1.0).

- [ ] **Step 7: Actualizar README marcando fase 1.2 como completa**

Editar `~/Projects/renpho-scale/README.md`:

En la tabla de Status (línea 13-19), cambiar la fila de fase 1.2:

De:
```
| 1.2 | `renpho-scale` (TBD) | Productive client: connects, parses weight + impedance from notifications, computes body composition, logs JSONL | 🚧 Not started |
```

A:
```
| 1.2 | `renpho-scale` | Productive client: connects, parses weight + impedance from notifications, logs JSONL. Body composition deferred to 1.3 | ✅ Complete |
```

(El README también podría agregar una sección "Run / Phase 1.2", pero lo dejamos para una segunda iteración. La línea de status alcanza para reflejar el estado.)

- [ ] **Step 8: Commit final**

```bash
cd ~/Projects/renpho-scale
git add README.md
git commit -m "docs: marcar fase 1.2 como completa en README"
```

- [ ] **Step 9: Verificación de DoD del spec**

Cross-check contra los 7 criterios del spec (`docs/superpowers/specs/2026-05-08-renpho-scale-fase1.2-design.md` línea 410-426):

1. [ ] `swift build` compila los 3 ejecutables + library + test target sin warnings nuevos.
2. [ ] `swift test` pasa todos los casos de `FrameParserTests` (10/10).
3. [ ] `renpho-scale --probe-checksum gatt.jsonl` identifica un algoritmo único con todos los frames matching.
4. [ ] El algoritmo identificado está hardcodeado en `FrameParser.swift::computeChecksum(_:)` y los tests verifican `verifyChecksum=true`.
5. [ ] La pesada real con `--filter "R-A033" --out medida.jsonl --verbose`:
   - [ ] Conecta exitosamente.
   - [ ] Lee al menos 5 de 8 chars de metadata.
   - [ ] Imprime evento `subscribed`.
   - [ ] Imprime ≥5 líneas `peso ...`.
   - [ ] Imprime `medición completa` cuando llega `flags[0]=1`.
   - [ ] Sale con exit 0.
   - [ ] `medida.jsonl` es JSONL válido.
   - [ ] `measurement_complete` con peso ±0.05 kg vs pantalla, impedancia > 0.
6. [ ] `renpho-explore --filter "R-A033" --duration 5` post-refactor sigue arrancando sin regresiones (Step 3 de esta task).
7. [ ] `medida.jsonl` no commiteado.

---

## Definition of Done — Fase 1.2

Todos los criterios de Task 13 Step 9 verificados con check ✅.

Artefactos producidos:
- [ ] Library `RenphoBLE` con utilidades extraídas.
- [ ] `renpho-explore` refactorizado para consumir `RenphoBLE`, sin cambios de comportamiento.
- [ ] Ejecutable `renpho-scale` con modo medición y modo `--probe-checksum`.
- [ ] Test target `RenphoScaleTests` con 10 tests del parser.
- [ ] `docs/superpowers/notes/2026-05-08-checksum-discovery.md` con el algoritmo identificado.
- [ ] Al menos un `medida.jsonl` con una pesada real (no en git).
- [ ] README actualizado con fase 1.2 ✅ Complete.
