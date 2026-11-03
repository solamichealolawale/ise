import AppKit
import SwiftUI

if CommandLineTool.isCommand(CommandLine.arguments) {
    exit(CommandLineTool.run(CommandLine.arguments))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let store = PlanStore()
let window = FloatingController()
store.onNeedsAttention = { window.expand() }
DistributedNotificationCenter.default().addObserver(forName: CommandLineTool.showPanelNotification, object: nil, queue: .main) { _ in
    window.expand()
}
window.show(panel: PanelView(store: store, window: window), bubble: BubbleView(store: store, window: window))

app.run()
