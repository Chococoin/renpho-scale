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
