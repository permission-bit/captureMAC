import AppKit
import AVKit
import ScreenCaptureKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: CaptureModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var advanced = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)
                if model.page == 0 { capturePage } else { libraryPage }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 850, idealWidth: 980, minHeight: 670, idealHeight: 740)
        .tint(CaptureModel.accent)
        .alert("Still", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $model.showPreferences) { preferences }
        .sheet(item: $model.conversionItem) { item in ConversionView(item: item, model: model) }
        .sheet(item: $model.selectedMedia) { item in MediaPreview(item: item, model: model) }
        .onChange(of: model.sourceMode) { _, _ in refreshPreview() }
        .onChange(of: model.selectedDisplay) { _, _ in refreshPreview() }
        .onChange(of: model.selectedWindow) { _, _ in refreshPreview() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !model.active else { return }
            model.refreshLibrary()
            Task { await model.refreshSources() }
        }
        .environment(\.locale, model.locale)
        .environment(\.layoutDirection, model.layoutDirection)
    }
    private func refreshPreview() { Task { await model.updatePreview() } }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(CaptureModel.accent.gradient)
                    Image(systemName: "record.circle").font(.system(size: 23, weight: .medium)).foregroundStyle(.white)
                }.frame(width: 36, height: 36)
                Text("Still").font(.system(size: 25, weight: .semibold, design: .rounded)).tracking(-1)
            }
            .padding(.horizontal, 22).padding(.top, 25).padding(.bottom, 32)
            Text(L("nav.workspace")).font(.system(size: 10, weight: .semibold)).tracking(["ar", "hi"].contains(Localization.identifier) ? 0 : 1.2)
                .foregroundStyle(.tertiary).padding(.horizontal, 24).padding(.bottom, 10)
            navButton(L("nav.capture"), icon: "rectangle.inset.filled.and.person.filled", page: 0)
            navButton(L("nav.library"), icon: "square.stack", page: 1)
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text(L("privacy.tagline")).font(.system(size: 11, weight: .medium))
                Text(L("privacy.local")).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .padding(16)
            Divider().padding(.horizontal, 16)
            Button { model.showPreferences = true } label: {
                Label(L("nav.settings"), systemImage: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }.buttonStyle(.plain)
        }
        .frame(width: 205)
        .background(.ultraThinMaterial)
    }
    private func navButton(_ title: String, icon: String, page: Int) -> some View {
        Button {
            model.page = page
            if page == 1 { model.refreshLibrary() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                Text(title).lineLimit(2).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                Spacer()
                if page == 1 && !model.library.isEmpty {
                    Text("\(model.library.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .foregroundStyle(model.page == page ? CaptureModel.accent : Color.primary.opacity(0.7))
            .background(model.page == page ? CaptureModel.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 4)
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.page == 0 ? L("capture.new") : L("nav.library")).font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                Text(model.page == 0 ? L("capture.subtitle") : L("library.subtitle"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.page == 0 {
                HStack(spacing: 6) {
                    Circle().fill(model.phase == 3 ? .red : model.active || !model.hasPermission ? .orange : .green).frame(width: 6, height: 6)
                    Text(model.phase == 3 ? model.clock : !model.hasPermission ? L("permission.required") : model.statusText).font(.system(size: 11, weight: .medium, design: .monospaced))
                }.padding(.horizontal, 11).padding(.vertical, 7).background(.quaternary.opacity(0.5), in: Capsule())
                .accessibilityLabel(model.statusText)
            } else {
                Button { model.revealFolder(at: model.currentLibraryFolder) } label: { Image(systemName: "folder") }.help(L("folder.open"))
                    .buttonStyle(.borderless)
            }
        }.padding(.horizontal, 28).padding(.vertical, 22)
    }
    private var capturePage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Picker(L("source.label"), selection: $model.sourceMode) {
                            Label(L("source.screen"), systemImage: "display").tag(0)
                            Label(L("source.window"), systemImage: "macwindow").tag(1)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 235)
                            .disabled(model.active)
                        Spacer()
                        Button { Task { await model.refreshSources() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 12))
                        }.buttonStyle(.borderless).help(L("source.refresh"))
                            .disabled(model.active || model.loadingSources || !model.hasPermission)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(L("settings.location")).font(.caption).foregroundStyle(.secondary)
                        Button { model.chooseRecordingFolder() } label: {
                            HStack { Text(model.mediaDirectory.lastPathComponent).lineLimit(1); Image(systemName: "chevron.down").font(.caption2) }
                        }.buttonStyle(.borderless).help(model.mediaDirectory.path).disabled(model.active)
                        Spacer()
                    }
                    sourcePreview
                    if model.hasPermission {
                        HStack {
                            Image(systemName: model.sourceMode == 0 ? "display" : "macwindow").foregroundStyle(.secondary)
                            if model.sourceMode == 0 {
                                Picker(L("source.screen"), selection: $model.selectedDisplay) {
                                    if model.displays.isEmpty { Text(L("source.no_screen")).tag(UInt32(0)) }
                                    ForEach(Array(model.displays.enumerated()), id: \.element.displayID) { index, display in
                                        Text(model.displayName(display, index: index)).tag(display.displayID)
                                    }
                                }.labelsHidden()
                            } else {
                                Picker(L("source.window"), selection: $model.selectedWindow) {
                                    if model.windows.isEmpty { Text(L("source.no_window")).tag(UInt32(0)) }
                                    ForEach(model.windows, id: \.windowID) { window in
                                        Text(model.windowTitle(window)).tag(window.windowID)
                                    }
                                }.labelsHidden()
                            }
                            Spacer(minLength: 0)
                            Text(L("source.hidden")).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }.font(.system(size: 12)).disabled(model.active).padding(.top, -8)
                    }
                    HStack(spacing: 10) {
                        optionTile(L("audio.system"), subtitle: L("audio.system_detail"), icon: "speaker.wave.2", key: \.system_audio)
                        optionTile(L("audio.microphone"), subtitle: L("audio.microphone_detail"), icon: "mic", key: \.microphone)
                        optionTile(L("cursor.label"), subtitle: L("cursor.detail"), icon: "cursorarrow", key: \.cursor)
                    }.disabled(model.active)
                    DisclosureGroup(isExpanded: $advanced) {
                        VStack(spacing: 16) {
                            HStack(spacing: 20) {
                                settingPicker(L("quality.label"), selection: model.binding(\.max_height)) {
                                    Text("1080p").tag(UInt32(1080)); Text("1440p").tag(UInt32(1440))
                                    Text("4K").tag(UInt32(2160)); Text(L("quality.original")).tag(UInt32(0))
                                }
                                settingPicker(L("quality.fps"), selection: model.binding(\.fps)) {
                                    Text("24 fps").tag(UInt32(24)); Text("30 fps").tag(UInt32(30)); Text("60 fps").tag(UInt32(60))
                                }
                                settingPicker(L("countdown.label"), selection: model.binding(\.countdown)) {
                                    Text(L("common.off")).tag(UInt32(0)); Text(LF("duration.seconds", 3)).tag(UInt32(3)); Text(LF("duration.seconds", 5)).tag(UInt32(5)); Text(LF("duration.seconds", 10)).tag(UInt32(10))
                                }
                            }
                            Divider()
                            HStack {
                                Toggle(L("cursor.clicks"), isOn: model.toggle(\.clicks)).toggleStyle(.checkbox)
                                    .help(L("cursor.clicks_help"))
                                Spacer()
                                Toggle(L("capture.hide"), isOn: model.toggle(\.hide_app)).toggleStyle(.checkbox)
                            }.font(.system(size: 11))
                            HStack {
                                Text(L("capture.auto_stop")).font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Picker(L("capture.auto_stop"), selection: model.binding(\.auto_stop_seconds)) {
                                    Text(L("common.never")).tag(UInt32(0)); Text(LF("duration.minutes", 1)).tag(UInt32(60)); Text(LF("duration.minutes", 5)).tag(UInt32(300))
                                    Text(LF("duration.minutes", 15)).tag(UInt32(900)); Text(LF("duration.minutes", 30)).tag(UInt32(1800)); Text(LF("duration.minutes", 60)).tag(UInt32(3600))
                                }.labelsHidden().frame(width: 140)
                            }
                        }.padding(.top, 18).padding(.bottom, 4).disabled(model.active)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "slider.horizontal.3")
                            Text(L("capture.options"))
                            Spacer()
                            if !advanced {
                                Text(LF("capture.summary", model.settings.max_height == 0 ? L("quality.original") : "\(model.settings.max_height)p", Int(model.settings.fps), LF("duration.seconds", Int(model.settings.countdown))))
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }.font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(15).background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.05)))
                }.padding(28)
            }
            Divider().opacity(0.6)
            captureFooter
        }
    }
    private var cardBackground: Color { Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.45 : 0.8) }
    private var sourcePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15).fill(Color(nsColor: .controlBackgroundColor))
            LinearGradient(colors: [CaptureModel.accent.opacity(0.045), Color.cyan.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let preview = model.preview, model.hasPermission {
                ZStack {
                    LinearGradient(colors: [CaptureModel.accent.opacity(0.12), .cyan.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(0.14), radius: 15, y: 6)
                        .padding(24)
                }
                VStack {
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "viewfinder")
                        Text(LF("preview.source", model.sourceTitle)).lineLimit(1)
                    }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule()).padding(.bottom, 10)
                }
            } else {
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(CaptureModel.accent.opacity(0.07)).frame(width: 84, height: 84)
                        Image(systemName: "display")
                            .font(.system(size: 34, weight: .ultraLight)).foregroundStyle(CaptureModel.accent)
                    }
                    Text(model.hasPermission ? L("preview.ready") : L("permission.title"))
                        .font(.system(size: 15, weight: .medium))
                    Text(model.hasPermission ? L("source.choose") : L("permission.detail"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !model.hasPermission {
                        HStack(spacing: 12) {
                            Button(L("permission.allow")) { model.requestPermission() }.buttonStyle(.borderedProminent)
                                .disabled(model.loadingSources)
                            Button(L("permission.settings")) { model.openPrivacy() }.buttonStyle(.link)
                        }.controlSize(.small).padding(.top, 3)
                    } else if model.loadingSources { ProgressView().controlSize(.small) }
                }.padding(20)
            }
            if model.phase == 1 {
                Color.black.opacity(0.35)
                Text("\(model.countdown)").font(.system(size: 72, weight: .light, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(height: 248)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.07)))
        .accessibilityLabel(L("preview.accessibility"))
    }
    private func optionTile(_ title: String, subtitle: String, icon: String, key: WritableKeyPath<StillSettings, UInt32>) -> some View {
        let enabled = model.settings[keyPath: key] != 0
        return Button { model.change(key, enabled ? 0 : 1) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.system(size: 16)).foregroundStyle(enabled ? CaptureModel.accent : .secondary)
                    Spacer()
                    Image(systemName: enabled ? "checkmark.circle.fill" : "circle").font(.system(size: 13))
                        .foregroundStyle(enabled ? CaptureModel.accent : Color.secondary.opacity(0.3))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fixedSize(horizontal: false, vertical: true).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                    Text(subtitle).fixedSize(horizontal: false, vertical: true).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(enabled ? CaptureModel.accent.opacity(0.045) : cardBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(enabled ? CaptureModel.accent.opacity(0.22) : .primary.opacity(0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
            .accessibilityLabel(title).accessibilityValue(enabled ? L("common.on") : L("common.off"))
            .accessibilityAddTraits(enabled ? .isSelected : [])
    }
    private func settingPicker<Options: View>(_ title: String, selection: Binding<UInt32>, @ViewBuilder options: () -> Options) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Picker(title, selection: selection, content: options).labelsHidden()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var captureFooter: some View {
        HStack(spacing: 14) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                Button(L("common.view")) { model.page = 1; model.refreshLibrary() }.buttonStyle(.link).font(.system(size: 11))
            } else {
                Image(systemName: "lock.shield").foregroundStyle(.tertiary)
                Text(model.phase == 3 ? L("capture.stop_hint") : L("privacy.saved"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            Button { model.screenshot() } label: { Image(systemName: "camera").font(.system(size: 16)) }
                .buttonStyle(.bordered).controlSize(.large).help(L("screenshot.shortcut"))
                .disabled(!model.canCapture || model.active)
            Button { model.primaryAction() } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.phase == 3 ? "stop.fill" : model.phase == 1 ? "xmark" : "record.circle")
                    Text(model.phase == 3 ? L("capture.stop") : model.phase == 1 ? L("common.cancel") : model.phase == 4 ? L("status.saving") : model.phase == 2 ? L("status.starting") : L("capture.record"))
                        .fontWeight(.medium)
                }.frame(minWidth: 112).padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .tint(model.phase == 3 ? .red : CaptureModel.accent)
            .disabled((!model.canCapture && !model.active) || model.preflighting || model.phase == 2 || model.phase == 4)
            .help(L("capture.shortcut"))
        }.padding(.horizontal, 28).padding(.vertical, 18)
    }
    private var libraryPage: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.openLibraryFolder(nil) } label: { Image(systemName: "house") }.help(L("nav.library"))
                if model.libraryFolder != nil {
                    Button { model.openLibraryFolder(model.currentLibraryFolder.deletingLastPathComponent() == model.libraryRoot ? nil : model.currentLibraryFolder.deletingLastPathComponent()) } label: { Image(systemName: "chevron.backward") }
                }
                Text(model.currentLibraryFolder.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).help(model.currentLibraryFolder.path)
                Spacer()
                Button { model.setRecordingFolder(model.currentLibraryFolder) } label: { Image(systemName: "square.and.arrow.down") }.help(L("folders.use")).disabled(model.active)
                Button { model.createLibraryFolder() } label: { Label(L("folders.new"), systemImage: "folder.badge.plus") }
            }.buttonStyle(.borderless).padding(.horizontal, 24).padding(.top, 16)
            HStack {
                Picker(L("library.type"), selection: $model.libraryFilter) {
                    Text(L("library.all")).tag(0); Text(L("library.videos")).tag(1); Text(L("library.screenshots")).tag(2)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 245)
                Spacer()
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("library.search"), text: $model.search).textFieldStyle(.plain)
                }.font(.system(size: 12)).padding(8).frame(width: 170)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
            }.padding(24)
            if model.folderItems.isEmpty && model.folders.isEmpty {
                Spacer()
                ContentUnavailableView {
                    Label(model.library.isEmpty ? L("library.empty") : L("library.no_results"), systemImage: "square.stack.3d.up")
                } description: {
                    Text(model.library.isEmpty ? L("library.empty_detail") : L("library.search_detail"))
                } actions: {
                    if model.library.isEmpty { Button(L("library.first")) { model.page = 0 }.buttonStyle(.borderedProminent) }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 20) {
                        ForEach(model.folders, id: \.path) { folder in
                            Button { model.openLibraryFolder(folder) } label: {
                                Label(folder.lastPathComponent, systemImage: "folder.fill")
                                    .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(18)
                                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                        ForEach(model.folderItems) { item in
                            MediaCard(item: item, model: model)
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
            Divider()
            HStack {
                Text(LF("library.count", model.folderItems.count, ByteCountFormatter.string(fromByteCount: Int64(clamping: model.folderItems.reduce(UInt64(0)) { $0 &+ $1.bytes }), countStyle: .file)))
                Spacer()
                Button(L("folder.finder")) { model.revealFolder(at: model.currentLibraryFolder) }.buttonStyle(.link)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(20)
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(L("nav.settings")).font(.system(size: 20, weight: .semibold))
                Spacer()
                Button { model.showPreferences = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.title2) }.buttonStyle(.plain).help(L("common.close"))
            }
            Form {
                Section(L("language.label")) {
                    Picker(L("language.label"), selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                        Text(L("language.system")).tag("system")
                        ForEach(Localization.languages) { language in
                            Text(verbatim: language.name).tag(language.id)
                        }
                    }.disabled(model.active)
                    Text(L("language.detail")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section(L("settings.files")) {
                    LabeledContent(L("settings.location")) {
                        Button(model.mediaDirectory.path) { model.chooseRecordingFolder() }.disabled(model.active).buttonStyle(.link)
                    }
                    Toggle(L("settings.hevc"), isOn: model.toggle(\.hevc)).disabled(model.active)
                    Text(L("settings.codec_detail"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section(L("settings.keyboard")) {
                    LabeledContent(L("settings.record_stop"), value: L("settings.global_shortcut"))
                    LabeledContent(L("settings.screenshot"), value: L("settings.local_shortcut"))
                    LabeledContent(L("nav.settings"), value: "⌘,")
                }
                Section(L("settings.privacy")) {
                    Text(L("settings.privacy_detail"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(L("settings.manage_access")) { model.openPrivacy() }
                }
            }.formStyle(.grouped)
            HStack {
                Text("Still 0.1").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button(L("common.done")) { model.showPreferences = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 600, height: 680)
    }
}

struct MediaCard: View {
    let item: MediaItem
    @ObservedObject var model: CaptureModel
    @State private var thumbnail: NSImage?
    var body: some View {
        Button { model.selectedMedia = item } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4))
                    if let thumbnail { Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10)) }
                    else { Image(systemName: item.kind == "video" ? "play.rectangle" : "photo").font(.largeTitle).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    Image(systemName: item.kind == "video" ? "play.fill" : "photo").font(.system(size: 10))
                        .padding(8).background(.regularMaterial, in: Circle()).padding(9)
                }.frame(height: 145).clipped()
                Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                HStack {
                    Text(item.url.pathExtension.uppercased())
                    Text("·")
                    Text(item.size)
                    Spacer()
                    Image(systemName: "ellipsis")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(12).background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.05)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .contextMenu {
            Button(L("preview.label"), systemImage: "eye") { model.selectedMedia = item }
            Button(L("export.title"), systemImage: "arrow.triangle.2.circlepath") { model.conversionItem = item }
            Button(L("common.open"), systemImage: "arrow.up.forward.app") { model.open(item) }
            ShareLink(item: item.url) { Label(L("common.share"), systemImage: "square.and.arrow.up") }
            Button(L("file.copy"), systemImage: "doc.on.doc") { model.copy(item) }
            Button(L("file.reveal"), systemImage: "folder") { model.reveal(item) }
            Divider()
            Button(L("file.trash"), systemImage: "trash", role: .destructive) { model.trash(item) }
        }
        .task(id: item.id) {
            if item.kind == "image" {
                let url = item.url
                // Downsample rather than retaining each full-resolution screenshot.
                thumbnail = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 700,
                            kCGImageSourceCreateThumbnailWithTransform: true
                          ] as CFDictionary) else { return nil as NSImage? }
                    return NSImage(cgImage: image, size: .zero)
                }.value
            } else {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 700, height: 400)
                if let result = try? await generator.image(at: .zero) {
                    thumbnail = NSImage(cgImage: result.image, size: .zero)
                }
            }
        }
    }
}

struct MediaPreview: View {
    let item: MediaItem
    @ObservedObject var model: CaptureModel
    @State private var player: AVPlayer?
    @State private var showConversion = false
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(item.title).font(.headline)
                Spacer()
                Button { model.selectedMedia = nil } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
            if item.kind == "video" { VideoPlayer(player: player).frame(height: 360).clipShape(RoundedRectangle(cornerRadius: 10)) }
            else if item.url.pathExtension.lowercased() == "gif" {
                AnimatedImagePreview(url: item.url).frame(height: 360)
            }
            else if let image = NSImage(contentsOf: item.url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: 360)
            }
            HStack {
                Text(item.size).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("export.title")) { showConversion = true }
                ShareLink(item: item.url) { Label(L("common.share"), systemImage: "square.and.arrow.up") }
                Button(L("file.reveal")) { model.reveal(item) }
                Button(L("common.open")) { model.open(item) }.buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(width: 690)
        .sheet(isPresented: $showConversion) { ConversionView(item: item, model: model) }
        .onAppear { if item.kind == "video" { player = AVPlayer(url: item.url) } }
        .onDisappear { player?.pause(); player = nil }
    }
}

struct AnimatedImagePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        if view.identifier?.rawValue != url.path {
            view.identifier = NSUserInterfaceItemIdentifier(url.path)
            view.image = NSImage(contentsOf: url)
        }
    }
}
