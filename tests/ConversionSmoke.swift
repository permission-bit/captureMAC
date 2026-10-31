import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@main
struct ConversionSmoke {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.4, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = context.makeImage()!
        let source = root.appendingPathComponent("source.png")
        let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: source)
        for format in ExportFormat.images where (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(format.type.identifier) {
            if format.id == "HEIC", ProcessInfo.processInfo.environment["STILL_SKIP_HEIC_TEST"] == "1" {
                print("HEIC encoding skipped by explicit environment flag (restricted codec service).")
                continue
            }
            FileHandle.standardError.write(Data(("Testing image: " + format.id + "\n").utf8))
            let output = root.appendingPathComponent("image." + format.suffix)
            try await MediaConverter.convert(source: source, isVideo: false, format: format, options: ExportOptions(), output: output) { _ in }
            let decoded = CGImageSourceCreateWithURL(output as CFURL, nil)!
            precondition(CGImageSourceCreateImageAtIndex(decoded, 0, nil)!.width == 64)
        }
        if ProcessInfo.processInfo.environment["STILL_SKIP_VIDEO_TEST"] != "1" {
            let video = root.appendingPathComponent("source.mp4")
            let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
            let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error! }
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<20 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
                var buffer: CVPixelBuffer?
                precondition(CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &buffer) == kCVReturnSuccess)
                CVPixelBufferLockBaseAddress(buffer!, [])
                memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 10), CVPixelBufferGetDataSize(buffer!))
                CVPixelBufferUnlockBaseAddress(buffer!, [])
                precondition(adapter.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error! }
            var options = ExportOptions(); options.duration = 1; options.fps = 5
            for name in ["GIF", "PNG", "JPEG", "MP4", "MOV", "M4V"] {
                let format = (ExportFormat.images + ExportFormat.videos).first { $0.id == name }!
                FileHandle.standardError.write(Data(("Testing video: " + format.id + "\n").utf8))
                let output = root.appendingPathComponent("video." + format.suffix)
                try await MediaConverter.convert(source: video, isVideo: true, format: format, options: options, output: output) { _ in }
                if name == "GIF" {
                    let decoded = CGImageSourceCreateWithURL(output as CFURL, nil)!
                    precondition(CGImageSourceGetCount(decoded) == 5)
                } else if format.movie != nil {
                    let duration = try await AVURLAsset(url: output).load(.duration)
                    precondition(duration.seconds > 1)
                } else { precondition(CGImageSourceCreateWithURL(output as CFURL, nil) != nil) }
            }
        } else {
            print("Video codec tests skipped by explicit environment flag (restricted AVFoundation services).")
        }
        let options = ExportOptions()
        // Existing output must remain byte-for-byte intact on failure.
        do {
            try await MediaConverter.convert(source: source, isVideo: false, format: ExportFormat.images[0], options: options, output: source) { _ in }
            preconditionFailure("An existing file was overwritten")
        } catch { }
        let cancelledOutput = root.appendingPathComponent("cancelled.png")
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            try await MediaConverter.convert(source: source, isVideo: false, format: ExportFormat.images[0], options: options, output: cancelledOutput) { _ in }
        }
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("Cancelled conversion succeeded") }
        catch is CancellationError { }
        precondition(!FileManager.default.fileExists(atPath: cancelledOutput.path))
        let preserved = try Data(contentsOf: source)
        precondition(original == preserved)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(remaining.allSatisfy { !$0.hasPrefix(".export-") })
        print("Conversion smoke passed for enabled codecs, original preservation, and staging cleanup; explicit skips are reported above.")
    }
}
