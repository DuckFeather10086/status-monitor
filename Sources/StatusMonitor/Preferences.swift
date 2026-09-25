import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct MonitorSettings: Codable, Equatable {
    var overlay = 0.55
    var blur = 0.0
    var color = "0.06,0.075,0.10,1"
    var interval = 2.0
    var smartInterval = 60.0
    var interface = "auto"
    var sensor = "cpu"
    var showCPU = true
    var showGPU = true
    var showNetwork = true
    var showTemperature = false
    var compact = false
    var pinned = false
}

@MainActor
final class Preferences: ObservableObject {
    @Published var settings: MonitorSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "settings.v2") }
        }
    }
    @Published private(set) var image: NSImage?
    @Published var imageError: String?
    private let defaults: UserDefaults
    private let imageURL: URL

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StatusMonitor", isDirectory: true)
        imageURL = folder.appendingPathComponent("background.png")
        settings = defaults.data(forKey: "settings.v2").flatMap { try? JSONDecoder().decode(MonitorSettings.self, from: $0) } ?? MonitorSettings()
        if defaults.data(forKey: "settings.v2") == nil, let oldColor = defaults.string(forKey: "backgroundColor") {
            settings.color = oldColor
        }
        image = NSImage(contentsOf: imageURL)
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Background"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.importImage(url) }
        }
    }

    func importImage(_ url: URL) {
        do {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw ImageError.invalid }
            let representation = NSBitmapImageRep(cgImage: thumbnail)
            guard let data = representation.representation(using: .png, properties: [:]) else { throw ImageError.invalid }
            try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: imageURL, options: .atomic)
            image = NSImage(cgImage: thumbnail, size: .zero)
            imageError = nil
        } catch { imageError = "Image unavailable" }
    }

    func removeImage() {
        do {
            if FileManager.default.fileExists(atPath: imageURL.path) { try FileManager.default.removeItem(at: imageURL) }
            image = nil
            imageError = nil
        } catch { imageError = "Remove failed" }
    }
    private enum ImageError: Error { case invalid }
}

struct PanelBackground: View {
    @ObservedObject var preferences: Preferences
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(rgba: preferences.settings.color)
                if let image = preferences.image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: preferences.settings.blur)
                    Color.black.opacity(preferences.settings.overlay)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.allowsHitTesting(false)
    }
}

extension Color {
    init(rgba: String) {
        let values = rgba.split(separator: ",").compactMap { Double($0) }
        self.init(red: values.indices.contains(0) ? values[0] : 0.06,
                  green: values.indices.contains(1) ? values[1] : 0.075,
                  blue: values.indices.contains(2) ? values[2] : 0.10,
                  opacity: values.indices.contains(3) ? values[3] : 1)
    }
    var rgbaString: String {
        let color = NSColor(self).usingColorSpace(.deviceRGB) ?? .black
        return "\(color.redComponent),\(color.greenComponent),\(color.blueComponent),\(color.alphaComponent)"
    }
}
