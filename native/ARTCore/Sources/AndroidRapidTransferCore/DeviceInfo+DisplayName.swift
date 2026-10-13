import MTPKit

extension DeviceInfo {
    /// The name the app shows for the phone: its MTP model, else its USB
    /// product string unless that is generic, else its maker ("Samsung
    /// phone"), else nil (the UI then uses a generic name). See
    /// ``DeviceFriendlyName``.
    var displayName: String? {
        DeviceFriendlyName.resolve(model: model, productName: usb.product, vendorID: usb.vendorID)
    }
}
