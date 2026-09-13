import SwiftUI

struct AutoStopSettings: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    @State private var showCustom = false
    @State private var hours = String(ShareAutoStop.defaultMinutes / 60)
    @State private var minutes = "0"

    private var customMinutes: Int? {
        guard let h = Int(hours), (0...99).contains(h),
              let m = Int(minutes), (0...59).contains(m),
              ShareAutoStop.customRange.contains(h * 60 + m) else { return nil }
        return h * 60 + m
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.autoStopTitle(state.lang)).font(.sans(13, .semibold)).foregroundStyle(t.ink)
                    Text(L.autoStopDesc(state.lang)).font(.sans(11.5)).foregroundStyle(t.inkMute)
                }
                Spacer(minLength: 8)
                Menu {
                    durationOption(0)
                    ForEach(ShareAutoStop.presets, id: \.self) { durationOption($0) }
                    Divider()
                    Button(L.autoStopCustom(state.lang)) {
                        hours = String(state.customAutoStopMinutes / 60)
                        minutes = String(state.customAutoStopMinutes % 60)
                        showCustom = true
                    }
                } label: {
                    Text(durationLabel(state.autoStopMinutes)).font(.sans(13))
                }
                .fixedSize()
            }
            if state.isRunning {
                Text(L.autoStopHint(state.lang)).font(.sans(11.5)).foregroundStyle(t.inkMute)
            }
            AutoStopDeadline(t: t)
        }
        .padding(.vertical, 12)
        .sheet(isPresented: $showCustom) { customEditor }
    }

    private func durationOption(_ value: Int) -> some View {
        Button { state.setAutoStopMinutes(value) } label: {
            if state.autoStopMinutes == value {
                Label(durationLabel(value), systemImage: "checkmark")
            } else {
                Text(durationLabel(value))
            }
        }
    }

    private func durationLabel(_ value: Int) -> String {
        if value == 0 { return L.autoStopNever(state.lang) }
        let h = value / 60, m = value % 60
        if state.lang == .zh {
            return [h > 0 ? "\(h) 小时" : nil, m > 0 ? "\(m) 分钟" : nil].compactMap { $0 }.joined(separator: " ")
        }
        return [h > 0 ? "\(h) hr" : nil, m > 0 ? "\(m) min" : nil].compactMap { $0 }.joined(separator: " ")
    }

    private var customEditor: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L.autoStopTitle(state.lang)).font(.display(21, .semibold)).foregroundStyle(t.ink)
            HStack(spacing: 16) {
                durationField(L.hours(state.lang), text: $hours)
                Text(":").font(.mono(24)).foregroundStyle(t.inkMute)
                durationField(L.minutes(state.lang), text: $minutes)
            }
            if state.isRunning {
                Text(L.autoStopHint(state.lang)).font(.sans(11.5)).foregroundStyle(t.inkMute)
            }
            HStack {
                Spacer()
                Button(L.cancel(state.lang)) { showCustom = false }.keyboardShortcut(.cancelAction)
                Button(L.autoStopApply(state.lang)) {
                    guard let value = customMinutes else { return }
                    state.setAutoStopMinutes(value, custom: true)
                    showCustom = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(customMinutes == nil)
            }
        }
        .padding(24)
        .frame(width: 350)
        .background(t.bg)
    }

    private func durationField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("0", text: text)
                .textFieldStyle(.plain)
                .font(.mono(28, .medium))
                .foregroundStyle(t.ink)
                .multilineTextAlignment(.center)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(t.field))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(t.lineStrong))
                .onChange(of: text.wrappedValue) { text.wrappedValue = String($0.filter(\.isNumber).prefix(2)) }
                .accessibilityLabel(label)
            Text(label).font(.sans(12)).foregroundStyle(t.inkMute)
        }
    }
}

struct AutoStopDeadline: View {
    let t: Theme
    @EnvironmentObject var state: AppState

    var body: some View {
        if let deadline = state.autoStopAt {
            Label(deadlineLabel(deadline), systemImage: "timer")
                .font(.mono(11.5)).foregroundStyle(t.inkMute)
        }
    }

    private func deadlineLabel(_ deadline: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: state.lang == .zh ? "zh_CN" : "en_US")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let date = formatter.string(from: deadline)
        return state.lang == .zh ? "\(date) 关闭分享" : "Stops \(date)"
    }
}
