import Foundation

struct BrowserSelectionState {
    private(set) var selectedIDs: Set<BrowserEntry.ID> = []
    private var anchorID: BrowserEntry.ID?
    private var focusedID: BrowserEntry.ID?
    private var orderedIDs: [BrowserEntry.ID] = []
    private var indexByID: [BrowserEntry.ID: Int] = [:]

    mutating func updateOrderedIDs(_ orderedIDs: [BrowserEntry.ID]) {
        self.orderedIDs = orderedIDs
        indexByID.removeAll(keepingCapacity: true)
        indexByID.reserveCapacity(orderedIDs.count)
        for (index, id) in orderedIDs.enumerated() where indexByID[id] == nil {
            indexByID[id] = index
        }
        retainAvailableIDs()
    }

    mutating func replaceSelection(
        with newSelection: Set<BrowserEntry.ID>
    ) {
        let addedIDs = newSelection.subtracting(selectedIDs)
        selectedIDs = newSelection.filter { indexByID[$0] != nil }

        if selectedIDs.isEmpty {
            anchorID = nil
            focusedID = nil
        } else if addedIDs.count == 1, let addedID = addedIDs.first {
            anchorID = addedID
            focusedID = addedID
        } else if selectedIDs.count == 1, let onlyID = selectedIDs.first {
            anchorID = onlyID
            focusedID = onlyID
        } else if let focusedID, !selectedIDs.contains(focusedID) {
            self.focusedID = selectedIDs.first
        }
    }

    mutating func select(
        _ id: BrowserEntry.ID,
        extending: Bool,
        toggling: Bool
    ) {
        guard let selectedIndex = indexByID[id] else { return }

        if extending,
           let anchorID,
           let anchorIndex = indexByID[anchorID] {
            let range = min(anchorIndex, selectedIndex)...max(anchorIndex, selectedIndex)
            selectedIDs = Set(orderedIDs[range])
            focusedID = id
            return
        }

        if toggling {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
            anchorID = id
            focusedID = id
            return
        }

        selectedIDs = [id]
        anchorID = id
        focusedID = id
    }

    mutating func selectAll() {
        selectedIDs = Set(orderedIDs)
        anchorID = orderedIDs.first
        focusedID = orderedIDs.first
    }

    mutating func clear() {
        selectedIDs = []
        anchorID = nil
        focusedID = nil
    }

    mutating func move(
        by offset: Int,
        extending: Bool
    ) {
        guard !orderedIDs.isEmpty else {
            clear()
            return
        }

        let currentID = focusedID.flatMap { indexByID[$0] == nil ? nil : $0 }
            ?? selectedIDs.first(where: { indexByID[$0] != nil })
        let currentIndex = currentID.flatMap { indexByID[$0] }
        let defaultIndex = offset < 0 ? orderedIDs.count : -1
        let destinationIndex = min(max((currentIndex ?? defaultIndex) + offset, 0), orderedIDs.count - 1)
        let destinationID = orderedIDs[destinationIndex]

        if extending {
            if anchorID == nil {
                anchorID = currentID ?? destinationID
            }
            select(
                destinationID,
                extending: true,
                toggling: false
            )
        } else {
            select(
                destinationID,
                extending: false,
                toggling: false
            )
        }
    }

    private mutating func retainAvailableIDs() {
        selectedIDs = selectedIDs.filter { indexByID[$0] != nil }
        if let anchorID, indexByID[anchorID] == nil {
            self.anchorID = selectedIDs.first
        }
        if let focusedID, indexByID[focusedID] == nil {
            self.focusedID = selectedIDs.first
        }
    }
}
