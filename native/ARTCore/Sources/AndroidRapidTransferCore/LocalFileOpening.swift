import Foundation

/// Opens a local file with its default application. Injected so the core
/// never launches applications itself, and so tests can observe the request.
@MainActor
public protocol LocalFileOpening {
    func open(_ url: URL)
}
