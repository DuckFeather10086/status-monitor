# Status Monitor

A lightweight native macOS monitor built with SwiftUI and AppKit. No subscriptions, accounts, telemetry, or runtime dependencies.

## Install

macOS 13+ and Swift 5.9+. Install Command Line Tools with `xcode-select --install` if needed. Build on the Mac where you will run the app; Apple Silicon and Intel are supported.

```sh
git clone https://github.com/DuckFeather10086/status-monitor.git && cd status-monitor && ./build-app.sh && open StatusMonitor.app
```

## Update

For a checkout in your home directory:

```sh
cd ~/status-monitor && git pull --ff-only && ./build-app.sh && open StatusMonitor.app
```

The build script stops only the running app inside that checkout after compilation succeeds. If you previously copied the app into Applications, quit that copy and replace it with the newly built app. Builds use ad-hoc signing, not Developer ID notarization.

## Features

- **CPU:** overall load, per-logical-core bars, and a rolling two-minute graph. Numbered cores do not claim a physical P/E-core mapping.
- **GPU:** utilization and history, plus separate device / Renderer / Tiler readings where exposed. Expand **GPU engines** for details. For multiple GPUs the headline shows the highest utilization, with individual readings below. GPU compute-core utilization is not exposed.
- **Temp:** read-only AppleSMC, with CPU/GPU sensor mappings for Intel and M1–M5 / A18 Pro. The default is the average of available mapped CPU sensors. Choose a raw sensor under Settings → Temp. Invalid or missing readings show **—**, never an invented fallback. New models can expose different keys; not every mapping has been tested on hardware.
- **Fans:** measured RPM when available; no fan-control writes or privileged helper.
- **Network:** 64-bit interface counters, rates, graphs, and session traffic. Auto selects the primary interface; choose `en…` or `utun…` explicitly in Settings. Only one interface is counted, avoiding VPN/physical-interface double counting. Totals reset on interface changes/relaunch.
- **SMART:** resolves APFS physical stores and caches diskutil health. Refresh interval: 30s / 1m / 5m / 15m. Some disks do not report SMART.
- **Battery:** percentage, charging / plugged in / full status, and available system time estimates. Hidden on desktops; UPS devices are excluded.

## Appearance

Open the sliders button → **Background → Choose Image…**. PNG, JPEG, HEIC, TIFF and WebP are accepted when supported by the system decoder. Images are downsampled to 1600 px and saved locally under `~/Library/Application Support/StatusMonitor/background.png`, so moving the original file does not break the background. **Dim**, **Blur**, **Color**, and **Remove** are available. Backgrounds apply to the popup and pinned panel, not the macOS menu bar.

**Pin** opens a movable floating panel across Spaces. It remains available when the menu bar is crowded by an input method or the display notch. Close or unpin it to dismiss. Reopening the app also opens this panel. Settings include **Icon Only** and individual menu-bar metric toggles to save space. All app labels use short English text.

## Verification

```sh
zsh test.sh && ./build-app.sh
```

Tests run with Command Line Tools alone: battery states, SMC encodings, CPU tick rollover, 64-bit network counters, interface switching, image persistence/invalid imports, and live sampling. Use `zsh test.sh --require-temperature` to also require a real CPU sensor on the development machine.

Sensor diagnostics (no root required):

```sh
./StatusMonitor.app/Contents/MacOS/StatusMonitor --diagnostics
```

Hardware verified on an M4 Mac mini: CPU temperature, 10 logical-core loads, GPU utilization, fan RPM, primary-interface traffic, and SMART. This machine did not expose a valid mapped GPU temperature during verification. Actual MacBook battery behavior still requires laptop testing.

## Credits

Sensor ABI/mappings reference [Stats](https://github.com/exelban/stats), under the MIT license; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), also bundled inside the app. Interface selection and adjustable SMART polling were inspired by its [recent releases](https://github.com/exelban/stats/releases).
