# Renpho Elis 1C — Descubrimiento del checksum

**Fecha:** 2026-05-08
**Captura usada:** `gatt.jsonl` de la sesión 2026-05-07 (28 frames del char `2a10`).
**Comando:** `swift run renpho-scale --probe-checksum gatt.jsonl`

## Resultado

**Algoritmo identificado:** `SUM mod 256` sobre slice `fullFrameMinusCk` con `28/28` matches.

Es decir, el checksum es la suma simple (mod 256) de todos los bytes del frame
desde el sync header (`55 aa`) hasta el byte previo al checksum (excluido).

## Tabla completa

```
--- Checksum probe ---
Frames analyzed: 28

Algorithm                               Slice                 Matches
SUM mod 256                             fullFrameMinusCk      28/28 ✓
XOR                                     payloadOnly           0/28
XOR                                     headerPlusPayload     0/28
XOR                                     fullFrameMinusCk      0/28
SUM mod 256                             payloadOnly           0/28
SUM mod 256                             headerPlusPayload     0/28
(SUM mod 256) ^ 0xFF                    payloadOnly           0/28
(SUM mod 256) ^ 0xFF                    headerPlusPayload     0/28
(SUM mod 256) ^ 0xFF                    fullFrameMinusCk      0/28
two's complement of SUM                 payloadOnly           0/28
two's complement of SUM                 headerPlusPayload     0/28
two's complement of SUM                 fullFrameMinusCk      0/28
CRC-8 poly 0x07                         payloadOnly           0/28
CRC-8 poly 0x07                         headerPlusPayload     0/28
CRC-8 poly 0x07                         fullFrameMinusCk      0/28
CRC-8/MAXIM (poly 0x31, refin/refout)   payloadOnly           0/28
CRC-8/MAXIM (poly 0x31, refin/refout)   headerPlusPayload     0/28
CRC-8/MAXIM (poly 0x31, refin/refout)   fullFrameMinusCk      0/28

Winner: SUM mod 256 over fullFrameMinusCk — 28/28 frames
```

## Implicaciones

El algoritmo queda hardcodeado en `FrameParser.swift::computeChecksum(_:)` (Task 8). El sub-comando `--probe-checksum` queda disponible para validar contra futuras capturas (firmware nuevo, otro modelo Renpho).

## Reproducibilidad

Para validar contra una nueva captura:
```
swift run renpho-explore --filter "R-A033" --duration 90 --verbose --out gatt-new.jsonl
swift run renpho-scale --probe-checksum gatt-new.jsonl
```
