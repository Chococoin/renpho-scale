# Renpho Elis 1C — Fase 1.2: Cliente productivo `renpho-scale`

**Fecha:** 2026-05-08
**Estado:** Aprobado, pendiente de implementación
**Plataforma objetivo:** macOS 11+, Swift nativo, CoreBluetooth
**Spec predecesor:** `docs/superpowers/specs/2026-05-07-gatt-recon-fase1.1-design.md`
**Notas de input:** `docs/superpowers/notes/2026-05-07-gatt-results.md`

## Contexto

La fase 1.1 confirmó empíricamente que el Renpho Elis 1C entrega peso e impedancia por notification en `service 1A10 / char 2A10`, sin necesidad de comandos previos. Las notas de la 1.1 documentan dos tipos de frame:

- **Idle** (`type 0x0011`, payload 5 bytes): `55 aa 11 00 05 XX 01 01 09 CK` — `XX=01` antes de la pesada, `XX=00` después.
- **Measurement** (`type 0x0014`, payload 7 bytes): `55 aa 14 00 07 FL FL WW WW II II CK` — `FL FL` flags, `WW WW` peso big-endian con factor 0.01 kg/LSB, `II II` impedancia big-endian en ohms (cero hasta que `flags[0]=01`).

El algoritmo de checksum quedó pendiente en 1.1.

La fase 1.2 (esta) construye `renpho-scale`: un cliente productivo que se conecta a la balanza, parsea los frames del char `2A10`, identifica la medición completa, y persiste un JSONL de auditoría. **No** calcula composición corporal (% grasa, masa muscular, etc.) — esa es la fase 1.3.

## Justificación de la separación 1.2 / 1.3

Misma lógica que 1.0/1.1: cada fase produce un artefacto verificable que alimenta el spec siguiente. La 1.2 entrega:

- Mediciones reales en JSONL con peso e impedancia parseados y auditables.
- Un binario reproducible con un sub-modo `--probe-checksum` que identifica el algoritmo desde una captura.
- Un parser puro testeado con fixtures, listo para que la 1.3 le agregue las fórmulas de composición sobre `peso + impedancia + bio` del usuario (altura, edad, sexo).

Mantenemos la composición corporal fuera de scope para no acoplar la captura/parseo (cosas que dependen del frame format) con las fórmulas (que dependen de openScale y de inputs del usuario).

## Objetivo concreto

Al terminar la fase 1.2:

1. Library interna `RenphoBLE` con utilidades compartidas.
2. `renpho-explore` refactorizado para consumir `RenphoBLE` (sin cambios de comportamiento observable).
3. `renpho-scale` funcional como ejecutable independiente:
   - Modo medición: scan → connect → subscribe → parse → JSONL.
   - Modo análisis: `--probe-checksum <jsonl>` para identificar el algoritmo del checksum a partir de una captura del Explorer.
4. Tests del parser (`swift test`) cubriendo idle, measurement, errores de sync/length/checksum.
5. Algoritmo de checksum identificado y hardcodeado en el parser.
6. Al menos una medición real registrada en `medida.jsonl` con peso e impedancia coherentes con la pantalla de la balanza.

## Alcance

**Dentro:**
- Refactor: extracción de `RenphoBLE` como library target con utilidades (hex, formatter ISO8601, props→strings, UUIDs conocidos, errores comunes).
- Cliente BLE productivo enfocado: discovery dirigido por UUIDs (`1A10`, `180A`, `180F`), subscribe a `2A10`, lectura de metadata DIS + battery una vez al conectar.
- Parser puro de frames `55 aa …` con verificación de checksum.
- Sub-comando `--probe-checksum <jsonl>` para descubrir el algoritmo.
- Detección de "medición completa" por `flags[0]=01` con impedancia no-cero.
- Manejo de "incomplete": disconnect antes de impedancia → JSONL con `incomplete: true`.
- JSONL append a path indicado por `--out` (sin default oculto).
- Tests del parser con fixtures sintéticos.

**Fuera:**
- Cálculo de composición corporal (BMI, % grasa, masa muscular, agua, hueso). Es la fase 1.3.
- Reconexión automática / modo daemon. Una pesada, un run.
- Escritura a characteristics. La 1.1 confirmó que no hace falta.
- Refactor de `renpho-recon` para consumir `RenphoBLE`. La duplicación con `renpho-recon` es ~30 líneas y su delegate no comparte forma con los otros dos. Reevaluar en una iteración futura si vale.
- Soporte multi-peripheral.
- Tests del cliente BLE (`ScaleClient`). Mockear CoreBluetooth no aporta para esta fase. Los tests cubren parser puro.

## Diseño técnico

### Layout del paquete

```
renpho-scale/
├── Package.swift                       # 3 targets ejecutables + 1 library + 1 test
├── Resources/Info.plist                # compartido vía linker flag (sin cambios)
└── Sources/
    ├── RenphoBLE/                      # 🆕 library target interna
    │   ├── Hex.swift                   # Data ↔ hex string
    │   ├── ISO8601+Fractional.swift    # ISO8601DateFormatter.fractional
    │   ├── CBProperties+Strings.swift  # CBCharacteristicProperties → [String]
    │   ├── RenphoUUIDs.swift           # constantes: 1A10/2A10/2A11, DIS chars, Battery
    │   └── BLEErrors.swift             # power state + scan timeout enums
    ├── renpho-recon/                   # sin tocar
    ├── renpho-explore/                 # refactor: borrar utilidades duplicadas, importar RenphoBLE
    │   ├── main.swift
    │   ├── Explorer.swift
    │   └── EventLogger.swift
    ├── renpho-scale/                   # 🆕 executable productivo
    │   ├── main.swift                  # CLI parsing, orquestación, exit codes
    │   ├── ScaleClient.swift           # CBCentral/Peripheral delegate enfocado
    │   ├── FrameParser.swift           # decode `55aa…` + checksum verify (algoritmo hardcodeado)
    │   ├── ChecksumProbe.swift         # modo --probe-checksum: análisis de JSONL
    │   ├── Measurement.swift           # tipos: Frame, MeasurementComplete
    │   └── EventLogger.swift           # consola + JSONL + summary
    └── RenphoScaleTests/               # 🆕 test target
        └── FrameParserTests.swift
```

### Library `RenphoBLE` — qué se extrae

Todas piezas puras, sin estado. Ningún delegate vive acá.

| Archivo | Contenido |
|---------|-----------|
| `Hex.swift` | `extension Data { var hex: String }`, helper `Data(hex: String)` (para fixtures de tests) |
| `ISO8601+Fractional.swift` | `extension ISO8601DateFormatter { static let fractional: ... }` con `[.withInternetDateTime, .withFractionalSeconds]` |
| `CBProperties+Strings.swift` | `extension CBCharacteristicProperties { func descriptors() -> [String] }` que mapea cada bit a su nombre lowercase |
| `RenphoUUIDs.swift` | `enum RenphoUUIDs { static let measurementService = CBUUID(string: "1A10"); static let measurementChar = CBUUID(string: "2A10"); static let dis = ...; static let battery = ... }` con todas las chars de DIS y Battery por nombre legible |
| `BLEErrors.swift` | `enum BLEPowerError: Error { case unauthorized, poweredOff, unsupported }` y `enum BLEScanError: Error { case timeoutNoMatch }`. Los errores específicos de cada cliente (`connectFailed`, etc.) viven en sus propios módulos |

`renpho-explore` borra sus copias locales de estas piezas e importa `RenphoBLE`. Los enums de error específicos del Explorer (`ExplorerError.connectFailed(Error?)`, etc.) se quedan en su módulo — sólo los compartidos suben a la librería.

### Cliente BLE productivo: `ScaleClient`

```swift
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

final class ScaleClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    func run(
        nameFilter: String,
        scanTimeout: TimeInterval,
        connectTimeout: TimeInterval
    ) async throws -> AsyncStream<ScaleEvent>

    func stop()
}
```

**Flujo:**

1. `CBCentralManager` + esperar `.poweredOn` (lanza `BLEPowerError.*` si falla).
2. `scanForPeripherals(withServices: nil)` con name-filter case-insensitive. Watchdog de `scanTimeout` (default 15s). Match → `stopScan` → continuar.
3. `central.connect(peripheral)` con `connectTimeout` (default 10s).
4. **Discovery dirigido**: `discoverServices([RenphoUUIDs.measurementService, .dis, .battery])`.
5. Por cada service, `discoverCharacteristics([…uuids específicas…], for: service)` con la lista esperada de cada uno.
6. **Reads de metadata** disparadas en paralelo con **subscribe a 2A10**:
   - DIS: 7 reads (`2A29`, `2A24`, `2A25`, `2A27`, `2A28`, `2A26`, `2A23`).
   - Battery: 1 read (`2A19`).
   - Subscribe: `setNotifyValue(true, for: 2A10)`.
7. Cuando `setNotifyValue` confirma → emitir `.subscribed`. Las metadata reads pueden seguir entrando después; cada una emite `.metadataRead(...)` o `.metadataReadFailed(...)`.
8. Cada notification entrante en `2A10` → emitir `.rawNotification(value: Data)`. Sin parseo en este nivel.
9. `stop()` desde `main` → `cancelPeripheralConnection` → `didDisconnect` → emitir `.disconnected` → `continuation.finish()`.

**Decisiones puntuales:**
- Discovery dirigido (con UUIDs, no `nil`) reduce latencia y evita gastar tiempo descubriendo chars que ya conocemos del Explorer.
- Metadata no es bloqueante: si una read individual falla, lo logueamos y seguimos.
- `.subscribed` es la señal "subite a la balanza" (UI-friendly), llega antes que en el Explorer porque el discovery es más corto.
- `rawNotification` deliberadamente crudo: el parsing vive en `FrameParser`, separación de concerns + parser testeable sin BT.

### Parser puro: `FrameParser`

```swift
enum Frame {
    case idle(status: UInt8)
    case measurement(flags: UInt16, weightKg: Double, impedanceOhms: UInt16?)
}

struct MeasurementComplete {
    let timestamp: Date
    let weightKg: Double
    let impedanceOhms: UInt16
    let rawHex: String
    let incomplete: Bool   // true si vino de fallback por disconnect sin flags[0]=1
}

enum ParseError: Error {
    case tooShort
    case badSync
    case unknownType(UInt16)
    case lengthMismatch(declared: Int, actual: Int)
    case badChecksum(expected: UInt8, calculated: UInt8)
}

struct FrameParser {
    var verifyChecksum: Bool = true
    func parse(_ data: Data) throws -> Frame
}
```

**Estructura de bytes** (confirmada empíricamente en 1.1):

```
offset:  0   1   2   3   4   5 ... 5+len-1
         55  aa  TT  TT  LL  <data útiles>  CK
```

Donde:
- `data[0..<2]` = sync `55 aa`.
- `data[2..<4]` = type (UInt16, LE).
- `data[4]` = `len`. **`len` cuenta los bytes desde `data[5]` hasta el final del frame, incluyendo el checksum**. Por eso idle (`payload XX 01 01 09 CK`, 5 bytes) declara `len=5` y measurement (`FL FL WW WW II II CK`, 7 bytes) declara `len=7`.
- `data[5..<data.count-1]` = datos útiles.
- `data[data.count-1]` = checksum.
- Total: `data.count == 5 + len`.

**Reglas:**
- `data.count >= 6` (sync 2 + type 2 + len 1 + cksum 1; datos útiles pueden ser 0).
- `data[0..<2] == 0x55 0xaa` o lanza `badSync`.
- `len = data[4]`. Si `data.count != 5 + Int(len)` → `lengthMismatch`.
- Si `verifyChecksum == true`: calcular checksum según el algoritmo identificado por `--probe-checksum` (hardcodeado). Si no matchea → `badChecksum`.
- `type = readUInt16LE(data[2..<4])`:
  - `0x0011` (idle, `len == 5`) → `Frame.idle(status: data[5])`.
  - `0x0014` (measurement, `len == 7`) → leer datos útiles `data[5..<11]`:
    - `flags = readUInt16LE(data[5..<7])` — LE para que `flags & 1 == 1` matchee la observación empírica de 1.1 ("byte 0 bit 0 set when impedance is ready"). Para los bytes `01 00`, LE da `0x0001`, y `0x0001 & 1 == 1`. ✓
    - `weight = readUInt16BE(data[7..<9]) * 0.01`
    - `impedance = (flags & 1 == 1) ? readUInt16BE(data[9..<11]) : nil`
  - Otro → `unknownType(type)`.

Byte-order: header `type` es LE (convención `55 aa 11 00`/`55 aa 14 00`). Flags es LE para alinearse con la convención bit-0 de la 1.1. Peso e impedancia son BE, confirmado contra peso real en la 1.1.

### Modo descubrimiento: `--probe-checksum <jsonl>`

Parte productiva del binario, no script efímero. Vive en `ChecksumProbe.swift` y comparte tipos con `FrameParser`.

```swift
struct ChecksumProbe {
    func run(jsonlPath: String) throws -> ProbeResult
}

struct ProbeResult {
    let totalFrames: Int
    let candidates: [Candidate]   // ordenado por matchCount desc
    let winner: Candidate?         // sólo si hay un único 100%
}

struct Candidate {
    let algorithm: ChecksumAlgorithm   // enum: xor, sumMod256, sumMod256Negated, twosComplement, crc8Poly07, crc8Maxim
    let slice: Slice                    // enum: payloadOnly, headerPlusPayload, fullFrameMinusCk, fromTypeByte
    let matchCount: Int                 // 0..totalFrames
}
```

**Procedimiento:**
1. Leer JSONL línea por línea, filtrar `type == "notification"` y `char == "2a10"`.
2. Por cada frame: extraer `data` desde el `value` hex.
3. Para cada `(algorithm, slice)`:
   - Calcular `slice` sobre `data`, aplicar `algorithm`, comparar con `data[len-1]` (último byte = checksum).
   - Contar matches.
4. Output:
   - Tabla con `(algorithm, slice, matchCount, totalFrames)`, ordenada por matches.
   - Si exactamente un par tiene `matchCount == totalFrames` → `winner = (alg, slice)`, exit 0 con mensaje "Algorithm: X over slice Y matched 28/28 frames".
   - Si ninguno → exit 9 con el listado.
   - Si varios empatan en 100% → exit 9 también, con sugerencia de capturar más frames.

**Después del descubrimiento**: el algoritmo identificado se hardcodea en `FrameParser.swift` como una función privada `private func computeChecksum(_ data: Data) -> UInt8`. El sub-comando `--probe-checksum` queda en el binario como capacidad de validación a futuro (firmware nuevo, otro modelo Renpho).

**Fallback si no hay ganador único** (improbable con 28 frames de 2 tipos):
- Documentamos el resultado en `docs/superpowers/notes/2026-05-08-checksum-discovery.md`.
- Implementamos el parser con `verifyChecksum = false` por default temporalmente.
- Se ofrece `--no-verify-checksum` como flag pero el default queda en true una vez que hardcodeamos un ganador.

### Detección de "medición completa"

Vive en `main.swift`, no en el parser. El parser se mantiene puro.

**Estado:** un buffer `lastMeasurement: Frame.measurement?`.

**Reglas:**
- Cada vez que llega una `Frame.measurement`, actualiza `lastMeasurement`.
- Si `flags & 1 == 1 && impedance != nil && impedance! > 0`:
  - Construir `MeasurementComplete(weight, impedance, raw, incomplete: false)`.
  - Loguear, llamar `client.stop()`.
- Si `client.disconnected` llega antes de un frame con `flags[0]=1`:
  - Si `lastMeasurement` existe con `weight > 0`:
    - Construir `MeasurementComplete(weight, impedance: 0, raw, incomplete: true)`. Loguear.
    - Exit 0.
  - Si no hay `lastMeasurement` útil:
    - Exit 8.
- Watchdog `--timeout` (default 60s desde `.subscribed`):
  - Si no hubo `measurement_complete` ni disconnect: `client.stop()`, exit 7.

### Output: consola

**Modo medición sin `--verbose`:**

```
[10:23:14.102] scan started
[10:23:14.420] found R-A033 (XXXXXXXX)
[10:23:14.421] connecting...
[10:23:14.812] connected
[10:23:15.030] manufacturer: LeFu Scale
[10:23:15.064] model: 38400
[10:23:15.087] firmware: V2.9
[10:23:15.108] battery: 100%
[10:23:15.230] subscribed — subite a la balanza

[10:23:18.401] peso 75.34 kg
[10:23:18.601] peso 75.42 kg
[10:23:18.801] peso 75.40 kg
[10:23:23.840] peso 75.40 kg | impedancia 512 Ω ✓ medición completa

--- Resultado ---
peso:        75.40 kg
impedancia:  512 Ω
batería:     100%
firmware:    V2.9
[10:23:24.012] disconnected
```

**Modo `--verbose`:** cada notification añade hex crudo + frame parseado (`Frame.measurement(flags=0x0001, weight=75.40, impedance=512)`).

Reads de metadata fallidas se imprimen como `[ts] firmware: <unavailable>`.

### Output: JSONL

Una línea JSON por evento. Convenciones de fases anteriores (UTC ISO-8601 con ms, hex lowercase, omisión de campos null).

```jsonl
{"ts":"2026-05-08T10:23:14.102Z","type":"scan_started"}
{"ts":"...","type":"peripheral_found","name":"R-A033","id":"XXXXXXXX-..."}
{"ts":"...","type":"connecting"}
{"ts":"...","type":"connected"}
{"ts":"...","type":"metadata","field":"manufacturer_name","value":"LeFu Scale"}
{"ts":"...","type":"metadata","field":"model_number","value":"38400"}
{"ts":"...","type":"metadata","field":"firmware_revision","value":"V2.9"}
{"ts":"...","type":"metadata","field":"battery_level","value":100}
{"ts":"...","type":"subscribed"}
{"ts":"...","type":"frame","raw":"55aa14000700001d6a0000cc","kind":"measurement","weight_kg":75.30,"flags":0}
{"ts":"...","type":"frame","raw":"55aa14000700001d700000cc","kind":"measurement","weight_kg":75.36,"flags":0}
{"ts":"...","type":"frame","raw":"55aa14000701001d740200cc","kind":"measurement","weight_kg":75.40,"impedance_ohms":512,"flags":1}
{"ts":"...","type":"measurement_complete","weight_kg":75.40,"impedance_ohms":512,"battery_level":100,"firmware":"V2.9","raw":"55aa14000701001d740200cc","incomplete":false}
{"ts":"...","type":"disconnected"}
```

El byte `cc` en los samples es un placeholder — el byte real depende del algoritmo de checksum identificado por `--probe-checksum`. Pesos y bytes correspondientes verificados: `0x1D6A=7530→75.30 kg`, `0x1D70=7536→75.36 kg`, `0x1D74=7540→75.40 kg`, `0x0200=512 Ω`.

**Convenciones del JSONL:**
- `frame.raw` es el hex del frame entero (sync incluido), permite recomputar checksum offline.
- `frame.kind`: `"idle"` o `"measurement"`. Frames con `unknownType` se loguean como `{"type":"frame","raw":"...","kind":"unknown","type_hex":"XXXX"}`.
- `frame.impedance_ohms` se omite cuando es null.
- `measurement_complete` consolida + duplica metadata útil para que cada línea sea autocontenida (`jq` directo, no necesitás unir con `metadata`).
- `metadata.value` es string para chars de DIS, número para battery.
- `incomplete: true` si la balanza desconectó sin entregar `flags[0]=1` y tenemos un `lastMeasurement` útil.
- Frames con `ParseError`: `{"type":"frame_error","raw":"...","error":"badChecksum","expected":"XX","calculated":"YY"}`. La sesión continúa.

### CLI surface

```
renpho-scale --filter <substring> [--out <path>] [--connect-timeout <s>]
             [--timeout <s>] [--no-verify-checksum] [--verbose]
             [--probe-checksum <jsonl-path>]
```

| Flag | Default | Comportamiento |
|------|---------|----------------|
| `--filter` | requerido (excepto en `--probe-checksum`) | Substring case-insensitive del nombre BLE |
| `--out` | sin guardar | Path al JSONL. Append si existe, crea si no |
| `--connect-timeout` | 10s | Timeout del `central.connect` |
| `--timeout` | 60s | Watchdog desde `subscribed`. Sin medición ni disconnect → exit 7 |
| `--no-verify-checksum` | false | Salta verificación de checksum (no rechaza frames) |
| `--verbose` | false | Imprime hex crudo + frame parseado por cada notification |
| `--probe-checksum <path>` | — | Modo análisis. Lee el JSONL, identifica algoritmo, imprime tabla, exit 0 si winner único |

### Manejo de errores y exit codes

| Code | Condición |
|------|-----------|
| 0 | medición completa, o `incomplete: true` registrado, o `--probe-checksum` con winner único |
| 1 | args inválidos (`--filter` ausente, `--out` sin path, etc.) |
| 2 | Bluetooth unauthorized |
| 3 | Bluetooth off / unsupported |
| 4 | `--out` no escribible |
| 5 | scan timeout (15s sin match del filter) |
| 6 | connect failed/timeout |
| 7 | watchdog `--timeout` (no measurement_complete, no disconnect) |
| 8 | disconnect sin frames útiles parseables |
| 9 | `--probe-checksum`: sin algoritmo único o JSONL vacío |

**Filosofía:** errores de sesión (no encontrar peripheral, no poder conectar) son fatales. Errores por frame individual (sync inválido, checksum corrupto) se loguean como `frame_error` y la sesión continúa — la balanza puede emitir un frame corrupto y los siguientes sí ser válidos.

## Tests

Target nuevo `RenphoScaleTests`. Sólo cubre el parser puro.

**Casos:**

Los fixtures se construyen con `Data(hex: "...")` (helper de `RenphoBLE`). Los pesos/impedancias en los fixtures son números round (75.00 kg, 500 Ω) — no son la pesada real del usuario. Los bytes de checksum se calculan con la función ya hardcodeada (post `--probe-checksum`); marco como `<CK>` los lugares donde el byte exacto depende del algoritmo y se completa al implementar.

| Caso | Input (hex) | Output esperado |
|------|-------------|-----------------|
| Idle pre-pesada | `55aa1100050101010921` | `.idle(status: 0x01)` |
| Idle post-pesada | `55aa1100050001010920` | `.idle(status: 0x00)` |
| Measurement sin impedancia | `55aa14000700001d4c0000<CK>` | `.measurement(flags: 0, weight: 75.00, impedance: nil)` |
| Measurement con impedancia | `55aa14000701001d7401f4<CK>` | `.measurement(flags: 1, weight: 75.40, impedance: 500)` |
| Sync inválido | `aa55110005…` | `throws .badSync` |
| Length mismatch | idle con un byte extra al final | `throws .lengthMismatch` |
| Checksum corrupto (verify=true) | idle con último byte alterado | `throws .badChecksum` |
| Checksum corrupto (verify=false) | idle con último byte alterado | parsea OK como `.idle(status: 0x01)` |
| Type desconocido | `55aa9900000000` con CK válido | `throws .unknownType(0x0099)` |
| Frame demasiado corto | `55aa11` (3 bytes) | `throws .tooShort` |

Verificación de los pesos en los fixtures: `0x1D4C = 7500 → 75.00 kg`, `0x1D74 = 7540 → 75.40 kg`, `0x01F4 = 500 Ω`.

## Criterios de éxito (Definition of Done)

1. `swift build` compila los 3 targets ejecutables + library + test target sin warnings nuevos sobre código del proyecto.
2. `swift test` pasa todos los casos de `FrameParserTests`.
3. `renpho-scale --probe-checksum gatt.jsonl` (sobre el JSONL existente de la 1.1) identifica un algoritmo único con 28/28 frames.
4. El algoritmo identificado queda hardcodeado en `FrameParser.swift` como `computeChecksum(_ data:)`. Los tests del parser usan ese mismo algoritmo.
5. `renpho-scale --filter "R-A033" --out medida.jsonl --verbose` ejecutado contra la balanza activa:
   - Conecta exitosamente.
   - Lee al menos 5 de 8 chars de metadata (DIS + Battery).
   - Imprime al menos un evento `subscribed`.
   - Imprime al menos 5 líneas `peso ...` durante la pesada.
   - Imprime una línea `medición completa` cuando llega `flags[0]=1`.
   - Sale con exit 0.
   - `medida.jsonl` es JSONL válido (`jq -c .`).
   - El `measurement_complete` final tiene peso e impedancia coherentes con la pantalla de la balanza (peso ±0.05 kg, impedancia presente y > 0).
6. `renpho-explore --filter "R-A033" --duration 5` ejecutado después del refactor sigue arrancando, conectando y descubriendo (smoke test, sin necesidad de pesada completa). El comportamiento observable no cambia.
7. `medida.jsonl` no se commitea (cubierto por `*.jsonl` en `.gitignore` desde la 1.0).

## Artefactos producidos

1. Nueva library target `RenphoBLE` en el repo `renpho-scale`.
2. `renpho-explore` refactorizado.
3. Nuevo executable target `renpho-scale` con modo medición y modo `--probe-checksum`.
4. Nuevo test target `RenphoScaleTests` con cobertura del parser.
5. `docs/superpowers/notes/2026-05-08-checksum-discovery.md` con la salida del probe y el algoritmo identificado (sirve como evidencia + reproducibilidad).
6. Al menos un `medida.jsonl` con una pesada real (no en git).

## Decisiones tomadas y descartadas

- **Library `RenphoBLE` extraída**: justificado por 2 consumidores actuales (explore, scale) + 1 cerca (validador 1.3). El spec 1.1 marcó "reevaluar en 1.2" — esta es la reevaluación, decisión = sí.
- **Library con utilidades puras, no delegate genérico**: los dos delegates (Explorer y ScaleClient) tienen formas de evento muy distintas. Forzar abstracción común convierte ahorro en complejidad. Lo que sube a la library son piezas verdaderamente compartidas (hex, time, props, UUIDs, errores de power).
- **`renpho-recon` no consume `RenphoBLE` por ahora**: su delegate no comparte forma con los otros, y el solapamiento real es ~30 líneas de utilidades. Reevaluar si una fase futura agrega tooling adicional.
- **Sub-comando `--probe-checksum` dentro del binario productivo, no script efímero**: descubrimiento reproducible y disponible si firmware/modelo cambian. Comparte tipos con `FrameParser`.
- **Algoritmo de checksum hardcodeado tras descubrimiento**: el parser runtime no tiene branching dinámico; el descubrimiento es una capacidad separada. Si en el futuro convive más de un algoritmo (p. ej. Elis 1C v2 con firmware nuevo) ya lo veremos en una iteración posterior.
- **Discovery dirigido con UUIDs específicos**: minimiza latencia (clave para no perder los primeros frames) y evita gastar tiempo en chars que ya conocemos del Explorer. Perdemos info de chars desconocidas, pero el Explorer ya cubrió eso.
- **Detección de "medición completa" en `main`, no en parser**: el parser se mantiene puro. La política (cuándo cerrar la sesión, qué considerar "completa") vive en el orquestador.
- **`incomplete: true` cuando hay disconnect sin impedancia**: preservamos la medición de peso aunque la impedancia no haya llegado, en lugar de descartar el JSONL. El campo deja explícito el estado al consumidor.
- **Sin tests del cliente BLE (`ScaleClient`)**: mockear CoreBluetooth no aporta para esta fase. La capa BLE se valida con la corrida real contra la balanza (criterio 5 de DoD).
- **Sin reconexión automática / daemon**: una pesada un run. Daemon mode queda para una posible 1.4 si lo justificamos.
- **Sin escritura a `2A11`**: la 1.1 confirmó que pasive+subscribe alcanza.
- **Sin composición corporal**: explícitamente fuera de scope. Es la 1.3.
- **`--out` requerido para JSONL, sin default oculto**: coherente con `renpho-explore`. Sin `--out`, sólo consola.
- **Watchdog `--timeout` default 60s**: balanza típicamente termina en ~30s. 60s da margen para subirse despacio sin ser tan generoso que oculte balanzas colgadas.
