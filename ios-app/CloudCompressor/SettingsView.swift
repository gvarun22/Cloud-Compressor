import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = Settings.shared
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
                    Stepper(
                        "Max uploads per sync: \(settings.maxUploadsPerSync)",
                        value: $settings.maxUploadsPerSync, in: 1...50
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

                // MARK: Processed history
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Processed videos")
                            Text("\(settings.processedPhotoIds.count) original(s) marked as done")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset", role: .destructive) { showClearConfirm = true }
                    }
                } footer: { Text("Clear this if you deleted a compressed copy and want the original to be re-encoded.") }
                .confirmationDialog(
                    "Reset processed history?",
                    isPresented: $showClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) { settings.clearProcessed() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The next sync will re-evaluate all videos. Already-compressed videos with the encode tag embedded will still be skipped.")
                }

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
