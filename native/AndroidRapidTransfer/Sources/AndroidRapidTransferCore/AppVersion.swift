import Foundation

public enum AppVersion {
    public static let current = "0.1.0"

    /// A version with a pre-release suffix (`0.2.0-beta.1`) marks a beta build.
    public static func isPrerelease(_ version: String = current) -> Bool {
        version.contains("-")
    }

    public static func isOlder(_ candidate: String, than current: String) -> Bool {
        let candidateComponents = numericComponents(of: candidate)
        let currentComponents = numericComponents(of: current)
        let componentCount = max(candidateComponents.count, currentComponents.count)

        for index in 0..<componentCount {
            let candidateComponent = candidateComponents[safe: index] ?? 0
            let currentComponent = currentComponents[safe: index] ?? 0
            if candidateComponent != currentComponent {
                return candidateComponent < currentComponent
            }
        }
        return false
    }

    private static func numericComponents(of version: String) -> [Int] {
        version
            .split(separator: "-", maxSplits: 1)
            .first?
            .split(separator: ".")
            .map { Int($0) ?? 0 } ?? []
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
