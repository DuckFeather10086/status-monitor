import AppKit
import SwiftUI

@main
struct StatusMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--diagnostics") {
            let metrics = SensorReader().read()
            print("Sensors: \(metrics.status) (\(metrics.sensors.count))")
            print("CPU: \(temperature(metrics.cpu)), GPU: \(temperature(metrics.gpu))")
            for fan in metrics.fans { print("\(fan.id): \(Int(fan.value)) RPM") }
            print("Battery: \(BatteryMetrics.read()?.level ?? "None")")
            for sensor in metrics.sensors { print("\(sensor.id): \(temperature(sensor.value))") }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(store: delegate.store, preferences: delegate.preferences, windows: delegate.windows)
        } label: {
            MenuBarLabel(store: delegate.store, preferences: delegate.preferences)
        }.menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    lazy var store = MetricsStore(preferences: preferences)
    lazy var windows = WindowCoordinator(store: store, preferences: preferences)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if preferences.settings.pinned || CommandLine.arguments.contains("--panel") { windows.showPanel() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showPanel()
        return true
    }
}

@MainActor
final class WindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var panelVisible = false
    private let store: MetricsStore
    private let preferences: Preferences
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?

    init(store: MetricsStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    func togglePanel() {
        if panelVisible { panel?.close() } else { showPanel() }
    }

    func showPanel() {
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 660),
                                 styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Status Monitor"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: DashboardView(store: store, preferences: preferences, windows: self, floating: true))
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("StatusMonitorPanel")
            panel = window
        }
        // Bring back a panel saved on a disconnected external display.
        if let panel, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }),
           let screen = NSScreen.main {
            var frame = panel.frame
            frame.origin = NSPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                   y: screen.visibleFrame.midY - frame.height / 2)
            panel.setFrame(frame, display: true)
        }
        panel?.orderFrontRegardless()
        panelVisible = true
        preferences.settings.pinned = true
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 660),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, store: store))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        panelVisible = false
        preferences.settings.pinned = false
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: MetricsStore
    @ObservedObject var preferences: Preferences
    var body: some View {
        let settings = preferences.settings
        HStack(spacing: 6) {
            if settings.compact || (!settings.showCPU && !settings.showGPU && !settings.showNetwork && !settings.showTemperature) {
                Image(systemName: "waveform.path.ecg")
            } else {
                if settings.showCPU { Text("C \(percent(store.metrics.cpuUsage))") }
                if settings.showGPU { Text("G \(percent(store.metrics.gpuUsage))") }
                if settings.showTemperature { Text(temperature(store.metrics.temperature(sensor: settings.sensor))) }
                if settings.showNetwork {
                    Image(nsImage: NetworkMenuImage.make(download: store.metrics.network.download, upload: store.metrics.network.upload))
                        .accessibilityLabel("Upload \(shortRate(store.metrics.network.upload)), download \(shortRate(store.metrics.network.download))")
                }
            }
        }.font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
    }
}

func percent(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return "\(Int(value.rounded()))%"
}
func temperature(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return "\(Int(value.rounded()))°C"
}
func shortRate(_ bytes: Double) -> String { byteCount(bytes) + "/s" }
func byteCount(_ bytes: Double) -> String {
    let units = ["B", "K", "M", "G", "T"]
    var value = bytes.isFinite ? max(0, bytes) : 0
    var index = 0
    while value >= 1024, index < units.count - 1 { value /= 1024; index += 1 }
    return value >= 100 || index == 0 ? "\(Int(value.rounded()))\(units[index])" : String(format: "%.1f%@", value, units[index])
}
