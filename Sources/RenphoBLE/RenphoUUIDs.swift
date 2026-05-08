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
