import AppKit
import Carbon
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: CaptureModel?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x5354494C, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in delegate.model?.primaryAction() }
            return noErr
        }, 1, [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))], Unmanaged.passUnretained(self).toOpaque(), &handler)
        let registration = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x5354494C, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr || registration != noErr {
            model?.errorMessage = L("error.shortcut")
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.requestQuit() == false ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@main
struct StillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CaptureModel()
    var body: some Scene {
        Window("Still", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 980, height: 740)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button(L("menu.settings")) { model.showPreferences = true; NSApp.activate(ignoringOtherApps: true) }
                    .keyboardShortcut(",")
            }
            CommandMenu(L("nav.capture")) {
                // Carbon owns ⇧⌘R globally. Defining the same SwiftUI key
                // equivalent would invoke two toggles when Still is frontmost.
                Button(model.phase == 3 ? L("menu.stop") + " (⇧⌘R)" : L("capture.record") + " (⇧⌘R)") { model.primaryAction() }
                    .disabled((!model.canCapture && !model.active) || model.phase == 2 || model.phase == 4 || model.preflighting)
                Button(L("menu.screenshot")) { model.screenshot() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canCapture || model.active)
                Divider()
                Button(L("menu.refresh")) { Task { await model.refreshSources() } }.disabled(model.active)
                Button(L("menu.folder")) { model.revealFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra {
            MenuBarContent(model: model)
                .environment(\.locale, model.locale)
                .environment(\.layoutDirection, model.layoutDirection)
        } label: {
            if model.phase == 3 { Label(model.clock, systemImage: "record.circle.fill") }
            else if model.phase == 1 { Label("\(model.countdown)", systemImage: "timer") }
            else { Image(systemName: "record.circle") }
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Still · \(model.statusText)")
        if model.phase == 3 { Text(LF("menu.duration", model.clock)) }
        Divider()
        Button(model.phase == 3 ? L("menu.stop") : model.phase == 1 ? L("menu.cancel") : L("capture.record")) { model.primaryAction() }
            .disabled((!model.canCapture && !model.active) || model.phase == 2 || model.phase == 4 || model.preflighting)
        Button(L("menu.screenshot")) { model.screenshot() }.disabled(!model.canCapture || model.active)
        if model.phase == 1 || model.phase == 3 {
            Button(L("capture.discard"), role: .destructive) { model.discardRecording() }
        }
        Divider()
        Button(L("menu.open")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(L("nav.library")) { model.page = 1; model.refreshLibrary(); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(L("menu.folder")) { model.revealFolder() }
        Divider()
        Button(L("menu.quit")) { NSApp.terminate(nil) }
    }
}

