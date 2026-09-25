import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var store: MetricsStore

    var body: some View {
        Form {
            Section("Background") {
                ZStack {
                    PanelBackground(preferences: preferences)
                    HStack {
                        Text("CPU").font(.caption)
                        Spacer()
                        Text("42%").font(.system(size: 26, weight: .medium, design: .rounded)).foregroundStyle(.mint)
                    }.foregroundStyle(.white).padding(18)
                }.frame(height: 90).clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button("Choose Image…") { preferences.chooseImage() }
                    if preferences.image != nil { Button("Remove") { preferences.removeImage() } }
                }
                if let error = preferences.imageError { Text(error).foregroundStyle(.orange).font(.caption) }
                ColorPicker("Color", selection: Binding(get: { Color(rgba: preferences.settings.color) },
                                                        set: { preferences.settings.color = $0.rgbaString }), supportsOpacity: false)
                if preferences.image != nil {
                    Slider(value: $preferences.settings.overlay, in: 0...0.9) { Text("Dim") }
                    Slider(value: $preferences.settings.blur, in: 0...20) { Text("Blur") }
                }
            }
            Section("Menu Bar") {
                Toggle("Icon Only", isOn: $preferences.settings.compact)
                HStack(spacing: 12) {
                    Toggle("CPU", isOn: $preferences.settings.showCPU)
                    Toggle("GPU", isOn: $preferences.settings.showGPU)
                    Toggle("Temp", isOn: $preferences.settings.showTemperature)
                    Toggle("Net", isOn: $preferences.settings.showNetwork)
                }.disabled(preferences.settings.compact)
            }
            Section("Sampling") {
                Picker("Refresh", selection: $preferences.settings.interval) {
                    Text("1s").tag(1.0)
                    Text("2s").tag(2.0)
                    Text("5s").tag(5.0)
                }
                Picker("SMART", selection: $preferences.settings.smartInterval) {
                    Text("30s").tag(30.0)
                    Text("1m").tag(60.0)
                    Text("5m").tag(300.0)
                    Text("15m").tag(900.0)
                }
                Picker("Interface", selection: $preferences.settings.interface) {
                    Text("Auto").tag("auto")
                    ForEach(store.metrics.network.interfaces, id: \.self) { Text($0).tag($0) }
                    if preferences.settings.interface != "auto", !store.metrics.network.interfaces.contains(preferences.settings.interface) {
                        Text("\(preferences.settings.interface) · Offline").tag(preferences.settings.interface)
                    }
                }
                Picker("Temp", selection: $preferences.settings.sensor) {
                    Text("CPU · Average").tag("cpu")
                    Text("GPU · Average").tag("gpu")
                    ForEach(store.metrics.thermal.sensors) { sensor in
                        Text("\(sensor.id) · \(temperature(sensor.value))").tag(sensor.id)
                    }
                    if !["cpu", "gpu"].contains(preferences.settings.sensor), !store.metrics.thermal.sensors.contains(where: { $0.id == preferences.settings.sensor }) {
                        Text("\(preferences.settings.sensor) · Unavailable").tag(preferences.settings.sensor)
                    }
                }
                HStack {
                    Text("Sensors")
                    Spacer()
                    Text("\(store.metrics.thermal.sensors.count) · \(store.metrics.thermal.status)").foregroundStyle(.secondary)
                }.font(.caption)
            }
        }.formStyle(.grouped).frame(width: 460, height: 660).preferredColorScheme(.dark)
    }
}
