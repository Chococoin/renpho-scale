# Renpho Elis 1C — Fase 1.0: Reconocimiento BLE

**Fecha:** 2026-05-07
**Estado:** Aprobado, pendiente de implementación
**Plataforma objetivo:** macOS (Big Sur o superior), Swift nativo, CoreBluetooth

## Contexto

El proyecto `renpho-scale` busca capturar y procesar localmente las mediciones (peso y composición corporal) de una balanza inteligente Renpho Elis 1C vía Bluetooth Low Energy en macOS, sin pasar por la app oficial ni por sus servidores.

El proyecto se ejecuta en tres fases:

- **Fase 1.0 (este spec):** reconocimiento del protocolo BLE.
- **Fase 1.1:** CLI MVP que parsea, calcula composición corporal y persiste a JSONL.
- **Fase 1.2:** validación y hardening de fórmulas contra la app oficial.

A futuro, fase 2: app de menubar SwiftUI reutilizando los módulos del CLI.

## Justificación de una fase de reconocimiento separada

Renpho usa varias variantes de protocolo BLE según el hardware del modelo. Algunos modelos emiten peso e impedancia directamente en el *advertisement* (sin requerir conexión); otros requieren conexión GATT y lectura de una característica específica. Sin observar empíricamente qué hace el Elis 1C, escribir el parser sería adivinar.

La fase 1.0 produce un artefacto determinístico (un archivo JSONL con frames reales y una nota con el byte layout descifrado) que permite especificar la fase 1.1 sobre datos observados, no sobre asunciones. El costo es bajo (~50–150 líneas de Swift), el riesgo evitado es alto (reescribir el parser desde cero si se asume mal el protocolo).

## Objetivo concreto

Al terminar la fase 1.0:

1. Un archivo JSONL con *advertisement frames* crudos capturados mientras el usuario está parado en la balanza.
2. Una nota técnica con el byte layout confirmado del advertisement (qué bytes son peso, cuáles son impedancia, cuál es el flag de medición estable, endianness, checksum si aplica). O, si se confirma que requiere GATT, los UUIDs de servicio y característica relevantes.
3. Decisión binaria documentada: ¿el Elis 1C emite todo en advertisement, o requiere conexión GATT?

## Alcance

**Dentro:**
- Escaneo BLE pasivo (sin establecer conexión) de todos los dispositivos cercanos.
- Filtro opcional por substring en el nombre del dispositivo.
- Volcado en consola con formato legible, resaltando bytes que cambiaron entre frames consecutivos del mismo dispositivo.
- Persistencia opcional a JSONL.
- Manejo correcto del permiso de Bluetooth en macOS.

**Fuera:**
- Conexión GATT y lectura de características. Si la fase 1.0 revela que es necesario, queda como objetivo de la fase 1.1.
- Parseo semántico (kg, % grasa, etc.). El JSONL guarda bytes crudos en hex.
- Persistencia con esquema estructurado.
- UI gráfica.
- Soporte multi-usuario.

## Diseño técnico

### Interfaz de línea de comandos

```
renpho-recon [--duration <seconds>] [--filter <substring>] [--verbose] [--out <path>]
```

| Flag | Default | Comportamiento |
|------|---------|----------------|
| `--duration` | 30 | Duración del escaneo en segundos. |
| `--filter` | sin filtro | Solo procesa dispositivos cuyo nombre contenga el substring (case insensitive). |
| `--verbose` | false | Imprime cada frame; sin esto, solo imprime cuando hay cambios respecto al frame anterior del mismo dispositivo. |
| `--out` | sin guardar | Path al JSONL donde se guardan todos los frames. |

### Protocolo de captura previsto (uso por el usuario)

Dos pasadas, ejecutadas manualmente:

1. **Identificación** — `renpho-recon --duration 15` sin filtro. El usuario activa la balanza durante el escaneo (subiéndose brevemente o tocándola, según cómo despierte el Elis 1C). El CLI lista todos los dispositivos BLE cercanos; el usuario identifica el Elis 1C como el que apareció recién al activarla, o por nombre si lo reconoce.

2. **Captura activa** — `renpho-recon --filter "<nombre>" --duration 60 --verbose --out captura.jsonl`. El usuario se para en la balanza; el escaneo registra cada frame con resaltado de bytes cambiantes que hace evidente el byte layout.

### Arquitectura de módulos

Un único target ejecutable de Swift Package Manager, sin dependencias externas. Cuatro archivos:

```
renpho-scale/
├── Package.swift
├── Resources/
│   └── Info.plist
└── Sources/
    └── renpho-recon/
        ├── main.swift
        ├── Scanner.swift
        ├── Formatter.swift
        └── Recorder.swift
```

#### `main.swift`
Parseo de argumentos a mano usando `CommandLine.arguments`. Decisión: no usar `swift-argument-parser` — para 4 flags es overkill y agrega una dependencia que la fase 1.1 puede o no querer mantener. Orquesta el flujo: instancia el scanner, suscribe el formatter y el recorder, espera la duración configurada, termina con exit code apropiado.

#### `Scanner.swift`
Wrapper sobre `CBCentralManager`. Implementa `CBCentralManagerDelegate`. Expone un `AsyncStream<AdvertisementFrame>` donde cada frame es:

```swift
struct AdvertisementFrame {
    let timestamp: Date
    let identifier: UUID         // CoreBluetooth identifier (estable per-host, no es MAC)
    let name: String?
    let rssi: Int
    let manufacturerData: Data?
    let serviceUUIDs: [CBUUID]
    let serviceData: [CBUUID: Data]
}
```

Maneja explícitamente los estados del central manager — especialmente `unauthorized` y `poweredOff` — con mensajes claros antes de empezar a producir frames.

#### `Formatter.swift`
- Función `format(frame:previous:) -> String` que renderiza el frame con metadatos legibles y el manufacturer data en hex, resaltando con ANSI colors los bytes que cambiaron respecto al frame previo del mismo identifier.
- Mantiene en memoria un `[UUID: AdvertisementFrame]` con el último frame por dispositivo para hacer el diff.
- Si `--verbose` no está activo, solo emite output cuando el manufacturer data o los service data cambiaron respecto al frame anterior del mismo dispositivo.

#### `Recorder.swift`
- Si se pasó `--out`, abre un `FileHandle` en modo append y escribe cada frame como una línea JSON. Cierra el handle al terminar el escaneo.
- Esquema JSON por línea:

```json
{
  "ts": "2026-05-07T18:42:13.421Z",
  "id": "A1B2C3D4-E5F6-7890-ABCD-1234567890AB",
  "name": "Renpho-XX",
  "rssi": -43,
  "mfg": "deadbeef02...",
  "services": ["fff0"],
  "serviceData": {"fff0": "01..."}
}
```

`mfg` y los valores de `serviceData` son strings hex en minúscula. Si un campo no está presente en el frame (p. ej. `name`), se omite la clave (no `null`). El timestamp es ISO 8601 con milisegundos en UTC.

### Manejo de permiso Bluetooth en macOS

Desde Big Sur, todo proceso que use Core Bluetooth necesita la clave `NSBluetoothAlwaysUsageDescription` en su `Info.plist`. Un ejecutable SPM crudo no la tiene; sin esto, `CBCentralManager` reporta estado `unauthorized` sin mostrar prompt al usuario.

**Solución:** embeber el `Info.plist` vía linker flags en `Package.swift`:

```swift
.executableTarget(
    name: "renpho-recon",
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

`Resources/Info.plist` mínimo:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.choco.renpho-recon</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>renpho-recon escanea dispositivos BLE cercanos para identificar y capturar datos de balanzas Renpho.</string>
</dict>
</plist>
```

En la primera ejecución, macOS muestra el prompt del sistema; el usuario aprueba en System Settings → Privacy & Security → Bluetooth.

**Alternativa descartada:** empaquetar como `.app`. Más fricción de iteración (rebuild bundle cada vez), sin beneficio para esta fase.

### Manejo de errores y exit codes

| Condición | Acción | Exit |
|-----------|--------|------|
| `--duration` no numérico o ≤ 0 | Mensaje a stderr, no escanea | 1 |
| `CBCentralManager.state == .unauthorized` | Mensaje claro indicando cómo aprobar el permiso | 2 |
| `CBCentralManager.state == .poweredOff` | Mensaje pidiendo encender Bluetooth | 3 |
| Path de `--out` no escribible | Mensaje a stderr antes de empezar a escanear | 4 |
| Escaneo completado sin frames capturados | Advertencia ("¿está la balanza activa?") | 0 |
| Escaneo completado con al menos un frame | Resumen final con contadores por dispositivo | 0 |

## Criterios de éxito (Definition of Done)

1. `swift build` compila sin warnings en la versión actual de Swift en macOS.
2. Ejecutado sin balanza, lista al menos un dispositivo BLE cercano (cualquiera, p. ej. el iPhone del usuario), confirmando que el permiso y el scanner funcionan.
3. Ejecutado con la balanza Elis 1C activa y el filtro adecuado, registra al menos 10 frames del dispositivo en el JSONL durante una pesada.
4. El JSONL es válido: `jq -c . captura.jsonl` no produce errores, una línea por frame.
5. El diff de bytes en consola hace identificable a ojo desnudo qué bytes cambian al cambiar el peso (p. ej., al subir y bajar de la balanza).

## Artefactos producidos

Al terminar la fase 1.0:

1. Repo `renpho-scale` con su primer ejecutable funcional (`renpho-recon`).
2. Al menos una `captura.jsonl` con datos reales del Elis 1C.
3. Anexo al spec de la fase 1.1 con el byte layout descifrado (o decisión documentada de ir por GATT en su lugar).

## Decisiones tomadas y descartadas

- **Sin `swift-argument-parser`:** parseo manual; 4 flags no justifican una dependencia.
- **No empaquetar como `.app`:** linker flag en `Package.swift` es más simple y rápido para iterar.
- **No usar `bleak` u otra alternativa Python/Linux:** requisito explícito del usuario es 100% Swift nativo en macOS.
- **CoreBluetooth no expone MAC address en macOS:** se usa el `identifier: UUID` que es estable per-host. Limitación de la plataforma, no decisión de diseño.
- **JSONL crudo (bytes en hex), no parseado:** el parsing semántico pertenece a la fase 1.1; mezclarlo aquí difumina el alcance.
- **Sin tests automatizados en esta fase:** el valor de la fase 1.0 es el artefacto JSONL contra la balanza real; un test unitario de "parsea un Data en hex" no aporta sobre código de tan poco volumen. La fase 1.1 sí tendrá tests (sobre los fixtures que produce esta fase).
