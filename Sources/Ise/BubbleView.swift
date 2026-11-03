import AppKit
import SwiftUI

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The collapsed state: a round bubble with a time ring, a short label, and a count of blocks left.
struct BubbleView: View {
    @ObservedObject var store: PlanStore
    @ObservedObject var window: FloatingController

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                VisualEffectBackground().clipShape(Circle())
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                centerLabel
            }
            .frame(width: 60, height: 60)

            if blocksLeft > 0 {
                Text("\(blocksLeft)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 2)
                    .background(Color.red, in: Capsule())
                    .offset(x: 4, y: -4)
            }
        }
        .padding(8)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in window.dragChanged() }
                .onEnded { _ in window.dragEnded() }
        )
        .onTapGesture { window.expand() }
        .help(helpText)
    }

    private var currentBlock: Block? {
        store.currentIndex.map { store.blocks[$0] }
    }

    private var blocksLeft: Int {
        guard store.isForToday else { return 0 }
        return store.blocks.filter { $0.status != .done && $0.status != .waiting }.count
    }

    private var ringProgress: Double {
        guard let block = currentBlock else { return 0 }
        guard let left = store.minutesLeft(block), left > 0 else { return 1 }
        return min(Double(left) / Double(block.minutes + block.extraMinutes), 1)
    }

    private var ringColor: Color {
        switch store.alert {
        case .overrun: return .red
        case .notStarted, .chase, .pausedTooLong: return .orange
        case .none: return currentBlock?.pausedAt == nil ? .accentColor : .secondary
        }
    }

    @ViewBuilder
    private var centerLabel: some View {
        if !store.isForToday {
            Image(systemName: "calendar").font(.title3).foregroundStyle(.secondary)
        } else if currentBlock?.pausedAt != nil {
            VStack(spacing: 0) {
                Image(systemName: "pause.fill").font(.body).foregroundStyle(ringColor)
                Text("paused").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        } else if let block = currentBlock, let left = store.minutesLeft(block) {
            VStack(spacing: -2) {
                Text(left > 0 ? Self.shortTime(left) : "+\(Self.shortTime(-left))")
                    .font(.system(size: abs(left) >= 60 ? 16 : 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(left > 0 ? Color.primary : Color.red)
                Text(left > 0 ? (left >= 60 ? "hours" : "min") : "over").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        } else if currentBlock != nil {
            VStack(spacing: 0) {
                Image(systemName: "play.fill").font(.body).foregroundStyle(ringColor)
                Text("start").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        } else if !store.waitingItems.isEmpty {
            Image(systemName: "hand.raised.fill").font(.title3).foregroundStyle(.orange)
        } else if !store.laterIndices.isEmpty {
            Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(.secondary)
        } else {
            Image(systemName: "checkmark").font(.title3.weight(.semibold)).foregroundStyle(.green)
        }
    }

    /// Minutes as "45", or as "1:15" from an hour up, to fit inside the small circle.
    private static func shortTime(_ minutes: Int) -> String {
        minutes >= 60 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : "\(minutes)"
    }

    private var helpText: String {
        let now = currentBlock.map { "Now: \($0.title). " } ?? ""
        return now + "Click to open, drag to move to another corner."
    }
}
