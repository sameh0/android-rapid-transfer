import CGtk

// MARK: - Model

/// The payload each list row object carries (as qdata on a plain GObject).
final class ItemBox<Item> {
    let value: Item
    init(_ value: Item) { self.value = value }
}

/// An array of Swift values mirrored into a `GListStore` for GTK list views.
///
/// Each row is a plain `GObject` carrying its Swift value; GTK's views only
/// see the objects, and the factory closures get the Swift values back. The
/// Swift array (``items``) and the store stay in step because every mutation
/// goes through this class. Replacing a row (``update(at:with:)``) swaps its
/// object, so views rebind just that row.
///
///     let store = ListStore<FileRow>(rows)
///     store.append(row); store.remove(at: 0); store.update(at: 3, with: renamed)
@MainActor
public final class ListStore<Item>: GObjectRef {
    public private(set) var items: [Item]

    public init(_ items: [Item] = []) {
        self.items = []
        super.init(rawPtr(g_list_store_new(art_type_object()))!)
        replaceAll(items)
    }

    public var listModel: OpaquePointer { pointer.cast() }
    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }
    public subscript(index: Int) -> Item { items[index] }

    public func append(_ item: Item) { splice(at: items.count, removing: 0, inserting: [item]) }
    public func append(contentsOf newItems: [Item]) { splice(at: items.count, removing: 0, inserting: newItems) }
    public func insert(_ item: Item, at index: Int) { splice(at: index, removing: 0, inserting: [item]) }
    public func remove(at index: Int) { splice(at: index, removing: 1, inserting: []) }
    public func removeAll() { splice(at: 0, removing: items.count, inserting: []) }
    public func replaceAll(_ newItems: [Item]) { splice(at: 0, removing: items.count, inserting: newItems) }

    /// Replaces one row; views showing it rebind.
    public func update(at index: Int, with item: Item) { splice(at: index, removing: 1, inserting: [item]) }

    /// Removes the rows at `indices` (any order), in as few splices as possible.
    public func remove(at indices: some Sequence<Int>) {
        for index in Set(indices).sorted(by: >) { remove(at: index) }
    }

    /// One `items-changed` emission for the whole change.
    public func splice(at index: Int, removing removeCount: Int, inserting newItems: [Item]) {
        precondition(index >= 0 && index + removeCount <= items.count, "ListStore splice out of range")
        items.replaceSubrange(index..<(index + removeCount), with: newItems)
        var objects: [gpointer?] = newItems.map(Self.makeObject)
        objects.withUnsafeMutableBufferPointer { buffer in
            g_list_store_splice(pointer.cast(), UInt32(index), UInt32(removeCount), buffer.baseAddress, UInt32(buffer.count))
        }
        objects.forEach { g_object_unref($0) } // the store holds its own references
    }

    private static func makeObject(_ item: Item) -> gpointer? {
        let object = art_plain_object_new()!
        g_object_set_qdata_full(object, g_quark_from_static_string(itemKeyCString), Unmanaged.passRetained(ItemBox(item)).toOpaque(), releaseNotify)
        return UnsafeMutableRawPointer(object)
    }

    /// The Swift value a row object of any ``ListStore`` of `Item` carries.
    public nonisolated static func item(of object: UnsafeMutableRawPointer?) -> Item? {
        guard let object, let p = g_object_get_qdata(object.cast(), g_quark_from_static_string(itemKeyCString)) else { return nil }
        return (Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? ItemBox<Item>)?.value
    }

    /// The item at `position` of any `GListModel` whose rows came from a
    /// `ListStore<Item>` (a sorted, filtered or selection model on top of one).
    public nonisolated static func item(in model: OpaquePointer, at position: Int) -> Item? {
        guard let object = g_list_model_get_item(model, UInt32(position)) else { return nil }
        defer { g_object_unref(object) }
        return item(of: object)
    }
}

/// A static C string for the qdata key (quarks from static strings are cheap).
nonisolated(unsafe) private let itemKeyCString: UnsafePointer<CChar> = {
    let s = strdup("art-list-item")!
    return UnsafePointer(s)
}()

/// Number of items in any `GListModel`.
public func listModelCount(_ model: OpaquePointer) -> Int { Int(g_list_model_get_n_items(model)) }

// MARK: - Sorting and filtering

typealias RawCompare = (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
typealias RawPredicate = (UnsafeMutableRawPointer?) -> Bool

private let sorterTrampoline: GCompareDataFunc = { a, b, data in
    Boxed<RawCompare>.borrow(data!).value(UnsafeMutableRawPointer(mutating: a), UnsafeMutableRawPointer(mutating: b))
}

private let filterTrampoline: GtkCustomFilterFunc = { object, data in
    Boxed<RawPredicate>.borrow(data!).value(UnsafeMutableRawPointer(object)).gbool
}

/// A `GtkCustomSorter` comparing Swift items.
///
///     Sorter<FileRow>(\.name)                       // Comparable key
///     Sorter<FileRow> { $0.size < $1.size }          // "are in increasing order"
@MainActor
public final class Sorter<Item>: GObjectRef {
    public typealias AreInIncreasingOrder = (Item, Item) -> Bool

    public init(_ areInIncreasingOrder: @escaping AreInIncreasingOrder) {
        // C function pointers cannot capture generic context, so the generic
        // part lives in a boxed closure behind a non-generic trampoline.
        let compare: RawCompare = { a, b in
            guard let x = ListStore<Item>.item(of: a), let y = ListStore<Item>.item(of: b) else { return 0 }
            if areInIncreasingOrder(x, y) { return -1 }
            if areInIncreasingOrder(y, x) { return 1 }
            return 0
        }
        super.init(rawPtr(gtk_custom_sorter_new(sorterTrampoline, Boxed(compare).retainedPointer(), releaseNotify))!)
    }

    public convenience init<Key: Comparable>(_ key: KeyPath<Item, Key>) {
        nonisolated(unsafe) let key = key
        self.init { $0[keyPath: key] < $1[keyPath: key] }
    }

    /// Tell views to re-sort (after the comparison's inputs changed).
    public func invalidate() { gtk_sorter_changed(pointer.cast(), GTK_SORTER_CHANGE_DIFFERENT) }
}

/// A `GtkCustomFilter` over Swift items.
@MainActor
public final class Filter<Item>: GObjectRef {
    public typealias Predicate = (Item) -> Bool
    private let box: Boxed<Predicate>

    public init(_ isIncluded: @escaping Predicate = { _ in true }) {
        let box = Boxed(isIncluded)
        self.box = box
        let match: RawPredicate = { object in
            guard let item = ListStore<Item>.item(of: object) else { return false }
            return box.value(item)
        }
        super.init(rawPtr(gtk_custom_filter_new(filterTrampoline, Boxed(match).retainedPointer(), releaseNotify))!)
    }

    /// Replaces the predicate and re-filters.
    public func update(_ isIncluded: @escaping Predicate) {
        box.value = isIncluded
        gtk_filter_changed(pointer.cast(), GTK_FILTER_CHANGE_DIFFERENT)
    }
}

// MARK: - Selection

public enum SelectionMode: Sendable { case none, single, multiple }

/// A `GtkSelectionModel` (none/single/multi) over a list model.
@MainActor
public final class SelectionModel: GObjectRef {
    public let mode: SelectionMode

    /// - Parameter model: the list model to select from (a reference is taken).
    public init(_ model: OpaquePointer, mode: SelectionMode) {
        self.mode = mode
        g_object_ref(UnsafeMutableRawPointer(model)) // the selection constructors take ownership
        let p: UnsafeMutableRawPointer = switch mode {
        case .none: rawPtr(gtk_no_selection_new(model))!
        case .single: rawPtr(gtk_single_selection_new(model))!
        case .multiple: rawPtr(gtk_multi_selection_new(model))!
        }
        super.init(p)
        if mode == .single {
            gtk_single_selection_set_autoselect(pointer.cast(), 0)
            gtk_single_selection_set_can_unselect(pointer.cast(), 1)
        }
    }

    public var listModel: OpaquePointer { pointer.cast() }
    public var count: Int { listModelCount(listModel) }

    /// Selected positions, ascending.
    public var selectedPositions: [Int] {
        guard let bitset = gtk_selection_model_get_selection(pointer.cast()) else { return [] }
        defer { gtk_bitset_unref(bitset) }
        var result: [Int] = []
        let size = gtk_bitset_get_size(bitset)
        result.reserveCapacity(Int(size))
        var iter = GtkBitsetIter()
        var value: UInt32 = 0
        var ok = gtk_bitset_iter_init_first(&iter, bitset, &value)
        while ok.isTrue {
            result.append(Int(value))
            ok = gtk_bitset_iter_next(&iter, &value)
        }
        return result
    }

    public func select(_ position: Int, exclusive: Bool = true) {
        gtk_selection_model_select_item(pointer.cast(), UInt32(position), exclusive.gbool)
    }

    public func selectAll() { gtk_selection_model_select_all(pointer.cast()) }
    public func unselectAll() { gtk_selection_model_unselect_all(pointer.cast()) }

    public func onSelectionChanged(_ body: @escaping @MainActor () -> Void) { connect("selection-changed", body) }
}

// MARK: - Factory

/// What a list cell exposes to its factory: its root widget.
@MainActor
public protocol ListCell: AnyObject {
    var root: Widget { get }
}

extension Widget: ListCell {
    public var root: Widget { self }
}

/// A `GtkSignalListItemFactory` that builds recycled cells in Swift.
///
/// `setup` makes a cell (a widget, or any ``ListCell`` holding several);
/// `bind` fills it for an item; `unbind` (optional) resets it before reuse.
///
///     ListItemFactory<FileRow, Label>(
///         setup: { Label().align(h: .start) },
///         bind: { label, row, _ in label.text = row.name })
@MainActor
public final class ListItemFactory<Item, Cell: ListCell>: GObjectRef {
    public typealias Setup = @MainActor () -> Cell
    public typealias Bind = @MainActor (Cell, Item, Int) -> Void
    public typealias Unbind = @MainActor (Cell, Item) -> Void

    private static var cellKey: String { "art-list-cell" }

    /// Cells created and not yet torn down (diagnostics and tests).
    public private(set) var liveCells = 0

    public init(setup: @escaping Setup, bind: @escaping Bind, unbind: Unbind? = nil) {
        super.init(rawPtr(gtk_signal_list_item_factory_new())!)
        let cellKey = Self.cellKey
        let weakSelf = Weak(self)
        connectPointer("setup") { listItem in
            guard let listItem else { return }
            let cell = setup()
            gtk_list_item_set_child(listItem.cast(), cell.root.widget)
            g_object_set_qdata_full(listItem.cast(), g_quark_from_string(cellKey), Unmanaged.passRetained(cell as AnyObject).toOpaque(), releaseNotify)
            weakSelf.value?.liveCells += 1
        }
        connectPointer("bind") { listItem in
            guard let listItem,
                  let cell = GObjectRef.associated(on: listItem, forKey: cellKey) as? Cell,
                  let item = ListStore<Item>.item(of: rawPtr(gtk_list_item_get_item(listItem.cast())))
            else { return }
            bind(cell, item, Int(gtk_list_item_get_position(listItem.cast())))
        }
        if let unbind {
            connectPointer("unbind") { listItem in
                guard let listItem,
                      let cell = GObjectRef.associated(on: listItem, forKey: cellKey) as? Cell,
                      let item = ListStore<Item>.item(of: rawPtr(gtk_list_item_get_item(listItem.cast())))
                else { return }
                unbind(cell, item)
            }
        }
        connectPointer("teardown") { listItem in
            guard let listItem else { return }
            g_object_set_qdata(listItem.cast(), g_quark_from_string(cellKey), nil)
            weakSelf.value?.liveCells -= 1
        }
    }
}

/// A weak box usable from main-actor closures.
@MainActor
final class Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

// MARK: - Views

/// Store → filter → sort → selection: the model stack every view uses.
@MainActor
public final class ListPipeline<Item> {
    public let store: ListStore<Item>
    public let filter: Filter<Item>
    public let selection: SelectionModel
    let filterModel: GObjectRef
    let sortModel: GObjectRef

    /// - Parameter sorter: a `GtkSorter` pointer (a column view's own sorter or a ``Sorter``), or nil.
    init(store: ListStore<Item>, sorter: UnsafeMutableRawPointer?, mode: SelectionMode) {
        self.store = store
        filter = Filter<Item>()
        g_object_ref(store.pointer)
        g_object_ref(filter.pointer)
        filterModel = GObjectRef(rawPtr(gtk_filter_list_model_new(store.listModel, filter.pointer.cast()))!)
        g_object_ref(filterModel.pointer)
        if let sorter { g_object_ref(sorter) }
        sortModel = GObjectRef(rawPtr(gtk_sort_list_model_new(filterModel.pointer.cast(), sorter?.cast()))!)
        selection = SelectionModel(sortModel.pointer.cast(), mode: mode)
    }

    /// Rows currently shown (after filtering).
    public var visibleCount: Int { selection.count }

    /// The item shown at `position` (after filtering and sorting).
    public func item(at position: Int) -> Item? { ListStore<Item>.item(in: selection.listModel, at: position) }

    public var selectedItems: [Item] { selection.selectedPositions.compactMap(item(at:)) }
}

/// A `GtkListView`.
@MainActor
public final class ListView<Item>: Widget {
    public let pipeline: ListPipeline<Item>

    public init<Cell>(store: ListStore<Item>, factory: ListItemFactory<Item, Cell>, sorter: Sorter<Item>? = nil, selection: SelectionMode = .multiple) {
        pipeline = ListPipeline(store: store, sorter: sorter?.pointer, mode: selection)
        g_object_ref(pipeline.selection.pointer)
        g_object_ref(factory.pointer)
        super.init(rawPtr(gtk_list_view_new(pipeline.selection.pointer.cast(), factory.pointer.cast()))!)
    }

    /// Double-click / Enter on a row; gets the item and its display position.
    public func onActivate(_ body: @escaping @MainActor (Item, Int) -> Void) {
        let pipeline = pipeline
        connectUInt("activate") { position in
            if let item = pipeline.item(at: Int(position)) { body(item, Int(position)) }
        }
    }
}

/// A `GtkGridView` (icon grid).
@MainActor
public final class GridView<Item>: Widget {
    public let pipeline: ListPipeline<Item>

    public init<Cell>(store: ListStore<Item>, factory: ListItemFactory<Item, Cell>, sorter: Sorter<Item>? = nil, selection: SelectionMode = .multiple) {
        pipeline = ListPipeline(store: store, sorter: sorter?.pointer, mode: selection)
        g_object_ref(pipeline.selection.pointer)
        g_object_ref(factory.pointer)
        super.init(rawPtr(gtk_grid_view_new(pipeline.selection.pointer.cast(), factory.pointer.cast()))!)
    }

    public var maxColumns: UInt32 {
        get { gtk_grid_view_get_max_columns(pointer.cast()) }
        set { gtk_grid_view_set_max_columns(pointer.cast(), newValue) }
    }

    public func onActivate(_ body: @escaping @MainActor (Item, Int) -> Void) {
        let pipeline = pipeline
        connectUInt("activate") { position in
            if let item = pipeline.item(at: Int(position)) { body(item, Int(position)) }
        }
    }
}

/// A `GtkColumnView` (the file table): columns with their own cell factories
/// and sorters; clicking a header sorts by it.
///
///     let table = ColumnView(store: store)
///     table.append(ColumnViewColumn("Name", expand: true, sorter: Sorter(\.name),
///         factory: ListItemFactory(setup: { Label().align(h: .start) },
///                                  bind: { $0.text = $1.name })))
@MainActor
public final class ColumnView<Item>: Widget {
    public let pipeline: ListPipeline<Item>
    public private(set) var columns: [ColumnViewColumn<Item>] = []

    public init(store: ListStore<Item>, selection: SelectionMode = .multiple) {
        let view = rawPtr(gtk_column_view_new(nil))!
        // The view's sorter follows the clicked header; the sort model uses it.
        let sorter = rawPtr(gtk_column_view_get_sorter(view.cast()))
        pipeline = ListPipeline(store: store, sorter: sorter, mode: selection)
        super.init(view)
        gtk_column_view_set_model(pointer.cast(), pipeline.selection.pointer.cast())
    }

    public func append(_ column: ColumnViewColumn<Item>) {
        columns.append(column)
        gtk_column_view_append_column(pointer.cast(), column.pointer.cast())
    }

    /// Sorts by `column` as if its header had been clicked (nil = unsorted).
    public func sort(by column: ColumnViewColumn<Item>?, ascending: Bool = true) {
        gtk_column_view_sort_by_column(pointer.cast(), column?.pointer.cast(), ascending ? GTK_SORT_ASCENDING : GTK_SORT_DESCENDING)
    }

    public var showsRowSeparators: Bool {
        get { gtk_column_view_get_show_row_separators(pointer.cast()).isTrue }
        set { gtk_column_view_set_show_row_separators(pointer.cast(), newValue.gbool) }
    }

    public var showsColumnSeparators: Bool {
        get { gtk_column_view_get_show_column_separators(pointer.cast()).isTrue }
        set { gtk_column_view_set_show_column_separators(pointer.cast(), newValue.gbool) }
    }

    /// Double-click / Enter on a row.
    public func onActivate(_ body: @escaping @MainActor (Item, Int) -> Void) {
        let pipeline = pipeline
        connectUInt("activate") { position in
            if let item = pipeline.item(at: Int(position)) { body(item, Int(position)) }
        }
    }
}

/// A `GtkColumnViewColumn`.
@MainActor
public final class ColumnViewColumn<Item>: GObjectRef {
    public init<Cell>(_ title: String, expand: Bool = false, fixedWidth: Int32? = nil, sorter: Sorter<Item>? = nil, factory: ListItemFactory<Item, Cell>) {
        g_object_ref(factory.pointer) // _new takes ownership of the factory
        super.init(rawPtr(gtk_column_view_column_new(title, factory.pointer.cast()))!)
        gtk_column_view_column_set_resizable(pointer.cast(), 1)
        gtk_column_view_column_set_expand(pointer.cast(), expand.gbool)
        if let fixedWidth { gtk_column_view_column_set_fixed_width(pointer.cast(), fixedWidth) }
        if let sorter { gtk_column_view_column_set_sorter(pointer.cast(), sorter.pointer.cast()) }
    }

    public var title: String? {
        get { borrowedString(gtk_column_view_column_get_title(pointer.cast())) }
        set { gtk_column_view_column_set_title(pointer.cast(), newValue) }
    }

    public var isVisible: Bool {
        get { gtk_column_view_column_get_visible(pointer.cast()).isTrue }
        set { gtk_column_view_column_set_visible(pointer.cast(), newValue.gbool) }
    }
}
