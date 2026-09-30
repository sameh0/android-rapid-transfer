import CGtk

// MARK: - Pointer plumbing
//
// GTK types import into Swift either as `UnsafeMutablePointer<GtkFoo>` (the C
// struct is public) or as `OpaquePointer` (the struct is private). Wrappers
// keep one untyped pointer and convert at each call with `.cast()`; overload
// resolution picks whichever form the C function wants.

extension UnsafeMutableRawPointer {
    @inlinable public func cast<T>() -> UnsafeMutablePointer<T> { assumingMemoryBound(to: T.self) }
    @inlinable public func cast() -> OpaquePointer { OpaquePointer(self) }
}

@inlinable func rawPtr<T>(_ p: UnsafeMutablePointer<T>?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }
@inlinable func rawPtr<T>(_ p: UnsafePointer<T>?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer(mutating: $0) } }
@inlinable func rawPtr(_ p: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? { p }
@inlinable func rawPtr(_ p: OpaquePointer?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }

extension Bool {
    @inlinable public var gbool: gboolean { self ? 1 : 0 }
}

extension gboolean {
    @inlinable public var isTrue: Bool { self != 0 }
}

/// Copies a C string GLib hands back without ownership (`const char *`).
@inlinable func borrowedString(_ p: UnsafePointer<CChar>?) -> String? { p.map { String(cString: $0) } }

/// Copies and frees a C string GLib hands back with ownership (`char *`).
@inlinable func takenString(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { g_free(p) }
    return String(cString: p)
}

/// Calls `body` with a NULL-terminated `const char *const *` array.
func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    let copies: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
    defer { copies.forEach { free($0) } }
    return copies.map { $0.map { UnsafePointer($0) } }.withUnsafeBufferPointer { body($0.baseAddress!) }
}

// MARK: - Boxes

/// A Swift value parked behind a `gpointer` (signal closures, qdata, async callbacks).
final class Boxed<Value>: @unchecked Sendable { // touched on the main thread only
    var value: Value
    init(_ value: Value) { self.value = value }

    /// A +1 pointer; balance with ``releaseNotify`` / ``closureReleaseNotify`` or ``take(_:)``.
    func retainedPointer() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }
    static func borrow(_ p: UnsafeRawPointer) -> Boxed<Value> { Unmanaged<Boxed<Value>>.fromOpaque(p).takeUnretainedValue() }
    static func take(_ p: UnsafeRawPointer) -> Boxed<Value> { Unmanaged<Boxed<Value>>.fromOpaque(p).takeRetainedValue() }
}

/// Releases a +1 Swift object pointer (GDestroyNotify).
let releaseNotify: GDestroyNotify = { p in
    if let p { Unmanaged<AnyObject>.fromOpaque(p).release() }
}

/// Releases a +1 Swift object pointer (GClosureNotify).
let closureReleaseNotify: GClosureNotify = { p, _ in
    if let p { Unmanaged<AnyObject>.fromOpaque(p).release() }
}

/// A C callback may only touch main-actor state after proving it runs on the
/// main thread; every GTK signal does.
@inline(__always)
func onMain<T>(_ body: @MainActor () -> T) -> T {
    nonisolated(unsafe) var result: T?
    MainActor.assumeIsolated { result = body() }
    return result!
}

// MARK: - GObject

/// Owns one reference to a GObject and exposes signals, qdata and lifetime
/// hooks. Subclasses wrap concrete types.
///
/// Ownership: `init(_:_:)` with `.take` adopts the reference the constructor
/// returned (sinking a floating one, as GTK widgets are), `.retain` adds a
/// reference for pointers GTK lends (transfer none).
///
/// The wrapper then turns its reference into a GLib *toggle reference*, the
/// mechanism language bindings use to tie a wrapper's lifetime to its object:
/// while anything else (a parent widget, a list model, GTK's window list)
/// holds the object, the object keeps its Swift wrapper alive, so a wrapper
/// that only a parent references is not lost (its bindings and stored child
/// wrappers survive). Once the toggle reference is the only one left, the
/// wrapper lives as long as Swift code references it and drops the object in
/// `deinit`. Each object has at most one such wrapper (see ``wrapper(for:)``).
///
/// Closures connected with ``connect(_:_:)`` and friends are boxed and
/// released by GLib when the handler is disconnected or the object is
/// disposed. Capture widgets weakly in them (handlers get what they need as
/// arguments, ``BindingHost/bind(_:)`` passes the widget in): a closure that
/// strongly captures its own object's wrapper keeps the object alive forever.
@MainActor
open class GObjectRef {
    public enum Ownership: Sendable {
        /// Adopt the constructor's reference (and sink it if floating).
        case take
        /// Add a reference (for pointers lent by GTK).
        case retain
    }

    /// The GObject. `nonisolated(unsafe)` so `deinit` can release it.
    nonisolated(unsafe) public let pointer: UnsafeMutableRawPointer
    /// Whether this wrapper holds the object's toggle reference (false for a
    /// second wrapper of an already-wrapped object, which holds a plain one).
    nonisolated(unsafe) private var usesToggleRef = false
    /// Whether the object currently keeps this wrapper alive (toggle state).
    nonisolated(unsafe) fileprivate var retainedByObject = false

    public init(_ pointer: UnsafeMutableRawPointer, _ ownership: Ownership = .take) {
        self.pointer = pointer
        switch ownership {
        case .take:
            if g_object_is_floating(pointer).isTrue { g_object_ref_sink(pointer) }
        case .retain:
            g_object_ref_sink(pointer)
        }
        guard g_object_get_qdata(pointer.cast(), wrapperQuark) == nil else { return }
        usesToggleRef = true
        let me = Unmanaged.passUnretained(self).toOpaque()
        g_object_set_qdata(pointer.cast(), wrapperQuark, me)
        g_object_add_toggle_ref(pointer.cast(), toggleNotify, me)
        g_object_unref(pointer) // keep only the toggle reference
        if art_object_refcount(pointer) > 1 {
            retainedByObject = true
            _ = Unmanaged.passUnretained(self).retain()
        }
    }

    deinit {
        if usesToggleRef {
            g_object_set_qdata(pointer.cast(), wrapperQuark, nil)
            g_object_remove_toggle_ref(pointer.cast(), toggleNotify, Unmanaged.passUnretained(self).toOpaque())
        } else {
            g_object_unref(pointer)
        }
    }

    /// The Swift wrapper already bound to `pointer`, if any.
    public static func wrapper(for pointer: UnsafeMutableRawPointer) -> GObjectRef? {
        guard let p = g_object_get_qdata(pointer.cast(), wrapperQuark) else { return nil }
        return Unmanaged<GObjectRef>.fromOpaque(p).takeUnretainedValue()
    }

    public var object: UnsafeMutablePointer<GObject> { pointer.cast() }

    /// The GType name, e.g. `GtkButton` (diagnostics).
    public var typeName: String {
        String(cString: g_type_name_from_instance(pointer.cast()))
    }

    /// The current reference count (diagnostics and tests).
    public var referenceCount: UInt32 { art_object_refcount(pointer) }

    // MARK: Properties (by name; for the few without a C accessor)

    public func setProperty(_ name: String, _ value: Bool) { art_object_set_bool(pointer, name, value.gbool) }
    public func setProperty(_ name: String, _ value: Int32) { art_object_set_int(pointer, name, value) }
    public func setProperty(_ name: String, _ value: Double) { art_object_set_double(pointer, name, value) }
    public func setProperty(_ name: String, _ value: String?) { art_object_set_string(pointer, name, value) }
    public func boolProperty(_ name: String) -> Bool { art_object_get_bool(pointer, name).isTrue }
    public func intProperty(_ name: String) -> Int32 { art_object_get_int(pointer, name) }
    public func hasProperty(_ name: String) -> Bool { art_object_has_property(pointer, name).isTrue }

    // MARK: Associated Swift objects (qdata)

    /// Attaches `value` to the GObject under `key`, released when replaced or
    /// when the object is finalized.
    public func setAssociated(_ value: AnyObject?, forKey key: String) {
        let quark = g_quark_from_string(key)
        if let value {
            g_object_set_qdata_full(object, quark, Unmanaged.passRetained(value).toOpaque(), releaseNotify)
        } else {
            g_object_set_qdata(object, quark, nil)
        }
    }

    public func associated(forKey key: String) -> AnyObject? {
        Self.associated(on: pointer, forKey: key)
    }

    nonisolated static func associated(on pointer: UnsafeMutableRawPointer, forKey key: String) -> AnyObject? {
        guard let p = g_object_get_qdata(pointer.cast(), g_quark_from_string(key)) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
    }

    /// Keeps `value` alive for as long as the GObject lives.
    public func retainForLifetime(_ value: AnyObject) {
        let bag: LifetimeBag
        if let existing = associated(forKey: LifetimeBag.key) as? LifetimeBag {
            bag = existing
        } else {
            bag = LifetimeBag()
            setAssociated(bag, forKey: LifetimeBag.key)
        }
        bag.values.append(value)
    }

    /// Runs `body` when the object is disposed (via `g_object_weak_ref`).
    public func onDispose(_ body: @escaping @MainActor () -> Void) {
        let box = Boxed(body)
        g_object_weak_ref(object, { data, _ in
            guard let data else { return }
            let box = Boxed<@MainActor () -> Void>.take(data)
            onMain { box.value() }
        }, box.retainedPointer())
    }

    // MARK: Signals

    /// Connects a handler for a signal whose arguments it does not need
    /// (any arity, returning void). The handler is released when the object
    /// is disposed or the connection is disconnected.
    @discardableResult
    public func connect(_ signal: String, _ handler: @escaping @MainActor () -> Void) -> SignalConnection {
        connectRaw(signal, callback: Trampolines.void, box: Boxed(handler), swapped: true)
    }

    /// Connects a handler for a signal that returns `gboolean` and whose
    /// arguments it does not need (e.g. `close-request`).
    @discardableResult
    public func connectBool(_ signal: String, _ handler: @escaping @MainActor () -> Bool) -> SignalConnection {
        connectRaw(signal, callback: Trampolines.bool, box: Boxed(handler), swapped: true)
    }

    /// Connects a handler for a signal with exactly one pointer argument
    /// (`void (*)(instance, gpointer arg, gpointer data)`).
    @discardableResult
    public func connectPointer(_ signal: String, _ handler: @escaping @MainActor (UnsafeMutableRawPointer?) -> Void) -> SignalConnection {
        connectRaw(signal, callback: Trampolines.pointer, box: Boxed(handler), swapped: false)
    }

    /// Connects a handler for a signal with one `guint` argument (e.g. a list
    /// view's `activate(position)`).
    @discardableResult
    public func connectUInt(_ signal: String, _ handler: @escaping @MainActor (UInt32) -> Void) -> SignalConnection {
        connectRaw(signal, callback: Trampolines.uint, box: Boxed(handler), swapped: false)
    }

    /// Emits a signal without arguments or return value (e.g. `clicked`).
    public func emit(_ signal: String) { art_signal_emit_simple(pointer, signal) }

    /// Runs `handler` whenever the GObject property `property` changes.
    @discardableResult
    public func onNotify(_ property: String, _ handler: @escaping @MainActor () -> Void) -> SignalConnection {
        connect("notify::\(property)", handler)
    }

    /// Connects a boxed closure through a C trampoline. `swapped` passes the
    /// box as the first argument (G_CONNECT_SWAPPED).
    @discardableResult
    func connectRaw(_ signal: String, callback: UnsafeRawPointer, box: AnyObject, swapped: Bool) -> SignalConnection {
        let data = Unmanaged.passRetained(box).toOpaque()
        let id = art_signal_connect(pointer, signal, callback, data, closureReleaseNotify, swapped.gbool)
        precondition(id != 0, "\(typeName) has no signal \(signal)")
        return SignalConnection(object: self, id: id)
    }
}

private let wrapperQuark: GQuark = g_quark_from_string("art-swift-wrapper")

/// Toggle-reference notification: `isLast` means only the wrapper's toggle
/// reference remains, so the object stops keeping the wrapper alive;
/// otherwise someone else holds the object again and it retains the wrapper.
private let toggleNotify: GToggleNotify = { data, _, isLast in
    guard let data else { return }
    let unmanaged = Unmanaged<GObjectRef>.fromOpaque(data)
    let wrapper = unmanaged.takeUnretainedValue()
    if isLast.isTrue {
        guard wrapper.retainedByObject else { return }
        wrapper.retainedByObject = false
        unmanaged.release() // may deinit the wrapper, which drops the object
    } else if !wrapper.retainedByObject {
        wrapper.retainedByObject = true
        _ = unmanaged.retain()
    }
}

/// Holder for ``GObjectRef/retainForLifetime(_:)``.
final class LifetimeBag {
    static let key = "art-lifetime-bag"
    var values: [AnyObject] = []
}

/// The C entry points signal emissions land in. Each unpacks its `Box` and
/// runs the Swift closure on the main actor.
enum Trampolines {
    typealias VoidFn = @MainActor () -> Void
    typealias BoolFn = @MainActor () -> Bool
    typealias PointerFn = @MainActor (UnsafeMutableRawPointer?) -> Void
    typealias UIntFn = @MainActor (UInt32) -> Void

    nonisolated(unsafe) static let void: UnsafeRawPointer = unsafeBitCast(
        { (data: UnsafeMutableRawPointer?) in
            let box = Boxed<VoidFn>.borrow(data!)
            onMain { box.value() }
        } as @convention(c) (UnsafeMutableRawPointer?) -> Void, to: UnsafeRawPointer.self)

    nonisolated(unsafe) static let bool: UnsafeRawPointer = unsafeBitCast(
        { (data: UnsafeMutableRawPointer?) -> gboolean in
            let box = Boxed<BoolFn>.borrow(data!)
            return onMain { box.value() }.gbool
        } as @convention(c) (UnsafeMutableRawPointer?) -> gboolean, to: UnsafeRawPointer.self)

    nonisolated(unsafe) static let pointer: UnsafeRawPointer = unsafeBitCast(
        { (_: UnsafeMutableRawPointer?, arg: UnsafeMutableRawPointer?, data: UnsafeMutableRawPointer?) in
            let box = Boxed<PointerFn>.borrow(data!)
            nonisolated(unsafe) let arg = arg
            onMain { box.value(arg) }
        } as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
        to: UnsafeRawPointer.self)

    nonisolated(unsafe) static let uint: UnsafeRawPointer = unsafeBitCast(
        { (_: UnsafeMutableRawPointer?, arg: UInt32, data: UnsafeMutableRawPointer?) in
            let box = Boxed<UIntFn>.borrow(data!)
            onMain { box.value(arg) }
        } as @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void,
        to: UnsafeRawPointer.self)
}

/// A connected signal handler. Dropping it does NOT disconnect (handlers live
/// as long as the object); call ``disconnect()`` to remove it early.
@MainActor
public final class SignalConnection {
    private let weakObject: WeakObject
    public let handlerID: gulong

    init(object: GObjectRef, id: gulong) {
        weakObject = WeakObject(object.pointer)
        handlerID = id
    }

    /// Disconnects the handler (releasing its closure). Safe after the object is gone.
    public func disconnect() {
        weakObject.withObject { p in
            if g_signal_handler_is_connected(p.cast(), handlerID).isTrue {
                g_signal_handler_disconnect(p.cast(), handlerID)
            }
        }
    }

    public var isConnected: Bool {
        weakObject.withObject { g_signal_handler_is_connected($0.cast(), handlerID).isTrue } ?? false
    }
}

/// A GLib weak reference (`GWeakRef`): does not keep the object alive and
/// reads as nil once it is finalized.
public final class WeakObject: @unchecked Sendable {
    private let ref: UnsafeMutablePointer<GWeakRef>

    public init(_ object: UnsafeMutableRawPointer?) {
        ref = .allocate(capacity: 1)
        ref.initialize(to: GWeakRef())
        g_weak_ref_init(ref, object)
    }

    deinit {
        g_weak_ref_clear(ref)
        ref.deallocate()
    }

    /// Whether the object has been finalized.
    public var isGone: Bool {
        guard let p = g_weak_ref_get(ref) else { return true }
        g_object_unref(p)
        return false
    }

    /// Runs `body` with a temporary strong reference, or returns nil if gone.
    @discardableResult
    public func withObject<R>(_ body: (UnsafeMutableRawPointer) -> R) -> R? {
        guard let p = g_weak_ref_get(ref) else { return nil }
        defer { g_object_unref(p) }
        return body(p)
    }
}
