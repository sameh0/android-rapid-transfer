import Foundation

/// The udev rules that give the person logged in at the computer access to
/// Android phones on Linux, for systems whose own rules do not. They are the
/// rules the .deb and .rpm install
/// (native/AndroidRapidTransferLinux/packaging/70-android-rapid-transfer.rules;
/// LinuxUdevRulesTests keeps the two identical), so the command the app shows
/// also covers older phones that offer only a vendor-specific MTP interface.
public enum LinuxUdevRules {
    /// The file name, the packaged one: installed in /etc/udev/rules.d it
    /// takes the place of a packaged copy instead of adding a second one.
    public static let fileName = "70-android-rapid-transfer.rules"

    /// The rule lines, without the packaged file's comments.
    public static let lines = [
        #"ACTION=="remove", GOTO="android_rapid_transfer_end""#,
        #"SUBSYSTEM!="usb", GOTO="android_rapid_transfer_end""#,
        #"ENV{DEVTYPE}!="usb_device", GOTO="android_rapid_transfer_end""#,
        #"ENV{ID_USB_INTERFACES}=="*:060101:*", TAG+="uaccess""#,
        #"ENV{ID_USB_INTERFACES}=="*:ffff00:*", TAG+="uaccess""#,
        #"ENV{ID_MTP_DEVICE}=="1", TAG+="uaccess""#,
        #"LABEL="android_rapid_transfer_end""#
    ]

    /// A shell command that writes the rules to /etc/udev/rules.d, reloads
    /// udev and applies them to the USB devices already plugged in.
    public static var installCommand: String {
        let quotedLines = lines.map { "'\($0)'" }.joined(separator: " ")
        return "printf '%s\\n' \(quotedLines) | sudo tee /etc/udev/rules.d/\(fileName) >/dev/null"
            + " && sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=usb"
    }
}
