import Foundation

/// IOReturn values this transport interprets. (The IOKit macros that define
/// them are not importable into Swift.)
public enum IOReturnCode {
    public static let success: Int32 = 0
    public static let error: Int32 = Int32(bitPattern: 0xE000_02BC)
    public static let noDevice: Int32 = Int32(bitPattern: 0xE000_02C0)
    public static let exclusiveAccess: Int32 = Int32(bitPattern: 0xE000_02C5)
    public static let busy: Int32 = Int32(bitPattern: 0xE000_02D5)
    public static let timeout: Int32 = Int32(bitPattern: 0xE000_02D6)
    public static let notPermitted: Int32 = Int32(bitPattern: 0xE000_02E2)
    public static let notPrivileged: Int32 = Int32(bitPattern: 0xE000_02C1)
    public static let aborted: Int32 = Int32(bitPattern: 0xE000_02EB)
    public static let notResponding: Int32 = Int32(bitPattern: 0xE000_02ED)
    public static let notOpen: Int32 = Int32(bitPattern: 0xE000_02CD)
    public static let offline: Int32 = Int32(bitPattern: 0xE000_02CA)
    public static let noResources: Int32 = Int32(bitPattern: 0xE000_02BE)
    /// kUSBHostReturnPipeStalled (IOUSBHostFamily).
    public static let pipeStalled: Int32 = Int32(bitPattern: 0xE000_4051)
    /// Legacy kIOUSBPipeStalled.
    public static let legacyPipeStalled: Int32 = Int32(bitPattern: 0xE000_404F)

    public static func name(_ code: Int32) -> String {
        switch code {
        case success: return "kIOReturnSuccess"
        case error: return "kIOReturnError"
        case noDevice: return "kIOReturnNoDevice"
        case exclusiveAccess: return "kIOReturnExclusiveAccess"
        case busy: return "kIOReturnBusy"
        case timeout: return "kIOReturnTimeout"
        case notPermitted: return "kIOReturnNotPermitted"
        case notPrivileged: return "kIOReturnNotPrivileged"
        case aborted: return "kIOReturnAborted"
        case notResponding: return "kIOReturnNotResponding"
        case notOpen: return "kIOReturnNotOpen"
        case offline: return "kIOReturnOffline"
        case noResources: return "kIOReturnNoResources"
        case pipeStalled, legacyPipeStalled: return "pipe stalled"
        default: return String(format: "IOReturn 0x%08X", UInt32(bitPattern: code))
        }
    }

    static func kind(_ code: Int32) -> MTPTransportError.Kind {
        switch code {
        case noDevice, offline, notResponding: return .noDevice
        case timeout: return .timeout
        case pipeStalled, legacyPipeStalled: return .stall
        case exclusiveAccess, busy: return .exclusiveAccess
        case notPermitted, notPrivileged: return .notPermitted
        case aborted: return .aborted
        default: return .io
        }
    }
}
