import SwiftUI

/// The choices made at setup, changeable any time from the gear in the panel's footer.
struct SettingsView: View {
    @ObservedObject var store: PlanStore
    @State private var isOpeningAtLogin = LoginItem.isOn

    private var opensAtLogin: Binding<Bool> {
        Binding(get: { isOpeningAtLogin }, set: { isOn in
            do {
                try LoginItem.set(isOn)
                isOpeningAtLogin = isOn
            } catch {
                store.settingsProblem = "Could not change opening at login: \(error.localizedDescription)"
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                timeRow("Day starts", value: binding(\.dayStart), help: "When your working day starts")
                timeRow("Day ends", value: binding(\.dayEnd), help: "When your working day ends. Work past it shows in orange.")
                Toggle("Lunch break", isOn: lunchIsOn)
                    .help("Add a lunch block to each new day")
                if let lunch = store.settings.lunch {
                    timeRow("Lunch at", value: Binding(get: { lunch }, set: { change(\.lunch, to: $0) }), help: "When lunch starts")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Each morning, bring over what is not done", isOn: binding(\.carriesOverUnfinishedWork))
                    .help("Unfinished tasks from yesterday start today's list")
                Toggle("At day end, show what got done", isOn: binding(\.showsEndOfDayReport))
                    .help("At the end of your day the panel opens with a short report")
                Toggle("Notice Claude sessions with work left", isOn: binding(\.tracksClaudeSessions))
                    .help("Sessions that stop with open tasks or a question for you appear under From Claude")
                Toggle("Share my plan between my Macs", isOn: binding(\.syncsWithICloud))
                    .help("Keeps the plan in iCloud Drive, so every Mac signed in to it shows the same day")
                Toggle("Open Ise when I log in", isOn: opensAtLogin)
                    .help("Starts the panel each time you log in to this Mac")
            }
            if let problem = store.settingsProblem {
                Text(problem).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 300)
    }

    private func timeRow(_ title: String, value: Binding<String>, help: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            DatePicker(title, selection: clockDate(value), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.field)
        }
        .help(help)
    }

    private var lunchIsOn: Binding<Bool> {
        Binding(get: { store.settings.lunch != nil }, set: { change(\.lunch, to: $0 ? "13:00" : nil) })
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(get: { store.settings[keyPath: keyPath] }, set: { change(keyPath, to: $0) })
    }

    private func change<Value>(_ keyPath: WritableKeyPath<Settings, Value>, to value: Value) {
        var settings = store.settings
        settings[keyPath: keyPath] = value
        store.updateSettings(settings)
    }

    /// Shows an "HH:mm" setting in a time field.
    private func clockDate(_ text: Binding<String>) -> Binding<Date> {
        Binding(
            get: {
                let minute = Plan.minuteOfDay(text.wrappedValue) ?? 9 * 60
                return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                text.wrappedValue = String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)
            }
        )
    }
}

/// Shown once at the end of the day when that setting is on: what got done and what moves to tomorrow.
struct DayReportCard: View {
    @ObservedObject var store: PlanStore

    var body: some View {
        let done = store.blocks.filter { $0.status == .done }
        let movingOn = store.blocks.filter { $0.fixedStart == nil && $0.status != .done }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your day").font(.system(size: 15, weight: .semibold))
                Spacer()
                SmallIconButton(symbol: "xmark", label: "Close the report") { store.isShowingDayReport = false }
            }
            Text("\(done.count) of \(store.blocks.count) done").font(.system(size: 13))
            if movingOn.isEmpty {
                Text("Everything is done. Well done.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Text(store.settings.carriesOverUnfinishedWork ? "Moving to tomorrow:" : "Not done:")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(movingOn.prefix(5).enumerated()), id: \.offset) { _, block in
                    Text("• \(block.title)").font(.system(size: 13)).lineLimit(1)
                }
                if movingOn.count > 5 {
                    Text("and \(movingOn.count - 5) more").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }
}
