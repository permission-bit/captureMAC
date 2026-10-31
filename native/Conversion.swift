import AppKit
@preconcurrency import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ExportFormat: Identifiable, Equatable {
    let id: String
    let type: UTType
    let movie: AVFileType?
    static let images: [ExportFormat] = [
        .init(id: "PNG", type: .png, movie: nil), .init(id: "JPEG", type: .jpeg, movie: nil),
        .init(id: "HEIC", type: .heic, movie: nil), .init(id: "TIFF", type: .tiff, movie: nil),
        .init(id: "BMP", type: .bmp, movie: nil), .init(id: "GIF", type: .gif, movie: nil)
    ]
    static let videos: [ExportFormat] = [
        .init(id: "MP4", type: .mpeg4Movie, movie: .mp4),
        .init(id: "MOV", type: .quickTimeMovie, movie: .mov),
        .init(id: "M4V", type: UTType(filenameExtension: "m4v") ?? .mpeg4Movie, movie: .m4v)
    ]
    var suffix: String { id.lowercased() == "jpeg" ? "jpg" : id.lowercased() }
    static func available(for item: MediaItem) -> [ExportFormat] {
        let supported = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
        return images.filter { supported.contains($0.type.identifier) } + (item.kind == "video" ? videos : [])
    }
}

struct ExportOptions {
    var start = 0.0
    var duration = 10.0
    var fps = 10
    var width = 640
    var quality = 0.9
}

// AVFoundation supports cancelling an export from another thread. This holder
// shares only that cancellation operation, never mutable export configuration.
private final class ExportCancellation: @unchecked Sendable {
    private let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}

enum MediaConverter {
    /// Writes into a unique staging file and atomically publishes only a complete
    /// result. The source is never modified, even on cancellation or failure.
    static func convert(source: URL, isVideo: Bool, format: ExportFormat, options: ExportOptions, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".export-\(UUID().uuidString).\(format.suffix)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        if let movie = format.movie {
            guard isVideo else { throw CocoaError(.fileReadUnsupportedScheme) }
            let asset = AVURLAsset(url: source)
            let preset = movie == .m4a ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
            guard let session = AVAssetExportSession(asset: asset, presetName: preset), session.supportedFileTypes.contains(movie) else {
                throw CocoaError(.featureUnsupported)
            }
            session.shouldOptimizeForNetworkUse = true
            let cancellation = ExportCancellation(session)
            try await withTaskCancellationHandler {
                try await session.export(to: temporary, as: movie)
            } onCancel: { cancellation.cancel() }
        } else if isVideo {
            let asset = AVURLAsset(url: source)
            let seconds = try await asset.load(.duration).seconds
            guard seconds.isFinite, seconds > 0, options.start.isFinite, options.start >= 0, options.start < seconds else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            if format.id == "GIF" {
                let fps = min(12, max(1, options.fps))
                let duration = min(30, max(0.1, options.duration), seconds - options.start)
                let frames = min(360, max(1, Int(ceil(duration * Double(fps)))))
                generator.maximumSize = CGSize(width: min(960, max(320, options.width)), height: min(960, max(320, options.width)))
                guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.gif.identifier as CFString, frames, nil) else { throw CocoaError(.fileWriteUnknown) }
                CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
                for index in 0..<frames {
                    try Task.checkCancellation()
                    let time = CMTime(seconds: options.start + Double(index) / Double(fps), preferredTimescale: 600)
                    let image = try await generator.image(at: time).image
                    CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary)
                    progress(Double(index + 1) / Double(frames))
                }
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            } else {
                let image = try await generator.image(at: CMTime(seconds: options.start, preferredTimescale: 600)).image
                try write(image, format: format, quality: options.quality, to: temporary)
            }
        } else {
            guard let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(sourceImage, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
            try write(image, format: format, quality: options.quality, to: temporary)
        }
        try Task.checkCancellation()
        // moveItem refuses overwrites, including races after the save panel.
        try FileManager.default.moveItem(at: temporary, to: output)
        progress(1)
    }
    private static func write(_ image: CGImage, format: ExportFormat, quality: Double, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        // Opaque formats get a white background rather than transparent black.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

struct ConversionView: View {
    let item: MediaItem
    @ObservedObject var model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @State private var formatID = "GIF"
    @State private var options = ExportOptions()
    @State private var duration = 0.0
    @State private var exporting = false
    @State private var progress = 0.0
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    private var formats: [ExportFormat] { ExportFormat.available(for: item) }
    private var format: ExportFormat { formats.first(where: { $0.id == formatID }) ?? formats[0] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("export.title")).font(.title2.weight(.semibold))
            Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Form {
                Picker(L("export.format"), selection: $formatID) {
                    ForEach(formats) { Text($0.id).tag($0.id) }
                }
                if item.kind == "video" && format.movie == nil {
                    TextField(L("export.time"), value: $options.start, format: .number).help("0 – \(max(0, duration - 0.1))")
                    if format.id == "GIF" {
                        TextField(L("export.duration"), value: $options.duration, format: .number)
                        Picker(L("quality.fps"), selection: $options.fps) {
                            ForEach([5, 10, 12], id: \.self) { Text("\($0) fps").tag($0) }
                        }
                        Picker(L("export.size"), selection: $options.width) {
                            ForEach([320, 640, 960], id: \.self) { Text("\($0) px").tag($0) }
                        }
                        Text(L("export.gif_hint")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if ["JPEG", "HEIC"].contains(format.id) {
                    Slider(value: $options.quality, in: 0.2...1) { Text(L("quality.label")) }
                }
            }.disabled(exporting)
            if exporting {
                if format.movie != nil { ProgressView().controlSize(.small) }
                else { ProgressView(value: progress) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text(L("export.original")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("common.cancel")) { task?.cancel(); if !exporting { dismiss() } }.keyboardShortcut(.cancelAction)
                Button(L("export.save")) { save() }.buttonStyle(.borderedProminent).disabled(exporting).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 490)
        .environment(\.locale, model.locale).environment(\.layoutDirection, model.layoutDirection)
        .interactiveDismissDisabled(exporting)
        .onDisappear { task?.cancel() }
        .task {
            formatID = item.kind == "video" ? "GIF" : "JPEG"
            if item.kind == "video" { duration = (try? await AVURLAsset(url: item.url).load(.duration).seconds) ?? 0 }
        }
    }
    private func save() {
        guard options.start.isFinite, options.duration.isFinite else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = item.url.deletingPathExtension().lastPathComponent + "-export." + format.suffix
        panel.directoryURL = model.mediaDirectory
        guard panel.runModal() == .OK, let output = panel.url else { return }
        // Keep existing files safe: request a fresh name instead of deleting an
        // earlier export or the source after an overwrite prompt.
        guard output.standardizedFileURL != item.url.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else { error = L("export.exists"); return }
        exporting = true; model.exportingMedia = true; error = nil; progress = 0
        let selectedFormat = format
        let chosenOptions = options
        task = Task {
            defer { model.exportingMedia = false }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await MediaConverter.convert(source: item.url, isVideo: item.kind == "video", format: selectedFormat, options: chosenOptions, output: output) { value in
                        Task { @MainActor in progress = value }
                    }
                }
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                exporting = false
                model.refreshLibrary()
                NSWorkspace.shared.activateFileViewerSelecting([output])
                dismiss()
            } catch {
                exporting = false
                if error is CancellationError || (error as NSError).code == NSUserCancelledError { dismiss() }
                else { self.error = error.localizedDescription }
            }
        }
    }
}
