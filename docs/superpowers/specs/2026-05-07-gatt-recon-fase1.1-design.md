# Renpho Elis 1C — Fase 1.1: Reconocimiento GATT

**Fecha:** 2026-05-07
**Estado:** Aprobado, pendiente de implementación
**Plataforma objetivo:** macOS (Big Sur o superior), Swift nativo, CoreBluetooth
**Spec predecesor:** `docs/superpowers/specs/2026-05-07-renpho-recon-fase1.0-design.md`
**Notas de input:** `docs/superpowers/notes/2026-05-07-recon-results.md`

## Contexto

La fase 1.0 confirmó empíricamente que el Renpho Elis 1C **no emite peso ni impedancia en advertisements BLE**: 172 frames capturados durante una pesada completa contienen el mismo manufacturer data constante (`101a00040003<MAC-bytes>0101`). Por descarte, los datos de medición se intercambian vía conexión GATT activa.

La fase 1.1 construye el equivalente bare-metal de lo que haría una herramienta como LightBlue o Bluetility: un cliente CoreBluetooth en Swift que se conecta al peripheral, descubre el árbol completo de services y characteristics, lee todas las readable, se suscribe a todas las notify, y vuelca todo a consola y JSONL durante una pesada.

El producto de la 1.1 es:
- Un nuevo ejecutable `renpho-explore` en el mismo repo `renpho-scale`.
- Un archivo `gatt.jsonl` con el árbol GATT y los payloads recibidos en una sesión real.
- Notas técnicas con la decisión: ¿alcanza con suscribirse a notifications (passive + read), o la balanza requiere comandos previos (write)? La respuesta determina el alcance de la 1.2.

## Justificación de la separación 1.1 / 1.2

La cadena de fases originalmente prevista era 1.0 (recon ads) → 1.1 (parser ads) → 1.2 (hardening). La 1.0 reveló que el camino es GATT, no ads, así que las fases siguientes se renombran:

- **Fase 1.1 (este spec):** GATT recon (descubrir árbol y captar payloads).
- **Fase 1.2:** GATT productivo (parser de payloads + cálculo de composición + persistencia).
- **Fase 1.3:** Hardening de fórmulas vs. app oficial.

La 1.1 está separada de la 1.2 por las mismas razones que justificaron la 1.0 separada de la 1.1 original: produce un artefacto determinístico (el árbol GATT y los payloads crudos) que permite escribir el spec de la 1.2 con datos en mano en lugar de asunciones.

## Objetivo concreto

Al terminar la fase 1.1:

1. `renpho-explore` funcional como ejecutable independiente.
2. Un `gatt.jsonl` con la sesión completa contra la balanza: scan, connect, todos los services, todas las characteristics con sus properties, todas las reads (exitosas o fallidas), todas las suscripciones, y todas las notifications recibidas durante una pesada.
3. Notas técnicas con: árbol GATT documentado, payloads observados durante la pesada, y decisión binaria de si la 1.2 puede limitarse a passive+read o necesita write commands.

## Alcance

**Dentro:**
- Escanear BLE buscando un peripheral cuyo nombre matchee un substring (case-insensitive).
- Conectar al primer match encontrado.
- Discovery completo: services + characteristics (sin filtros).
- Leer todas las characteristics con propiedad `read`.
- Suscribirse (`setNotifyValue(true, ...)`) a todas las characteristics con propiedad `notify`.
- Escuchar durante una duración configurable.
- Persistir todos los eventos a JSONL si se solicita.
- Manejo de timeouts de scan, connect, y disconnect prematuro durante listening.

**Fuera:**
- Escribir a characteristics (no `peripheral.writeValue(...)` en ningún caso).
- Reintentos automáticos si falla la conexión.
- Parseo semántico de los payloads (eso es la 1.2).
- Cálculo de composición corporal.
- Soporte multi-peripheral o multi-sesión.
- Filtros para excluir services "estándar" (DIS 0x180A, GAS 0x1800) — mejor sobrar info que faltar.

## Diseño técnico

### Interfaz de línea de comandos

```
renpho-explore --filter <substring> [--duration <s>] [--connect-timeout <s>] [--verbose] [--out <path>]
```

| Flag | Default | Comportamiento |
|------|---------|----------------|
| `--filter` | **requerido** | Substring case-insensitive del nombre BLE; conecta al primer peripheral que matchee. |
| `--duration` | 60 | Segundos a escuchar tras suscribirse a notifications. Cuenta a partir de "subscripción hecha", no desde el inicio del proceso. |
| `--connect-timeout` | 10 | Segundos máximos esperando que la balanza responda al connect. |
| `--verbose` | false | Imprime hex completo en cada evento; sin esto, formato más compacto. |
| `--out` | sin guardar | Path al JSONL donde se persisten todos los eventos. |

### Workflow de una corrida

```
1. parseArgs                                       (exit 1 si inválido)
2. abrir output file si --out                      (exit 4 si falla)
3. instanciar CBCentralManager, esperar .poweredOn (exit 2 si unauthorized, 3 si poweredOff)
4. iniciar scan, esperar primer peripheral matching --filter
   ├─ encontrado en ≤15s → stopScan, continuar
   └─ timeout            → exit 5
5. central.connect(peripheral)
   ├─ connected en ≤--connect-timeout → continuar
   └─ timeout/error                    → exit 6
6. peripheral.discoverServices(nil)              → log cada service
7. peripheral.discoverCharacteristics(nil, for: service) por cada service → log cada char
8. para cada char con .read   → readValue → log read_ok o read_failed
   para cada char con .notify → setNotifyValue(true) → log notify_subscribed
9. listening: esperar --duration segundos mientras llegan notifications
10. cancelPeripheralConnection
11. imprimir summary, exit 0
```

**Comportamiento durante listening:**
- El usuario dispara la pesada manualmente cuando ve `--- Listening for notifications ---` en consola.
- Disconnect prematuro durante el listening (la balanza se duerme tras la medición) se loguea como evento y termina la sesión normalmente con exit 0.
- Reads pueden devolver datos pre-medición (ej. peso anterior cacheado, batería). Todo se loguea.

### Arquitectura de módulos

Tres archivos en un nuevo target ejecutable `renpho-explore` dentro del paquete `renpho-scale` existente. Sin dependencias externas.

```
renpho-scale/
├── Package.swift                     # ahora con 2 targets
├── Resources/Info.plist              # reusado (Bluetooth permission)
└── Sources/
    ├── renpho-recon/                 # 1.0, sin tocar
    └── renpho-explore/               # 1.1, nuevo
        ├── main.swift
        ├── Explorer.swift
        └── EventLogger.swift
```

Decisión: **no** extraer biblioteca compartida con `renpho-recon`. La duplicación es de ~30 líneas (escáner mínimo + helper de timestamp); abstraer prematuramente complica más de lo que ahorra. Cuando la 1.2 introduzca un tercer consumidor, evaluamos extracción.

#### `Explorer.swift`

Una sola clase `BLEExplorer: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate`. Implementa ambos protocolos delegate de CoreBluetooth porque la misma sesión maneja scan/connect (central) y discovery/read/notify (peripheral). Patrón Apple-idiomático para sesiones de un solo peripheral.

```swift
final class BLEExplorer: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// Escanea, conecta al primer match de `nameFilter`, hace discovery completo,
    /// lee readable y se suscribe a notify. Devuelve un AsyncStream que emite
    /// ExplorerEvent hasta que `stop()` o el peripheral se desconecte.
    func run(
        nameFilter: String,
        scanTimeout: TimeInterval,
        connectTimeout: TimeInterval
    ) async throws -> AsyncStream<ExplorerEvent>

    func stop()
}

enum ExplorerEvent {
    case scanStarted
    case peripheralFound(name: String, identifier: UUID)
    case connecting
    case connected
    case serviceDiscovered(uuid: CBUUID)
    case characteristicDiscovered(service: CBUUID, uuid: CBUUID, properties: CBCharacteristicProperties)
    case readSucceeded(characteristic: CBUUID, value: Data)
    case readFailed(characteristic: CBUUID, error: Error)
    case notifySubscribed(characteristic: CBUUID)
    case notification(characteristic: CBUUID, value: Data)
    case disconnected(error: Error?)
}

enum ExplorerError: Error {
    case bluetoothUnauthorized
    case bluetoothPoweredOff
    case bluetoothUnsupported
    case scanTimeoutNoMatch       // exit 5
    case connectFailed(Error?)    // exit 6
}
```

#### `EventLogger.swift`

Equivalente del Formatter+Recorder de la 1.0 pero para `ExplorerEvent`. Pretty-print a consola (formato compacto) y opcionalmente JSONL append. También aloja la extensión `ISO8601DateFormatter.fractional` (duplicada del target `renpho-recon` por la decisión de YAGNI sobre módulo compartido).

#### `main.swift`

Top-level async (sin `@main` por la restricción de Swift sobre archivos llamados `main.swift`, igual que en la 1.0). Arg parsing manual con `CommandLine.arguments`. Crea `BLEExplorer` y `EventLogger`, lanza un timer task que llama `explorer.stop()` tras `--duration` segundos *contados desde la última suscripción*, consume el stream y se lo pasa al logger, espera a que termine, imprime resumen y sale con el exit code apropiado.

### Formato JSONL

Una línea JSON por evento, con campo `type` discriminador. Convenciones de la 1.0 mantenidas (UTC ISO-8601 con ms, hex en minúscula, omisión de campos nulos).

```jsonl
{"ts":"2026-05-07T13:00:00.123Z","type":"scan_started"}
{"ts":"...","type":"peripheral_found","name":"R-A033","id":"XXXXXXXX-..."}
{"ts":"...","type":"connecting"}
{"ts":"...","type":"connected"}
{"ts":"...","type":"service_discovered","service":"fff0"}
{"ts":"...","type":"char_discovered","service":"fff0","char":"fff1","props":["read","notify"]}
{"ts":"...","type":"read_ok","char":"fff1","value":"deadbeef"}
{"ts":"...","type":"read_failed","char":"fff3","error":"insufficient authorization"}
{"ts":"...","type":"notify_subscribed","char":"fff1"}
{"ts":"...","type":"notification","char":"fff1","value":"6f0a4b16..."}
{"ts":"...","type":"disconnected","error":null}
```

`props` es un array de strings: subset de `read`, `write`, `writeWithoutResponse`, `notify`, `indicate`, `broadcast`, `notifyEncryptionRequired`, `extendedProperties`. UUIDs en forma corta (`fff0`) para 16-bit y forma larga lowercase para 128-bit. `value` y `error` se omiten si no aplican.

### Formato consola

```
[12:59:58.123] scan started
[12:59:58.405] found R-A033 (XXXXXXXX)
[12:59:58.406] connecting...
[12:59:58.821] connected
[12:59:58.822] service fff0
[12:59:58.965]   char fff1 [read,notify]
[12:59:59.102]   read fff1 = deadbeef
[12:59:59.150]   subscribed fff1

--- Listening for notifications (--duration=60s) ---
[13:00:03.421]   notify fff1 = 6f0a4b16871002...
...
[13:00:58.821] disconnected

--- Summary ---
Services: 1 (fff0)
Characteristics: 2 read, 1 write, 1 notify
Reads: 1 succeeded, 0 failed
Notifications: 23 received on fff1
```

Timestamp acortado a `HH:mm:ss.fff` en consola (la fecha es contexto redundante en sesión interactiva). El JSONL guarda timestamp completo.

### Manejo de errores y exit codes

| Condición | Acción | Exit |
|-----------|--------|------|
| Args inválidos / `--filter` ausente | stderr | 1 |
| `bluetoothUnauthorized` | stderr indicando System Settings | 2 |
| `bluetoothPoweredOff` | stderr pidiendo encender BT | 3 |
| `--out` no escribible | stderr con path | 4 |
| Scan timeout sin match | stderr "Scale not found within 15s. Is it active?" | 5 |
| Connect failed/timeout | stderr "Failed to connect: \<reason\>" | 6 |
| Disconnect prematuro durante listening | log evento + summary | 0 |
| Read falla en una characteristic individual | log read_failed + continuar | 0 |
| Sesión completada normalmente | summary | 0 |

**Filosofía:** errores de sesión (no encontrar peripheral, no poder conectarse) son fatales. Errores por characteristic individual (read denegado por encriptación, char temporalmente no disponible) son informativos — se loguean y la sesión continúa, porque otras chars del mismo peripheral pueden funcionar y son interesantes para el mapeo.

## Criterios de éxito (Definition of Done)

1. `swift build` compila ambos targets (`renpho-recon` + `renpho-explore`) sin warnings.
2. `renpho-explore --filter "R-A033" --duration 60 --verbose --out gatt.jsonl` ejecutado contra la balanza activa:
   - Conecta exitosamente.
   - Descubre al menos 1 service y al menos 1 characteristic.
   - Loguea al menos 1 evento de respuesta del peripheral por characteristic — sea `read_ok`, `read_failed` (ej. encriptación requerida), o `notification`. Cualquiera de los tres prueba que la sesión GATT funcionó; la ausencia total sí indicaría falla del cliente.
3. `gatt.jsonl` es JSONL válido (`jq -c .` sin errores) y contiene la secuencia esperada de eventos (scan_started, peripheral_found, connecting, connected, service_discovered, char_discovered, read_ok/read_failed, notify_subscribed, notification, disconnected).
4. Si `--filter` matchea pero el peripheral no responde a connect en `--connect-timeout` segundos, sale con exit code 6 y mensaje claro.
5. Si la balanza no está activa al arrancar (no se ve el peripheral en 15s), sale con exit code 5 con mensaje claro.

## Artefactos producidos

1. Nuevo target `renpho-explore` en el repo `renpho-scale`.
2. Al menos un `gatt.jsonl` con el árbol GATT completo del Elis 1C + payloads recibidos durante una pesada real.
3. Notas técnicas en `docs/superpowers/notes/2026-05-07-gatt-results.md` con:
   - Tabla de services descubiertos (UUIDs).
   - Por cada service, tabla de characteristics con sus properties.
   - Resumen de payloads observados durante la pesada (qué char emitió cuántas notifications, ejemplo de bytes).
   - Decisión binaria: ¿alcanza con passive+read en la 1.2, o necesitamos write commands?
   - Si la decisión es "necesitamos writes": qué services/chars writable existen, y referencia a `RenphoLib` de openScale para la rutina probable.

## Decisiones tomadas y descartadas

- **Sin `swift-argument-parser`:** coherencia con `renpho-recon`.
- **Sin biblioteca compartida con `renpho-recon`:** YAGNI; la duplicación es ~30 líneas. Reevaluar en 1.2.
- **Sin reintento automático de conexión:** explorador es one-shot. La 1.2 manejará retries.
- **Sin filtros de services "estándar" (DIS, GAS):** ruido bajo, riesgo de perder info útil alto. Loguear todo.
- **Sin writes a characteristics en esta fase:** explorador es read-only contra el peripheral. Si la balanza necesita comandos para emitir, lo descubriremos por *ausencia* de notifications durante la pesada y lo abordaremos en una iteración pequeña posterior (1.1.5) o en el alcance de la 1.2.
- **Sin tests automatizados:** coherencia con 1.0; los fixtures de test para 1.2 vendrán del JSONL real producido en esta fase.
- **Una sola clase `BLEExplorer` implementando ambos protocolos delegate:** patrón Apple-idiomático para sesiones de un solo peripheral; separar en dos clases (Finder + Explorer) duplicaría coordinación y manejo de delegates.
