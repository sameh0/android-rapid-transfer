/// The app's stylesheet: small adjustments on top of libadwaita, using its
/// colour variables so light, dark and high-contrast all follow. Transitions
/// here honour the desktop's animation switch.
enum AppStyle {
    static let css = """
    .browser-pane { background-color: var(--view-bg-color); }
    .pane-header { padding: 6px 8px 2px 8px; }
    .pane-toolbar { padding: 2px 8px 6px 8px; border-bottom: 1px solid var(--border-color); }
    .pane-title-button { font-weight: bold; }
    .pane-title-button > button { padding-left: 8px; padding-right: 8px; }
    .path-bar { margin-left: 4px; }
    .path-bar button.path-crumb { padding: 2px 6px; min-height: 26px; font-weight: normal; }
    .path-bar button.path-crumb.current { font-weight: bold; }
    .path-separator { margin: 0 1px; }
    .pane-search { padding: 0 8px 6px 8px; border-bottom: 1px solid var(--border-color); }
    .copy-button { padding-left: 10px; padding-right: 12px; }

    .pane-content { transition: box-shadow 150ms ease-out, background-color 150ms ease-out; }
    .pane-content.drop-active {
      box-shadow: inset 0 0 0 2px var(--accent-bg-color);
      background-color: color-mix(in srgb, var(--accent-bg-color) 8%, transparent);
    }
    .browser-list { background: none; }
    .browser-grid { background: none; padding: 6px; }
    .browser-grid > child { border-radius: 10px; margin: 2px; }
    .grid-cell { padding: 10px 4px 8px 4px; }
    .empty-folder image { color: color-mix(in srgb, var(--accent-color) 70%, transparent); }

    .pane-status { padding: 4px 10px; border-top: 1px solid var(--border-color); }
    levelbar block.normal { background-color: var(--accent-bg-color); }
    levelbar block.nearly-full { background-color: var(--warning-bg-color); }
    levelbar block.full { background-color: var(--error-bg-color); }
    levelbar trough { min-height: 5px; }
    levelbar block { min-height: 5px; }

    .connection-stage { background-color: var(--view-bg-color); }
    .connection-step {
      padding: 8px 12px; border-radius: 12px;
      background-color: color-mix(in srgb, currentColor 5%, transparent);
    }
    .step-number {
      font-weight: bold; min-width: 22px; min-height: 22px; border-radius: 999px;
      background-color: color-mix(in srgb, var(--accent-bg-color) 18%, transparent);
      color: var(--accent-color);
    }
    .link-button { color: var(--accent-color); }
    .command-card { padding: 8px 8px 8px 14px; }
    .command-text { font-size: 0.92em; }
    .details-toggle { font-size: 0.9em; }
    .details-card { padding: 8px; }

    .transfer-panel {
      background-color: var(--headerbar-bg-color);
      border-top: 1px solid var(--border-color);
    }
    .transfer-header { padding: 4px 10px 4px 6px; }
    .summary-button { padding: 4px 8px; }
    .count-badge {
      padding: 1px 8px; border-radius: 999px; font-weight: bold; font-size: 0.85em;
      background-color: color-mix(in srgb, currentColor 10%, transparent);
    }
    .small-pill { padding: 2px 12px; min-height: 26px; border-radius: 999px; }
    progressbar.overall-progress trough, progressbar.overall-progress progress { min-height: 3px; border-radius: 0; }
    progressbar.overall-progress trough { background: none; }
    .transfer-body { padding: 0 0 8px 0; }
    .transfer-list { background: none; }
    .transfer-list > row { padding: 0; }
    .transfer-row { padding: 8px 14px; border-bottom: 1px solid color-mix(in srgb, currentColor 7%, transparent); }
    .transfer-row.failed { background-color: color-mix(in srgb, var(--error-bg-color) 7%, transparent); }
    .transfer-row progressbar trough, .transfer-row progressbar progress { min-height: 5px; }
    progressbar.row-progress.upload progress { background-color: var(--teal-3, #2190a4); }
    progressbar.row-progress.stopping progress { background-color: var(--warning-bg-color); }
    .direction-badge {
      background-color: var(--view-bg-color); border-radius: 999px; padding: 1px;
      color: var(--accent-color);
    }
    .queue-row { padding: 6px 14px; }
    .queue-footer { padding: 8px 14px 0 14px; }

    .conflict-card { padding: 14px 8px; transition: opacity 200ms ease-out; }
    .conflict-card.dimmed { opacity: 0.4; }
    .conflict-badge {
      padding: 1px 8px; border-radius: 999px;
      background-color: color-mix(in srgb, var(--accent-bg-color) 15%, transparent);
      color: var(--accent-color);
    }

    .storage-card { padding: 0; border-radius: 12px; }
    .storage-card.selected { box-shadow: inset 0 0 0 2px var(--accent-bg-color); }
    .favorites-popover button { padding: 6px 10px; }

    .onboarding-step { padding: 10px 14px; }
    .date-range-match { padding: 4px 12px; }
    .stage-row { padding: 6px 12px; }
    """
}
