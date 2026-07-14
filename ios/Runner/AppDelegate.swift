import Flutter
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {
  private var pendingImageResult: FlutterResult?
  private var pendingSaveResult: FlutterResult?
  private var exportUrl: URL?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "bs_font/native",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "pickImages":
        let args = call.arguments as? [String: Any]
        let source = args?["source"] as? String ?? "photo"
        self.pickImages(source: source, result: result)
      case "saveFont":
        self.saveFont(arguments: call.arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }

  private func pickImages(source: String, result: @escaping FlutterResult) {
    guard pendingImageResult == nil else {
      result(FlutterError(code: "busy", message: "正在处理上一次图片选择", details: nil))
      return
    }
    pendingImageResult = result

    if source == "camera", UIImagePickerController.isSourceTypeAvailable(.camera) {
      let picker = UIImagePickerController()
      picker.sourceType = .camera
      picker.mediaTypes = ["public.image"]
      picker.delegate = self
      topViewController()?.present(picker, animated: true)
      return
    }

    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.filter = .images
    config.selectionLimit = 0
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    topViewController()?.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let pending = pendingImageResult else { return }
    if results.isEmpty {
      pendingImageResult = nil
      pending([])
      return
    }

    var output: [[String: String]] = []
    let group = DispatchGroup()
    for (index, item) in results.enumerated() {
      let provider = item.itemProvider
      guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
      group.enter()
      provider.loadObject(ofClass: UIImage.self) { object, _ in
        defer { group.leave() }
        guard let image = object as? UIImage,
              let data = image.pngData() else { return }
        let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        output.append([
          "name": (suggested?.isEmpty == false ? suggested! : "图片_\(index + 1)") + ".png",
          "mime": "image/png",
          "base64": data.base64EncodedString()
        ])
      }
    }

    group.notify(queue: .main) {
      self.pendingImageResult = nil
      pending(output)
    }
  }

  func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
    picker.dismiss(animated: true)
    guard let pending = pendingImageResult else { return }
    pendingImageResult = nil
    guard let image = info[.originalImage] as? UIImage,
          let data = image.pngData() else {
      pending([])
      return
    }
    pending([[
      "name": "拍照导入.png",
      "mime": "image/png",
      "base64": data.base64EncodedString()
    ]])
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    pendingImageResult?([])
    pendingImageResult = nil
  }

  private func saveFont(arguments: Any?, result: @escaping FlutterResult) {
    guard pendingSaveResult == nil else {
      result(FlutterError(code: "busy", message: "正在处理上一次保存", details: nil))
      return
    }
    guard let args = arguments as? [String: Any],
          let filename = args["filename"] as? String,
          let base64 = args["base64"] as? String,
          let data = Data(base64Encoded: base64) else {
      result(FlutterError(code: "bad_args", message: "字体文件数据无效", details: nil))
      return
    }

    let safeName = filename
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      result(FlutterError(code: "write_failed", message: "字体临时文件写入失败", details: error.localizedDescription))
      return
    }

    pendingSaveResult = result
    exportUrl = url
    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    picker.delegate = self
    picker.shouldShowFileExtensions = true
    topViewController()?.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingSaveResult?(nil)
    pendingSaveResult = nil
    exportUrl = nil
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    pendingSaveResult?(true)
    pendingSaveResult = nil
    exportUrl = nil
  }
}
