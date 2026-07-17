import AndroidRapidTransferCore
import SwiftUI

/// Collects a modification-date range, runs the folder scan, and lets the user
/// review the matches before the copy is queued.
struct DateRangeCopySheet: View {
    @Bindable var model: DateRangeCopyViewModel
    let dismiss: () -> Void

    @State private var isChoosingDestination = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Group {
                switch model.phase {
                case .configuring:
                    configuration
                case let .scanning(progress):
                    scanning(progress)
                case .reviewing:
                    review
                }
            }
            .motionTransition(.opacity)
        }
        .motion(Motion.gentle, value: phaseStep)
        .padding()
        .frame(width: 560)
        .interactiveDismissDisabled()
        .destinationImporter(isPresented: $isChoosingDestination) {
            model.destination = $0.path
        }
    }

    /// Which step the sheet is on, for animating between them (scan
    /// progress updates within a step must not re-trigger the transition).
    private var phaseStep: Int {
        switch model.phase {
        case .configuring: 0
        case .scanning: 1
        case .reviewing: 2
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Copy by Date Range")
                .font(.headline)
            Text(scanScopeSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Configuring

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                DatePicker(
                    "Modified after",
                    selection: $model.startDate,
                    displayedComponents: .date
                )
                .accessibilityLabel("Start date")

                Toggle("Set an end date", isOn: $model.hasEndDate)
                    .accessibilityLabel("Limit the range with an end date")

                DatePicker(
                    "Modified before end of",
                    selection: $model.endDate,
                    displayedComponents: .date
                )
                .accessibilityLabel("End date")
                .disabled(!model.hasEndDate)

                Toggle("Ignore dot files", isOn: $model.ignoreDotFiles)
                    .accessibilityLabel(
                        "Skip files and folders whose names begin with a dot"
                    )

                Toggle("Ignore cache files", isOn: $model.ignoreCacheFiles)
                    .accessibilityLabel(
                        "Skip cache folders and temporary files"
                    )

                Section("Ignore extensions") {
                    ForEach(model.extensionOptions, id: \.self) { fileExtension in
                        HStack {
                            Toggle(
                                fileExtension,
                                isOn: ignoredExtensionBinding(for: fileExtension)
                            )
                            .accessibilityLabel("Ignore files ending in \(fileExtension)")

                            if model.customExtensions.contains(fileExtension) {
                                Button(
                                    "Remove \(fileExtension)",
                                    systemImage: "minus.circle"
                                ) {
                                    model.removeCustomExtension(fileExtension)
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                    }

                    HStack {
                        TextField("Custom extension", text: $model.customExtensionInput)
                            .accessibilityLabel("Custom extension")
                            .onSubmit(model.addCustomExtension)
                        Button("Add", action: model.addCustomExtension)
                            .accessibilityLabel("Add custom extension")
                            .disabled(!model.canAddCustomExtension)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Text(rangeSummary)
                .font(.footnote)
                .foregroundStyle(model.filter.isValid ? .secondary : Color.red)
                .accessibilityLabel("Range summary. \(rangeSummary)")

            HStack(alignment: .firstTextBaseline) {
                Text("Files will be copied to \(model.destination), keeping their folder structure.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") {
                    isChoosingDestination = true
                }
            }

            HStack {
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Preview") {
                    model.startScan(intent: .preview)
                }
                .disabled(!model.canStartScan)
                Button("Copy Now") {
                    model.startScan(intent: .copyNow)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStartScan)
            }
        }
    }

    // MARK: - Scanning

    private var listingDescription: String {
        guard let listing = model.currentListing else { return "Starting…" }
        let path = listing.path == "/" ? "/" : String(listing.path.drop(while: { $0 == "/" }))
        if let count = listing.itemCount {
            return "Reading \(path) — \(count.formatted()) items"
        }
        return "Reading \(path)…"
    }

    private func scanning(_ progress: DateRangeScanProgress) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if let fraction = model.currentListing?.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .accessibilityLabel(listingDescription)

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Scanned \(progress.scannedFolders) folders, found \(progress.matchedFiles) files"
                )
                .font(.callout)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(progress.matchedFiles)))
                .motion(Motion.snappy, value: progress.matchedFiles)
                Text(listingDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                """
                Scanning. \(progress.scannedFolders) folders scanned, \
                \(progress.matchedFiles) files found. \(listingDescription)
                """
            )

            matchList(model.streamedMatches, allowsSelection: false)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancelScan()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Reviewing

    @ViewBuilder
    private var review: some View {
        if let result = model.result {
            VStack(alignment: .leading, spacing: 12) {
                if result.isEmpty {
                    ContentUnavailableView(
                        "No Matching Files",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text(
                            """
                            Nothing in \(scanScopeSummary.lowercased()) was modified \
                            in this date range.
                            """
                        )
                    )
                    .frame(height: 220)
                } else {
                    matchList(result.matches)
                    Text(selectionSummary)
                        .font(.callout)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(model.selectedFileCount)))
                        .motion(Motion.snappy, value: model.selectedFileCount)
                        .accessibilityLabel("Selection summary. \(selectionSummary)")
                }

                if !result.failures.isEmpty {
                    Label(
                        """
                        \(result.failures.count) folders could not be read and \
                        were skipped.
                        """,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .help(result.failures.map(\.path).joined(separator: "\n"))
                }

                HStack {
                    Button("Back") {
                        model.editRange()
                    }
                    Spacer()
                    Button("Cancel", role: .cancel, action: dismiss)
                        .keyboardShortcut(.cancelAction)
                    Button("Copy") {
                        model.copySelection()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCopySelection)
                }
            }
        }
    }

    private func matchList(
        _ matches: [DateRangeMatch],
        allowsSelection: Bool = true
    ) -> some View {
        List {
            ForEach(matches) { match in
                if allowsSelection {
                    Toggle(isOn: inclusionBinding(for: match)) {
                        matchLabel(match)
                    }
                    .accessibilityLabel(matchAccessibilityLabel(match))
                } else {
                    matchLabel(match)
                        .accessibilityLabel(matchAccessibilityLabel(match))
                }
            }
        }
        .frame(height: 260)
    }

    private func matchLabel(_ match: DateRangeMatch) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(match.relativePath)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(match.entry.formattedSize) · \(match.entry.formattedModifiedDate)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func matchAccessibilityLabel(_ match: DateRangeMatch) -> String {
        """
        \(match.relativePath), \(match.entry.formattedSize), \
        modified \(match.entry.formattedModifiedDate)
        """
    }

    private func inclusionBinding(for match: DateRangeMatch) -> Binding<Bool> {
        Binding(
            get: { model.isIncluded(match) },
            set: { model.setIncluded($0, for: match) }
        )
    }

    private func ignoredExtensionBinding(for fileExtension: String) -> Binding<Bool> {
        Binding(
            get: { model.isIgnoringExtension(fileExtension) },
            set: { model.setIgnoringExtension($0, fileExtension: fileExtension) }
        )
    }

    // MARK: - Summaries

    private var scanScopeSummary: String {
        model.roots.count == 1
            ? "1 folder selected"
            : "\(model.roots.count) folders selected"
    }

    private var rangeSummary: String {
        guard model.filter.isValid else {
            return "The end date must be on or after the start date."
        }
        let start = model.startDate.formatted(date: .abbreviated, time: .omitted)
        guard model.hasEndDate else {
            return "Files modified on or after \(start), until now."
        }
        let end = model.endDate.formatted(date: .abbreviated, time: .omitted)
        return "Files modified between \(start) and \(end), inclusive."
    }

    private var selectionSummary: String {
        let size = model.selectedTotalSize.formatted(.byteCount(style: .file))
        let total = model.result?.matches.count ?? 0
        return "\(model.selectedFileCount) of \(total) files selected · \(size)"
    }
}
