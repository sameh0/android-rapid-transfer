import ARTGtk
import AndroidRapidTransferCore
import CGtk
import Foundation
import Glibc

// android-rapid-transfer: the Linux desktop app.
//   android-rapid-transfer                 connect to a real phone over USB
//   android-rapid-transfer --mock          use the built-in mock phone
//   android-rapid-transfer --self-test     drive the real UI against the mock
//                                          phone; prints "VERIFICATION ok" and
//                                          exits 0 when every check passes
//   android-rapid-transfer --mock --scenario transfer|conflict|grid|prefs|nophone|dark
//                                          set up a state for screenshots

let options = LaunchOptions(arguments: CommandLine.arguments)
let isolated = options.selfTest || options.mock || options.scenario != nil || options.deviceCheck != nil
let application = Application(
    id: options.selfTest ? AppIdentity.bundleIdentifier + ".SelfTest"
        : options.deviceCheck != nil ? AppIdentity.bundleIdentifier + ".DeviceCheck" : AppIdentity.bundleIdentifier,
    unique: !isolated
)
gtk_window_set_default_icon_name(AppIdentity.bundleIdentifier)
g_set_application_name(AppIdentity.name)

var controller: AppController?
var selfTest: SelfTest?
var deviceCheck: DeviceCheck?

application.onActivate {
    if controller == nil {
        controller = AppController(application: application, options: options)
    }
    guard let controller else { return }
    controller.activate()
    if options.selfTest, selfTest == nil {
        let test = SelfTest(controller: controller)
        selfTest = test
        test.start()
    } else if let mode = options.deviceCheck, deviceCheck == nil {
        let check = DeviceCheck(controller: controller, quick: mode == "quick")
        deviceCheck = check
        check.begin()
    } else if let scenario = options.scenario {
        Scenarios.run(scenario, controller: controller)
    }
}

// Ctrl+C in a terminal or a session logout: stop copies and release the
// phone before exiting, as a quit from the menu does.
for signal in [SIGINT, SIGTERM, SIGHUP] {
    g_unix_signal_add(signal, { _ in
        MainActor.assumeIsolated {
            if let controller {
                Task { await controller.shutdownAndQuit() }
            } else {
                application.quit()
            }
        }
        return 0 // G_SOURCE_REMOVE
    }, nil)
}

let status = application.run()
if let selfTest {
    exit(selfTest.exitStatus)
}
if let deviceCheck {
    exit(deviceCheck.exitStatus)
}
exit(status)
