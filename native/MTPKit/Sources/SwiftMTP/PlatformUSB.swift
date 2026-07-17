import Foundation
import MTPKit

/// The platform's USB backend: interface discovery and claiming a transport.
public enum PlatformUSB {
    #if os(macOS)
    public static let backendName = "IOUSBHost"
    #else
    public static let backendName = "usbfs"
    #endif

    /// Every USB interface the platform can describe (reads metadata only).
    public static func allInterfaces() -> [MTPInterfaceCandidate] {
        USBDeviceDiscovery.allInterfaces()
    }

    /// Claims the candidate's interface. A busy interface is retried, never reset.
    public static func open(_ candidate: MTPInterfaceCandidate,
                            log: ((String) -> Void)? = nil) throws -> MTPTransport & USBEndpointDescribing {
        #if os(macOS)
        return try IOUSBHostTransport.open(candidate, log: log)
        #else
        throw MTPCallError(message: "USB transport not available on this platform", type: .mtpDetectFailed)
        #endif
    }
}

#if !os(macOS)
public enum USBDeviceDiscovery {
    public static func allInterfaces() -> [MTPInterfaceCandidate] { [] }
}
#endif
