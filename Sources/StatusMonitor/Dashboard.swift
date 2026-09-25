import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: MetricsStore
    @ObservedObject var preferences: Preferences
    @ObservedObject var windows: WindowCoordinator
    var floating = false
    @State private var showCores = true
    @State private var showGPU = false

    private var selectedTemperature: Double? { store.metrics.temperature(sensor: preferences.settings.sensor) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.mint)
                Text("STATUS").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2)
                Spacer()
                Circle().fill(store.isSampling ? Color.mint : Color.mint.opacity(0.45)).frame(width: 5, height: 5)
                Text("LIVE").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.top, floating ? 30 : 18).padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        MetricCard(title: "CPU", value: percent(store.metrics.cpuUsage), tint: .mint,
                                   history: store.history.map(\.cpu), ceiling: 100)
                        MetricCard(title: "GPU", value: percent(store.metrics.gpuUsage), tint: .cyan,
                                   history: store.history.map(\.gpu), ceiling: 100)
                    }

                    if !store.metrics.cores.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            disclosure("Cores", detail: "\(store.metrics.cores.count)", expanded: $showCores)
                            if showCores {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                                    ForEach(Array(store.metrics.cores.enumerated()), id: \.offset) { index, usage in
                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack(spacing: 2) {
                                                Text("\(index + 1)").foregroundStyle(.white.opacity(0.4))
                                                Spacer(minLength: 1)
                                                Text(percent(usage)).foregroundStyle(.white.opacity(0.85))
                                            }.font(.system(size: 9, weight: .medium, design: .monospaced))
                                            GeometryReader { geometry in
                                                ZStack(alignment: .leading) {
                                                    Capsule().fill(.white.opacity(0.07))
                                                    Capsule().fill((usage ?? 0) > 80 ? Color.orange : Color.mint)
                                                        .frame(width: geometry.size.width * min(1, max(0, (usage ?? 0) / 100)))
                                                }
                                            }.frame(height: 4)
                                        }.accessibilityElement(children: .ignore)
                                            .accessibilityLabel("Core \(index + 1), \(percent(usage))")
                                    }
                                }
                            }
                        }.cardSurface()
                    }

                    if !store.metrics.gpus.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            disclosure("GPU engines", detail: store.metrics.gpus.count > 1 ? "\(store.metrics.gpus.count)" : "", expanded: $showGPU)
                            if showGPU {
                                ForEach(store.metrics.gpus) { gpu in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(gpu.name).font(.system(size: 11, weight: .medium))
                                            Spacer()
                                            Text(percent(gpu.usage)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.cyan)
                                        }
                                        if let renderer = gpu.renderer { engineRow("Renderer", value: renderer) }
                                        if let tiler = gpu.tiler { engineRow("Tiler", value: tiler) }
                                    }
                                }
                            }
                        }.cardSurface()
                    }

                    HStack(spacing: 10) {
                        MetricCard(title: "Temp", value: temperature(selectedTemperature), tint: .orange,
                                   history: store.history.map(\.temperature), ceiling: 120)
                            .help(selectedTemperature == nil ? "\(preferences.settings.sensor): unavailable · \(store.metrics.thermal.status)" : "\(preferences.settings.sensor) · SMC")
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Disk", systemImage: "internaldrive").foregroundStyle(.secondary)
                                Spacer()
                                Circle().fill(store.metrics.smartStatus == "Verified" ? Color.mint : Color.orange).frame(width: 5, height: 5)
                            }.font(.system(size: 10, weight: .medium))
                            Text(store.metrics.smartStatus).font(.system(size: 15, weight: .semibold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text("S.M.A.R.T.").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading).cardSurface()
                    }

                    if !store.metrics.thermal.fans.isEmpty {
                        HStack {
                            Label("Fans", systemImage: "fanblades").font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text(store.metrics.thermal.fans.map { String(Int($0.value.rounded())) }.joined(separator: " / ") + " RPM")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }.cardSurface()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Network").font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Text(store.metrics.network.interface).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 18) {
                            networkColumn("Down", symbol: "arrow.down", value: store.metrics.network.download,
                                          total: store.metrics.network.received, values: store.history.map { $0.download }, tint: .cyan)
                            networkColumn("Up", symbol: "arrow.up", value: store.metrics.network.upload,
                                          total: store.metrics.network.sent, values: store.history.map { $0.upload }, tint: .mint)
                        }
                    }.cardSurface()

                    if let battery = store.metrics.battery {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: battery.charging ? "battery.100.bolt" : "battery.100").foregroundStyle(.mint)
                                Text("Battery").font(.system(size: 11, weight: .semibold))
                                Spacer()
                                Text(battery.level).font(.system(size: 16, weight: .semibold, design: .rounded))
                            }
                            HStack {
                                Text(battery.status)
                                Spacer()
                                if let time = battery.timeDescription { Text(time) }
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }.cardSurface()
                    }
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }.scrollIndicators(.hidden)

            HStack(spacing: 16) {
                Button { windows.togglePanel() } label: {
                    Image(systemName: windows.panelVisible ? "pin.fill" : "pin")
                        .foregroundStyle(windows.panelVisible ? Color.mint : .secondary)
                }.help("Pin window").accessibilityLabel("Pin window")
                Button { windows.showSettings() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Settings").accessibilityLabel("Settings")
                Spacer()
                Text("2m").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).help("History window")
                Button { store.sample(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh").accessibilityLabel("Refresh")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit").accessibilityLabel("Quit")
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 13)
                .background(.black.opacity(0.15))
        }
        .frame(width: 360, height: 660)
        .background(PanelBackground(preferences: preferences))
        .preferredColorScheme(.dark)
    }

    private func disclosure(_ title: String, detail: String, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func engineRow(_ title: String, value: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 52, alignment: .leading)
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.06)).overlay(alignment: .leading) {
                    Capsule().fill(.cyan).frame(width: geometry.size.width * value / 100)
                }
            }.frame(height: 4)
            Text(percent(value)).frame(width: 30, alignment: .trailing)
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
    }

    private func networkColumn(_ title: String, symbol: String, value: Double, total: UInt64, values: [Double], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
            Text(shortRate(value)).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
            Sparkline(values: values.map(Optional.some), ceiling: max(1024, (store.history.map { max($0.download, $0.upload) }.max() ?? 0)), tint: tint)
                .frame(height: 26)
            Text("Σ \(byteCount(Double(total)))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                .help("Traffic observed on this interface during this session")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func cardSurface() -> some View {
        padding(12)
            .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.075), lineWidth: 0.5))
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let tint: Color
    let history: [Double?]
    let ceiling: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            Sparkline(values: history, ceiling: ceiling, tint: tint).frame(height: 25)
        }.frame(maxWidth: .infinity, alignment: .leading).cardSurface()
    }
}

struct Sparkline: View {
    let values: [Double?]
    let ceiling: Double
    let tint: Color
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                var connected = false
                for (index, sample) in values.enumerated() {
                    guard let sample, sample.isFinite else { connected = false; continue }
                    let point = CGPoint(x: geometry.size.width * Double(index) / Double(max(1, values.count - 1)),
                                        y: geometry.size.height * (1 - min(1, max(0, sample / max(1, ceiling)))))
                    if connected { path.addLine(to: point) } else { path.move(to: point) }
                    connected = true
                }
            }.stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            Path { path in
                path.move(to: CGPoint(x: 0, y: geometry.size.height))
                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
            }.stroke(.white.opacity(0.08), lineWidth: 0.5)
        }.accessibilityHidden(true)
    }
}
