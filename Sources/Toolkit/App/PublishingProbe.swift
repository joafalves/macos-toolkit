#if TOOLKIT_DEV
import AppKit
import OSLog
import SwiftUI

/// `--test-publishing`: SwiftUI's "Publishing changes from within view
/// updates" runtime issue, which it logs and otherwise lets go. The made-up
/// mouse's page (its changes reach no real one), in a
/// window that's never shown: each segmented control and switch on it is
/// changed as a click would, through its action, and the process's own log
/// is read for the issue after each.
enum PublishingProbe {
    static func run() {
        _ = NSApplication.shared
        let model = AppModel()
        model.persists = false
        model.general = GeneralConfig()
        model.section = .mouse
        // The made-up mouse's own page, where its settings are.
        MouseController.previewOpen = true
        let mouse = MouseController.preview()
        let window = MainWindow.make(MainView(
            model: model, mouse: mouse, switcher: SwitcherController.preview(), layout: LayoutController.preview(),
            mixer: MixerController.preview(), finder: FinderController.preview(), capture: CaptureController.preview(),
            awake: AwakeController.preview(), stats: StatsController.preview()))
        window.setContentSize(NSSize(width: 780, height: 2400))
        settle()

        let start = Date()
        var failed = 0
        for (index, control) in controls(in: window.contentView!).enumerated() {
            let before = issues(since: start)
            let config = mouse.config
            let what: String
            if let segments = control as? NSSegmentedControl {
                what = "segments \(index) (\((0..<segments.segmentCount).compactMap { segments.label(forSegment: $0) }.joined(separator: "/")))"
                segments.selectedSegment = (segments.selectedSegment + 1) % segments.segmentCount
            } else if let toggle = control as? NSSwitch {
                what = "switch \(index)"
                toggle.state = toggle.state == .on ? .off : .on
            } else {
                continue
            }
            _ = control.sendAction(control.action, to: control.target)
            settle()
            let found = issues(since: start) - before
            // The change still has to reach the settings.
            let changed = mouse.config != config
            if found > 0 || !changed { failed += 1 }
            print("\(what): \(found == 0 ? "ok" : "\(found) issue(s)")\(changed ? "" : ", but the setting didn't change")")
        }
        print(failed == 0 ? "ok: no control published from within a view update" : "FAIL: \(failed) control(s) did")
    }

    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    /// Segmented controls and switches, top to bottom.
    private static func controls(in view: NSView) -> [NSControl] {
        var found: [NSControl] = []
        func walk(_ view: NSView) {
            if let segments = view as? NSSegmentedControl, !segments.isHidden {
                found.append(segments)
            } else if let toggle = view as? NSSwitch, !toggle.isHidden {
                found.append(toggle)
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    private static func issues(since date: Date) -> Int {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: date))
        else { return 0 }
        return entries.reduce(0) { count, entry in
            count + ((entry as? OSLogEntryLog)?.composedMessage.contains("Publishing changes from within view updates") == true ? 1 : 0)
        }
    }
}
#endif
