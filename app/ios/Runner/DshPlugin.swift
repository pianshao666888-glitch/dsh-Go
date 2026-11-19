import AVFoundation
import CoreLocation
import Darwin
import Flutter
import PDFKit
import Photos
import QuickLook
import UIKit
import UserNotifications

// The app's own platform channels on iOS. The Android side of each is under
// android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/. A channel nobody
// registers reaches Dart as MissingPluginException, which already means "not on
// this platform": `dsh/runtime` (no local engine), `dsh/update`, `dsh/phone`,
// `dsh/pet_overlay` and the rest stay that way until there is something to say.

final class DshPlugin: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  private static var instance: DshPlugin?

  private let links: LinksChannel
  private let shortcuts: ShortcutsChannel
  private let shares: ShareChannel
  private let keep: [AnyObject]

  static func register(with registrar: any FlutterPluginRegistrar) {
    let plugin = DshPlugin(registrar: registrar)
    instance = plugin
    registrar.addSceneDelegate(plugin)
  }

  private init(registrar: any FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    links = LinksChannel(messenger: messenger)
    shortcuts = ShortcutsChannel(messenger: messenger)
    shares = ShareChannel(messenger: messenger)
    keep = [
      GuestChannel(messenger: messenger, kernel: NativeGuestKernelAccess.shared, support: Result {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true)
      }),
      AppChannel(messenger: messenger),
      FilesChannel(messenger: messenger),
      MediaChannel(messenger: messenger),
      NotifyChannel(messenger: messenger),
      VoiceChannel(messenger: messenger),
      IOSSpeechChannel(messenger: messenger),
      IOSCompanionWidget(messenger: messenger),
      LauncherIconChannel(messenger: messenger),
      PerformanceChannel(messenger: messenger),
      AdvancedEnvironmentChannel(messenger: messenger),
      SystemShellChannel(messenger: messenger),
      DiagnosticsChannel(messenger: messenger),
      UsageChannel(messenger: messenger),
      LaunchChannel(messenger: messenger),
      StartupChannel(messenger: messenger),
      LaunchClipChannel(messenger: messenger, textures: registrar.textures()),
      NativeFilesChannel(messenger: messenger),
      NativeMediaChannel(messenger: messenger),
      IslandsChannel(registrar: registrar),
      // In a build without the engine, the runtime controller subscribes before it learns
      // there is none, and activating a stream with no handler reports an error to Flutter.
      EngineChannel.isBundled
        ? EngineChannel(messenger: messenger) as AnyObject
        : SilentEvents(name: "dsh/runtime/events", messenger: messenger) as AnyObject,
    ]
    super.init()
  }

  // Optional requirements, called by selector: spelled out, since a Swift name that
  // missed one would compile and simply never be called.
  @objc(scene:willConnectToSession:options:)
  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    connectionOptions?.urlContexts.forEach { open($0.url) }
    if let item = connectionOptions?.shortcutItem { _ = shortcuts.perform(item) }
    return false
  }

  @objc(scene:openURLContexts:)
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    URLContexts.forEach { open($0.url) }
    return !URLContexts.isEmpty
  }

  /// A share left while the app was away; the wake-up address isn't always what brought it back.
  @objc(sceneWillEnterForeground:)
  func sceneWillEnterForeground(_ scene: UIScene) {
    shares.drain()
  }

  @objc(windowScene:performActionForShortcutItem:completionHandler:)
  func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) -> Bool {
    let handled = shortcuts.perform(shortcutItem)
    if handled { completionHandler(true) }
    return handled
  }

  private func open(_ url: URL) {
    if url == ShareInbox.wakeUp {
      shares.drain()
    } else {
      links.open(url)
    }
  }
}

/// An event channel that never sends anything.
private final class SilentEvents: NSObject, FlutterStreamHandler {
  private let channel: FlutterEventChannel

  init(name: String, messenger: any FlutterBinaryMessenger) {
    channel = FlutterEventChannel(name: name, binaryMessenger: messenger)
    super.init()
    channel.setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { nil }

  func onCancel(withArguments arguments: Any?) -> FlutterError? { nil }
}

func arguments(_ call: FlutterMethodCall) -> [String: Any] {
  call.arguments as? [String: Any] ?? [:]
}

func onMain(_ work: @escaping () -> Void) {
  DispatchQueue.main.async(execute: work)
}

// MARK: - dsh/app

private final class AppChannel {
  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/app", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getTimeZoneId": result(TimeZone.current.identifier)
      // iOS doesn't let an app bring itself forward.
      case "bringToFront": result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}

// MARK: - dsh/links

/// Incoming `dshgo://` links and files opened with the app. Files are copied into
/// the cache on one serial queue, so links reach Dart in the order they arrived even
/// when a large file comes before a small one.
private final class LinksChannel {
  private let channel: FlutterMethodChannel
  private let copies = DispatchQueue(label: "dsh.links")
  private var ready = false
  private var held: [[String: String]] = []

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/links", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "ready", let self else { return result(FlutterMethodNotImplemented) }
      self.ready = true
      self.held.forEach { self.channel.invokeMethod("link", arguments: $0) }
      self.held.removeAll()
      result(true)
    }
    // New opened files queue after old cached copies are removed.
    copies.async {
      let manager = FileManager.default
      if let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first {
        try? manager.removeItem(at: caches.appendingPathComponent("links", isDirectory: true))
      }
    }
  }

  func open(_ url: URL) {
    copies.async { [weak self] in
      let link = url.isFileURL ? Self.copied(url) : ["uri": url.absoluteString]
      onMain {
        guard let self else { return }
        if self.ready {
          self.channel.invokeMethod("link", arguments: link)
        } else {
          self.held.append(link)
        }
      }
    }
  }

  /// Keeps the sender's file name in a folder of its own. The access granted for an
  /// opened file ends with this call, so the copy is what Dart gets.
  private static func copied(_ url: URL) -> [String: String] {
    let name = url.lastPathComponent
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let manager = FileManager.default
      let folder = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent("links/\(UUID().uuidString)", isDirectory: true)
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
      let copy = folder.appendingPathComponent(name)
      try manager.copyItem(at: url, to: copy)
      return ["uri": copy.absoluteString]
    } catch {
      return ["error": "unreadable", "name": name]
    }
  }
}

// MARK: - dsh/shortcuts

/// The home screen's quick actions. 新对话 and 语音输入 are declared in Info.plist, the
/// latest conversations are set from Dart, and the system shows four in all.
private final class ShortcutsChannel {
  private static let prefix = "io.github.ccch1mneyyy.dshgo."
  private static let recentShown = 2

  private let channel: FlutterMethodChannel
  private var ready = false
  private var held: [[String: String]] = []

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/shortcuts", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "ready":
        self.ready = true
        self.held.forEach { self.channel.invokeMethod("entry", arguments: $0) }
        self.held.removeAll()
        result(true)
      case "setRecent":
        self.setRecent(arguments(call)["items"] as? [[String: Any]] ?? [])
        result(true)
      default: result(FlutterMethodNotImplemented)
      }
    }
    SystemEntries.attach { [weak self] in self?.send($0) }
  }

  /// False for an item that isn't the app's.
  func perform(_ item: UIApplicationShortcutItem) -> Bool {
    guard let entry = Self.entry(item) else { return false }
    send(entry)
    return true
  }

  private func send(_ entry: [String: String]) {
    if ready {
      channel.invokeMethod("entry", arguments: entry)
    } else {
      held.append(entry)
    }
  }

  private static func entry(_ item: UIApplicationShortcutItem) -> [String: String]? {
    switch item.type {
    case prefix + "new": return ["kind": "new"]
    case prefix + "voice": return ["kind": "voice"]
    case prefix + "chat":
      guard let id = item.userInfo?["sessionId"] as? String else { return nil }
      return ["kind": "chat", "sessionId": id, "host": item.userInfo?["host"] as? String ?? ""]
    default: return nil
    }
  }

  private func setRecent(_ items: [[String: Any]]) {
    UIApplication.shared.shortcutItems = items.prefix(Self.recentShown).compactMap { item -> UIApplicationShortcutItem? in
      guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
      var info: [String: NSSecureCoding] = ["sessionId": id as NSString]
      if let host = item["host"] as? String { info["host"] = host as NSString }
      return UIApplicationShortcutItem(
        type: Self.prefix + "chat",
        localizedTitle: title,
        localizedSubtitle: nil,
        icon: UIApplicationShortcutIcon(systemImageName: "bubble.left"),
        userInfo: info
      )
    }
  }
}

// MARK: - dsh/launcher_icon

/// 桌面图标. The default icon is the primary one and the rest are the asset catalog's
/// alternates (ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES). The system says so with
/// an alert of its own when one changes, and there's no mask to report: Dart's
/// rounded square is close enough to iOS's.
private final class LauncherIconChannel {
  private static let primary = "mist"
  private static let alternates = ["night": "AppIconNight", "frost": "AppIconFrost", "ink": "AppIconInk"]

  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/launcher_icon", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "state": result(Self.reply())
      case "set": Self.set(arguments(call)["id"] as? String, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func reply() -> [String: String] {
    let name = UIApplication.shared.alternateIconName
    return ["current": alternates.first { $0.value == name }?.key ?? primary]
  }

  private static func set(_ id: String?, result: @escaping FlutterResult) {
    let known = id == primary || id.flatMap { alternates[$0] } != nil
    guard known, UIApplication.shared.supportsAlternateIcons else {
      return result(FlutterError(code: "unavailable", message: nil, details: nil))
    }
    UIApplication.shared.setAlternateIconName(id.flatMap { alternates[$0] }) { error in
      onMain {
        if error == nil {
          result(Self.reply())
        } else {
          result(FlutterError(code: "refused", message: nil, details: nil))
        }
      }
    }
  }
}

// MARK: - dsh/files

/// Only the engine's committed, private migration record authorizes old-root aliases.
/// No history text is rewritten, and callers still validate the resolved file.
private enum RelocatedGuestPaths {
  private struct Marker: Decodable {
    let version: Int
    let currentRoot: String
    let previousRoots: [String]
  }

  private static func validRoot(_ path: String) -> Bool {
    guard path.hasPrefix("/"), path != "/", !path.contains("\0") else { return false }
    return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
      .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  static func map(_ path: String, root: String) -> String {
    guard validRoot(root), path.hasPrefix("/"), !path.contains("\0") else { return path }
    if path == root || path.hasPrefix(root + "/") { return path }
    let home = root + "/root/.dsh"
    guard let resolved = realpath(home, nil) else { return path }
    let privateHome = String(cString: resolved)
    free(resolved)
    guard privateHome == home else { return path }
    let fd = open(home + "/ios-container-paths.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return path }
    defer { close(fd) }
    var info = stat()
    let limit = 64 * 1024
    guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      info.st_size > 0, info.st_size <= limit
    else { return path }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { return path }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= limit else { return path }
    }
    guard let marker = try? JSONDecoder().decode(Marker.self, from: data), marker.version == 1,
      validRoot(marker.currentRoot), marker.previousRoots.allSatisfy(validRoot)
    else { return path }
    // A second move can occur before JS updates currentRoot. Both it and the
    // older roots therefore map to the native root of this launch.
    let aliases = ([marker.currentRoot] + marker.previousRoots).sorted { $0.count > $1.count }
    for old in aliases where path == old || path.hasPrefix(old + "/") {
      return root + path.dropFirst(old.count)
    }
    return path
  }
}

/// iOS tool paths are already absolute sandbox paths, not Android guest paths.
/// This is a point-in-time lookup; the Dart caller opens the returned path later.
private struct LocalEngineFiles {
  let guestRoot: URL

  private func canonical(_ path: String) -> String? {
    guard path.hasPrefix("/"), !path.contains("\0"), let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  func resolve(_ path: String) -> String? {
    guard
      let root = canonical(guestRoot.path),
      let file = canonical(RelocatedGuestPaths.map(path, root: root)),
      file.hasPrefix(root + "/"),
      let values = try? FileManager.default.attributesOfItem(atPath: file),
      values[.type] as? FileAttributeType == .typeRegular,
      FileManager.default.isReadableFile(atPath: file)
    else { return nil }
    return file
  }

  /// Same directory advertised by EngineChannel's managed AGENTS.md. Results
  /// carry engine-visible absolute paths and epoch milliseconds, as Dart expects.
  func outputs(depth: Int) -> [[String: Any]] {
    guard let root = canonical(guestRoot.path) else { return [] }
    let expected = root + "/root/workspace/DSH-Go"
    guard canonical(expected) == expected else { return [] }
    let manager = FileManager.default
    let maxDepth = min(max(depth, 1), 8)
    var rows: [[String: Any]] = []
    var visited = 0
    func walk(_ folder: URL, level: Int) {
      guard let entries = try? manager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      else { return }
      for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        // Bound both returned files and work in a directory-heavy tree.
        guard rows.count < 500, visited < 5000 else { return }
        visited += 1
        guard let values = try? manager.attributesOfItem(atPath: entry.path) else { continue }
        let type = values[.type] as? FileAttributeType
        // Never recurse into or publish a symlink from the output scan.
        if type == .typeDirectory {
          if level < maxDepth { walk(entry, level: level + 1) }
        } else if type == .typeRegular, let path = resolve(entry.path),
          path.hasPrefix(expected + "/"),
          let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date
        {
          rows.append(["path": path, "bytes": size.int64Value, "modified": Int64(modified.timeIntervalSince1970 * 1000)])
        }
      }
    }
    walk(URL(fileURLWithPath: expected, isDirectory: true), level: 1)
    return rows
  }
}

/// Opening, saving and previewing the files a turn produced.
private final class FilesChannel: NSObject, QLPreviewControllerDataSource {
  private let channel: FlutterMethodChannel
  private let pdfQueue = DispatchQueue(label: "dsh.pdf")
  private var pdf: (path: String, document: PDFDocument)?
  private var previewing: URL?

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/files", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      let args = arguments(call)
      let path = args["path"] as? String ?? ""
      switch call.method {
      case "resolveGuest":
        self.pdfQueue.async {
          let path = self.localFiles.resolve(path)
          onMain { result(path) }
        }
      case "listOutputs":
        let depth = args["depth"] as? Int ?? 3
        self.pdfQueue.async {
          let rows = self.localFiles.outputs(depth: depth)
          onMain { result(rows) }
        }
      case "open":
        self.open(path: path, name: args["name"] as? String, chooser: args["chooser"] as? Bool ?? false, result: result)
      case "saveToDownloads": self.save(path: path, name: args["name"] as? String, result: result)
      case "pdfInfo": self.pdfInfo(path: path, result: result)
      case "pdfPage":
        self.pdfPage(path: path, page: args["page"] as? Int ?? 0, width: args["width"] as? Int ?? 0, result: result)
      case "pdfClose":
        self.pdfQueue.async {
          self.pdf = nil
          onMain { result(nil) }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Match EngineChannel's application-support root and fallback exactly. Resolve
  /// aliases only when reading, after the engine has prepared its root.
  private var localFiles: LocalEngineFiles {
    let base =
      (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return LocalEngineFiles(guestRoot: base.appendingPathComponent("runtime/rootfs", isDirectory: true))
  }

  // Open

  private func open(path: String, name: String?, chooser: Bool, result: FlutterResult) {
    guard FileManager.default.isReadableFile(atPath: path), let top = topViewController() else {
      return result(FlutterError(code: "missing", message: "no such file", details: nil))
    }
    let url: URL
    do {
      url = try named(URL(fileURLWithPath: path), as: name)
    } catch {
      return result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
    }
    if !chooser && QLPreviewController.canPreview(url as NSURL) {
      previewing = url
      let preview = QLPreviewController()
      preview.dataSource = self
      top.present(preview, animated: true)
    } else {
      let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      if let popover = share.popoverPresentationController {
        popover.sourceView = top.view
        popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
      top.present(share, animated: true)
    }
    result(nil)
  }

  /// The preview and other apps go by the file's extension, and the cache may not
  /// have it under the name the file should show.
  private func named(_ url: URL, as name: String?) throws -> URL {
    guard let name, !name.isEmpty, name != url.lastPathComponent else { return url }
    let manager = FileManager.default
    let folder = manager.temporaryDirectory.appendingPathComponent("open/\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent((name as NSString).lastPathComponent)
    try manager.copyItem(at: url, to: copy)
    return copy
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewing == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
    (previewing ?? URL(fileURLWithPath: "/")) as NSURL
  }

  // Save

  /// Into the app's Documents, which the Files app shows under the app's name
  /// (UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace). No dialog, like the
  /// save on Android; returns where it landed.
  private func save(path: String, name: String?, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let manager = FileManager.default
      guard manager.isReadableFile(atPath: path) else {
        return onMain { result(FlutterError(code: "missing", message: "no such file", details: nil)) }
      }
      do {
        let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let wanted = name?.isEmpty == false ? name! : URL(fileURLWithPath: path).lastPathComponent
        let target = Self.free(in: documents, name: (wanted as NSString).lastPathComponent)
        try manager.copyItem(at: URL(fileURLWithPath: path), to: target)
        onMain { result("DSH Go/\(target.lastPathComponent)") }
      } catch {
        onMain { result(FlutterError(code: "failed", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  /// `report.pdf`, then `report (1).pdf`, the first name not taken.
  private static func free(in folder: URL, name: String) -> URL {
    let manager = FileManager.default
    let plain = folder.appendingPathComponent(name)
    if !manager.fileExists(atPath: plain.path) { return plain }
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var number = 1
    while true {
      let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)")
      if !manager.fileExists(atPath: candidate.path) { return candidate }
      number += 1
    }
  }

  // PDF preview

  private func document(_ path: String) -> PDFDocument? {
    if let pdf, pdf.path == path { return pdf.document }
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
    pdf = (path, document)
    return document
  }

  /// A page's size as it is shown: rotated pages swap width and height.
  private static func size(of page: PDFPage) -> CGSize {
    let box = page.bounds(for: .mediaBox).size
    return page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
  }

  private func pdfInfo(path: String, result: @escaping FlutterResult) {
    pdfQueue.async {
      guard let document = self.document(path) else {
        return onMain { result(FlutterError(code: "missing", message: "no such PDF", details: nil)) }
      }
      let pages: [[String: Int]] = (0..<document.pageCount).compactMap { index in
        guard let page = document.page(at: index) else { return nil }
        let size = Self.size(of: page)
        return ["width": Int(size.width.rounded()), "height": Int(size.height.rounded())]
      }
      onMain { result(pages) }
    }
  }

  private func pdfPage(path: String, page index: Int, width: Int, result: @escaping FlutterResult) {
    pdfQueue.async {
      guard width > 0, let page = self.document(path)?.page(at: index) else {
        return onMain { result(FlutterError(code: "missing", message: "no such page", details: nil)) }
      }
      let size = Self.size(of: page)
      guard size.width > 0, size.height > 0 else {
        return onMain { result(FlutterError(code: "failed", message: "empty page", details: nil)) }
      }
      let scale = CGFloat(width) / size.width
      let target = CGSize(width: CGFloat(width), height: (size.height * scale).rounded())
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let png = UIGraphicsImageRenderer(size: target, format: format).pngData { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: target))
        context.cgContext.translateBy(x: 0, y: target.height)
        context.cgContext.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: context.cgContext)
      }
      onMain { result(FlutterStandardTypedData(bytes: png)) }
    }
  }
}

func topViewController() -> UIViewController? {
  let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
  let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
  var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
  while let presented = top?.presentedViewController { top = presented }
  return top
}

func openAppSettings(_ address: String, result: @escaping FlutterResult) {
  guard let url = URL(string: address) else { return result(false) }
  UIApplication.shared.open(url) { result($0) }
}

// MARK: - dsh/media

private final class MediaChannel {
  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/media", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "saveImage":
        let args = arguments(call)
        guard let bytes = args["bytes"] as? FlutterStandardTypedData, let name = args["name"] as? String else {
          return result(FlutterError(code: "invalid", message: "no image", details: nil))
        }
        Self.save(bytes.data, name: name, result: result)
      case "saveVideoFile":
        let args = arguments(call)
        guard let path = args["path"] as? String, let name = args["name"] as? String,
          let file = Self.videoFile(path, name: name) else {
          return result(FlutterError(code: "invalid", message: "invalid local video", details: nil))
        }
        Self.saveVideo(file, name: name, result: result)
      case "openSettings": openAppSettings(UIApplication.openSettingsURLString, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func videoFile(_ path: String, name: String) -> URL? {
    guard path.hasPrefix("/"), !name.isEmpty, name.utf8.count <= 255,
      name == (name as NSString).lastPathComponent,
      ["mp4", "mov", "m4v"].contains((name as NSString).pathExtension.lowercased()) else { return nil }
    let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(root + "/"),
      ["mp4", "mov", "m4v"].contains(file.pathExtension.lowercased()),
      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
    return file
  }

  private static func saveVideo(_ file: URL, name: String, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        return onMain { result(FlutterError(code: "permission", message: "photos refused", details: nil)) }
      }
      PHPhotoLibrary.shared().performChanges({
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name
        options.shouldMoveFile = false
        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: options)
      }) { saved, error in
        onMain {
          if saved { result("Photos/\(name)") }
          else { result(FlutterError(code: "failed", message: error?.localizedDescription, details: nil)) }
        }
      }
    }
  }

  /// Add-only access: saving doesn't need to read the rest of the library.
  private static func save(_ data: Data, name: String, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        return onMain { result(FlutterError(code: "permission", message: "photos refused", details: nil)) }
      }
      PHPhotoLibrary.shared().performChanges({
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
      }) { saved, error in
        onMain {
          if saved {
            result("Photos/\(name)")
          } else {
            result(FlutterError(code: "failed", message: error?.localizedDescription, details: nil))
          }
        }
      }
    }
  }
}

// MARK: - dsh/notify

/// Notifications posted by the app itself. They only cover what happens while the
/// app is running: once iOS suspends it nothing here runs, and telling the person a
/// turn ended then takes a push from the host.
///
/// Approving from a notification isn't offered: the person opens the conversation and
/// approves there, against what the host says now. Live activities come later.
private final class NotifyChannel {
  private let channel: FlutterMethodChannel
  private let actions: SilentEvents
  private let taps: FlutterEventChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/notify", binaryMessenger: messenger)
    actions = SilentEvents(name: "dsh/notify/actions", messenger: messenger)
    taps = FlutterEventChannel(name: "dsh/notify/taps", binaryMessenger: messenger)
    taps.setStreamHandler(NotifyTaps.shared)
    channel.setMethodCallHandler { call, result in
      Self.handle(call, result: result)
    }
  }

  private static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    let args = arguments(call)
    switch call.method {
    case "status": status(center, result: result)
    case "requestPermission":
      center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        onMain { result(granted) }
      }
    case "show": show(center, args, result: result)
    case "cancel":
      let id = identifier(args)
      center.removeDeliveredNotifications(withIdentifiers: [id])
      center.removePendingNotificationRequests(withIdentifiers: [id])
      result(nil)
    case "cancelGroup":
      let group = args["group"] as? String
      center.getDeliveredNotifications { delivered in
        let ids = delivered.filter { $0.request.content.threadIdentifier == group }.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        onMain { result(nil) }
      }
    case "cancelAll":
      center.removeAllDeliveredNotifications()
      center.removeAllPendingNotificationRequests()
      result(nil)
    case "openSettings", "openLiveSettings": openNotificationSettings(center, result: result)
    case "live", "actionResult": result(nil)
    case "liveStatus": result(["supported": false, "allowed": false])
    default: result(FlutterMethodNotImplemented)
    }
  }

  private static func identifier(_ args: [String: Any]) -> String {
    "\(args["group"] as? String ?? "")|\(args["key"] as? String ?? "")"
  }

  /// Not asked yet reads as off: nothing can post, and first run's dialog is what
  /// [requestPermission] is for.
  private static func status(_ center: UNUserNotificationCenter, result: @escaping FlutterResult) {
    center.getNotificationSettings { settings in
      let status = settings.authorizationStatus
      let on = status != .denied && status != .notDetermined
      onMain { result(["enabled": on, "done": true, "attention": true]) }
    }
  }

  /// Settings has no notifications page for an app that hasn't asked yet, so the
  /// first time this is the question itself.
  private static func openNotificationSettings(
    _ center: UNUserNotificationCenter,
    result: @escaping FlutterResult
  ) {
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus != .notDetermined else {
        return center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
          onMain { result(true) }
        }
      }
      onMain {
        if #available(iOS 16.0, *) {
          openAppSettings(UIApplication.openNotificationSettingsURLString, result: result)
        } else {
          openAppSettings(UIApplication.openSettingsURLString, result: result)
        }
      }
    }
  }

  private static func show(_ center: UNUserNotificationCenter, _ args: [String: Any], result: @escaping FlutterResult) {
    let content = UNMutableNotificationContent()
    content.title = args["title"] as? String ?? ""
    content.body = args["text"] as? String ?? ""
    content.threadIdentifier = args["group"] as? String ?? ""
    content.sound = .default
    content.userInfo = ["sessionId", "host", "kind", "eventId"].reduce(into: [String: String]()) { info, key in
      if let value = args[key] as? String { info[key] = value }
    }
    center.add(UNNotificationRequest(identifier: identifier(args), content: content, trigger: nil)) { error in
      onMain {
        if let error {
          result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
        } else {
          result(nil)
        }
      }
    }
  }
}

/// Set as the notification center's delegate at launch, before there is a Flutter
/// engine, so the tap that launched the app is held until Dart listens.
final class NotifyTaps: NSObject, UNUserNotificationCenterDelegate, FlutterStreamHandler {
  static let shared = NotifyTaps()

  private var sink: FlutterEventSink?
  private var held: [[AnyHashable: Any]] = []

  /// On screen, Dart shows its own banner.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let tap = response.notification.request.content.userInfo
    onMain {
      if let sink = self.sink {
        sink(tap)
      } else {
        self.held.append(tap)
      }
      completionHandler()
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    held.forEach { events($0) }
    held.removeAll()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

// MARK: - 后台保活（静音音频 + 定位）
// 合并在本文件里而不是单独建 .swift：工程用传统 pbxproj 注册文件，
// 新增的源文件必须同时加进 PBXBuildFile / PBXFileReference / group / Sources，
// 只复制文件进目录不会被编译。

// 后台保活 —— iOS 沙盒环境下维持 dsh-go 引擎存活
//
// 两条独立通道，可单独开关：
//   1. audio   ：循环播放极低幅度静音音频。依赖 Info.plist 的 UIBackgroundModes=audio
//                （工程里已有），App 进入后台后不会被立刻挂起。
//   2. location：CLLocationManager 持续定位。需要 UIBackgroundModes 追加 location，
//                且权限为「始终允许」。定位精度调到最低、距离过滤拉大，尽量省电。
//
// 注意：这只是「延缓挂起」，不是真常驻。iOS 仍可能在极端情况下回收进程；
// 做到长期稳定必须越狱 + launchd daemon。


@objc(BackgroundKeepAlive)
final class BackgroundKeepAlive: NSObject {

    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private var locationManager: CLLocationManager?
    private var audioActive = false
    private var locationActive = false

    private override init() { super.init() }

    // MARK: - 音频通道

    /// 生成一段 1 秒的极低幅度正弦波（-60 dBFS），循环播放。
    /// 不用全零 PCM：部分 iOS 版本会把它当作静音流回落到低优先级。
    private func makeNearSilentWAV(seconds: Double = 1.0, sampleRate: Double = 8000) -> Data? {
        let frames = Int(seconds * sampleRate)
        let amplitude: Int16 = 6           // ≈ -62 dBFS，人耳不可闻
        let freq = 220.0
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let v = Int16(Double(amplitude) * sin(2.0 * .pi * freq * t))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append("RIFF".data(using: .ascii)!)
        le32(UInt32(36 + pcm.count))
        wav.append("WAVEfmt ".data(using: .ascii)!)
        le32(16); le16(1); le16(1)             // PCM, mono
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2))
        le16(2); le16(16)
        wav.append("data".data(using: .ascii)!)
        le32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }

    @discardableResult
    func setAudioKeepAlive(_ on: Bool) -> Bool {
        if on == audioActive { return audioActive }
        guard on else {
            player?.stop(); player = nil
            audioActive = false
            try? AVAudioSession.sharedInstance().setActive(false,
                options: [.notifyOthersOnDeactivation])
            return false
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback + .mixWithOthers：不打断别的 App 的音乐，也不被电话打断后彻底停掉
            try session.setCategory(.playback, mode: .default,
                                    options: [.mixWithOthers])
            try session.setActive(true)
            guard let wav = makeNearSilentWAV() else { return false }
            let p = try AVAudioPlayer(data: wav)
            p.numberOfLoops = -1          // 无限循环
            p.volume = 0.0                // 输出音量归零，双保险
            p.prepareToPlay()
            p.play()
            player = p
            audioActive = true
            return true
        } catch {
            NSLog("[dshgo] 音频保活启动失败: \(error)")
            audioActive = false
            return false
        }
    }

    // MARK: - 定位通道

    @discardableResult
    func setLocationKeepAlive(_ on: Bool) -> Bool {
        if on == locationActive { return locationActive }
        guard on else {
            locationManager?.stopUpdatingLocation()
            locationManager = nil
            locationActive = false
            return false
        }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyThreeKilometers   // 最省电
        m.distanceFilter = 3000                                   // 3km 才回调一次
        m.pausesLocationUpdatesAutomatically = false
        m.allowsBackgroundLocationUpdates = true                  // 需要 location background mode
        let status = m.authorizationStatus
        if status == .notDetermined {
            m.requestAlwaysAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            m.startUpdatingLocation()
            locationActive = true
        } else {
            return false
        }
        locationManager = m
        return true
    }

    // MARK: - 状态查询

    func status() -> [String: Any] {
        let s = CLLocationManager().authorizationStatus
        let locAuth: String
        switch s {
        case .authorizedAlways: locAuth = "always"
        case .authorizedWhenInUse: locAuth = "whenInUse"
        case .denied: locAuth = "denied"
        case .restricted: locAuth = "restricted"
        case .notDetermined: locAuth = "notDetermined"
        @unknown default: locAuth = "unknown"
        }
        return [
            "audio": audioActive,
            "location": locationActive,
            "locationAuthorization": locAuth,
        ]
    }
}

extension BackgroundKeepAlive: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 只要回调就算续命成功，不消费坐标
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[dshgo] 定位回调错误: \(error.localizedDescription)")
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
            locationActive = true
        }
    }
}


// Flutter 侧通道：把后台保活开关暴露给 Dart
//
// Dart 端调用：
//   MethodChannel('dshgo/keepalive').invokeMethod('status')
//   ... invokeMethod('setAudio', true)
//   ... invokeMethod('setLocation', true)
//   ... invokeMethod('setAll', {'audio': true, 'location': true})

@objc(KeepAliveChannel)
final class KeepAliveChannel: NSObject, FlutterPlugin {

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dshgo/keepalive",
                                           binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(KeepAliveChannel(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let ka = BackgroundKeepAlive.shared
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "status":
            result(ka.status())
        case "setAudio":
            result(ka.setAudioKeepAlive(args["on"] as? Bool ?? false))
        case "setLocation":
            result(ka.setLocationKeepAlive(args["on"] as? Bool ?? false))
        case "setAll":
            if let audio = args["audio"] as? Bool { _ = ka.setAudioKeepAlive(audio) }
            if let loc = args["location"] as? Bool { _ = ka.setLocationKeepAlive(loc) }
            result(ka.status())
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// MARK: - 高级权限环境探测（越狱 / 巨魔）

// 设置页要回答一个问题：这台设备上有多少「高级权限」？因为读写系统文件、
// 执行 shell 这类能力只在越狱或巨魔（TrollStore）环境下成立。
//
// 判定信号按硬度分三层：
//
//   1) 自身代码签名的 entitlements（platform-application /
//      com.apple.private.security.no-container）。只有被巨魔或越狱工具重签过的
//      App 才可能带这两个 entitlement，拿到就是硬证据。
//   2) 沙盒是否真的被打破：fork(2) / posix_spawn(2) 起 shell、往
//      /private/var/mobile 写文件、读 /etc/hosts。能成功就说明沙盒没了。
//   3) 特征路径、URL scheme、注入的 dylib、环境变量。弱信号，用来补前两层
//      看不出来的情况（例如巨魔装的是别的 App）。
//
// 沙盒的坑（这是本文件里最容易写错的地方）：普通 App 沙盒里，容器外的路径连
// stat 都不给，access(2) 会回 EPERM/EACCES —— 对「不存在」的路径同样如此。
// 所以「被拒」不等于「存在」，两者都只能算「看不见」。代码里把 denied 单独
// 记进 sandboxDeniedPaths 供排查，不拿它当命中依据；命中只认 access(2) == 0。
// 换句话说：App 本身没有 platform-application 时，本文件对宿主机上真实存在的
// 越狱路径基本都会返回「没有」—— 这不是 bug，是沙盒的事实（见 detailLines）。

/// 一次探测得到的「高级权限环境」结论。
///
/// 四类环境互相独立，可能同时命中：例如 rootless 越狱的机器上装了巨魔、
/// 或者 roothide 把 /var/jb 重映射之后同时命中 rootless。
struct AdvancedEnvironment {

    /// 巨魔（TrollStore）：scheme、.TrollStore 标记、重签 entitlements、注入库
    let trollStore: Bool
    /// 有根越狱（rootful）：/usr/bin、/bin/bash、MobileSubstrate、Cydia/Sileo、dpkg
    let rootful: Bool
    /// 无根越狱（rootless）：/var/jb 那一套 + /private/preboot 下的 jb 目录
    let rootless: Bool
    /// 隐根越狱（roothide）：.jbroot-* 目录、JBROOT/_JBROOT 环境变量、libroothide
    let roothide: Bool

    /// 能直接执行的 shell 绝对路径（/var/jb/bin/sh 之类），找不到是 nil
    let shellPath: String?
    /// 能否往 /private/var/mobile 写文件：越狱/巨魔下才可能为 true
    let systemWritable: Bool

    /// fork(2) 成功（沙盒被打穿的旁证；普通安装下必然 false）
    let canFork: Bool
    /// posix_spawn 起了 shell 并正常回收（同上，但更能说明「真能执行」）
    let canSpawnShell: Bool
    /// 能打开并读 /etc/hosts（普通沙盒读不到，越狱后可以）
    let canReadSystemFiles: Bool
    /// dyld 镜像里命中的注入库全路径（Substrate / ElleKit / libhooker / TweakInject / roothide / TrollStore）
    let injectionLibraries: [String]
    /// 被沙盒挡住的探测点：这些「看不到」不代表「不存在」，只用于排查
    let sandboxDeniedPaths: [String]
    /// 探测完成的时间戳（秒），用来判断缓存新旧
    let detectedAt: TimeInterval

    init(
        trollStore: Bool = false,
        rootful: Bool = false,
        rootless: Bool = false,
        roothide: Bool = false,
        shellPath: String? = nil,
        systemWritable: Bool = false,
        canFork: Bool = false,
        canSpawnShell: Bool = false,
        canReadSystemFiles: Bool = false,
        injectionLibraries: [String] = [],
        sandboxDeniedPaths: [String] = [],
        detectedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.trollStore = trollStore
        self.rootful = rootful
        self.rootless = rootless
        self.roothide = roothide
        self.shellPath = shellPath
        self.systemWritable = systemWritable
        self.canFork = canFork
        self.canSpawnShell = canSpawnShell
        self.canReadSystemFiles = canReadSystemFiles
        self.injectionLibraries = injectionLibraries
        self.sandboxDeniedPaths = sandboxDeniedPaths
        self.detectedAt = detectedAt
    }

    /// 四类环境里是否至少命中一个
    var anyDetected: Bool { trollStore || rootful || rootless || roothide }

    /// 设置页直接显示的行：有几类环境就几行，顺序固定为
    /// 巨魔 → rootful → rootless → roothide。一个都没有时给一句人话。
    var summaryLines: [String] {
        var lines: [String] = []
        if trollStore { lines.append("巨魔（TrollStore）") }
        if rootful { lines.append("有根越狱（rootful，/usr/bin）") }
        if rootless { lines.append("无根越狱（rootless，/var/jb）") }
        if roothide { lines.append("隐根越狱（roothide，.jbroot）") }
        if lines.isEmpty {
            lines.append("当前设备未高级权限 · 可能无法使用系统读写")
        }
        return lines
    }

    /// 展开后的明细行（诊断/设置页的「详情」），不做任何美化
    var detailLines: [String] {
        var lines: [String] = []
        lines.append("shell：\(shellPath ?? "未找到可执行 shell")")
        lines.append("系统可写（/private/var/mobile）：\(systemWritable ? "是" : "否")")
        lines.append("可读 /etc/hosts：\(canReadSystemFiles ? "是" : "否")")
        lines.append("fork：\(canFork ? "可用（沙盒已突破）" : "被拒（正常沙盒）")")
        lines.append("posix_spawn：\(canSpawnShell ? "可用" : "不可用")")
        if injectionLibraries.isEmpty {
            lines.append("注入库：无")
        } else {
            lines.append("注入库：\(injectionLibraries.count) 个")
            lines.append(contentsOf: injectionLibraries.map { "· \($0)" })
        }
        if !sandboxDeniedPaths.isEmpty {
            lines.append("被沙盒挡住、无法判断的探测点：\(sandboxDeniedPaths.count) 个")
        }
        return lines
    }

    /// 给 Flutter 通道用的字典（nil 用 NSNull 表示，避免 Dart 侧判空踩坑）
    var dictionary: [String: Any] {
        return [
            "trollStore": trollStore,
            "rootful": rootful,
            "rootless": rootless,
            "roothide": roothide,
            "anyDetected": anyDetected,
            "shellPath": shellPath ?? NSNull(),
            "systemWritable": systemWritable,
            "canFork": canFork,
            "canSpawnShell": canSpawnShell,
            "canReadSystemFiles": canReadSystemFiles,
            "injectionLibraries": injectionLibraries,
            "sandboxDeniedPaths": sandboxDeniedPaths,
            "summaryLines": summaryLines,
            "detailLines": detailLines,
            "detectedAt": detectedAt,
        ]
    }
}

/// 无状态的探测器：所有方法 static，结果做进程内缓存。
///
/// 第一次调用会跑几十次 access(2) + 一次 fork/posix_spawn，别在滚动列表里反复调；
/// 缓存之后返回同一个值，要重算显式调 `detect(forceRefresh: true)`。
final class AdvancedEnvironmentDetector {

    // MARK: - 入口

    /// 唯一的公开入口：拿到（必要时计算）当前设备的高级权限环境。
    static func detect() -> AdvancedEnvironment {
        return detect(forceRefresh: false)
    }

    /// forceRefresh 为 true 时忽略缓存重算（例如用户刚装/卸了 TrollStore，
    /// 或者从设置页点了「重新检测」）。
    @discardableResult
    static func detect(forceRefresh: Bool) -> AdvancedEnvironment {
        if !forceRefresh {
            lock.lock()
            let existing = cached
            lock.unlock()
            if let existing = existing {
                return existing
            }
        }
        // 探测不持锁：里面有一次同步等主线程的 canOpenURL（最多 0.5s），
        // 持锁算会把别的调用者一起堵住。两边都算一遍只是多几十次 syscall，
        // 比卡住 UI 线程便宜。
        let fresh = probeAll()
        lock.lock()
        cached = fresh
        lock.unlock()
        return fresh
    }

    /// 清掉缓存（下次 detect() 重新探测）
    static func invalidateCache() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// 已经算出来的结论（没算过是 nil），给「不想触发探测」的地方看
    static var lastKnown: AdvancedEnvironment? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    // MARK: - 缓存

    private static let lock = NSLock()
    private static var cached: AdvancedEnvironment?

    // MARK: - 路径可见性

    /// access(2) 的三态结果。关键区别在 denied：路径可能真的存在，
    /// 只是这个进程没权限看；沙盒对这种路径和不存在的路径回的是同一个 errno，
    /// 所以 denied 永远不能当成「存在」。
    private enum PathProbe {
        /// access(2) == 0：路径在，且本进程有权限
        case present
        /// EPERM / EACCES：沙盒或权限拦住，存在性未知
        case denied
        /// ENOENT / ENOTDIR / 其它：本进程看到的是「不存在」
        case missing
    }

    /// 用 access(2) 而不是 fileExists：fileExists 把 EPERM 和 ENOENT 都压成 false，
    /// 分不清「沙盒不让看」和「真没有」，而这里必须分开。
    /// mode 传 F_OK 判存在，X_OK 判可执行，W_OK 判可写，R_OK 判可读。
    private static func probePath(_ path: String, mode: Int32 = F_OK) -> PathProbe {
        errno = 0
        if access(path, mode) == 0 {
            return .present
        }
        switch errno {
        case EACCES, EPERM:
            return .denied
        default:
            return .missing
        }
    }

    /// 任意一条路径「确实可见」就算命中；被挡住的路径顺手记进 denied。
    private static func anyVisible(_ paths: [String], denied: inout [String]) -> Bool {
        var hit = false
        for path in paths {
            switch probePath(path) {
            case .present:
                hit = true
            case .denied:
                // 普通沙盒下这里会吃满：容器外一律 EPERM，连不存在的路径也一样。
                // 反过来，带 no-container / platform-application 的 App（巨魔装的）
                // 在这里会直接返回 present 或 missing —— 判定因此是确定的。
                denied.append(path)
            case .missing:
                break
            }
        }
        return hit
    }

    /// 只有「可执行」才算数：/var/jb/bin/sh 存在但没 x 位，是残留目录不是越狱。
    private static func anyExecutable(_ paths: [String]) -> Bool {
        for path in paths where probePath(path, mode: X_OK) == .present {
            return true
        }
        return false
    }

    /// 列目录（沙盒下容器外必然失败，吞掉错误交给调用方）
    private static func directoryNames(_ path: String) -> [String] {
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    /// 目录里有没有指定前缀的条目（roothide 的 .jbroot-<随机后缀> 靠它找）
    private static func hasEntry(_ dir: String, prefix: String) -> Bool {
        let names = directoryNames(dir)
        if names.isEmpty { return false }
        return names.contains { $0.hasPrefix(prefix) }
    }

    // MARK: - dyld 镜像 / 注入库

    // 用 dlsym 取 dyld 符号，而不是直接调 _dyld_image_count：这样不依赖
    // mach-o/dyld.h 在 Swift 里的导出情况，也能容忍符号被隐藏的环境。
    private typealias ImageCountFn = @convention(c) () -> UInt32
    private typealias ImageNameFn = @convention(c) (UInt32) -> UnsafePointer<CChar>?

    /// 从 libSystem 里取出 dyld 的两个枚举函数；拿不到就返回 nil（老系统/异常环境）
    private static func dyldFunctions() -> (count: ImageCountFn, name: ImageNameFn)? {
        guard let handle = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY) else { return nil }
        // 不 dlclose：返回的函数指针会活过这个作用域，留着更安全（libSystem 本来也不会被卸载）。
        guard let countSymbol = dlsym(handle, "_dyld_image_count"),
              let nameSymbol = dlsym(handle, "_dyld_get_image_name") else {
            return nil
        }
        return (unsafeBitCast(countSymbol, to: ImageCountFn.self),
                unsafeBitCast(nameSymbol, to: ImageNameFn.self))
    }

    /// 当前进程加载的全部镜像路径。每次探测现算：dlopen 之后镜像会变，
    /// 缓存住反而会漏掉新注入的库。
    private static func currentImagePaths() -> [String] {
        guard let fns = dyldFunctions() else { return [] }
        var paths: [String] = []
        let total = fns.count()
        for index in 0..<total {
            if let cString = fns.name(index) {
                paths.append(String(cString: cString))
            }
        }
        return paths
    }

    // 注入类关键字：substrate（经典/无根）、ellekit（Dopamine 之后的新一代）、
    // libhooker（odyssey 系）、TweakInject（rootless 的注入点）、
    // libroothide（隐根）、TrollStore（巨魔自己的 dylib）
    private static let injectionMarkers = [
        "substrate", "ellekit", "libhooker", "tweakinject", "libroothide", "roothide", "trollstore",
    ]

    /// 命中的注入库全路径（去重、保持加载顺序）
    private static func injectionHits(in images: [String]) -> [String] {
        var seen = Set<String>()
        var hits: [String] = []
        for image in images {
            let lowered = image.lowercased()
            guard injectionMarkers.contains(where: { lowered.contains($0) }) else { continue }
            guard !seen.contains(image) else { continue }
            seen.insert(image)
            hits.append(image)
        }
        return hits
    }

    // MARK: - 自身 entitlements（巨魔/越狱重签的硬证据）

    // SecTask 的符号用 dlsym 取：这几个函数在 Security.framework 里导出，
    // 但不在公开 SDK 头里，直接链接会在老 Xcode 上炸；dlsym 则一律安全。
    private typealias SecTaskCreateFromSelfFn = @convention(c) (CFAllocator?) -> CFTypeRef?
    private typealias SecTaskCopyValueFn = @convention(c) (CFTypeRef?, CFString?,
                                                          UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

    private static func securityFunctions() -> (create: SecTaskCreateFromSelfFn,
                                                copy: SecTaskCopyValueFn)? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security",
                                  RTLD_LAZY) else { return nil }
        guard let createSymbol = dlsym(handle, "SecTaskCreateFromSelf"),
              let copySymbol = dlsym(handle, "SecTaskCopyValueForEntitlement") else {
            return nil
        }
        return (unsafeBitCast(createSymbol, to: SecTaskCreateFromSelfFn.self),
                unsafeBitCast(copySymbol, to: SecTaskCopyValueFn.self))
    }

    /// 读自身签名里的某个 entitlement 的布尔值；拿不到一律 false
    private static func entitlementIsTrue(_ name: String) -> Bool {
        guard let fns = securityFunctions(), let task = fns.create(nil) else { return false }
        // Swift 里 CF 对象由 ARC 管理，不需要 CFRelease
        guard let value = fns.copy(task, name as CFString, nil) else { return false }
        // Swift 里 CF 对象由 ARC 管理，不需要 CFRelease
        // CFBoolean 到 Swift 会桥成 NSNumber
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text == "true" || text == "1" }
        return false
    }

    // MARK: - 已安装 App 的签名（巨魔装进来的 App 也会带 platform-application）

    /// 读文件尾部若干字节（Mach-O 的 code signature 就在文件末尾）
    private static func fileTail(_ path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    /// 主二进制的 code signature 里是否带 TrollStore 那两个 entitlement。
    /// 不用 SecStaticCodeCopySigningInformation：那是 Security 的 SPI，得多套一层
    /// dlsym ABI；而 entitlements 是以明文 XML 落在 LC_CODE_SIGNATURE 里的，
    /// 直接找字符串更稳（误报率低到可以忽略：正常 App 的二进制里不会出现这串）。
    private static func binaryCarriesPlatformEntitlement(_ executablePath: String) -> Bool {
        guard let tail = fileTail(executablePath, maxBytes: 512 * 1024) else { return false }
        guard let text = String(data: tail, encoding: .isoLatin1) else { return false }
        return text.contains("platform-application")
            && text.contains("com.apple.private.security.no-container")
    }

    /// 抽查已安装 App：容器目录下每个目录里有一个 *.app，看它的主二进制。
    /// 这条路只有在进程本身能看到 /var/containers/Bundle/Application 时才成立
    /// （巨魔/越狱环境）；普通沙盒里列目录直接失败，函数立刻返回 false。
    /// 最多看 12 个，避免首次探测把设置页卡住。
    private static func installedTrollStoreSignedApp() -> Bool {
        let roots = [
            "/private/var/containers/Bundle/Application",
            "/var/containers/Bundle/Application",
        ]
        var checked = 0
        for root in roots {
            let containers = directoryNames(root)
            if containers.isEmpty { continue }
            for container in containers {
                let containerPath = root + "/" + container
                guard let appName = directoryNames(containerPath).first(where: { $0.hasSuffix(".app") })
                else { continue }
                // 主二进制一般就是 <bundle 名去掉 .app>
                let executable = containerPath + "/" + appName + "/" + String(appName.dropLast(4))
                checked += 1
                if binaryCarriesPlatformEntitlement(executable) { return true }
                if checked >= 12 { return false }
            }
        }
        return false
    }

    // MARK: - 进程能力

    /// fork(2)：iOS 沙盒下恒返回 -1/EPERM。能成功就说明沙盒确实没了。
    ///
    /// fork 在 iOS SDK 里被标成 unavailable（Apple 要求用线程或 posix_spawn），
    /// 所以经 dlsym 从 libsystem_c 取符号绕过编译期检查——越狱环境下它确实存在。
    /// 子进程里不碰 Swift 运行时（ARC/栈展开都可能崩），直接 _exit。
    private static func canFork() -> Bool {
        typealias ForkFn = @convention(c) () -> pid_t
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "fork") else { return false }
        let forkPtr = unsafeBitCast(sym, to: ForkFn.self)
        errno = 0
        let pid = forkPtr()
        if pid == 0 {
            _exit(0)
        }
        if pid < 0 {
            return false
        }
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        return true
    }

    /// posix_spawn 一个 shell 跑 `exit 0`：能起来并回收就算「真能执行」。
    /// 沙盒下 posix_spawn 会回 EPERM；shell 不存在回 ENOENT，两种都算 false。
    private static func spawnProbe(shell: String, timeout: TimeInterval = 1.0) -> Bool {
        // posix_spawn 要 NULL 结尾的 C 数组，先自己 strdup，结束后释放。
        // 用循环构造而不是 map：map 推导出的元素类型是隐式解包 Optional，
        // 和这里声明的 [UnsafeMutablePointer<CChar>?] 不一致。
        var argv: [UnsafeMutablePointer<CChar>?] = []
        for piece in [shell, "-c", "exit 0"] {
            argv.append(strdup(piece))
        }
        argv.append(nil)
        defer {
            for pointer in argv {
                if let pointer = pointer { free(pointer) }
            }
        }

        // 子进程的输出丢进 /dev/null：探针不该在 App 的 stdout 上留东西
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, shell, &actions, nil, argv, environ)
        // 显式销毁，不放 defer：defer 里对局部变量取地址不好读，也容易在
        // 以后改动时被提前 return 绕过
        posix_spawn_file_actions_destroy(&actions)
        guard spawned == 0 else { return false }

        // 起来了就算能力成立；等一会儿回收，避免留僵尸进程
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid || reaped < 0 { return true }
            usleep(20000)   // 20ms
        }
        kill(pid, SIGKILL)
        _ = waitpid(pid, &status, 0)
        return true
    }

    /// 往 /private/var/mobile 真写一个文件再删掉。
    /// 普通安装：EACCES/EPERM（沙盒）或 EROFS（根卷只读）；
    /// 巨魔/越狱（no-container）：直接成功。
    private static func canWriteSystemArea() -> Bool {
        let token = ".dshgo-env-probe-\(getpid())-\(UInt32(Date().timeIntervalSince1970))"
        for directory in ["/private/var/mobile", "/var/mobile"] {
            let path = directory + "/" + token
            let fd = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
            if fd >= 0 {
                close(fd)
                unlink(path)
                return true
            }
        }
        return false
    }

    /// 能 open + read 这个路径就算可读（/etc/hosts 在沙盒里是禁读的）
    private static func canReadFile(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        var byte: UInt8 = 0
        let count = read(fd, &byte, 1)
        close(fd)
        return count >= 0
    }

    // MARK: - 环境变量 / URL scheme

    /// 环境变量里出现指定 token（键名或值都看）。
    /// 巨魔和 roothide 都会往被拉起进程的环境里塞标记（_TrollStore / JBROOT）。
    private static func environmentHits(_ token: String) -> Bool {
        let uppercase = token.uppercased()
        for (key, value) in ProcessInfo.processInfo.environment {
            if key.uppercased().contains(uppercase) { return true }
            if value.contains(token) { return true }
        }
        return false
    }

    /// 指定环境变量有非空值
    private static func environmentHasValue(_ name: String) -> Bool {
        guard let raw = getenv(name) else { return false }
        return strlen(raw) > 0
    }

    /// canOpenURL 必须在主线程调；不在主线程就同步等主线程一次（最多 0.5s）。
    /// 注意：Info.plist 的 LSApplicationQueriesSchemes 里没声明的 scheme，
    /// 这里永远返回 false —— 本仓库已在 Info.plist 里补了 apple-magnifier /
    /// trollstore / sileo / cydia。
    private static func canOpenScheme(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        if Thread.isMainThread {
            return UIApplication.shared.canOpenURL(url)
        }
        var opened = false
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            opened = UIApplication.shared.canOpenURL(url)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 0.5)
        return opened
    }

    /// /private/preboot 下有没有越狱用的 jb 目录（rootless 的 /var/jb 是指向这里的符号链接）。
    /// 这里必须扫两层：第一层是 boot manifest 的 UUID 目录，jb 目录在它里面。
    private static func prebootHasJailbreak() -> Bool {
        let roots = ["/private/preboot", "/var/preboot"]
        let tokens = ["jbroot", "dopamine", "procursus", "palera1n", "unc0ver", "jb-"]
        for root in roots {
            let firstLevel = directoryNames(root)
            if firstLevel.isEmpty { continue }
            for name in firstLevel {
                let lowered = name.lowercased()
                if tokens.contains(where: { lowered.contains($0) }) { return true }
            }
            // 再看一层：/private/preboot/<bootUUID>/<某某 jb 目录>
            for name in firstLevel where !name.hasPrefix(".") {
                let inner = directoryNames(root + "/" + name)
                if inner.contains(where: { entry in
                    let lowered = entry.lowercased()
                    return tokens.contains(where: { lowered.contains($0) })
                }) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - 汇总探测

    private static func probeAll() -> AdvancedEnvironment {
        var denied: [String] = []
        let images = currentImagePaths()
        let injected = injectionHits(in: images)

        // ---- 1. 巨魔（TrollStore）----
        // a) 标记文件：TrollStore 会在 Application 容器目录里留 .TrollStore，
        //    自己的偏好 plist 落在 /var/mobile/Library/Preferences 下。
        let trollStoreMarkers = [
            "/var/containers/Bundle/Application/.TrollStore",
            "/private/var/containers/Bundle/Application/.TrollStore",
            "/var/mobile/Library/Preferences/com.opa334.TrollStore.plist",
            "/var/mobile/Library/Preferences/com.opa334.TrollStoreHelper.plist",
        ]
        var trollStore = anyVisible(trollStoreMarkers, denied: &denied)

        // b) 重签 entitlements：TrollStore 用 ldid 签名，必然带
        //    platform-application + com.apple.private.security.no-container。
        //    自身带这两个，说明本 App 就是被巨魔（或越狱工具）装进来的。
        let platformApplication = entitlementIsTrue("platform-application")
        let noContainer = entitlementIsTrue("com.apple.private.security.no-container")
        if platformApplication && noContainer {
            trollStore = true
        }

        // c) URL scheme：TrollStore 劫持了放大镜的 scheme（apple-magnifier://），
        //    装了 TrollStore 就能打开；trollstore:// 是部分版本的别名。
        if canOpenScheme("apple-magnifier://") || canOpenScheme("trollstore://") {
            trollStore = true
        }

        // d) 注入痕迹：巨魔会带 libTrollStore.dylib，环境里也可能带 _TrollStore。
        //    environmentHits 既比键名也比值，"TrollStore" 一个词就覆盖了 _TrollStore。
        if injected.contains(where: { $0.lowercased().contains("trollstore") }) {
            trollStore = true
        }
        if environmentHits("TrollStore") {
            trollStore = true
        }
        // e) 已安装 App 的签名：本机有任何 App 的主二进制里带
        //    platform-application + no-container，就说明这台机器在用巨魔签名
        //    （哪怕本 App 自己是正常安装的）。看不到容器目录时直接跳过。
        if !trollStore && installedTrollStoreSignedApp() {
            trollStore = true
        }

        // ---- 2. 有根越狱（rootful）----
        // 依据：rootful 越狱把东西直接铺在根文件系统上 —— shell、ssh、
        // MobileSubstrate、Cydia/Sileo、dpkg/apt 的状态目录。
        let rootfulPaths = [
            "/bin/bash",
            "/bin/sh",
            "/usr/bin/ssh",
            "/usr/sbin/sshd",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/usr/lib/libsubstrate.dylib",
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/var/lib/dpkg/status",
            "/private/var/lib/apt",
            "/etc/apt",
        ]
        var rootful = anyVisible(rootfulPaths, denied: &denied)
        // 路径在但没 x 位只能算残留，所以 shell 单独再确认可执行
        if !rootful && anyExecutable(["/bin/bash", "/bin/sh", "/usr/bin/ssh"]) {
            rootful = true
        }

        // ---- 3. 无根越狱（rootless）----
        // 依据：rootless 把整棵用户态文件树挪进 /var/jb（通常是指向
        // /private/preboot/<bootUUID>/... 的符号链接），根卷保持只读。
        let rootlessPaths = [
            "/var/jb",
            "/var/jb/usr/bin/ssh",
            "/var/jb/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/var/jb/Applications/Sileo.app",
            "/var/jb/usr/lib/libhooker.dylib",
            "/var/jb/usr/lib/libellekit.dylib",
        ]
        var rootless = anyVisible(rootlessPaths, denied: &denied)
        if !rootless && prebootHasJailbreak() {
            rootless = true
        }

        // ---- 4. 隐根越狱（roothide）----
        // 依据：roothide 把 jailbreak root 藏成 .jbroot-<随机后缀> 目录，
        // 并把真实路径通过 JBROOT 环境变量和 libroothide 的 dyld 钩子传进去。
        var roothide = anyVisible(
            [
                "/var/containers/Bundle/Application/.jbroot",
                "/var/mobile/.jbroot",
                "/private/var/containers/Bundle/Application/.jbroot",
            ],
            denied: &denied
        )
        if !roothide {
            for root in ["/var/containers/Bundle/Application",
                         "/private/var/containers/Bundle/Application",
                         "/var/mobile"] {
                if hasEntry(root, prefix: ".jbroot") {
                    roothide = true
                    break
                }
            }
        }
        if environmentHasValue("JBROOT") || environmentHasValue("_JBROOT") {
            roothide = true
        }
        if injected.contains(where: { $0.lowercased().contains("roothide") }) {
            roothide = true
        }
        // 注意：roothide 会把 /var/jb 重新映射出来，所以隐根机器经常同时命中
        // rootless + roothide。这是真实情况，不要为了「只显示一行」去人为互斥。

        // ---- 能力探测（沙盒破了才有可能成功）----
        let shells = [
            "/var/jb/bin/sh",
            "/var/jb/usr/bin/sh",
            "/bin/sh",
            "/bin/bash",
            "/var/jb/bin/bash",
            "/var/jb/usr/bin/bash",
            "/usr/bin/bash",
        ]
        var shellPath: String? = nil
        for candidate in shells where probePath(candidate, mode: X_OK) == .present {
            shellPath = candidate
            break
        }

        let forked = canFork()
        var spawned = false
        if let shellPath = shellPath {
            spawned = spawnProbe(shell: shellPath)
        }
        let writable = canWriteSystemArea()
        let readable = canReadFile("/etc/hosts") || canReadFile("/private/etc/hosts")

        // 兜底：带 platform-application 的进程本来就跑在沙盒外，
        // 上面某个能力探针偶发失败时（例如 shell 被删），按 entitlements 认定可写。
        let systemWritable = writable || (platformApplication && noContainer)

        // denied 去重后排序，方便设置页里对照排查
        let deniedPaths = Array(Set(denied)).sorted()

        return AdvancedEnvironment(
            trollStore: trollStore,
            rootful: rootful,
            rootless: rootless,
            roothide: roothide,
            shellPath: shellPath,
            systemWritable: systemWritable,
            canFork: forked,
            canSpawnShell: spawned,
            canReadSystemFiles: readable,
            injectionLibraries: injected,
            sandboxDeniedPaths: deniedPaths,
            detectedAt: Date().timeIntervalSince1970
        )
    }
}

// Flutter 侧通道：把探测结果暴露给 Dart 设置页
//
// Dart 端调用：
//   MethodChannel('dshgo/advanced_env').invokeMethod('detect')        → Map
//   ... invokeMethod('summary')                                        → List<String>
//   ... invokeMethod('detail')                                         → List<String>
//   ... invokeMethod('invalidateCache')                                → Map（重算）
// 通道在 DshPlugin 的 keep 列表里注册；没注册的话 Dart 侧拿到的是
// MissingPluginException，等同于「这台设备没有这个能力」。

@objc(AdvancedEnvironmentChannel)
final class AdvancedEnvironmentChannel: NSObject {

    private let methods: FlutterMethodChannel

    init(messenger: any FlutterBinaryMessenger) {
        methods = FlutterMethodChannel(name: "dshgo/advanced_env", binaryMessenger: messenger)
        super.init()
        methods.setMethodCallHandler { call, result in
            switch call.method {
            case "detect":
                // 命中缓存，进设置页不会重复跑 syscall
                result(AdvancedEnvironmentDetector.detect().dictionary)
            case "summary":
                result(AdvancedEnvironmentDetector.detect().summaryLines)
            case "detail":
                result(AdvancedEnvironmentDetector.detect().detailLines)
            case "invalidateCache":
                AdvancedEnvironmentDetector.invalidateCache()
                result(AdvancedEnvironmentDetector.detect().dictionary)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}

// MARK: - 系统终端（越狱 / 巨魔下的 posix_spawn）

/// 在越狱 / 巨魔环境里直接执行设备命令。
///
/// 和 iSH guest 里那个 bash 是两条路：iSH 跑的是 App 沙盒里的 Alpine，看不到
/// iOS 自己的文件系统；这里用的是系统上的真实 shell（rootless 的
/// /var/jb/bin/sh、rootful 的 /bin/sh、巨魔下被重签后的 /usr/bin/sh），
/// 执行结果直接回到 agent。
///
/// 没有高级权限时所有入口返回 nil，Dart 侧据此判定「不可用」。
final class SystemShellChannel: NSObject {

  private let methods: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "dshgo/system_shell", binaryMessenger: messenger)
    super.init()
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  /// 输出上限：超过就保留头尾，中间标注截断。
  private static let maxBytesCap = 512 * 1024

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "shellPath":
      result(SystemShellChannel.shellPath())
    case "exec":
      guard let command = args["command"] as? String else {
        result(FlutterError(code: "bad-args", message: "command is required", details: nil)); return
      }
      let timeout = (args["timeoutMs"] as? NSNumber)?.intValue ?? 30000
      let maxBytes = min((args["maxBytes"] as? NSNumber)?.intValue ?? 256 * 1024, SystemShellChannel.maxBytesCap)
      DispatchQueue.global(qos: .userInitiated).async {
        let out = SystemShellChannel.run(
          command: command,
          cwd: args["cwd"] as? String,
          env: args["env"] as? [String: String],
          timeoutMs: max(timeout, 1000),
          maxBytes: maxBytes)
        DispatchQueue.main.async { result(out) }
      }
    case "readFile":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "bad-args", message: "path is required", details: nil)); return
      }
      let cap = (args["maxBytes"] as? NSNumber)?.intValue ?? 4 * 1024 * 1024
      result(SystemShellChannel.readBytes(path: path, cap: cap))
    case "list":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "bad-args", message: "path is required", details: nil)); return
      }
      result(SystemShellChannel.listDirectory(path: path))
    case "writeFile":
      guard let path = args["path"] as? String, let data = args["bytes"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "bad-args", message: "path and bytes are required", details: nil)); return
      }
      result(SystemShellChannel.writeBytes(path: path, data: data.data))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // ── shell 探测 ────────────────────────────────────────────────────────
  /// 按「越狱形态」的常见优先级找可执行 shell。只有 access(X_OK) 通过才算。
  static func shellPath() -> String? { cachedShell }

  private static let cachedShell: String? = {
    let candidates = [
      "/var/jb/usr/bin/sh",     // rootless / roothide
      "/var/jb/bin/sh",
      "/var/jb/usr/bin/bash",
      "/var/jb/bin/bash",
      "/bin/sh",                // rootful
      "/bin/bash",
      "/usr/bin/sh",
      "/usr/bin/bash",
      "/private/preboot/tmp/sh",
    ]
    for candidate in candidates where access(candidate, X_OK) == 0 {
      return candidate
    }
    // TrollStore 装的 App 有时只能通过 posix_spawn 走系统默认 shell
    return access("/bin/sh", F_OK) == 0 ? "/bin/sh" : nil
  }()

  // ── 执行 ──────────────────────────────────────────────────────────────
  /// 用 posix_spawn 跑 `shell -c command`，stdout/stderr 合并到同一个 pipe。
  ///
  /// 超时先 SIGTERM 再 SIGKILL。输出超上限保留头尾，中间写一段截断标记——
  /// agent 读日志时最需要的是开头（报错）和结尾（结果）。
  static func run(command: String, cwd: String?, env: [String: String]?,
                  timeoutMs: Int, maxBytes: Int) -> [String: Any]? {
    guard let shell = shellPath() else { return nil }

    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { return nil }
    let readFd = fds[0], writeFd = fds[1]

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_adddup2(&fileActions, writeFd, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, writeFd, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&fileActions, readFd)
    posix_spawn_file_actions_addclose(&fileActions, writeFd)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    // 自己的进程组，方便超时时整组杀掉（命令里再起子进程也能一并清理）
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attr, 0)

    var argv: [UnsafeMutablePointer<CChar>?] = []
    for piece in [shell, "-c", command] {
      argv.append(strdup(piece))
    }
    argv.append(nil)
    defer { argv.forEach { if let p = $0 { free(p) } } }

    // 环境：继承当前 + 调用方覆盖。agent 需要 PATH 才能找到常用命令。
    // 变量名不能叫 environ：那是 C 的全局符号，会在 posix_spawn 处被遮蔽。
    var envp: [UnsafeMutablePointer<CChar>?] = []
    var envMap = ProcessInfo.processInfo.environment
    envMap["PATH"] = envMap["PATH"] ?? "/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if let extra = env { for (k, v) in extra { envMap[k] = v } }
    for (k, v) in envMap { envp.append(strdup("\(k)=\(v)")) }
    envp.append(nil)
    defer { envp.forEach { if let p = $0 { free(p) } } }

    var pid: pid_t = 0
    let spawnResult = posix_spawn(&pid, shell, &fileActions, &attr, argv, envp)
    close(writeFd)
    guard spawnResult == 0, pid > 0 else {
      close(readFd)
      return ["exitCode": -1, "stdout": "", "stderr": "posix_spawn failed: \(spawnResult)", "timedOut": false]
    }

    // 读端设非阻塞，配合超时轮询，避免大输出把线程卡死。
    let flags = fcntl(readFd, F_GETFL, 0)
    _ = fcntl(readFd, F_SETFL, flags | O_NONBLOCK)

    var collected = Data()
    var truncated = false
    var timedOut = false
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    func drain() -> Bool {
      while true {
        let n = read(readFd, &buffer, buffer.count)
        if n > 0 {
          if collected.count + n > maxBytes {
            truncated = true
            // 保留前 1/4 和后 3/4，中间的丢掉
            let headKeep = maxBytes / 4
            if collected.count > headKeep {
              collected = collected.prefix(headKeep)
            }
            let remaining = maxBytes - collected.count
            if n <= remaining {
              collected.append(contentsOf: buffer[0..<n])
            } else {
              collected.append(contentsOf: buffer[0..<remaining])
            }
          } else {
            collected.append(contentsOf: buffer[0..<n])
          }
          continue
        }
        if n == 0 { return true }              // EOF
        if errno == EAGAIN || errno == EWOULDBLOCK { return false }
        return true
      }
    }

    var exited = false
    while Date() < deadline {
      if drain() { exited = true; break }
      var status: Int32 = 0
      if waitpid(pid, &status, WNOHANG) == pid { exited = true; _ = drain(); break }
      usleep(20_000)  // 20ms
    }

    if !exited {
      timedOut = true
      kill(-pid, SIGTERM)          // 整组
      usleep(200_000)
      kill(-pid, SIGKILL)
      var status: Int32 = 0
      _ = waitpid(pid, &status, 0)
    }

    // 收尾：EOF 后可能还有残留数据
    _ = drain()
    close(readFd)

    var exitCode: Int32 = 0
    if !timedOut {
      var status: Int32 = 0
      if waitpid(pid, &status, WNOHANG) == pid {
        exitCode = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
      }
    } else {
      exitCode = 124  // 和 timeout(1) 的约定一致
    }

    let text = String(decoding: collected, as: UTF8.self)
    return [
      "exitCode": Int(exitCode),
      "stdout": text,
      "stderr": "",
      "timedOut": timedOut,
      "truncated": truncated,
      "cwd": cwd ?? "",
    ]
  }

  // ── 文件读写 ──────────────────────────────────────────────────────────
  static func readBytes(path: String, cap: Int) -> FlutterStandardTypedData? {
    guard FileManager.default.isReadableFile(atPath: path) else { return nil }
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: min(cap, 32 * 1024 * 1024))
    return FlutterStandardTypedData(bytes: data)
  }

  static func writeBytes(path: String, data: Data) -> Bool {
    do {
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
      return true
    } catch {
      return false
    }
  }

  static func listDirectory(path: String) -> [[String: Any]]? {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: path) else { return nil }
    var out: [[String: Any]] = []
    for name in names.sorted() {
      let full = path.hasSuffix("/") ? path + name : path + "/" + name
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
      var size = 0
      var modified = 0
      if let attrs = try? fm.attributesOfItem(atPath: full) {
        size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if let date = attrs[.modificationDate] as? Date {
          modified = Int(date.timeIntervalSince1970)
        }
      }
      out.append(["name": name, "path": full, "isDirectory": isDir.boolValue,
                  "size": size, "modified": modified])
    }
    return out
  }
}
