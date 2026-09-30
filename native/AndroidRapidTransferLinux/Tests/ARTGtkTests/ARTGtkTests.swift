@testable import ARTGtk
import CGtk
import Observation
import XCTest

// Tests for the parts that need no display: GLib/GIO objects, GTK list
// models, observation scheduling, parsing and motion math. Everything that
// needs a real GTK main loop and display is in `art-gtk-demo --self-test`.
// Linux XCTest cannot run `@MainActor` test methods, so each test body runs
// in `MainActor.assumeIsolated` (tests run on the main thread).

@Observable
final class TestModel {
    var title = "a"
    var count = 0
    var unrelated = 0
}

final class Sentinel {
    let onDeinit: () -> Void
    init(_ onDeinit: @escaping () -> Void) { self.onDeinit = onDeinit }
    deinit { onDeinit() }
}

struct Row: Equatable {
    let name: String
    let size: Int
}

final class ObservationBindingTests: XCTestCase {
    func testRunsImmediatelyAndCoalescesChanges() {
        MainActor.assumeIsolated {
            let model = TestModel()
            let scheduler = ManualScheduler()
            var seen: [String] = []
            let binding = ObservationBinding(scheduler: scheduler) { seen.append("\(model.title)/\(model.count)") }

            XCTAssertEqual(seen, ["a/0"])
            model.title = "b"
            model.count = 1
            model.count = 2
            XCTAssertEqual(scheduler.pending.count, 1, "several changes schedule one re-run")
            XCTAssertEqual(seen.count, 1, "nothing runs synchronously")

            scheduler.flush()
            XCTAssertEqual(seen, ["a/0", "b/2"], "the re-run sees the final values")
            XCTAssertEqual(binding.updateCount, 2)
        }
    }

    func testIgnoresPropertiesItDidNotRead() {
        MainActor.assumeIsolated {
            let model = TestModel()
            let scheduler = ManualScheduler()
            var runs = 0
            let binding = ObservationBinding(scheduler: scheduler) {
                runs += 1
                _ = model.title
            }
            model.unrelated = 5
            withExtendedLifetime(binding) {}
            XCTAssertTrue(scheduler.pending.isEmpty)
            XCTAssertEqual(runs, 1)
        }
    }

    func testTracksNewDependenciesAfterEachRun() {
        MainActor.assumeIsolated {
            let model = TestModel()
            let scheduler = ManualScheduler()
            var runs = 0
            let binding = ObservationBinding(scheduler: scheduler) {
                runs += 1
                if model.count > 0 { _ = model.title }
            }
            defer { withExtendedLifetime(binding) {} }
            model.title = "ignored" // not read yet
            XCTAssertTrue(scheduler.pending.isEmpty)
            model.count = 1
            scheduler.flush()
            model.title = "now read"
            XCTAssertEqual(scheduler.pending.count, 1)
            scheduler.flush()
            XCTAssertEqual(runs, 3)
        }
    }

    func testCancelStopsUpdates() {
        MainActor.assumeIsolated {
            let model = TestModel()
            let scheduler = ManualScheduler()
            var runs = 0
            let binding = ObservationBinding(scheduler: scheduler) {
                runs += 1
                _ = model.count
            }
            model.count = 1
            binding.cancel()
            scheduler.flush()
            model.count = 2
            scheduler.flush()
            XCTAssertEqual(runs, 1)
        }
    }

    func testReleasedBindingDoesNotRun() {
        MainActor.assumeIsolated {
            let model = TestModel()
            let scheduler = ManualScheduler()
            var runs = 0
            do {
                _ = ObservationBinding(scheduler: scheduler) {
                    runs += 1
                    _ = model.count
                }
            }
            model.count = 1
            scheduler.flush()
            XCTAssertEqual(runs, 1)
        }
    }
}

final class ListModelTests: XCTestCase {
    func testStoreMirrorsSwiftArrayIntoGListModel() {
        MainActor.assumeIsolated {
            let store = ListStore<Row>((0..<100).map { Row(name: "row \($0)", size: $0) })
            XCTAssertEqual(listModelCount(store.listModel), 100)
            XCTAssertEqual(ListStore<Row>.item(in: store.listModel, at: 42), Row(name: "row 42", size: 42))

            store.remove(at: 0)
            store.insert(Row(name: "first", size: -1), at: 0)
            store.append(Row(name: "last", size: 1000))
            store.update(at: 1, with: Row(name: "renamed", size: 1))
            XCTAssertEqual(store.count, 101)
            XCTAssertEqual(listModelCount(store.listModel), 101)
            XCTAssertEqual(ListStore<Row>.item(in: store.listModel, at: 0)?.name, "first")
            XCTAssertEqual(ListStore<Row>.item(in: store.listModel, at: 1)?.name, "renamed")
            XCTAssertEqual(ListStore<Row>.item(in: store.listModel, at: 100)?.name, "last")

            store.remove(at: [5, 1, 3])
            XCTAssertEqual(store.items.map(\.name).prefix(4), ["first", "row 2", "row 4", "row 6"])
            XCTAssertEqual(listModelCount(store.listModel), 98)

            store.replaceAll([])
            XCTAssertEqual(listModelCount(store.listModel), 0)
            XCTAssertNil(ListStore<Row>.item(in: store.listModel, at: 0))
        }
    }

    func testItemsChangedIsOneEmissionPerSplice() {
        MainActor.assumeIsolated {
            let store = ListStore<Row>()
            var emissions = 0
            store.connect("items-changed") { emissions += 1 }
            store.replaceAll((0..<1000).map { Row(name: "\($0)", size: $0) })
            store.append(contentsOf: [Row(name: "x", size: 0), Row(name: "y", size: 0)])
            XCTAssertEqual(emissions, 2)
        }
    }

    func testPipelineSortsFiltersAndSelects() {
        MainActor.assumeIsolated {
            let store = ListStore<Row>([Row(name: "b", size: 2), Row(name: "c", size: 3), Row(name: "a", size: 1)])
            let sorter = Sorter<Row>(\.name)
            let pipeline = ListPipeline(store: store, sorter: sorter.pointer, mode: .multiple)
            XCTAssertEqual((0..<3).compactMap(pipeline.item(at:)).map(\.name), ["a", "b", "c"])

            let bySizeDescending = Sorter<Row> { $0.size > $1.size }
            let descending = ListPipeline(store: store, sorter: bySizeDescending.pointer, mode: .none)
            XCTAssertEqual((0..<3).compactMap(descending.item(at:)).map(\.size), [3, 2, 1])

            pipeline.filter.update { $0.size >= 2 }
            XCTAssertEqual(pipeline.visibleCount, 2)
            XCTAssertEqual(pipeline.item(at: 0)?.name, "b")
            pipeline.filter.update { _ in true }

            pipeline.selection.select(0)
            pipeline.selection.select(2, exclusive: false)
            XCTAssertEqual(pipeline.selection.selectedPositions, [0, 2])
            XCTAssertEqual(pipeline.selectedItems.map(\.name), ["a", "c"])

            store.append(Row(name: "0", size: 0))
            XCTAssertEqual(pipeline.item(at: 0)?.name, "0", "the sorted view follows store changes")
        }
    }
}

final class LifetimeTests: XCTestCase {
    func testWrapperReleaseFinalizesTheObject() {
        MainActor.assumeIsolated {
            let weak: WeakObject
            do {
                let store = ListStore<Int>([1, 2, 3])
                weak = WeakObject(store.pointer)
                XCTAssertFalse(weak.isGone)
            }
            XCTAssertTrue(weak.isGone)
        }
    }

    func testObjectKeepsItsWrapperAliveWhileReferencedElsewhere() {
        MainActor.assumeIsolated {
            weak var weakWrapper: ListStore<Int>?
            let raw: UnsafeMutableRawPointer
            do {
                let store = ListStore<Int>([1])
                weakWrapper = store
                raw = store.pointer
                g_object_ref(raw) // someone else (a parent, a model) takes a reference
            }
            XCTAssertNotNil(weakWrapper, "the GObject keeps its wrapper while others hold it")
            XCTAssertTrue(GObjectRef.wrapper(for: raw) === weakWrapper)
            let objectGone = WeakObject(raw)
            g_object_unref(raw)
            XCTAssertNil(weakWrapper, "dropping the other reference releases the wrapper")
            XCTAssertTrue(objectGone.isGone)
        }
    }

    func testSignalClosuresAreReleasedWithTheObject() {
        MainActor.assumeIsolated {
            var released = false
            do {
                let store = ListStore<Int>()
                let sentinel = Sentinel { released = true }
                store.connect("items-changed") { _ = sentinel }
            }
            XCTAssertTrue(released)
        }
    }

    func testDisconnectReleasesTheClosure() {
        MainActor.assumeIsolated {
            var released = false
            let store = ListStore<Int>()
            do {
                let sentinel = Sentinel { released = true }
                let connection = store.connect("items-changed") { _ = sentinel }
                XCTAssertTrue(connection.isConnected)
                connection.disconnect()
                XCTAssertFalse(connection.isConnected)
            }
            XCTAssertTrue(released)
        }
    }

    func testRetainForLifetimeAndOnDispose() {
        MainActor.assumeIsolated {
            var released = false
            var disposed = false
            do {
                let store = ListStore<Int>()
                store.retainForLifetime(Sentinel { released = true })
                store.onDispose { disposed = true }
                XCTAssertFalse(released)
            }
            XCTAssertTrue(released)
            XCTAssertTrue(disposed)
        }
    }
}

final class DropParsingTests: XCTestCase {
    func testURIListParsing() {
        MainActor.assumeIsolated {
            let text = "# comment\r\nfile:///home/me/My%20Photos/a.jpg\r\nfile:///tmp/b.txt\nsftp://host/c\n\n"
            XCTAssertEqual(parseURIList(text), ["/home/me/My Photos/a.jpg", "/tmp/b.txt", "sftp://host/c"])
        }
    }

    func testFileListValue() {
        MainActor.assumeIsolated {
            let paths_: [String] = ["/tmp/one", "/tmp/two words"]
            let files: [OpaquePointer?] = paths_.map { g_file_new_for_path($0) }
            defer { files.forEach { g_object_unref(UnsafeMutableRawPointer($0)) } }
            var mutableFiles = files
            let list = mutableFiles.withUnsafeMutableBufferPointer { gdk_file_list_new_from_array($0.baseAddress, gsize($0.count)) }
            var value = GValue()
            g_value_init(&value, art_type_file_list())
            g_value_take_boxed(&value, UnsafeRawPointer(list))
            defer { g_value_unset(&value) }
            XCTAssertEqual(paths(from: &value), ["/tmp/one", "/tmp/two words"])
        }
    }

    func testStringValueFallback() {
        MainActor.assumeIsolated {
            var value = GValue()
            g_value_init(&value, art_type_string())
            g_value_set_string(&value, "file:///var/tmp/x\n")
            defer { g_value_unset(&value) }
            XCTAssertEqual(paths(from: &value), ["/var/tmp/x"])
        }
    }

    func testDragActionsMatchGdk() {
        MainActor.assumeIsolated {
            XCTAssertEqual(DragAction.copy.rawValue, GDK_ACTION_COPY.rawValue)
            XCTAssertEqual(DragAction([.copy, .move]).rawValue, GDK_ACTION_COPY.rawValue | GDK_ACTION_MOVE.rawValue)
        }
    }
}

final class MotionTests: XCTestCase {
    func testSpringFromResponse() {
        MainActor.assumeIsolated {
            let spring = Motion.Spring(response: 0.5, dampingRatio: 0.55)
            let omega = 2 * Double.pi / 0.5
            XCTAssertEqual(spring.stiffness, omega * omega, accuracy: 1e-9)
            XCTAssertEqual(spring.dampingRatio, 0.55)
            XCTAssertEqual(Motion.snappy.dampingRatio, 1)
            XCTAssertLessThan(Motion.celebrate.dampingRatio, Motion.bouncy.dampingRatio, "celebrate overshoots most")
        }
    }

    func testPolicy() {
        MainActor.assumeIsolated {
            let on = MotionPolicy(animationsEnabled: true, reduceMotion: false)
            XCTAssertTrue(on.allowsMotion)
            XCTAssertEqual(on.duration(Motion.Duration.slow), 0.4)
            for off in [MotionPolicy(animationsEnabled: false, reduceMotion: false), MotionPolicy(animationsEnabled: true, reduceMotion: true)] {
                XCTAssertFalse(off.allowsMotion)
                XCTAssertEqual(off.duration(Motion.Duration.slow), 0)
            }
        }
    }
}
