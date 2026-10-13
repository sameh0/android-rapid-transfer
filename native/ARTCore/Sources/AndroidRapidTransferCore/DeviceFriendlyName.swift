import Foundation

/// The name the app shows for a phone. Its MTP model ("SM-S918B",
/// "Pixel 8") is best; the USB product string is next, unless it is one of
/// the generic strings phones put there ("SAMSUNG_Android", "Android",
/// "MTP"), which would read like an error code in a sentence such as
/// "Unplug SAMSUNG_Android". Then the maker's name from the USB vendor ID
/// ("Samsung phone"), else nil and the UI says "the phone".
public enum DeviceFriendlyName {
    public static func resolve(model: String?, productName: String?, vendorID: Int?) -> String? {
        for candidate in [model, productName] {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty, !isGeneric(name) {
                return name
            }
        }
        return vendorID.flatMap(vendorName(for:))
    }

    /// Whether a model or product string names no particular phone.
    public static func isGeneric(_ name: String) -> Bool {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if genericNames.contains(folded) { return true }
        // "SAMSUNG_Android", "MediaTek_Android", "rockchip-android": a maker
        // glued to "Android" is a placeholder, not a model name.
        let isMakerPlaceholder = (folded.hasSuffix("_android") || folded.hasSuffix("-android"))
            && !folded.contains(" ")
        return isMakerPlaceholder || folded.hasSuffix(" android device")
    }

    private static let genericNames: Set<String> = [
        "android", "android phone", "android device", "android-device",
        "mtp", "mtp device", "mtp-device", "ptp", "usb device", "phone", "smartphone"
    ]

    /// "Samsung phone" for a known maker's USB vendor ID.
    public static func vendorName(for vendorID: Int) -> String? {
        guard let maker = makers[vendorID] else { return nil }
        return String(localized: "\(maker) phone")
    }

    /// USB vendor IDs of common Android phone makers.
    private static let makers: [Int: String] = [
        0x04E8: "Samsung",
        0x18D1: "Google",
        0x22B8: "Motorola",
        0x2717: "Xiaomi",
        0x12D1: "Huawei",
        0x2A70: "OnePlus",
        0x22D9: "OPPO",
        0x2D95: "vivo",
        0x0FCE: "Sony",
        0x1004: "LG",
        0x0BB4: "HTC",
        0x0B05: "ASUS",
        0x17EF: "Lenovo",
        0x19D2: "ZTE",
        0x2A45: "Meizu"
    ]
}
