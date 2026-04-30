import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Azure
                Section {
                    TextField("https://func-name.azurewebsites.net/api", text: $settings.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: { Text("Function App Base URL") }

                Section {
                    SecureField("Function key", text: $settings.functionKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: { Text("Function Key") }
                  footer: { Text("Found in Azure Portal → Function App → App keys → default.") }

                // MARK: Sync
                Section {
                    Toggle("Auto-sync on app open", isOn: $settings.autoSyncOnOpen)
                    Stepper(
                        "Max concurrent uploads: \(settings.maxConcurrentUploads)",
                        value: $settings.maxConcurrentUploads, in: 1...5
                    )
                } header: { Text("Sync Behaviour") }
                  footer: { Text("Background sync also runs automatically when idle on WiFi.") }

                // MARK: Quiet window
                Section {
                    Toggle("Restrict background sync to quiet hours", isOn: $settings.quietWindowEnabled)

                    if settings.quietWindowEnabled {
                        timePicker(
                            label: "Start",
                            hour: $settings.quietWindowStartHour,
                            minute: $settings.quietWindowStartMinute
                        )
                        timePicker(
                            label: "End",
                            hour: $settings.quietWindowEndHour,
                            minute: $settings.quietWindowEndMinute
                        )
                    }
                } header: { Text("Quiet Window") }
                  footer: { Text("Background tasks will only be scheduled within these hours. Foreground sync always runs.") }

                // MARK: Encode settings (read-only info)
                Section {
                    LabeledContent("Current tag", value: settings.encodeSettingsTag)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: { Text("Encode Settings Tag") }
                  footer: { Text("Videos already compressed with this tag are skipped. If you change the FFmpeg command in Azure, update encodeSettingsTag in Settings.swift to match.") }
            }
            .navigationTitle("Settings")
        }
    }

    @ViewBuilder
    private func timePicker(label: String, hour: Binding<Int>, minute: Binding<Int>) -> some View {
        HStack {
            Text(label).frame(width: 44, alignment: .leading)
            Stepper(
                "\(String(format: "%02d", hour.wrappedValue)):\(String(format: "%02d", minute.wrappedValue))",
                onIncrement: {
                    var h = hour.wrappedValue, m = minute.wrappedValue
                    m += 15; if m >= 60 { m = 0; h = (h + 1) % 24 }
                    hour.wrappedValue = h; minute.wrappedValue = m
                },
                onDecrement: {
                    var h = hour.wrappedValue, m = minute.wrappedValue
                    m -= 15; if m < 0 { m = 45; h = (h - 1 + 24) % 24 }
                    hour.wrappedValue = h; minute.wrappedValue = m
                }
            )
        }
    }
}
