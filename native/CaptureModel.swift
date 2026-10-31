import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import SwiftUI

struct MediaItem: Decodable, Identifiable, Equatable {
    let path: String
    let name: String
    let kind: String
    let bytes: UInt64
    let created: TimeInterval
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var date: Date { Date(timeIntervalSince1970: created) }
    var title: String { "\(kind == "image" ? L("settings.screenshot") : L("nav.capture")) · \(Localization.date(date))" }
    var size: String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
}

@MainActor
final class CaptureModel: NSObject, ObservableObject, SCStreamDelegate, SCRecordingOutputDelegate {
    static let accent = Color(red: 0.29, green: 0.35, blue: 0.91)
    let core: OpaquePointer
    let root: URL
    var libraryRoot: URL { root.appendingPathComponent("Aufnahmen", isDirectory: true) }
    @Published var recordingFolder: URL?
    @Published var libraryFolder: URL?
    @Published var folders: [URL] = []
    var mediaDirectory: URL { recordingFolder ?? libraryRoot }
    var currentLibraryFolder: URL { libraryFolder ?? libraryRoot }
    var folderItems: [MediaItem] {
        filteredLibrary.filter { $0.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == currentLibraryFolder.standardizedFileURL.resolvingSymlinksInPath() }
    }
    @Published private(set) var language = "system"
    var locale: Locale { Localization.locale }
    var layoutDirection: LayoutDirection { Localization.direction }
    @Published var settings: StillSettings
    @Published var phase: UInt32 = 0
    @Published var countdown: UInt32 = 0
    @Published var elapsed: UInt64 = 0
    @Published var preflighting = false
    @Published var loadingSources = false
    @Published var hasPermission = CGPreflightScreenCaptureAccess()
    @Published var sourceMode = 0
    @Published var selectedDisplay: UInt32 = 0
    @Published var selectedWindow: UInt32 = 0
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var preview: NSImage?
    @Published var library: [MediaItem] = []
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var page = 0
    @Published var search = ""
    @Published var libraryFilter = 0
    @Published var selectedMedia: MediaItem?
    @Published var exportingMedia = false
    @Published var conversionItem: MediaItem?
    private var discarding = false
    @Published var showPreferences = false
    private var content: SCShareableContent?
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var ticker: AnyCancellable?
    private var launching = false
    private var handlingFailure = false
    private var previewGeneration = 0
    private var shouldQuit = false
    private var sleepAssertion: NSObjectProtocol?
    var active: Bool { phase != 0 || preflighting }
    var clock: String { String(format: "%02llu:%02llu", elapsed / 60, elapsed % 60) }
    var statusText: String {
        if preflighting { return L("status.preparing") }
        switch phase {
        case 1: return LF("status.countdown", Int(countdown))
        case 2: return L("status.recording_start")
        case 3: return L("status.recording")
        case 4: return L("status.saving")
        default: return L("status.ready")
        }
    }
    var sourceTitle: String {
        if sourceMode == 0 {
            guard let index = displays.firstIndex(where: { $0.displayID == selectedDisplay }) else { return L("source.screen") }
            return displayName(displays[index], index: index)
        }
        guard let window = windows.first(where: { $0.windowID == selectedWindow }) else { return L("source.select_window") }
        return windowTitle(window)
    }
    var canCapture: Bool {
        hasPermission && !loadingSources && (sourceMode == 0
            ? displays.contains(where: { $0.displayID == selectedDisplay })
            : windows.contains(where: { $0.windowID == selectedWindow }))
    }
    var filteredLibrary: [MediaItem] {
        library.filter { item in
            (libraryFilter == 0 || (libraryFilter == 1 ? item.kind == "video" : item.kind == "image")) &&
            (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.name.localizedCaseInsensitiveContains(search))
        }
    }

    let previewMode: Bool

    init(previewMode: Bool = false, rootURL: URL? = nil) {
        // All user data stays in a single, visible folder. No network services.
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        root = rootURL ?? base.appendingPathComponent("Still", isDirectory: true)
        self.previewMode = previewMode
        core = root.path.withCString { still_create($0)! }
        settings = still_settings(core)
        super.init()
        let savedLanguage = (try? String(contentsOf: root.appendingPathComponent("language.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "system"
        Localization.select(savedLanguage)
        language = Localization.preference
        recordingFolder = takeString(still_destination(core)).map { URL(fileURLWithPath: $0, isDirectory: true) }
        refreshLibrary()
        if previewMode { hasPermission = false }
        else if hasPermission { Task { await refreshSources() } }
    }

    deinit { still_destroy(core) }

    func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { still_string_free(pointer) }
        return String(cString: pointer)
    }
    func coreError() -> String {
        guard let message = takeString(still_error(core)), !message.isEmpty else { return L("error.unknown") }
        let parts = message.split(separator: "\t", maxSplits: 1).map(String.init)
        let key = parts[0]
        let text = key.hasPrefix("error.") ? L(key) : L("error.storage")
        let detail = key.hasPrefix("error.") ? parts.dropFirst().joined() : message
        return detail.isEmpty ? text : text + "\n\n" + detail
    }
    func setLanguage(_ value: String) {
        guard !active, value != language,
              value == "system" || Localization.languages.contains(where: { $0.id == value }) else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try value.write(to: root.appendingPathComponent("language.txt"), atomically: true, encoding: .utf8)
            Localization.select(value)
            language = value
            notice = nil
            errorMessage = nil
        } catch { errorMessage = L("error.language") + "\n\n" + error.localizedDescription }
    }
    func change(_ keyPath: WritableKeyPath<StillSettings, UInt32>, _ value: UInt32) {
        guard !active else { return }
        var next = settings
        next[keyPath: keyPath] = value
        if still_save_settings(core, next) { settings = still_settings(core) }
        else { errorMessage = coreError() }
    }
    func binding(_ path: WritableKeyPath<StillSettings, UInt32>) -> Binding<UInt32> {
        Binding(get: { self.settings[keyPath: path] }, set: { self.change(path, $0) })
    }
    func toggle(_ path: WritableKeyPath<StillSettings, UInt32>) -> Binding<Bool> {
        Binding(get: { self.settings[keyPath: path] != 0 }, set: { self.change(path, $0 ? 1 : 0) })
    }
    func displayName(_ display: SCDisplay, index: Int) -> String {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == display.displayID }
        return screen?.localizedName ?? LF("source.number", index + 1)
    }
    func windowTitle(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "App"
        guard let title = window.title, !title.isEmpty else { return app }
        return "\(app) — \(title)"
    }
    func requestPermission() {
        guard !loadingSources else { return }
        // A capture request triggers the system's permission sheet. Never retry
        // in a loop: denial is resolved by the user in System Settings.
        Task { await refreshSources(requestAccess: true) }
    }
    func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func refreshSources(requestAccess: Bool = false) async {
        guard !previewMode, !active, !loadingSources else { return }
        hasPermission = CGPreflightScreenCaptureAccess()
        guard hasPermission || requestAccess else { return }
        loadingSources = true
        defer { loadingSources = false }
        do {
            let next = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            content = next
            hasPermission = true
            displays = next.displays
            windows = next.windows.filter {
                $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60 &&
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
            }.sorted { windowTitle($0).localizedStandardCompare(windowTitle($1)) == .orderedAscending }
            if !displays.contains(where: { $0.displayID == selectedDisplay }) {
                selectedDisplay = displays.first?.displayID ?? 0
            }
            if !windows.contains(where: { $0.windowID == selectedWindow }) {
                selectedWindow = windows.first?.windowID ?? 0
            }
            await updatePreview()
        } catch {
            hasPermission = CGPreflightScreenCaptureAccess()
            errorMessage = L("error.screen_access") + "\n\n" + error.localizedDescription
        }
    }
    private func filter() throws -> SCContentFilter {
        if sourceMode == 0 {
            guard let display = displays.first(where: { $0.displayID == selectedDisplay }) else {
                throw CaptureError.message(L("error.choose_screen"))
            }
            let ownApps = content?.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier } ?? []
            return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        }
        guard let window = windows.first(where: { $0.windowID == selectedWindow }) else {
            throw CaptureError.message(L("error.window_gone"))
        }
        return SCContentFilter(desktopIndependentWindow: window)
    }
    private func configuration(for filter: SCContentFilter, preview: Bool = false, screenshot: Bool = false) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        let nativeWidth = max(2, filter.contentRect.width * scale)
        let nativeHeight = max(2, filter.contentRect.height * scale)
        let limit = preview ? 640.0 : (screenshot || settings.max_height == 0 ? nativeHeight : Double(settings.max_height))
        let codecWidthLimit = screenshot ? nativeWidth : (settings.hevc != 0 ? 7680.0 : 3840.0)
        let ratio = min(1, limit / nativeHeight, codecWidthLimit / nativeWidth)
        config.width = max(2, Int(nativeWidth * ratio) / 2 * 2)
        config.height = max(2, Int(nativeHeight * ratio) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(settings.fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = !preview && settings.cursor != 0
        config.showMouseClicks = !preview && !screenshot && settings.clicks != 0
        config.capturesAudio = !preview && !screenshot && settings.system_audio != 0
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = !preview && !screenshot && settings.microphone != 0
        config.sampleRate = 48_000
        config.channelCount = 2
        return config
    }
    func updatePreview() async {
        previewGeneration += 1
        let generation = previewGeneration
        guard hasPermission, !active else { return }
        do {
            let filter = try filter()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration(for: filter, preview: true))
            guard generation == previewGeneration, !active else { return }
            preview = NSImage(cgImage: image, size: .zero)
        } catch {
            if generation == previewGeneration { preview = nil }
            // Source selection remains usable if a preview is temporarily unavailable.
        }
    }
    func begin() {
        guard !active, canCapture else { return }
        preflighting = true
        notice = nil
        Task {
            defer { preflighting = false }
            if settings.microphone != 0 {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard allowed else {
                    errorMessage = L("error.microphone")
                    return
                }
            }
            discarding = false
            guard still_begin(core) else { errorMessage = coreError(); return }
            if settings.hide_app != 0 { NSApp.hide(nil) }
            // Prevent idle system sleep while preparing or recording.
            sleepAssertion = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: L("nav.capture"))
            ticker?.cancel()
            ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                self?.tick()
            }
            tick()
        }
    }
    private func tick() {
        let status = still_status(core)
        if phase != status.phase { phase = status.phase }
        if countdown != status.remaining { countdown = status.remaining }
        if elapsed != status.elapsed { elapsed = status.elapsed }
        if phase == 2 && !launching {
            launching = true
            Task { await startStream() }
        }
        if status.should_stop != 0 { stop() }
    }
    private func startStream() async {
        do {
            let filter = try filter()
            guard let path = takeString(still_path(core, false)) else { throw CaptureError.message(coreError()) }
            let url = URL(fileURLWithPath: path)
            outputURL = url
            let outputConfig = SCRecordingOutputConfiguration()
            outputConfig.outputURL = url
            outputConfig.outputFileType = .mp4
            outputConfig.videoCodecType = settings.hevc != 0 ? .hevc : .h264
            let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
            let stream = SCStream(filter: filter, configuration: configuration(for: filter), delegate: self)
            self.stream = stream; recordingOutput = output
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch { await fail(error.localizedDescription) }
    }
    func stop() {
        guard phase == 1 || phase == 3 else { return }
        guard still_stop(core) else { errorMessage = coreError(); return }
        let previousPhase = phase
        let state = still_status(core)
        phase = state.phase
        if previousPhase == 1 { restoreAfterCapture(); return }
        Task {
            do { try await stream?.stopCapture() }
            catch { await fail(error.localizedDescription) }
        }
    }
    func discardRecording() {
        guard phase == 1 || phase == 3 else { return }
        discarding = true
        notice = nil
        stop()
        if phase == 0 { discarding = false; notice = L("capture.discarded") }
    }
    func primaryAction() {
        if phase == 1 || phase == 3 { stop() }
        else if !active { begin() }
    }
    nonisolated func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        Task { @MainActor in
            guard output === self.recordingOutput else { return }
            if !still_started(self.core) { await self.fail(self.coreError()); return }
            self.tick()
        }
    }
    nonisolated func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        Task { @MainActor in
            guard output === self.recordingOutput, !self.handlingFailure else { return }
            let url = self.outputURL
            let discard = self.discarding
            let success = still_finish(self.core)
            self.stream = nil; self.recordingOutput = nil; self.outputURL = nil
            if discard {
                do {
                    if let url, FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    self.notice = L("capture.discarded")
                } catch { self.errorMessage = error.localizedDescription }
            } else if success { self.notice = L("notice.recording") }
            else { self.errorMessage = self.coreError() }
            self.discarding = false
            self.restoreAfterCapture()
            self.refreshLibrary()
            if self.shouldQuit { NSApp.terminate(nil) }
        }
    }
    nonisolated func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            guard output === self.recordingOutput else { return }
            await self.fail(error.localizedDescription)
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard stream === self.stream else { return }
            let nativeError = error as NSError
            if nativeError.domain == SCStreamErrorDomain &&
                (nativeError.code == SCStreamError.Code.userStopped.rawValue || nativeError.code == SCStreamError.Code.systemStoppedStream.rawValue) {
                // The OS can stop sharing from its own menu. The recording
                // output still finalizes normally; let its delegate save it.
                if self.phase == 3 {
                    _ = still_stop(self.core)
                    self.phase = 4
                }
                return
            }
            await self.fail(error.localizedDescription)
        }
    }
    private func fail(_ message: String) async {
        guard !handlingFailure else { return }
        handlingFailure = true
        // Invalidate delegates before awaiting stop; late callbacks must not
        // finalize a different session or erase the original error.
        let oldStream = stream
        stream = nil; recordingOutput = nil
        try? await oldStream?.stopCapture()
        if let url = outputURL, FileManager.default.fileExists(atPath: url.path) {
            if discarding {
                do { try FileManager.default.removeItem(at: url) }
                catch { errorMessage = error.localizedDescription }
            } else {
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("failed"))
            }
        }
        outputURL = nil
        still_reset(core)
        restoreAfterCapture()
        handlingFailure = false
        discarding = false
        shouldQuit = false
        errorMessage = L("error.capture") + "\n\n" + message
    }
    private func restoreAfterCapture() {
        ticker?.cancel()
        ticker = nil
        if let sleepAssertion { ProcessInfo.processInfo.endActivity(sleepAssertion) }
        sleepAssertion = nil
        launching = false
        phase = 0; countdown = 0
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func screenshot() {
        guard canCapture, !active else { return }
        preflighting = true
        notice = nil
        Task {
            defer { preflighting = false }
            do {
                let filter = try filter()
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration(for: filter, screenshot: true))
                guard let path = takeString(still_path(core, true)) else { throw CaptureError.message(coreError()) }
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.message(L("error.png")) }
                try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                notice = L("notice.screenshot")
                refreshLibrary()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func chooseRecordingFolder() {
        guard !active else { return }
        do { try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true) }
        catch { errorMessage = error.localizedDescription; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = mediaDirectory
        panel.message = L("folders.inside")
        panel.prompt = L("common.done")
        if panel.runModal() == .OK, let url = panel.url { setRecordingFolder(url) }
    }
    func setRecordingFolder(_ url: URL) {
        guard !active else { return }
        if url.path.withCString({ still_set_destination(core, $0) }) {
            recordingFolder = takeString(still_destination(core)).map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else { errorMessage = L("folders.inside") + "\n\n" + coreError() }
    }
    func openLibraryFolder(_ url: URL?) {
        libraryFolder = url
        refreshLibrary()
    }
    func createLibraryFolder() {
        let alert = NSAlert()
        alert.messageText = L("folders.new")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = L("folders.name")
        alert.accessoryView = field
        alert.addButton(withTitle: L("folders.create"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            errorMessage = L("folders.name"); return
        }
        do {
            try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: currentLibraryFolder.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: false)
            refreshLibrary()
        } catch { errorMessage = error.localizedDescription }
    }
    func refreshLibrary() {
        folders = ((try? FileManager.default.contentsOfDirectory(at: currentLibraryFolder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []).filter {
            guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard let text = takeString(still_library(core)), let data = text.data(using: .utf8) else {
            errorMessage = coreError(); return
        }
        do { library = try JSONDecoder().decode([MediaItem].self, from: data) }
        catch { errorMessage = L("error.library") + "\n\n" + error.localizedDescription }
    }
    func revealFolder(at folder: URL? = nil) {
        let destination = folder ?? mediaDirectory
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            NSWorkspace.shared.open(destination)
        } catch { errorMessage = error.localizedDescription }
    }
    func open(_ item: MediaItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: MediaItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    func copy(_ item: MediaItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item.url as NSURL])
        notice = L("notice.copied")
    }
    func trash(_ item: MediaItem) {
        guard !exportingMedia else { return }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            if selectedMedia == item { selectedMedia = nil }
            refreshLibrary()
        } catch { errorMessage = error.localizedDescription }
    }
    func requestQuit() -> Bool {
        if exportingMedia {
            errorMessage = L("status.saving")
            NSApp.activate(ignoringOtherApps: true)
            return false
        }
        guard active else { return true }
        if phase == 2 || phase == 4 || preflighting {
            errorMessage = L("error.wait")
            NSApp.activate(ignoringOtherApps: true)
            return false
        }
        let alert = NSAlert()
        alert.messageText = phase == 1 ? L("quit.cancel_title") : L("quit.save_title")
        alert.informativeText = phase == 1 ? L("quit.cancel_detail") : L("quit.save_detail")
        alert.addButton(withTitle: phase == 1 ? L("quit.cancel") : L("quit.save"))
        alert.addButton(withTitle: L("quit.continue"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if phase == 1 { stop(); return true }
        shouldQuit = true; stop(); return false
    }
}

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
