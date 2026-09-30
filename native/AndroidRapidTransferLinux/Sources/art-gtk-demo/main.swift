import ARTGtk
import Dispatch
import Glibc

// art-gtk-demo: a gallery window for the ARTGtk layer.
//   art-gtk-demo              open the gallery
//   art-gtk-demo --autoplay   open it and start a demo copy (for screenshots)
//   art-gtk-demo --page grid  open it on a side page (transfer, drop, grid)
//   art-gtk-demo --self-test  run automated checks against the real GTK loop
//                             (prints "VERIFICATION ok" and exits 0 on success)

let selfTestMode = CommandLine.arguments.contains("--self-test")

let app = Application(
    id: selfTestMode ? "com.sameh.AndroidRapidTransfer.GtkSelfTest" : "com.sameh.AndroidRapidTransfer.GtkDemo",
    unique: !selfTestMode
)

var gallery: Gallery?
var selfTest: SelfTest?

app.onActivate {
    if selfTestMode {
        guard selfTest == nil else { return }
        app.hold() // no window stays open between checks
        let test = SelfTest(app: app)
        selfTest = test
        test.start()
    } else {
        if gallery == nil {
            let created = Gallery(app: app)
            gallery = created
            if let index = CommandLine.arguments.firstIndex(of: "--page"), index + 1 < CommandLine.arguments.count {
                created.show(page: CommandLine.arguments[index + 1])
            }
            if CommandLine.arguments.contains("--autoplay") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated { created.autoplay() }
                }
            }
        }
        gallery?.present()
    }
}

let status = app.run()
if let selfTest {
    exit(selfTest.exitStatus)
}
exit(status)
