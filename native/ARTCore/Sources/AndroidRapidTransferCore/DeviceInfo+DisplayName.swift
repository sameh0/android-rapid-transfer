import MTPKit

extension DeviceInfo {
    /// The name the app shows for the phone: its MTP model, else its USB
    /// product string, else nil (the UI then uses a generic name).
    var displayName: String? {
        for name in [model, usb.product] where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return nil
    }
}
