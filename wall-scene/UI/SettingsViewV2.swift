import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The v1 settings screen. Modeled on the macOS System Settings experience (especially the
// Wallpaper settings), laid out as "one inset group per display" using Form + .formStyle(.grouped).
// Every UI action is only a notification through AppActionsV2, such as
// actions?.updateDisplayMode(displayUUID:mode:). This view never applies files or persists
// anything itself (AppControllerV2 in Wave 4 is responsible for that).

struct SettingsViewV2: View {
  @ObservedObject var state: AppStateV2

  var body: some View {
    VStack(spacing: 0) {
      if state.lastError != nil || state.isPowerSaving {
        statusBanner
      }

      Form {
        ForEach(state.displays) { display in
          DisplaySettingsSection(
            display: display,
            mode: state.config.displays[display.displayUUID]?.mode ?? .standard,
            actions: state.actions
          )
        }

        Section {
          Toggle(
            "Pause playback",
            isOn: Binding(
              get: { state.config.isGloballyPaused },
              set: { state.actions?.setGloballyPaused($0) }
            ))
          Toggle(
            "Show a still image to save power",
            isOn: Binding(
              get: { state.config.powerSavingEnabled },
              set: { state.actions?.setPowerSavingEnabled($0) }
            ))
          Toggle(
            "Launch at login",
            isOn: Binding(
              get: { state.config.launchAtLogin },
              set: { state.actions?.setLaunchAtLogin($0) }
            ))
        } footer: {
          Text(
            "On battery power, in Low Power Mode, or when your Mac gets hot, videos pause and a still image (the first frame) is shown instead."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Section {
          Picker(
            "When wallpaper is changed manually",
            selection: Binding(
              get: { state.config.externalChangePolicy },
              set: { state.actions?.setExternalChangePolicy($0) }
            )
          ) {
            Text("Ask").tag(ExternalChangePolicy.ask)
            Text("Always restore").tag(ExternalChangePolicy.alwaysRebeacon)
            Text("Stop managing that space").tag(ExternalChangePolicy.leaveUnmanaged)
          }
          .pickerStyle(.menu)

          ForEach(state.displays) { display in
            let unmanagedCount = state.unmanagedSpaces[display.displayUUID]?.count ?? 0
            if unmanagedCount > 0 {
              LabeledContent("Unmanaged spaces on \(display.name): \(unmanagedCount)") {
                Button("Resume managing") {
                  state.actions?.resetUnmanagedSpaces(displayUUID: display.displayUUID)
                }
              }
            }
          }
        } footer: {
          Text(
            "Controls what happens when the wallpaper of a space managed by Wall Scene is changed manually, for example in System Settings. “Ask” shows a dialog each time asking whether to restore it, and “Stop managing that space” leaves that space’s wallpaper untouched."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
    }
    .frame(minWidth: 560, minHeight: 480)
  }

  // MARK: - Top banners (error / power saving)

  @ViewBuilder
  private var statusBanner: some View {
    VStack(spacing: 8) {
      if let error = state.lastError {
        errorBanner(error)
      }
      if state.isPowerSaving {
        powerSavingRow
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 16)
    .padding(.bottom, 4)
  }

  private func errorBanner(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
      Text(message)
        .font(.callout)
        .foregroundStyle(.red)
      Spacer()
      Button {
        state.lastError = nil
      } label: {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
    }
    .padding(10)
    .background(Color.red.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var powerSavingRow: some View {
    HStack(spacing: 6) {
      Image(systemName: "leaf.fill")
        .foregroundStyle(.secondary)
      Text("Showing a still image to save power")
        .foregroundStyle(.secondary)
    }
    .font(.callout)
  }
}

// MARK: - Opening the Wallpaper settings (used from the folder-mode prerequisite note)

private func openWallpaperSettings() {
  if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"),
    NSWorkspace.shared.open(url)
  {
    return
  }
  NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
}

// MARK: - Per-display section

/// Mode kind (for the Picker's choices). A lightweight kind enum used to temporarily hold
/// DisplayMode's associated values inside the UI. It is reassembled into a DisplayMode on
/// commit (onCommit).
private enum ModeKind: String, CaseIterable, Identifiable {
  case standard
  case single
  case folder

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: return String(localized: "Use macOS default")
    case .single: return String(localized: "Single video or image")
    case .folder: return String(localized: "Folder (random per space)")
    }
  }
}

private struct DisplaySettingsSection: View {
  let display: DisplayInfo
  let mode: DisplayMode
  weak var actions: AppActionsV2?

  @State private var kind: ModeKind = .standard
  @State private var videoPath: String = ""
  @State private var folderPath: String = ""
  @State private var timing: RotationTiming = .interval(minutes: 30)
  @State private var scaling: ScalingMode = .fill

  @State private var showFolderConfirm = false
  @State private var pendingKind: ModeKind?

  // List of videos directly inside the folder (a lightweight enumeration used both for the
  // stacked preview and for the item count)
  @State private var folderVideoPaths: [String] = []
  @State private var isLoadingFolderVideos = false

  var body: some View {
    Section {
      previewRow

      Picker("Mode", selection: kindBinding) {
        ForEach(ModeKind.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .pickerStyle(.menu)

      switch kind {
      case .standard:
        EmptyView()
      case .single:
        singleModeControls
      case .folder:
        folderModeControls
      }
    } header: {
      header
    }
    .task(id: folderPath) { await loadFolderVideos() }
    .onAppear { syncFromMode() }
    .onChange(of: mode) { _, _ in syncFromMode() }
    .alert("Switch to folder mode", isPresented: $showFolderConfirm) {
      Button("Cancel", role: .cancel) {
        pendingKind = nil
        syncFromMode()
      }
      Button("OK") {
        pendingKind = nil
        kind = .folder
        commit()
      }
    } message: {
      Text(
        "The wallpaper of each space on this display will be replaced with a beacon image representing its assigned media (the first frame for videos and GIFs, or the image itself). The original wallpaper settings, including rotation, cannot be restored. Continue?"
      )
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text(display.name)
        .font(.headline)
        .foregroundStyle(.primary)
      if !display.isConnected {
        Text("Not connected")
          .font(.caption2)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Color.gray.opacity(0.2), in: Capsule())
          .foregroundStyle(.secondary)
      }
    }
    .textCase(nil)
  }

  // MARK: - Preview row

  private var previewRow: some View {
    HStack(alignment: .center, spacing: 12) {
      DisplayPreviewView(
        display: display,
        kind: kind,
        videoPath: videoPath,
        folderPath: folderPath,
        folderVideoPaths: folderVideoPaths
      )
      Text(modeDescription)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
  }

  private var modeDescription: String {
    if !display.isConnected {
      return String(localized: "This display is not currently connected")
    }
    switch kind {
    case .standard:
      return String(localized: "The macOS wallpaper settings are used as is")
    case .single:
      return videoPath.isEmpty
        ? String(localized: "Choose a video or image to fill the screen (videos and GIFs loop)")
        : String(localized: "The selected video or image is shown on this display")
    case .folder:
      if folderPath.isEmpty {
        return String(localized: "Choose a folder to show random media in each space")
      }
      return String(
        localized: "Each space randomly shows one of \(folderVideoPaths.count) media items")
    }
  }

  // MARK: - Per-mode controls

  private var singleModeControls: some View {
    Group {
      LabeledContent("Video or image") {
        HStack(spacing: 8) {
          VideoRowThumbnail(path: videoPath)
          Text(
            videoPath.isEmpty
              ? String(localized: "None selected") : (videoPath as NSString).lastPathComponent
          )
          .foregroundStyle(videoPath.isEmpty ? .secondary : .primary)
          .lineLimit(1)
          .truncationMode(.middle)
          Spacer(minLength: 8)
          Button("Choose…") {
            chooseVideoFile()
          }
        }
      }
      scalingPicker
      singleModeNote
    }
  }

  private var folderModeControls: some View {
    Group {
      LabeledContent("Folder") {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(
              folderPath.isEmpty
                ? String(localized: "None selected") : (folderPath as NSString).lastPathComponent
            )
            .foregroundStyle(folderPath.isEmpty ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
            if !folderPath.isEmpty {
              HStack(spacing: 4) {
                if isLoadingFolderVideos {
                  ProgressView()
                    .controlSize(.small)
                } else {
                  Text("\(folderVideoPaths.count) media items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
          Spacer(minLength: 8)
          Button("Choose…") {
            chooseFolder()
          }
        }
      }
      Picker("Rotation interval", selection: timingBinding) {
        Text("Every minute").tag(RotationTiming.interval(minutes: 1))
        Text("Every 5 minutes").tag(RotationTiming.interval(minutes: 5))
        Text("Every 15 minutes").tag(RotationTiming.interval(minutes: 15))
        Text("Every 30 minutes").tag(RotationTiming.interval(minutes: 30))
        Text("Every hour").tag(RotationTiming.interval(minutes: 60))
        Text("Every day").tag(RotationTiming.interval(minutes: 1440))
        Text("On login").tag(RotationTiming.onLogin)
        Text("On wake from sleep").tag(RotationTiming.onWake)
      }
      .pickerStyle(.menu)
      scalingPicker
      if !folderPath.isEmpty {
        reassignNowRow
      }
      folderPrerequisiteNote
    }
  }

  /// The manual "Reassign now" row. It is the only way to apply changes immediately in cases
  /// where the configuration (mode) itself does not change, such as when the folder's contents
  /// were swapped out afterwards. Because the macOS wallpaper API only affects the active space,
  /// "now" actually means "the space you are viewing changes immediately; other spaces change on
  /// your next visit", and the subtitle states that explicitly.
  private var reassignNowRow: some View {
    LabeledContent {
      Button("Reassign now") {
        actions?.reassignNow(displayUUID: display.displayUUID)
      }
    } label: {
      Text("Reassign wallpapers")
      Text(
        "The space you are viewing changes right away; other spaces change when you next visit them. Unmanaged spaces are not affected."
      )
    }
  }

  /// The single-mode note (wallpaper replacement, non-restorable). Shown contextually at the end
  /// of the Section, in the same tone as the folder-mode prerequisite note
  /// (folderPrerequisiteNote).
  private var singleModeNote: some View {
    Label {
      Text(
        "The wallpaper of each space will be replaced with a still image of the selected media (the first frame for videos and GIFs, or the image itself) and cannot be restored."
      )
      .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "info.circle")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.top, 2)
  }

  private var scalingPicker: some View {
    Picker("Scaling", selection: scalingBinding) {
      Text("Fill screen").tag(ScalingMode.fill)
      Text("Fit to screen (letterboxed)").tag(ScalingMode.fit)
    }
    .pickerStyle(.menu)
  }

  /// The folder-mode prerequisite note (successor to the old always-visible DisclosureGroup
  /// "Before using folder mode"). Shown contextually at the end of the Section only while folder
  /// mode is selected.
  private var folderPrerequisiteNote: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text(
          "Turn off “Show on all Spaces” in System Settings > Wallpaper (spaces cannot be told apart while it is on). In folder mode, the wallpaper of each space will be replaced with a beacon image representing its media (the first frame for videos and GIFs, or the image itself) and cannot be restored."
        )
        .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "info.circle")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      Button("Open Wallpaper settings") {
        openWallpaperSettings()
      }
      .font(.caption)
    }
    .padding(.top, 2)
  }

  // MARK: - Bindings

  private var kindBinding: Binding<ModeKind> {
    Binding(
      get: { kind },
      set: { newValue in
        if newValue == .folder && kind != .folder {
          // Show the confirmation alert only when switching to folder mode
          pendingKind = newValue
          showFolderConfirm = true
        } else {
          kind = newValue
          commit()
        }
      }
    )
  }

  private var timingBinding: Binding<RotationTiming> {
    Binding(
      get: { timing },
      set: {
        timing = $0
        commit()
      }
    )
  }

  private var scalingBinding: Binding<ScalingMode> {
    Binding(
      get: { scaling },
      set: {
        scaling = $0
        commit()
      }
    )
  }

  // MARK: - Syncing and committing state

  private func syncFromMode() {
    switch mode {
    case .standard:
      kind = .standard
    case .single(let videoPath, let scaling):
      kind = .single
      self.videoPath = videoPath
      self.scaling = scaling
    case .folder(let folderPath, let timing, let scaling):
      kind = .folder
      self.folderPath = folderPath
      self.timing = timing
      self.scaling = scaling
    }
  }

  private func loadFolderVideos() async {
    guard !folderPath.isEmpty else {
      folderVideoPaths = []
      isLoadingFolderVideos = false
      return
    }
    isLoadingFolderVideos = true
    folderVideoPaths = await ThumbnailProvider.shared.folderMediaList(folderPath: folderPath)
    isLoadingFolderVideos = false
  }

  private func chooseVideoFile() {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.movie, .image]
    if panel.runModal() == .OK, let url = panel.url {
      videoPath = url.path
      commit()
    }
  }

  private func chooseFolder() {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    if panel.runModal() == .OK, let url = panel.url {
      folderPath = url.path
      commit()
    }
  }

  /// Assembles the current UI state into a DisplayMode and notifies it via a single
  /// updateDisplayMode call
  private func commit() {
    let newMode: DisplayMode
    switch kind {
    case .standard:
      newMode = .standard
    case .single:
      newMode = .single(videoPath: videoPath, scaling: scaling)
    case .folder:
      newMode = .folder(folderPath: folderPath, timing: timing, scaling: scaling)
    }
    actions?.updateDisplayMode(displayUUID: display.displayUUID, mode: newMode)
  }
}

// MARK: - Preview display

/// Per-display preview card. Roughly 16:10 at 160pt wide, with a rounded-corner clip and a thin
/// border in the separator color. The content switches with the priority "not connected > mode".
private struct DisplayPreviewView: View {
  let display: DisplayInfo
  let kind: ModeKind
  let videoPath: String
  let folderPath: String
  let folderVideoPaths: [String]

  var body: some View {
    content
      .frame(width: 160, height: 100)
      .background(Color.gray.opacity(0.12))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
      )
  }

  @ViewBuilder
  private var content: some View {
    if !display.isConnected {
      PreviewPlaceholder(systemName: "display")
    } else {
      switch kind {
      case .standard:
        StandardWallpaperThumbnail(displayUUID: display.displayUUID)
      case .single:
        VideoFrameThumbnail(path: videoPath, maxPixel: 360)
      case .folder:
        FolderStackThumbnail(paths: folderVideoPaths)
      }
    }
  }
}

private struct PreviewPlaceholder: View {
  let systemName: String

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: 26))
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Shows the current wallpaper image of macOS standard mode (NSWorkspace.desktopImageURL).
private struct StandardWallpaperThumbnail: View {
  let displayUUID: String
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
      } else {
        PreviewPlaceholder(systemName: "photo")
      }
    }
    .task(id: displayUUID) {
      image = await Self.loadDesktopImage(displayUUID: displayUUID)
    }
  }

  private static func loadDesktopImage(displayUUID: String) async -> NSImage? {
    guard let screen = NSScreen.screen(forStableDisplayUUID: displayUUID),
      let url = NSWorkspace.shared.desktopImageURL(for: screen)
    else {
      return nil
    }
    return NSImage(contentsOf: url)
  }
}

/// General-purpose thumbnail that shows the first frame of a video file. Uses the
/// ThumbnailProvider cache.
private struct VideoFrameThumbnail: View {
  let path: String
  let maxPixel: CGFloat
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
      } else {
        PreviewPlaceholder(systemName: "photo")
      }
    }
    .task(id: path) {
      guard !path.isEmpty else {
        image = nil
        return
      }
      image = await ThumbnailProvider.shared.mediaThumbnail(path: path, maxPixel: maxPixel)
    }
  }
}

/// Folder-mode preview. A simplified layout: a frame from the first video plus an item-count
/// badge in the bottom-right corner (the idea of slightly overlapping multiple frames tends to
/// fall apart visually, so this design was adopted as the requirements allow).
private struct FolderStackThumbnail: View {
  let paths: [String]

  var body: some View {
    if let first = paths.first {
      ZStack(alignment: .bottomTrailing) {
        VideoFrameThumbnail(path: first, maxPixel: 360)
        if paths.count > 1 {
          Text("\(paths.count)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
        }
      }
    } else {
      PreviewPlaceholder(systemName: "photo")
    }
  }
}

/// Small thumbnail placed in the "Video" row (about 40pt tall, corner radius 4).
private struct VideoRowThumbnail: View {
  let path: String

  var body: some View {
    VideoFrameThumbnail(path: path, maxPixel: 160)
      .frame(width: 64, height: 40)
      .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
      )
  }
}
