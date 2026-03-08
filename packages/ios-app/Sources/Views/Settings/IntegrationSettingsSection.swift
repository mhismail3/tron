import SwiftUI

struct IntegrationSettingsSection: View {
    @Bindable var settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        // MARK: - Device Context

        Section {
            Toggle(isOn: $settingsState.integrationDeviceContextEnabled) {
                Label("Device context", systemImage: "iphone")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: settingsState.integrationDeviceContextEnabled) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(integrations: .init(deviceContext: .init(enabled: newValue)))
                }
            }

            if settingsState.integrationDeviceContextEnabled {
                signalToggle("Battery", "battery.100", $settingsState.integrationDeviceContextBattery) { newValue in
                    ServerSettingsUpdate(integrations: .init(deviceContext: .init(battery: newValue)))
                }
                signalToggle("Network", "wifi", $settingsState.integrationDeviceContextNetwork) { newValue in
                    ServerSettingsUpdate(integrations: .init(deviceContext: .init(network: newValue)))
                }
                signalToggle("Audio route", "headphones", $settingsState.integrationDeviceContextAudioRoute) { newValue in
                    ServerSettingsUpdate(integrations: .init(deviceContext: .init(audioRoute: newValue)))
                }
                signalToggle("Display", "sun.max", $settingsState.integrationDeviceContextDisplay) { newValue in
                    ServerSettingsUpdate(integrations: .init(deviceContext: .init(display: newValue)))
                }
                signalToggle("Activity", "figure.walk", $settingsState.integrationDeviceContextActivity) { newValue in
                    ServerSettingsUpdate(integrations: .init(deviceContext: .init(activity: newValue)))
                }
                signalToggle("Calendar preview", "calendar", $settingsState.integrationDeviceContextCalendarPreview) { newValue in
                    ServerSettingsUpdate(integrations: .init(deviceContext: .init(calendarPreview: newValue)))
                }
            }
        } footer: {
            Text("Injects device signals (battery, network, etc.) into the agent's context.")
                .font(TronTypography.caption2)
        }

        // MARK: - Clipboard

        Section {
            Toggle(isOn: $settingsState.integrationClipboardEnabled) {
                Label("Clipboard", systemImage: "doc.on.clipboard")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: settingsState.integrationClipboardEnabled) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(integrations: .init(clipboard: .init(enabled: newValue)))
                }
            }
        } footer: {
            Text("Allows the agent to copy text to your clipboard.")
                .font(TronTypography.caption2)
        }

        // MARK: - Haptics

        Section {
            Toggle(isOn: $settingsState.integrationHapticsEnabled) {
                Label("Haptics", systemImage: "waveform")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: settingsState.integrationHapticsEnabled) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(integrations: .init(haptics: .init(enabled: newValue)))
                }
            }

            if settingsState.integrationHapticsEnabled {
                signalToggle("On task complete", "checkmark.circle", $settingsState.integrationHapticsOnTaskComplete) { newValue in
                    ServerSettingsUpdate(integrations: .init(haptics: .init(onTaskComplete: newValue)))
                }
                signalToggle("On error", "exclamationmark.triangle", $settingsState.integrationHapticsOnError) { newValue in
                    ServerSettingsUpdate(integrations: .init(haptics: .init(onError: newValue)))
                }
                signalToggle("On notification", "bell", $settingsState.integrationHapticsOnNotification) { newValue in
                    ServerSettingsUpdate(integrations: .init(haptics: .init(onNotification: newValue)))
                }
            }
        } footer: {
            Text("Haptic feedback for agent events.")
                .font(TronTypography.caption2)
        }

        // MARK: - Calendar

        Section {
            Toggle(isOn: $settingsState.integrationCalendarEnabled) {
                Label("Calendar", systemImage: "calendar")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: settingsState.integrationCalendarEnabled) { _, newValue in
                if newValue {
                    Task { @MainActor in
                        let granted = await CalendarService.shared.requestPermission()
                        if granted {
                            updateServerSetting {
                                ServerSettingsUpdate(integrations: .init(calendar: .init(enabled: true)))
                            }
                        } else {
                            settingsState.integrationCalendarEnabled = false
                        }
                    }
                } else {
                    updateServerSetting {
                        ServerSettingsUpdate(integrations: .init(calendar: .init(enabled: false)))
                    }
                }
            }

            if settingsState.integrationCalendarEnabled {
                signalToggle("Allow creating events", "calendar.badge.plus", $settingsState.integrationCalendarAllowWrite) { newValue in
                    ServerSettingsUpdate(integrations: .init(calendar: .init(allowWrite: newValue)))
                }
            }
        } footer: {
            Text("Allows the agent to search and manage calendar events.")
                .font(TronTypography.caption2)
        }

        // MARK: - Contacts

        Section {
            Toggle(isOn: $settingsState.integrationContactsEnabled) {
                Label("Contacts", systemImage: "person.crop.circle")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: settingsState.integrationContactsEnabled) { _, newValue in
                if newValue {
                    Task { @MainActor in
                        let granted = await ContactsService.shared.requestPermission()
                        if granted {
                            updateServerSetting {
                                ServerSettingsUpdate(integrations: .init(contacts: .init(enabled: true)))
                            }
                        } else {
                            settingsState.integrationContactsEnabled = false
                        }
                    }
                } else {
                    updateServerSetting {
                        ServerSettingsUpdate(integrations: .init(contacts: .init(enabled: false)))
                    }
                }
            }
        } footer: {
            Text("Allows the agent to search your contacts (read-only).")
                .font(TronTypography.caption2)
        }

        // MARK: - Health

        Section {
            Toggle(isOn: $settingsState.integrationHealthEnabled) {
                Label("Health", systemImage: "heart.fill")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: settingsState.integrationHealthEnabled) { _, newValue in
                if newValue {
                    Task { @MainActor in
                        let granted = await HealthService.shared.requestPermission()
                        if granted {
                            updateServerSetting {
                                ServerSettingsUpdate(integrations: .init(health: .init(enabled: true)))
                            }
                        } else {
                            settingsState.integrationHealthEnabled = false
                        }
                    }
                } else {
                    updateServerSetting {
                        ServerSettingsUpdate(integrations: .init(health: .init(enabled: false)))
                    }
                }
            }
        } footer: {
            Text("Allows the agent to read health data (steps, sleep, workouts).")
                .font(TronTypography.caption2)
        }

        // MARK: - Location

        Section {
            Toggle(isOn: $settingsState.integrationLocationEnabled) {
                Label("Location", systemImage: "location")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: settingsState.integrationLocationEnabled) { _, newValue in
                if newValue {
                    Task { @MainActor in
                        let granted = await LocationService.shared.requestPermission()
                        if granted {
                            LocationService.shared.startMonitoring()
                            updateServerSetting {
                                ServerSettingsUpdate(integrations: .init(location: .init(enabled: true)))
                            }
                        } else {
                            settingsState.integrationLocationEnabled = false
                        }
                    }
                } else {
                    LocationService.shared.stopMonitoring()
                    updateServerSetting {
                        ServerSettingsUpdate(integrations: .init(location: .init(enabled: false)))
                    }
                }
            }

            if settingsState.integrationLocationEnabled {
                Picker(selection: $settingsState.integrationLocationPrecision) {
                    Text("City").tag("city")
                    Text("Coordinates").tag("coordinates")
                } label: {
                    Label("Precision", systemImage: "scope")
                        .font(TronTypography.subheadline)
                }
                .onChange(of: settingsState.integrationLocationPrecision) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(integrations: .init(location: .init(precision: newValue)))
                    }
                }
            }
        } footer: {
            Text("Adds location awareness to device context.")
                .font(TronTypography.caption2)
        }
    }

    // MARK: - Helpers

    private func signalToggle(
        _ title: String,
        _ icon: String,
        _ binding: Binding<Bool>,
        update: @escaping (Bool) -> ServerSettingsUpdate
    ) -> some View {
        Toggle(isOn: binding) {
            Label(title, systemImage: icon)
                .font(TronTypography.subheadline)
                .foregroundStyle(.tronTextSecondary)
        }
        .tint(.tronEmerald)
        .onChange(of: binding.wrappedValue) { _, newValue in
            updateServerSetting { update(newValue) }
        }
    }
}
