import Flutter
import CoreText
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
  private var pendingImageResult: FlutterResult?
  private var imageRequestToken: UUID?
  private weak var activeImagePicker: UIViewController?
  private var pendingFontResult: FlutterResult?
  private var pendingSaveResult: FlutterResult?
  private var exportUrl: URL?
  private let fontProcessingQueue = DispatchQueue(label: "icu.uxgzs.tool.font-processing", qos: .userInitiated)

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
      case "pickFont":
        self.pickFont(result: result)
      case "pickConfig":
        self.pickDocument(types: [UTType.json], result: result)
      case "pickZip":
        self.pickDocument(types: [UTType.zip], result: result)
      case "saveFont":
        self.saveFont(arguments: call.arguments, result: result)
      case "processFont":
        self.processFont(arguments: call.arguments, result: result)
      case "renameFont":
        self.renameFont(arguments: call.arguments, result: result)
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
    if pendingImageResult != nil {
      let active = activeImagePicker
      cancelImageRequest()
      if active?.presentingViewController != nil {
        active?.dismiss(animated: true)
        result([])
        return
      }
    }
    guard let presenter = topViewController() else {
      result(FlutterError(code: "unavailable", message: "暂时无法打开图片选择器，请稍后重试", details: nil))
      return
    }
    let token = UUID()
    pendingImageResult = result
    imageRequestToken = token

    if source == "camera", UIImagePickerController.isSourceTypeAvailable(.camera) {
      let picker = UIImagePickerController()
      picker.sourceType = .camera
      picker.mediaTypes = ["public.image"]
      picker.delegate = self
      activeImagePicker = picker
      presenter.present(picker, animated: true) { [weak self, weak picker] in
        guard picker?.presentingViewController == nil else { return }
        self?.finishImageRequest(token: token, value: FlutterError(code: "unavailable", message: "相机打开失败，请稍后重试", details: nil))
      }
      return
    }

    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.filter = .images
    config.selectionLimit = 1
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    picker.presentationController?.delegate = self
    activeImagePicker = picker
    presenter.present(picker, animated: true) { [weak self, weak picker] in
      guard picker?.presentingViewController == nil else { return }
      self?.finishImageRequest(token: token, value: FlutterError(code: "unavailable", message: "相册打开失败，请稍后重试", details: nil))
    }
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    guard picker === activeImagePicker, let token = imageRequestToken else {
      picker.dismiss(animated: true)
      return
    }
    activeImagePicker = nil
    picker.dismiss(animated: true)
    if results.isEmpty {
      finishImageRequest(token: token, value: [])
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
      self.finishImageRequest(token: token, value: output)
    }
  }

  func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
    guard picker === activeImagePicker, let token = imageRequestToken else {
      picker.dismiss(animated: true)
      return
    }
    activeImagePicker = nil
    picker.dismiss(animated: true)
    guard let image = info[.originalImage] as? UIImage,
          let data = image.pngData() else {
      finishImageRequest(token: token, value: [])
      return
    }
    finishImageRequest(token: token, value: [[
      "name": "拍照导入.png",
      "mime": "image/png",
      "base64": data.base64EncodedString()
    ]])
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    let token = imageRequestToken
    activeImagePicker = nil
    picker.dismiss(animated: true)
    if let token { finishImageRequest(token: token, value: []) }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    activeImagePicker = nil
    if let token = imageRequestToken {
      finishImageRequest(token: token, value: [])
    }
  }

  private func finishImageRequest(token: UUID, value: Any?) {
    guard imageRequestToken == token, let pending = pendingImageResult else { return }
    pendingImageResult = nil
    imageRequestToken = nil
    activeImagePicker = nil
    pending(value)
  }

  private func cancelImageRequest() {
    let pending = pendingImageResult
    pendingImageResult = nil
    imageRequestToken = nil
    activeImagePicker = nil
    pending?([])
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

  private func pickFont(result: @escaping FlutterResult) {
    pickDocument(types: [UTType.font], result: result)
  }

  private func pickDocument(types: [UTType], result: @escaping FlutterResult) {
    guard pendingFontResult == nil else {
      result(FlutterError(code: "busy", message: "正在处理上一次字体选择", details: nil))
      return
    }
    pendingFontResult = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    topViewController()?.present(picker, animated: true)
  }

  private func processFont(arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let base64 = args["base64"] as? String,
          let data = Data(base64Encoded: base64) else {
      result(FlutterError(code: "bad_args", message: "字体数据无效", details: nil))
      return
    }
      let characterAdjustments = (args["characterAdjustments"] as? [String: Any])?.reduce(into: [String: NativeGlyphAdjustment]()) { result, entry in
        guard let values = entry.value as? [String: Any] else { return }
        result[entry.key] = NativeGlyphAdjustment(
          size: (values["size"] as? NSNumber)?.doubleValue ?? 0,
          spacing: (values["spacing"] as? NSNumber)?.doubleValue ?? 0,
          x: (values["x"] as? NSNumber)?.doubleValue ?? 0,
          y: (values["y"] as? NSNumber)?.doubleValue ?? 0
        )
      } ?? [:]
      let replacements = (args["replacements"] as? [String: String])?.reduce(into: [String: Data]()) { result, entry in
        if let data = Data(base64Encoded: entry.value) { result[entry.key] = data }
      } ?? [:]
      let replacementTransforms = (args["replacementTransforms"] as? [String: Any])?.reduce(into: [String: NativeReplacementTransform]()) { result, entry in
        guard let values = entry.value as? [String: Any] else { return }
        result[entry.key] = NativeReplacementTransform(
          scale: max(0.001, (values["scale"] as? NSNumber)?.doubleValue ?? 1),
          x: (values["x"] as? NSNumber)?.doubleValue ?? 0,
          y: (values["y"] as? NSNumber)?.doubleValue ?? 0
        )
      } ?? [:]
      let characterColors = args["characterColors"] as? [String: String] ?? [:]
      let randomColors = args["randomColors"] as? [String] ?? []
      let params = NativeFontAdjustParams(
        size: args["size"] as? Double ?? 0,
        weight: args["weight"] as? Double ?? 0,
        letter: args["letter"] as? Double ?? 0,
        line: args["line"] as? Double ?? 0,
        rise: args["rise"] as? Double ?? 0,
        targetAll: args["targetAll"] as? Bool ?? true,
        chars: args["chars"] as? String ?? "",
        characterAdjustments: characterAdjustments,
        replacements: replacements,
        replacementTransforms: replacementTransforms,
        globalColor: args["globalColor"] as? String,
        characterColors: characterColors,
        randomColors: randomColors
      )
    fontProcessingQueue.async {
      do {
        let processed = try NativeOutlineFontProcessor.adjust(data: data, params: params)
        let payload = ["base64": processed.base64EncodedString()]
        DispatchQueue.main.async { result(payload) }
      } catch {
        let flutterError = FlutterError(code: "process_failed", message: error.localizedDescription, details: nil)
        DispatchQueue.main.async { result(flutterError) }
      }
    }
  }

  private func renameFont(arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let encoded = args["base64"] as? String,
          let data = Data(base64Encoded: encoded),
          let family = args["family"] as? String,
          !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      result(FlutterError(code: "bad_args", message: "字体名称不能为空", details: nil))
      return
    }
    let subfamily = args["subfamily"] as? String ?? "Regular"
    let fullName = args["fullName"] as? String ?? "\(family) \(subfamily)"
    let postScript = args["postScript"] as? String ?? "\(family)-\(subfamily)"
    fontProcessingQueue.async {
      do {
        let output = try NativeNameFontProcessor.apply(
          data: data,
          family: family,
          subfamily: subfamily,
          fullName: fullName,
          postScript: postScript
        )
        DispatchQueue.main.async { result(["base64": output.base64EncodedString()]) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "rename_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingFontResult?(nil)
    pendingFontResult = nil
    pendingSaveResult?(nil)
    pendingSaveResult = nil
    exportUrl = nil
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    if pendingFontResult != nil {
      guard let url = urls.first else {
        pendingFontResult?(nil)
        pendingFontResult = nil
        return
      }
      do {
        let data = try Data(contentsOf: url)
        pendingFontResult?(["name": url.lastPathComponent, "base64": data.base64EncodedString()])
      } catch {
        pendingFontResult?(FlutterError(code: "read_failed", message: error.localizedDescription, details: nil))
      }
      pendingFontResult = nil
      return
    }
    pendingSaveResult?(true)
    pendingSaveResult = nil
    exportUrl = nil
  }
}

private struct NativeGlyphAdjustment {
  let size: Double
  let spacing: Double
  let x: Double
  let y: Double
}

private struct NativeReplacementTransform {
  let scale: Double
  let x: Double
  let y: Double

  static let identity = NativeReplacementTransform(scale: 1, x: 0, y: 0)
}

private struct NativeFontAdjustParams {
  let size: Double
  let weight: Double
  let letter: Double
  let line: Double
  let rise: Double
  let targetAll: Bool
  let chars: String
  let characterAdjustments: [String: NativeGlyphAdjustment]
  let replacements: [String: Data]
  let replacementTransforms: [String: NativeReplacementTransform]
  let globalColor: String?
  let characterColors: [String: String]
  let randomColors: [String]
}

private enum NativeFontError: LocalizedError {
  case unsupportedFont
  case malformedFont

  var errorDescription: String? {
    switch self {
    case .unsupportedFont:
      return "当前原生引擎暂只支持 TTF glyf 字体，OTF/CFF 字体会保持原样"
    case .malformedFont:
      return "字体文件结构异常"
    }
  }
}

private struct FontTable {
  let tag: String
  var checksum: UInt32
  var data: Data
}

private final class NativeTTFProcessor {
  static func adjust(
    data: Data,
    params: NativeFontAdjustParams,
    selectedGlyphs: Set<Int>? = nil,
    glyphAdjustments: [Int: NativeGlyphAdjustment] = [:],
    replacementGlyphs: [Int: [[OutlinePoint]]] = [:]
  ) throws -> Data {
    var tables = try NativeTTFProcessor.readTables(data)
    guard let head = tables["head"], let maxp = tables["maxp"], let loca = tables["loca"], let glyf = tables["glyf"] else {
      throw NativeFontError.unsupportedFont
    }

    let upm = max(1, Int(readUInt16(head.data, 18)))
    let scale = max(0.01, 1.0 + params.size / 100.0)
    let riseUnits = Int(round((params.rise / 100.0) * Double(upm)))
    let spacingUnits = Int(round((params.letter / 100.0) * Double(upm)))
    let hhea = tables["hhea"]?.data
    let globalYMid = hhea.map { Double(Int(readInt16($0, 4)) + Int(readInt16($0, 6))) * 0.5 } ?? 0

    var averageBolden = 0.0
    let hasIndividualTransforms = glyphAdjustments.values.contains { abs($0.size) > 0.001 || abs($0.x) > 0.001 || abs($0.y) > 0.001 }
    if abs(scale - 1.0) > 0.001 || riseUnits != 0 || abs(params.weight) > 0.001 || hasIndividualTransforms || !replacementGlyphs.isEmpty {
      let patched = patchGlyf(head: head.data, maxp: maxp.data, loca: loca.data, glyf: glyf.data, scale: scale, riseUnits: riseUnits, weightPercent: params.weight, globalYMid: globalYMid, selectedGlyphs: selectedGlyphs, glyphAdjustments: glyphAdjustments, replacementGlyphs: replacementGlyphs, upm: upm)
      if let patched {
        tables["glyf"]?.data = patched.glyf
        tables["loca"]?.data = patched.loca
        tables["head"]?.data = patched.head
        var patchedMaxp = maxp.data
        if patchedMaxp.count >= 10 {
          writeUInt16(&patchedMaxp, 6, UInt16(min(65535, patched.maxPoints)))
          writeUInt16(&patchedMaxp, 8, UInt16(min(65535, patched.maxContours)))
          tables["maxp"]?.data = patchedMaxp
        }
        averageBolden = patched.averageBolden
      }
    }

    if spacingUnits != 0 || abs(scale - 1.0) > 0.001 || abs(averageBolden) > 0.001 || !glyphAdjustments.isEmpty || !replacementGlyphs.isEmpty,
       let hmtx = tables["hmtx"], let hhea = tables["hhea"] {
      let patchedHmtx = patchHmtx(hmtx: hmtx.data, hhea: hhea.data, scale: scale, spacingUnits: spacingUnits, boldenUnits: averageBolden, selectedGlyphs: selectedGlyphs, glyphAdjustments: glyphAdjustments, replacementGlyphs: replacementGlyphs, upm: upm)
      tables["hmtx"]?.data = patchedHmtx
      tables["hhea"]?.data = patchHheaHorizontalMetrics(
        hhea: hhea.data,
        hmtx: patchedHmtx,
        replacementGlyphs: replacementGlyphs
      )
    }

    if abs(params.line) > 0.01 {
      if let hhea = tables["hhea"] {
        tables["hhea"]?.data = patchHhea(hhea.data, lineHeightPercent: params.line)
      }
      if let vhea = tables["vhea"] {
        tables["vhea"]?.data = patchHhea(vhea.data, lineHeightPercent: params.line)
      }
    }

    if let os2 = tables["OS/2"] {
      var patched = os2.data
      if abs(params.weight) > 0.01 {
        patched = patchWeightClass(patched, weightPercent: params.weight)
      }
      if abs(params.line) > 0.01 {
        patched = patchOS2(patched, lineHeightPercent: params.line)
      }
      if let bounds = replacementVerticalBounds(replacementGlyphs) {
        patched = patchOS2VerticalBounds(
          patched,
          minY: bounds.minY,
          maxY: bounds.maxY,
          padding: max(8, upm / 64)
        )
      }
      tables["OS/2"]?.data = patched
    }

    if let bounds = replacementVerticalBounds(replacementGlyphs),
       let hhea = tables["hhea"] {
      tables["hhea"]?.data = patchHheaVerticalBounds(
        hhea.data,
        minY: bounds.minY,
        maxY: bounds.maxY,
        padding: max(8, upm / 64)
      )
    }

    return serializeTables(tables, sfntVersion: readUInt32(data, 0))
  }

  static func readTables(_ data: Data) throws -> [String: FontTable] {
    guard data.count >= 12 else { throw NativeFontError.malformedFont }
    let count = min(Int(readUInt16(data, 4)), max(0, (data.count - 12) / 16))
    var tables: [String: FontTable] = [:]
    for i in 0..<count {
      let p = 12 + i * 16
      guard p + 16 <= data.count else { continue }
      let tagData = data[p..<p+4]
      guard let tag = String(data: tagData, encoding: .ascii) else { continue }
      let checksum = readUInt32(data, p + 4)
      let offset = Int(readUInt32(data, p + 8))
      let length = Int(readUInt32(data, p + 12))
      guard offset >= 0, length >= 0, offset + length <= data.count else { continue }
      tables[tag] = FontTable(tag: tag, checksum: checksum, data: Data(data[offset..<offset+length]))
    }
    return tables
  }

  private static func patchGlyf(head: Data, maxp: Data, loca: Data, glyf: Data, scale: Double, riseUnits: Int, weightPercent: Double, globalYMid: Double, selectedGlyphs: Set<Int>?, glyphAdjustments: [Int: NativeGlyphAdjustment], replacementGlyphs: [Int: [[OutlinePoint]]], upm: Int) -> (glyf: Data, loca: Data, head: Data, maxPoints: Int, maxContours: Int, averageBolden: Double)? {
    guard head.count >= 52, maxp.count >= 6 else { return nil }
    let numGlyphs = Int(readUInt16(maxp, 4))
    let longLoca = readInt16(head, 50) == 1
    guard numGlyphs > 0 else { return nil }
    var offsets = [Int](repeating: 0, count: numGlyphs + 1)
    for i in 0...numGlyphs {
      let p = i * (longLoca ? 4 : 2)
      if p + (longLoca ? 4 : 2) > loca.count {
        offsets[i] = i > 0 ? offsets[i - 1] : 0
      } else {
        offsets[i] = longLoca ? Int(readUInt32(loca, p)) : Int(readUInt16(loca, p)) * 2
      }
    }

    var chunks: [Data] = []
    var newOffsets = [Int](repeating: 0, count: numGlyphs + 1)
    var current = 0
    var globalMinX = Int.max, globalMinY = Int.max, globalMaxX = Int.min, globalMaxY = Int.min
    var maxSimplePoints = maxp.count >= 8 ? Int(readUInt16(maxp, 6)) : 0
    var maxSimpleContours = maxp.count >= 10 ? Int(readUInt16(maxp, 8)) : 0
    var boldenTotal = 0.0
    var boldenCount = 0
    for i in 0..<numGlyphs {
      newOffsets[i] = current
      var start = min(max(0, offsets[i]), glyf.count)
      var end = min(max(0, offsets[i + 1]), glyf.count)
      if start > end { swap(&start, &end) }
      var chunk = Data(glyf[start..<end])
      let isReplacement = replacementGlyphs[i] != nil
      if let replacement = replacementGlyphs[i] {
        chunk = CoreTextOutlineConverter.encodeGlyph(replacement).data
      }
      let selected = selectedGlyphs == nil || selectedGlyphs!.contains(i)
      let adjustment = glyphAdjustments[i]
      let individualScale = max(0.01, 1.0 + (adjustment?.size ?? 0) / 100.0)
      let effectiveScale = isReplacement ? 1.0 : (selected ? scale : 1.0) * individualScale
      let effectiveRise = isReplacement ? 0 : (selected ? riseUnits : 0) + Int(round((adjustment?.y ?? 0) / 100.0 * Double(upm)))
      let xOffset = isReplacement ? 0 : Int(round((adjustment?.x ?? 0) / 100.0 * Double(upm)))
      let effectiveWeight = isReplacement ? 0 : (selected ? weightPercent : 0)
      let needsTransform = abs(effectiveScale - 1.0) > 0.001 ||
        effectiveRise != 0 || xOffset != 0 || abs(effectiveWeight) > 0.001
      if needsTransform, let transformed = transformSimpleGlyph(chunk, scale: effectiveScale, riseUnits: effectiveRise, xOffsetUnits: xOffset, weightPercent: effectiveWeight, globalYMid: globalYMid) {
        chunk = transformed.data
        if abs(transformed.boldenUnits) > 0.001 {
          boldenTotal += transformed.boldenUnits
          boldenCount += 1
        }
      }
      if chunk.count >= 10 && readInt16(chunk, 0) != 0 {
        globalMinX = min(globalMinX, Int(readInt16(chunk, 2)))
        globalMinY = min(globalMinY, Int(readInt16(chunk, 4)))
        globalMaxX = max(globalMaxX, Int(readInt16(chunk, 6)))
        globalMaxY = max(globalMaxY, Int(readInt16(chunk, 8)))
      }
      let contourCount = chunk.count >= 10 ? Int(readInt16(chunk, 0)) : 0
      if contourCount > 0, chunk.count >= 10 + contourCount * 2 {
        let pointCount = Int(readUInt16(chunk, 10 + (contourCount - 1) * 2)) + 1
        maxSimplePoints = max(maxSimplePoints, pointCount)
        maxSimpleContours = max(maxSimpleContours, contourCount)
      }
      chunks.append(chunk)
      current += chunk.count
      if current % 2 != 0 {
        chunks.append(Data([0]))
        current += 1
      }
    }
    newOffsets[numGlyphs] = current

    let needsLong = current > 0x1FFFF
    var newLoca = Data()
    for offset in newOffsets {
      if needsLong {
        appendUInt32(&newLoca, UInt32(offset))
      } else {
        appendUInt16(&newLoca, UInt16(max(0, offset / 2)))
      }
    }

    var newGlyf = Data()
    for chunk in chunks { newGlyf.append(chunk) }
    var newHead = head
    if needsLong != longLoca {
      writeInt16(&newHead, 50, needsLong ? 1 : 0)
    }
    if globalMinX != Int.max {
      writeInt16(&newHead, 36, globalMinX)
      writeInt16(&newHead, 38, globalMinY)
      writeInt16(&newHead, 40, globalMaxX)
      writeInt16(&newHead, 42, globalMaxY)
    }
    return (
      newGlyf,
      newLoca,
      newHead,
      maxSimplePoints,
      maxSimpleContours,
      boldenCount > 0 ? boldenTotal / Double(boldenCount) : 0
    )
  }

  private static func transformSimpleGlyph(_ chunk: Data, scale: Double, riseUnits: Int, xOffsetUnits: Int, weightPercent: Double, globalYMid: Double) -> (data: Data, boldenUnits: Double)? {
    guard chunk.count >= 10 else { return nil }
    let contours = Int(readInt16(chunk, 0))
    if contours < 0 {
      guard let data = transformCompositeGlyph(chunk, scale: scale, riseUnits: riseUnits, xOffsetUnits: xOffsetUnits, globalYMid: globalYMid) else { return nil }
      return (data, 0)
    }
    if contours == 0 { return nil }
    var p = 10
    guard p + contours * 2 + 2 <= chunk.count else { return nil }
    var endPts: [Int] = []
    for i in 0..<contours { endPts.append(Int(readUInt16(chunk, p + i * 2))) }
    guard let last = endPts.last else { return nil }
    let pointCount = last + 1
    p += contours * 2
    let instructionLength = Int(readUInt16(chunk, p))
    p += 2 + instructionLength
    guard p <= chunk.count else { return nil }

    var flags: [UInt8] = []
    while flags.count < pointCount && p < chunk.count {
      let flag = chunk[p]
      p += 1
      flags.append(flag)
      if flag & 8 != 0 {
        guard p < chunk.count else { return nil }
        let repeatCount = Int(chunk[p])
        p += 1
        for _ in 0..<repeatCount where flags.count < pointCount { flags.append(flag) }
      }
    }
    guard flags.count == pointCount else { return nil }

    var xs = [Int](), ys = [Int]()
    var x = 0, y = 0
    for flag in flags {
      var dx = 0
      if flag & 2 != 0 {
        guard p < chunk.count else { return nil }
        dx = Int(chunk[p]); p += 1
        if flag & 16 == 0 { dx = -dx }
      } else if flag & 16 == 0 {
        guard p + 2 <= chunk.count else { return nil }
        dx = Int(readInt16(chunk, p)); p += 2
      }
      x += dx; xs.append(x)
    }
    for flag in flags {
      var dy = 0
      if flag & 4 != 0 {
        guard p < chunk.count else { return nil }
        dy = Int(chunk[p]); p += 1
        if flag & 32 == 0 { dy = -dy }
      } else if flag & 32 == 0 {
        guard p + 2 <= chunk.count else { return nil }
        dy = Int(readInt16(chunk, p)); p += 2
      }
      y += dy; ys.append(y)
    }

    let stroke = estimateStrokeSize(xs: xs, ys: ys, endPts: endPts)
    let weightFactor = weightPercent > 0 ? 1.0 : 0.85
    let requestedBolden = (weightPercent / 100.0) * weightFactor * stroke * 0.55
    let boldenUnits = max(-0.35 * stroke, min(0.5 * stroke, requestedBolden))
    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
    var contourStart = 0
    for contourEnd in endPts {
      let adjusted = offsetContour(
        xs: xs,
        ys: ys,
        start: contourStart,
        end: contourEnd,
        requestedUnits: boldenUnits
      )
      for i in contourStart...contourEnd {
        let offset = adjusted[i - contourStart]
        xs[i] = clampInt16(Int(round(Double(xs[i]) * scale + offset.x)) + xOffsetUnits)
        ys[i] = clampInt16(Int(round(globalYMid + (Double(ys[i]) - globalYMid) * scale + offset.y + Double(riseUnits))))
        minX = min(minX, xs[i]); maxX = max(maxX, xs[i])
        minY = min(minY, ys[i]); maxY = max(maxY, ys[i])
      }
      contourStart = contourEnd + 1
    }

    var out = Data()
    appendInt16(&out, Int16(contours))
    appendInt16(&out, Int16(clampInt16(minX)))
    appendInt16(&out, Int16(clampInt16(minY)))
    appendInt16(&out, Int16(clampInt16(maxX)))
    appendInt16(&out, Int16(clampInt16(maxY)))
    for end in endPts { appendUInt16(&out, UInt16(end)) }
    appendUInt16(&out, 0)
    for flag in flags { out.append(flag & 1) }
    var lastX = 0, lastY = 0
    for value in xs {
      appendInt16(&out, Int16(clampInt16(value - lastX)))
      lastX = value
    }
    for value in ys {
      appendInt16(&out, Int16(clampInt16(value - lastY)))
      lastY = value
    }
    return (out, boldenUnits)
  }

  private static func transformCompositeGlyph(_ chunk: Data, scale: Double, riseUnits: Int, xOffsetUnits: Int, globalYMid: Double) -> Data? {
    guard chunk.count >= 14 else { return nil }
    let arg1And2AreWords: UInt16 = 0x0001
    let argsAreXYValues: UInt16 = 0x0002
    let weHaveScale: UInt16 = 0x0008
    let moreComponents: UInt16 = 0x0020
    let weHaveXYScale: UInt16 = 0x0040
    let weHaveTwoByTwo: UInt16 = 0x0080
    let weHaveInstructions: UInt16 = 0x0100

    let oldMinX = Int(readInt16(chunk, 2))
    let oldMinY = Int(readInt16(chunk, 4))
    let oldMaxX = Int(readInt16(chunk, 6))
    let oldMaxY = Int(readInt16(chunk, 8))
    let newMinX = clampInt16(Int(round(Double(oldMinX) * scale)) + xOffsetUnits)
    let newMaxX = clampInt16(Int(round(Double(oldMaxX) * scale)) + xOffsetUnits)
    let newMinY = clampInt16(Int(round(globalYMid + (Double(oldMinY) - globalYMid) * scale + Double(riseUnits))))
    let newMaxY = clampInt16(Int(round(globalYMid + (Double(oldMaxY) - globalYMid) * scale + Double(riseUnits))))

    var out = Data()
    appendInt16(&out, -1)
    appendInt16(&out, Int16(min(newMinX, newMaxX)))
    appendInt16(&out, Int16(min(newMinY, newMaxY)))
    appendInt16(&out, Int16(max(newMinX, newMaxX)))
    appendInt16(&out, Int16(max(newMinY, newMaxY)))

    var p = 10
    var flags: UInt16 = moreComponents
    repeat {
      guard p + 4 <= chunk.count else { return nil }
      flags = readUInt16(chunk, p)
      let glyphIndex = readUInt16(chunk, p + 2)
      p += 4
      let hasWordArgs = flags & arg1And2AreWords != 0
      let hasXYArgs = flags & argsAreXYValues != 0
      var arg1 = 0
      var arg2 = 0
      if hasWordArgs {
        guard p + 4 <= chunk.count else { return nil }
        arg1 = Int(readInt16(chunk, p))
        arg2 = Int(readInt16(chunk, p + 2))
        p += 4
      } else {
        guard p + 2 <= chunk.count else { return nil }
        arg1 = Int(Int8(bitPattern: chunk[p]))
        arg2 = Int(Int8(bitPattern: chunk[p + 1]))
        p += 2
      }

      var matrixValues: [Int16] = []
      if flags & weHaveScale != 0 {
        guard p + 2 <= chunk.count else { return nil }
        let value = Int(readInt16(chunk, p))
        matrixValues = [Int16(clampF2Dot14(Double(value) * scale))]
        p += 2
      } else if flags & weHaveXYScale != 0 {
        guard p + 4 <= chunk.count else { return nil }
        let xScale = Int(readInt16(chunk, p))
        let yScale = Int(readInt16(chunk, p + 2))
        matrixValues = [
          Int16(clampF2Dot14(Double(xScale) * scale)),
          Int16(clampF2Dot14(Double(yScale) * scale))
        ]
        p += 4
      } else if flags & weHaveTwoByTwo != 0 {
        guard p + 8 <= chunk.count else { return nil }
        let a = Int(readInt16(chunk, p))
        let b = Int(readInt16(chunk, p + 2))
        let c = Int(readInt16(chunk, p + 4))
        let d = Int(readInt16(chunk, p + 6))
        matrixValues = [
          Int16(clampF2Dot14(Double(a) * scale)),
          Int16(clampF2Dot14(Double(b) * scale)),
          Int16(clampF2Dot14(Double(c) * scale)),
          Int16(clampF2Dot14(Double(d) * scale))
        ]
        p += 8
      } else if abs(scale - 1.0) > 0.001 {
        flags |= weHaveScale
        matrixValues = [Int16(clampF2Dot14(16384.0 * scale))]
      }

      if hasXYArgs {
        arg1 = Int(round(Double(arg1) * scale)) + xOffsetUnits
        arg2 = Int(round(Double(arg2) * scale)) + riseUnits
      }

      flags &= ~weHaveInstructions
      appendUInt16(&out, flags)
      appendUInt16(&out, glyphIndex)
      if flags & arg1And2AreWords != 0 {
        appendInt16(&out, Int16(clampInt16(arg1)))
        appendInt16(&out, Int16(clampInt16(arg2)))
      } else {
        out.append(UInt8(bitPattern: Int8(max(-128, min(127, arg1)))))
        out.append(UInt8(bitPattern: Int8(max(-128, min(127, arg2)))))
      }
      for value in matrixValues { appendInt16(&out, value) }
    } while flags & moreComponents != 0

    if out.count % 2 != 0 { out.append(0) }
    return out
  }

  private static func patchHmtx(hmtx: Data, hhea: Data, scale: Double, spacingUnits: Int, boldenUnits: Double, selectedGlyphs: Set<Int>?, glyphAdjustments: [Int: NativeGlyphAdjustment], replacementGlyphs: [Int: [[OutlinePoint]]], upm: Int) -> Data {
    guard hhea.count >= 36 else { return hmtx }
    let count = min(Int(readUInt16(hhea, 34)), hmtx.count / 4)
    var out = hmtx
    for i in 0..<count {
      let selected = selectedGlyphs == nil || selectedGlyphs!.contains(i)
      let adjustment = glyphAdjustments[i]
      let characterSpacingUnits = Int(round((adjustment?.spacing ?? 0) / 100.0 * Double(upm)))
      if !selected && adjustment == nil && replacementGlyphs[i] == nil { continue }
      let p = i * 4
      let oldWidth = Int(readUInt16(out, p))
      let appliedScale = (selected ? scale : 1.0) * max(0.01, 1.0 + (adjustment?.size ?? 0) / 100.0)
      if let replacement = replacementGlyphs[i] {
        let points = replacement.flatMap { $0 }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? minX
        let inkWidth = max(1, maxX - minX)
        let spacingScale = max(0.01, appliedScale)
        let unscaledInk = Double(inkWidth) / max(0.05, appliedScale)
        let scaledAdvance = spacingScale * max(Double(oldWidth), unscaledInk)
        let visibleAdvance = Double(maxX - min(0, minX))
        let advance = Int(round(max(scaledAdvance, visibleAdvance))) +
          (selected ? spacingUnits : 0) + characterSpacingUnits
        writeUInt16(&out, p, UInt16(max(1, min(65535, advance))))
        writeInt16(&out, p + 2, minX)
        continue
      }
      let appliedBolden = selected ? boldenUnits : 0
      let appliedSpacing = selected ? spacingUnits : 0
      let width = Int(round(Double(oldWidth) * appliedScale + appliedBolden)) + appliedSpacing + characterSpacingUnits
      writeUInt16(&out, p, UInt16(max(0, min(65535, width))))
      let oldBearing = Int(readInt16(out, p + 2))
      let xOffsetUnits = Int(round((adjustment?.x ?? 0) / 100.0 * Double(upm)))
      writeInt16(&out, p + 2, Int(round(Double(oldBearing) * appliedScale - appliedBolden * 0.5)) + xOffsetUnits)
    }
    return out
  }

  private static func patchHheaHorizontalMetrics(
    hhea: Data,
    hmtx: Data,
    replacementGlyphs: [Int: [[OutlinePoint]]]
  ) -> Data {
    guard hhea.count >= 36 else { return hhea }
    var out = hhea
    let count = min(Int(readUInt16(hhea, 34)), hmtx.count / 4)
    var maximum = 0
    var minLeftSideBearing = Int(readInt16(hhea, 12))
    var minRightSideBearing = Int(readInt16(hhea, 14))
    var xMaxExtent = Int(readInt16(hhea, 16))
    for index in 0..<count {
      let offset = index * 4
      maximum = max(maximum, Int(readUInt16(hmtx, offset)))
      guard let replacement = replacementGlyphs[index] else { continue }
      let points = replacement.flatMap { $0 }
      guard let minX = points.map(\.x).min(),
            let maxX = points.map(\.x).max() else { continue }
      let advance = Int(readUInt16(hmtx, offset))
      let leftSideBearing = Int(readInt16(hmtx, offset + 2))
      let rightSideBearing = advance - leftSideBearing - (maxX - minX)
      minLeftSideBearing = min(minLeftSideBearing, leftSideBearing)
      minRightSideBearing = min(minRightSideBearing, rightSideBearing)
      xMaxExtent = max(xMaxExtent, leftSideBearing + (maxX - minX))
    }
    writeUInt16(&out, 10, UInt16(min(65535, maximum)))
    writeInt16(&out, 12, minLeftSideBearing)
    writeInt16(&out, 14, minRightSideBearing)
    writeInt16(&out, 16, xMaxExtent)
    return out
  }

  private static func replacementVerticalBounds(
    _ replacementGlyphs: [Int: [[OutlinePoint]]]
  ) -> (minY: Int, maxY: Int)? {
    var minY = Int.max
    var maxY = Int.min
    for contours in replacementGlyphs.values {
      for contour in contours {
        for point in contour {
          minY = min(minY, point.y)
          maxY = max(maxY, point.y)
        }
      }
    }
    guard minY != Int.max, maxY != Int.min else { return nil }
    return (minY, maxY)
  }

  private static func patchHheaVerticalBounds(
    _ hhea: Data,
    minY: Int,
    maxY: Int,
    padding: Int
  ) -> Data {
    guard hhea.count >= 10 else { return hhea }
    var out = hhea
    let asc = max(Int(readInt16(out, 4)), maxY + padding)
    let desc = min(Int(readInt16(out, 6)), minY - padding)
    writeInt16(&out, 4, asc)
    writeInt16(&out, 6, desc)
    return out
  }

  private static func patchOS2VerticalBounds(
    _ os2: Data,
    minY: Int,
    maxY: Int,
    padding: Int
  ) -> Data {
    guard os2.count >= 72 else { return os2 }
    var out = os2
    let asc = max(Int(readInt16(out, 68)), maxY + padding)
    let desc = min(Int(readInt16(out, 70)), minY - padding)
    writeInt16(&out, 68, asc)
    writeInt16(&out, 70, desc)
    if out.count >= 78 {
      let winAsc = max(Int(readUInt16(out, 74)), max(0, maxY + padding))
      let winDesc = max(Int(readUInt16(out, 76)), max(0, -minY + padding))
      writeUInt16(&out, 74, UInt16(min(65535, winAsc)))
      writeUInt16(&out, 76, UInt16(min(65535, winDesc)))
    }
    return out
  }

  private static func estimateStrokeSize(xs: [Int], ys: [Int], endPts: [Int]) -> Double {
    var area = 0.0
    var perimeter = 0.0
    var start = 0
    for end in endPts where end >= start && end < xs.count {
      area += signedArea(xs: xs, ys: ys, start: start, end: end)
      for index in start...end {
        let next = index == end ? start : index + 1
        perimeter += hypot(Double(xs[next] - xs[index]), Double(ys[next] - ys[index]))
      }
      start = end + 1
    }
    guard perimeter > 0.001 else { return 0 }
    return max(0, 2.0 * abs(area) / perimeter)
  }

  private static func offsetContour(xs: [Int], ys: [Int], start: Int, end: Int, requestedUnits: Double) -> [(x: Double, y: Double)] {
    let count = end - start + 1
    guard count >= 3, requestedUnits != 0 else {
      return Array(repeating: (0, 0), count: max(0, count))
    }

    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
    for i in start...end {
      minX = min(minX, xs[i]); maxX = max(maxX, xs[i])
      minY = min(minY, ys[i]); maxY = max(maxY, ys[i])
    }
    let contourLimit = max(4.0, Double(min(maxX - minX, maxY - minY)) * 0.34)
    let amount = max(-contourLimit, min(contourLimit, Double(requestedUnits)))
    if abs(amount) < 0.01 {
      return Array(repeating: (0, 0), count: count)
    }

    let area = signedArea(xs: xs, ys: ys, start: start, end: end)
    let ccw = area > 0
    var output: [(x: Double, y: Double)] = []
    output.reserveCapacity(count)

    for i in start...end {
      let prev = i == start ? end : i - 1
      let next = i == end ? start : i + 1
      let n1 = outwardNormal(
        dx: Double(xs[i] - xs[prev]),
        dy: Double(ys[i] - ys[prev]),
        ccw: ccw
      )
      let n2 = outwardNormal(
        dx: Double(xs[next] - xs[i]),
        dy: Double(ys[next] - ys[i]),
        ccw: ccw
      )
      var nx = n1.x + n2.x
      var ny = n1.y + n2.y
      let length = sqrt(nx * nx + ny * ny)
      if length < 0.001 {
        nx = n2.x
        ny = n2.y
      } else {
        nx /= length
        ny /= length
      }
      let projection = abs(nx * n2.x + ny * n2.y)
      let miter = projection > 0.15 ? min(4.0, 1.0 / projection) : 1.0
      output.append((nx * amount * miter, ny * amount * miter))
    }
    return output
  }

  private static func signedArea(xs: [Int], ys: [Int], start: Int, end: Int) -> Double {
    guard end > start else { return 0 }
    var area = 0.0
    for i in start...end {
      let next = i == end ? start : i + 1
      area += Double(xs[i] * ys[next] - xs[next] * ys[i])
    }
    return area / 2.0
  }

  private static func outwardNormal(dx: Double, dy: Double, ccw: Bool) -> (x: Double, y: Double) {
    let length = max(1.0, sqrt(dx * dx + dy * dy))
    if ccw {
      return (dy / length, -dx / length)
    }
    return (-dy / length, dx / length)
  }

  private static func patchHhea(_ hhea: Data, lineHeightPercent: Double) -> Data {
    guard hhea.count >= 10 else { return hhea }
    var out = hhea
    let asc = Int(readInt16(out, 4))
    let desc = Int(readInt16(out, 6))
    let currentGap = Int(readInt16(out, 8))
    let body = max(1, asc - desc + currentGap)
    let delta = Int(round(lineHeightPercent / 100.0 * Double(body) * 0.5))
    writeInt16(&out, 4, asc + delta)
    writeInt16(&out, 6, desc - delta)
    return out
  }

  private static func patchOS2(_ os2: Data, lineHeightPercent: Double) -> Data {
    guard os2.count >= 74 else { return os2 }
    var out = os2
    let asc = Int(readInt16(out, 68))
    let desc = Int(readInt16(out, 70))
    let currentGap = Int(readInt16(out, 72))
    let body = max(1, asc - desc + currentGap)
    let delta = Int(round(lineHeightPercent / 100.0 * Double(body) * 0.5))
    writeInt16(&out, 68, asc + delta)
    writeInt16(&out, 70, desc - delta)
    if out.count >= 78 {
      writeUInt16(&out, 74, UInt16(max(0, min(65535, Int(readUInt16(out, 74)) + delta))))
      writeUInt16(&out, 76, UInt16(max(0, min(65535, Int(readUInt16(out, 76)) + delta))))
    }
    return out
  }

  private static func patchWeightClass(_ os2: Data, weightPercent: Double) -> Data {
    guard os2.count >= 6 else { return os2 }
    var out = os2
    let value = max(1, min(1000, Int(round((1.0 + weightPercent / 100.0) * 400.0))))
    writeUInt16(&out, 4, UInt16(value))
    return out
  }

  static func serializeTables(_ tables: [String: FontTable], sfntVersion: UInt32) -> Data {
    var items = tables.values.sorted { $0.tag < $1.tag }
    let count = items.count
    let headerSize = 12 + count * 16
    var offset = headerSize
    var records: [(tag: String, checksum: UInt32, offset: Int, length: Int)] = []
    var body = Data()

    for i in 0..<items.count {
      var data = items[i].data
      if items[i].tag == "head", data.count >= 12 {
        writeUInt32(&data, 8, 0)
      }
      let length = data.count
      let checksum = checksum32(data)
      records.append((items[i].tag, checksum, offset, length))
      body.append(data)
      let padding = (4 - (length % 4)) % 4
      if padding > 0 { body.append(Data(repeating: 0, count: padding)) }
      offset += length + padding
      items[i].checksum = checksum
    }

    var out = Data()
    appendUInt32(&out, sfntVersion)
    appendUInt16(&out, UInt16(count))
    var maxPower = 1
    var entrySelector = 0
    while maxPower * 2 <= count {
      maxPower *= 2
      entrySelector += 1
    }
    appendUInt16(&out, UInt16(maxPower * 16))
    appendUInt16(&out, UInt16(entrySelector))
    appendUInt16(&out, UInt16(count * 16 - maxPower * 16))

    for record in records {
      out.append(record.tag.data(using: .ascii) ?? Data(repeating: 0, count: 4))
      appendUInt32(&out, record.checksum)
      appendUInt32(&out, UInt32(record.offset))
      appendUInt32(&out, UInt32(record.length))
    }
    out.append(body)

    if let headRecord = records.first(where: { $0.tag == "head" }), headRecord.offset + 12 <= out.count {
      writeUInt32(&out, headRecord.offset + 8, 0)
      let adjustment = UInt32(truncatingIfNeeded: 0xB1B0AFBA &- checksum32(out))
      writeUInt32(&out, headRecord.offset + 8, adjustment)
    }
    return out
  }

  private static func checksum32(_ data: Data) -> UInt32 {
    var sum: UInt32 = 0
    var i = 0
    while i < data.count {
      var word: UInt32 = 0
      for j in 0..<4 {
        word <<= 8
        if i + j < data.count { word |= UInt32(data[i + j]) }
      }
      sum = sum &+ word
      i += 4
    }
    return sum
  }

  private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    guard offset + 2 <= data.count else { return 0 }
    return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
  }

  private static func readInt16(_ data: Data, _ offset: Int) -> Int16 {
    Int16(bitPattern: readUInt16(data, offset))
  }

  private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
  }

  private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  private static func appendInt16(_ data: inout Data, _ value: Int16) {
    appendUInt16(&data, UInt16(bitPattern: value))
  }

  private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  private static func writeUInt16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
    guard offset + 2 <= data.count else { return }
    data[offset] = UInt8((value >> 8) & 0xff)
    data[offset + 1] = UInt8(value & 0xff)
  }

  private static func writeInt16(_ data: inout Data, _ offset: Int, _ value: Int) {
    writeUInt16(&data, offset, UInt16(bitPattern: Int16(clampInt16(value))))
  }

  private static func writeUInt32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
    guard offset + 4 <= data.count else { return }
    data[offset] = UInt8((value >> 24) & 0xff)
    data[offset + 1] = UInt8((value >> 16) & 0xff)
    data[offset + 2] = UInt8((value >> 8) & 0xff)
    data[offset + 3] = UInt8(value & 0xff)
  }

  private static func clampInt16(_ value: Int) -> Int {
    max(-32768, min(32767, value))
  }

  private static func clampF2Dot14(_ value: Double) -> Int {
    max(-32768, min(32767, Int(round(value))))
  }
}

private enum NativeOutlineFontProcessor {
  static func adjust(data: Data, params: NativeFontAdjustParams) throws -> Data {
    let sourceData = try NativeColorFontProcessor.prepareForAdjustment(
      data: data,
      hasReplacements: !params.replacements.isEmpty
    )
    let tables = try NativeTTFProcessor.readTables(sourceData)
    if tables["glyf"] != nil,
       tables["loca"] != nil,
       let provider = CGDataProvider(data: sourceData as CFData),
       let cgFont = CGFont(provider) {
      let unitsPerEm = max(1, Int(cgFont.unitsPerEm))
      let ctFont = CTFontCreateWithGraphicsFont(cgFont, CGFloat(unitsPerEm), nil, nil)
      let selectedGlyphs = params.targetAll ? nil : glyphIDs(for: params.chars, font: ctFont)
      var glyphAdjustments: [Int: NativeGlyphAdjustment] = [:]
      for (characters, adjustment) in params.characterAdjustments {
        for glyph in glyphIDs(for: characters, font: ctFont) {
          glyphAdjustments[glyph] = adjustment
        }
      }
      var replacementGlyphs: [Int: [[OutlinePoint]]] = [:]
      for (characters, imageData) in params.replacements {
        let transform = params.replacementTransforms[characters] ?? .identity
        for glyph in glyphIDs(for: characters, font: ctFont) {
          let glyphBox = replacementGlyphBox(
            glyph: glyph,
            font: ctFont,
            unitsPerEm: unitsPerEm
          )
          let userScale = transform.scale
          let xUnits = transform.x / 100.0 * Double(unitsPerEm)
          let yUnits = transform.y / 100.0 * Double(unitsPerEm)
          replacementGlyphs[glyph] = try RasterGlyphConverter.contours(
            from: imageData,
            unitsPerEm: unitsPerEm,
            glyphBox: glyphBox,
            userScale: userScale,
            offsetX: xUnits,
            offsetY: yUnits
          )
        }
      }
      let adjusted = try NativeTTFProcessor.adjust(
        data: sourceData,
        params: params,
        selectedGlyphs: selectedGlyphs,
        glyphAdjustments: glyphAdjustments,
        replacementGlyphs: replacementGlyphs
      )
      return try NativeColorFontProcessor.apply(data: adjusted, params: params)
    }
    let converted = try CoreTextOutlineConverter.convert(data: sourceData, selectedCharacters: params.targetAll ? "" : params.chars, characterAdjustments: params.characterAdjustments, replacements: params.replacements)
    let adjusted = try NativeTTFProcessor.adjust(data: converted.data, params: params, selectedGlyphs: params.targetAll ? nil : converted.selectedGlyphs, glyphAdjustments: converted.glyphAdjustments)
    return try NativeColorFontProcessor.apply(data: adjusted, params: params)
  }

  static func replacementGlyphBox(
    glyph: Int,
    font: CTFont,
    unitsPerEm: Int
  ) -> CGRect {
    var mutableGlyph = CGGlyph(glyph)
    var advance = CGSize.zero
    _ = CTFontGetAdvancesForGlyphs(
      font,
      .horizontal,
      &mutableGlyph,
      &advance,
      1
    )
    let side = CGFloat(max(1, unitsPerEm))
    let centerX = advance.width * 0.5
    let bounds = CTFontGetBoundingRectsForGlyphs(
      font,
      .default,
      &mutableGlyph,
      nil,
      1
    )
    let fallbackCenterY = (CTFontGetAscent(font) - CTFontGetDescent(font)) * 0.5
    let centerY = bounds.height > 0 ? bounds.midY : fallbackCenterY
    return CGRect(
      x: centerX - side * 0.5,
      y: centerY - side * 0.5,
      width: side,
      height: side
    )
  }

  private static func glyphIDs(for text: String, font: CTFont) -> Set<Int> {
    var output = Set<Int>()
    for scalar in text.unicodeScalars {
      var characters: [UniChar]
      if scalar.value <= 0xffff {
        characters = [UniChar(scalar.value)]
      } else {
        let value = scalar.value - 0x10000
        characters = [
          UniChar(0xD800 + (value >> 10)),
          UniChar(0xDC00 + (value & 0x3ff))
        ]
      }
      var glyphs = [CGGlyph](repeating: 0, count: characters.count)
      let mapped = characters.withUnsafeBufferPointer { characterPointer in
        glyphs.withUnsafeMutableBufferPointer { glyphPointer in
          CTFontGetGlyphsForCharacters(
            font,
            characterPointer.baseAddress!,
            glyphPointer.baseAddress!,
            characters.count
          )
        }
      }
      if mapped {
        for glyph in glyphs where glyph != 0 { output.insert(Int(glyph)) }
      }
    }
    return output
  }
}

private enum NativeColorFontProcessor {
  static func prepareForAdjustment(
    data: Data,
    hasReplacements: Bool
  ) throws -> Data {
    guard hasReplacements else { return data }
    var tables = try NativeTTFProcessor.readTables(data)
    guard let marker = tables["BSFT"]?.data,
          marker.count >= 4,
          readUInt16(marker, 0) == 1 else { return data }
    let baseGlyphCount = Int(readUInt16(marker, 2))
    guard let maxpTable = tables["maxp"] else { throw NativeFontError.malformedFont }
    let currentGlyphCount = Int(readUInt16(maxpTable.data, 4))

    for tag in ["COLR", "CPAL", "sbix", "CBDT", "CBLC", "SVG ", "BSFT"] {
      tables.removeValue(forKey: tag)
    }
    guard baseGlyphCount > 0, baseGlyphCount < currentGlyphCount else {
      return NativeTTFProcessor.serializeTables(tables, sfntVersion: 0x00010000)
    }
    guard let head = tables["head"]?.data,
          var hhea = tables["hhea"]?.data,
          var maxp = tables["maxp"]?.data,
          let hmtx = tables["hmtx"]?.data,
          let loca = tables["loca"]?.data,
          let glyf = tables["glyf"]?.data else {
      throw NativeFontError.malformedFont
    }
    let longLoca = Int16(bitPattern: readUInt16(head, 50)) == 1
    let locaEntrySize = longLoca ? 4 : 2
    guard loca.count >= (baseGlyphCount + 1) * locaEntrySize else {
      throw NativeFontError.malformedFont
    }
    let glyphEndOffset = baseGlyphCount * locaEntrySize
    let glyphEnd = longLoca
      ? Int(readUInt32(loca, glyphEndOffset))
      : Int(readUInt16(loca, glyphEndOffset)) * 2
    guard glyphEnd >= 0, glyphEnd <= glyf.count,
          Int(readUInt16(hhea, 34)) == currentGlyphCount,
          hmtx.count >= baseGlyphCount * 4 else {
      throw NativeFontError.malformedFont
    }

    writeUInt16(&maxp, 4, UInt16(baseGlyphCount))
    writeUInt16(&hhea, 34, UInt16(baseGlyphCount))
    tables["head"] = FontTable(tag: "head", checksum: 0, data: head)
    tables["hhea"] = FontTable(tag: "hhea", checksum: 0, data: hhea)
    tables["maxp"] = FontTable(tag: "maxp", checksum: 0, data: maxp)
    tables["hmtx"] = FontTable(
      tag: "hmtx",
      checksum: 0,
      data: Data(hmtx.prefix(baseGlyphCount * 4))
    )
    tables["loca"] = FontTable(
      tag: "loca",
      checksum: 0,
      data: Data(loca.prefix((baseGlyphCount + 1) * locaEntrySize))
    )
    tables["glyf"] = FontTable(
      tag: "glyf",
      checksum: 0,
      data: Data(glyf.prefix(glyphEnd))
    )
    return NativeTTFProcessor.serializeTables(tables, sfntVersion: 0x00010000)
  }

  static func apply(data: Data, params: NativeFontAdjustParams) throws -> Data {
    let hasGlobal = params.globalColor != nil
    let hasPalette = hasGlobal || !params.characterColors.isEmpty || !params.randomColors.isEmpty
    let hasReplacements = !params.replacements.isEmpty
    // The outline engine has already written a monochrome glyf fallback.
    // This stage adds color-font tables for renderers that support them.
    guard hasPalette || hasReplacements else { return data }
    guard let provider = CGDataProvider(data: data as CFData), let cgFont = CGFont(provider) else { return data }
    var tables = try NativeTTFProcessor.readTables(data)
    // Rebuild every color-font representation from the current replacement
    // images so stale tables from the source font cannot override the result.
    for tag in ["COLR", "CPAL", "sbix", "CBDT", "CBLC", "SVG "] {
      tables.removeValue(forKey: tag)
    }
    guard let maxp = tables["maxp"] else { return data }
    var glyphCount = max(1, Int(readUInt16(maxp.data, 4)))
    let baseGlyphCount = glyphCount
    let ctFont = CTFontCreateWithGraphicsFont(cgFont, CGFloat(max(1, cgFont.unitsPerEm)), nil, nil)
    var imageGlyphs = Set<Int>()
    var imagesByGlyph: [Int: Data] = [:]
    var transformsByGlyph: [Int: NativeReplacementTransform] = [:]
    for (characters, imageData) in params.replacements {
      let transform = params.replacementTransforms[characters] ?? .identity
      for glyph in glyphIDs(for: characters, font: ctFont) {
        imageGlyphs.insert(glyph)
        imagesByGlyph[glyph] = imageData
        transformsByGlyph[glyph] = transform
      }
    }
    var palette: [(UInt8, UInt8, UInt8, UInt8)] = []
    var paletteIndexes: [UInt32: Int] = [:]
    var layersByGlyph: [Int: [(glyph: Int, palette: Int)]] = [:]
    func paletteIndex(for color: (UInt8, UInt8, UInt8, UInt8)) -> Int {
      let key = UInt32(color.0) << 24 | UInt32(color.1) << 16 | UInt32(color.2) << 8 | UInt32(color.3)
      if let existing = paletteIndexes[key] { return existing }
      let index = palette.count
      palette.append(color)
      paletteIndexes[key] = index
      return index
    }

    if hasPalette {
      var glyphColors: [Int: String] = [:]
      if let global = params.globalColor, hasGlobal {
        for glyph in 1..<glyphCount where !imageGlyphs.contains(glyph) {
          glyphColors[glyph] = global
        }
      }
      if !params.randomColors.isEmpty {
        for glyph in 1..<glyphCount where !imageGlyphs.contains(glyph) {
          glyphColors[glyph] = params.randomColors[(glyph - 1) % params.randomColors.count]
        }
      }
      for (characters, color) in params.characterColors {
        for glyph in glyphIDs(for: characters, font: ctFont) where !imageGlyphs.contains(glyph) {
          glyphColors[glyph] = color
        }
      }
      for (glyph, value) in glyphColors {
        layersByGlyph[glyph] = [(glyph, paletteIndex(for: parseColor(value)))]
      }
    }

    // Keep the original glyf as the monochrome fallback, and add one outline
    // glyph per retained raster color for COLR/CPAL-capable renderers.
    if !imagesByGlyph.isEmpty {
      let imageLayers = try appendImageLayers(
        to: &tables,
        imagesByGlyph: imagesByGlyph,
        transformsByGlyph: transformsByGlyph,
        font: ctFont
      )
      for (baseGlyph, layers) in imageLayers {
        let mapped = layers.map { layer in
          (glyph: layer.glyph, palette: paletteIndex(for: layer.color))
        }
        if !mapped.isEmpty {
          layersByGlyph[baseGlyph] = mapped
        }
      }
      if let finalMaxp = tables["maxp"]?.data {
        glyphCount = max(1, Int(readUInt16(finalMaxp, 4)))
      }
    }

    if !layersByGlyph.isEmpty && !palette.isEmpty {
      tables["COLR"] = FontTable(tag: "COLR", checksum: 0, data: makeCOLR(layersByGlyph))
      tables["CPAL"] = FontTable(tag: "CPAL", checksum: 0, data: makeCPAL(palette))
    }
    if !imagesByGlyph.isEmpty {
      tables["sbix"] = FontTable(
        tag: "sbix",
        checksum: 0,
        data: makeSBIX(
          imagesByGlyph,
          transformsByGlyph: transformsByGlyph,
          glyphCount: glyphCount,
          font: ctFont,
          unitsPerEm: max(1, Int(cgFont.unitsPerEm))
        )
      )
    }
    if hasReplacements {
      var marker = Data()
      appendUInt16(&marker, 1)
      appendUInt16(&marker, UInt16(baseGlyphCount))
      tables["BSFT"] = FontTable(tag: "BSFT", checksum: 0, data: marker)
    }
    return NativeTTFProcessor.serializeTables(tables, sfntVersion: 0x00010000)
  }

  private static func appendImageLayers(
    to tables: inout [String: FontTable],
    imagesByGlyph: [Int: Data],
    transformsByGlyph: [Int: NativeReplacementTransform],
    font: CTFont
  ) throws -> [Int: [(glyph: Int, color: (UInt8, UInt8, UInt8, UInt8))]] {
    guard var head = tables["head"]?.data,
          var hhea = tables["hhea"]?.data,
          var maxp = tables["maxp"]?.data,
          var hmtx = tables["hmtx"]?.data,
          var loca = tables["loca"]?.data,
          var glyf = tables["glyf"]?.data else { throw NativeFontError.malformedFont }
    let originalCount = Int(readUInt16(maxp, 4))
    let upm = max(1, Int(readUInt16(head, 18)))
    let numberOfHMetrics = max(1, min(Int(readUInt16(hhea, 34)), originalCount))
    var metrics: [(advance: UInt16, bearing: UInt16)] = []
    metrics.reserveCapacity(originalCount + imagesByGlyph.count * 12)
    for glyph in 0..<originalCount {
      let advanceOffset = min(glyph, numberOfHMetrics - 1) * 4
      let bearingOffset = glyph < numberOfHMetrics
        ? advanceOffset + 2
        : numberOfHMetrics * 4 + (glyph - numberOfHMetrics) * 2
      guard advanceOffset + 2 <= hmtx.count,
            bearingOffset + 2 <= hmtx.count else {
        throw NativeFontError.malformedFont
      }
      metrics.append((
        readUInt16(hmtx, advanceOffset),
        readUInt16(hmtx, bearingOffset)
      ))
    }
    let longLoca = Int16(bitPattern: readUInt16(head, 50)) == 1
    var offsets = [Int](repeating: 0, count: originalCount + 1)
    for index in 0...originalCount {
      let offset = index * (longLoca ? 4 : 2)
      offsets[index] = longLoca ? Int(readUInt32(loca, offset)) : Int(readUInt16(loca, offset)) * 2
    }
    var output: [Int: [(glyph: Int, color: (UInt8, UInt8, UInt8, UInt8))]] = [:]
    var glyphCount = originalCount
    var maxSimplePoints = maxp.count >= 8 ? Int(readUInt16(maxp, 6)) : 0
    var maxSimpleContours = maxp.count >= 10 ? Int(readUInt16(maxp, 8)) : 0
    for (baseGlyph, imageData) in imagesByGlyph.sorted(by: { $0.key < $1.key }) {
      let baseMetric = metrics[max(0, min(baseGlyph, originalCount - 1))]
      let targetBox = NativeOutlineFontProcessor.replacementGlyphBox(
        glyph: baseGlyph,
        font: font,
        unitsPerEm: upm
      )
      let rasterLayers = try RasterGlyphConverter.colorLayers(
        from: imageData,
        unitsPerEm: upm,
        targetBox: targetBox,
        transform: transformsByGlyph[baseGlyph] ?? .identity
      )
      guard !rasterLayers.isEmpty else { continue }
      var mapped: [(glyph: Int, color: (UInt8, UInt8, UInt8, UInt8))] = []
      for layer in rasterLayers where glyphCount < 65535 {
        let transformed = layer.contours
        let encoded = CoreTextOutlineConverter.encodeGlyph(transformed)
        guard !encoded.data.isEmpty else { continue }
        let validContours = transformed.filter { $0.count >= 3 }
        maxSimplePoints = max(
          maxSimplePoints,
          validContours.reduce(0) { $0 + $1.count }
        )
        maxSimpleContours = max(maxSimpleContours, validContours.count)
        if glyf.count % 2 != 0 { glyf.append(0) }
        glyf.append(encoded.data)
        if glyf.count % 2 != 0 { glyf.append(0) }
        offsets.append(glyf.count)
        metrics.append(baseMetric)
        mapped.append((glyphCount, layer.color))
        glyphCount += 1
      }
      if !mapped.isEmpty { output[baseGlyph] = mapped }
    }
    if glyphCount == originalCount { return output }
    guard metrics.count == glyphCount, offsets.count == glyphCount + 1 else {
      throw NativeFontError.malformedFont
    }
    loca = Data()
    for offset in offsets { appendUInt32(&loca, UInt32(offset)) }
    hmtx = Data()
    for metric in metrics {
      appendUInt16(&hmtx, metric.advance)
      appendUInt16(&hmtx, metric.bearing)
    }
    writeUInt16(&head, 50, 1)
    writeUInt16(&maxp, 4, UInt16(glyphCount))
    if maxp.count >= 10 {
      writeUInt16(&maxp, 6, UInt16(min(65535, maxSimplePoints)))
      writeUInt16(&maxp, 8, UInt16(min(65535, maxSimpleContours)))
    }
    writeUInt16(&hhea, 34, UInt16(glyphCount))
    tables["head"] = FontTable(tag: "head", checksum: 0, data: head)
    tables["hhea"] = FontTable(tag: "hhea", checksum: 0, data: hhea)
    tables["maxp"] = FontTable(tag: "maxp", checksum: 0, data: maxp)
    tables["hmtx"] = FontTable(tag: "hmtx", checksum: 0, data: hmtx)
    tables["loca"] = FontTable(tag: "loca", checksum: 0, data: loca)
    tables["glyf"] = FontTable(tag: "glyf", checksum: 0, data: glyf)
    return output
  }

  private static func makeCOLR(_ layersByGlyph: [Int: [(glyph: Int, palette: Int)]]) -> Data {
    let records = layersByGlyph.keys.sorted().filter { !(layersByGlyph[$0] ?? []).isEmpty }
    let layerCount = records.reduce(0) { $0 + (layersByGlyph[$1]?.count ?? 0) }
    var table = Data()
    appendUInt16(&table, 0)
    appendUInt16(&table, UInt16(records.count))
    appendUInt32(&table, 14)
    appendUInt32(&table, UInt32(14 + records.count * 6))
    appendUInt16(&table, UInt16(layerCount))
    var firstLayer = 0
    for glyph in records {
      let count = layersByGlyph[glyph]?.count ?? 0
      appendUInt16(&table, UInt16(glyph))
      appendUInt16(&table, UInt16(firstLayer))
      appendUInt16(&table, UInt16(count))
      firstLayer += count
    }
    for glyph in records {
      for layer in layersByGlyph[glyph] ?? [] {
        appendUInt16(&table, UInt16(layer.glyph))
        appendUInt16(&table, UInt16(layer.palette))
      }
    }
    return table
  }

  private static func makeCPAL(_ palette: [(UInt8, UInt8, UInt8, UInt8)]) -> Data {
    var table = Data()
    appendUInt16(&table, 0)
    appendUInt16(&table, UInt16(palette.count))
    appendUInt16(&table, 1)
    appendUInt16(&table, UInt16(palette.count))
    appendUInt32(&table, 14)
    appendUInt16(&table, 0)
    for (red, green, blue, alpha) in palette {
      table.append(blue); table.append(green); table.append(red); table.append(alpha)
    }
    return table
  }

  private static func makeSBIX(
    _ imagesByGlyph: [Int: Data],
    transformsByGlyph: [Int: NativeReplacementTransform],
    glyphCount: Int,
    font: CTFont,
    unitsPerEm: Int
  ) -> Data {
    let strikeSizes = [512, 256, 128, 96, 64, 48, 32]
    let strikeHeaderSize = 4
    let offsetsSize = (glyphCount + 1) * 4
    var strikes: [Data] = []
    for ppem in strikeSizes {
      var strike = Data()
      appendUInt16(&strike, UInt16(ppem))
      appendUInt16(&strike, 72)
      var records = Data()
      var bitmapData = Data()
      var offset = strikeHeaderSize + offsetsSize
      for glyph in 0..<glyphCount {
        appendUInt32(&records, UInt32(offset))
        if let image = imagesByGlyph[glyph] {
          let glyphBox = NativeOutlineFontProcessor.replacementGlyphBox(
            glyph: glyph,
            font: font,
            unitsPerEm: unitsPerEm
          )
          let bitmap = makeSBIXBitmap(
            from: image,
            ppem: ppem,
            transform: transformsByGlyph[glyph] ?? .identity,
            centerX: Double(glyphBox.midX) / Double(unitsPerEm) * 512,
            centerY: Double(glyphBox.midY) / Double(unitsPerEm) * 512
          )
          if let bitmap {
            appendInt16(&bitmapData, bitmap.originX)
            appendInt16(&bitmapData, bitmap.originY)
            bitmapData.append(contentsOf: [0x70, 0x6e, 0x67, 0x20])
            bitmapData.append(bitmap.data)
            offset += 8 + bitmap.data.count
          }
        }
      }
      appendUInt32(&records, UInt32(offset))
      strike.append(records)
      strike.append(bitmapData)
      strikes.append(strike)
    }

    var table = Data()
    appendUInt16(&table, 1)
    // Bit zero is required by the OpenType sbix specification. Keeping bit
    // one clear prevents the monochrome outline from covering the bitmap.
    let sbixFlags: UInt16 = 1
    appendUInt16(&table, sbixFlags)
    appendUInt32(&table, UInt32(strikes.count))
    var strikeOffset = 8 + strikes.count * 4
    for strike in strikes {
      appendUInt32(&table, UInt32(strikeOffset))
      strikeOffset += strike.count
    }
    for strike in strikes { table.append(strike) }
    return table
  }

  private struct SBIXBitmap {
    let data: Data
    let originX: Int16
    let originY: Int16
  }

  private static func makeSBIXBitmap(
    from data: Data,
    ppem: Int,
    transform: NativeReplacementTransform,
    centerX: Double,
    centerY: Double
  ) -> SBIXBitmap? {
    guard let image = UIImage(data: data)?.cgImage else { return nil }
    let sourceImage = UIImage(cgImage: image)
    guard let bounds = bitmapAlphaBounds(sourceImage) else { return nil }
    let workspaceScale = image.width == image.height && image.width >= 1536
      ? Double(image.width) / 512.0
      : 1.0
    let workspace = workspaceScale > 1.0
    let baseScale = workspace
      ? 1.0
      : min(512.0 / Double(image.width), 512.0 / Double(image.height))
    let canvasLeft = workspace
      ? -(Double(image.width) - 512.0) * 0.5
      : (512.0 - Double(image.width) * baseScale) * 0.5
    let canvasBottom = workspace
      ? -(Double(image.height) - 512.0) * 0.5
      : (512.0 - Double(image.height) * baseScale) * 0.5
    let strikeScale = Double(ppem) / 512.0
    let visualScale = max(0.001, transform.scale)
    let baseOriginX = canvasLeft + Double(bounds.minX) * baseScale
    let bottomMargin = Double(image.height) - Double(bounds.maxY)
    let baseOriginY = canvasBottom + bottomMargin * baseScale
    let rawWidth = Double(bounds.width) * baseScale * visualScale
    let fitScale = rawWidth > 512.0 ? 512.0 / rawWidth : 1.0
    let effectiveVisualScale = visualScale * fitScale
    let totalScale = baseScale * strikeScale * effectiveVisualScale
    let outputWidth = max(1, Int(round(Double(bounds.width) * totalScale)))
    let outputHeight = max(1, Int(round(Double(bounds.height) * totalScale)))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let output = UIGraphicsImageRenderer(
      size: CGSize(width: CGFloat(outputWidth), height: CGFloat(outputHeight)),
      format: format
    ).image { _ in
      let drawingScale = CGFloat(totalScale)
      sourceImage.draw(
        in: CGRect(
          x: -bounds.minX * drawingScale,
          y: -bounds.minY * drawingScale,
          width: CGFloat(image.width) * drawingScale,
          height: CGFloat(image.height) * drawingScale
        )
      )
    }
    guard let png = output.pngData() else { return nil }
    let frameMinX = centerX - 256.0
    let frameMaxX = centerX + 256.0
    let width512 = Double(outputWidth) / strikeScale
    var originX512 = centerX + (baseOriginX - centerX) * effectiveVisualScale + transform.x / 100 * 512
    if originX512 < frameMinX { originX512 = frameMinX }
    if originX512 + width512 > frameMaxX { originX512 = frameMaxX - width512 }
    let originX = originX512 * strikeScale
    let originY = (
      centerY + (baseOriginY - centerY) * effectiveVisualScale + transform.y / 100 * 512
    ) * strikeScale
    return SBIXBitmap(
      data: png,
      originX: Int16(max(-32768, min(32767, Int(round(originX))))),
      originY: Int16(max(-32768, min(32767, Int(round(originY)))))
    )
  }

  private static func bitmapAlphaBounds(_ image: UIImage) -> CGRect? {
    guard let cgImage = image.cgImage else { return nil }
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let normalized = UIGraphicsImageRenderer(
      size: CGSize(width: CGFloat(width), height: CGFloat(height)),
      format: format
    ).image { _ in
      image.draw(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    }
    guard let renderedImage = normalized.cgImage else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
          CGBitmapInfo.byteOrder32Big.rawValue
      ) else { return false }
      context.draw(renderedImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
      return true
    }
    guard rendered else { return nil }
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
      for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= 8 {
        minX = min(minX, x); minY = min(minY, y)
        maxX = max(maxX, x); maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    let padding = 1
    minX = max(0, minX - padding); minY = max(0, minY - padding)
    maxX = min(width - 1, maxX + padding); maxY = min(height - 1, maxY + padding)
    return CGRect(
      x: CGFloat(minX),
      y: CGFloat(minY),
      width: CGFloat(maxX - minX + 1),
      height: CGFloat(maxY - minY + 1)
    )
  }

  private static func parseColor(_ value: String) -> (UInt8, UInt8, UInt8, UInt8) {
    let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return (0, 0, 0, 255) }
    return (UInt8((number >> 16) & 255), UInt8((number >> 8) & 255), UInt8(number & 255), 255)
  }

  private static func glyphIDs(for text: String, font: CTFont) -> Set<Int> {
    var output = Set<Int>()
    for scalar in text.unicodeScalars {
      var characters = scalar.value <= 0xffff ? [UniChar(scalar.value)] : [UniChar(0xD800 + ((scalar.value - 0x10000) >> 10)), UniChar(0xDC00 + ((scalar.value - 0x10000) & 0x3ff))]
      var glyphs = [CGGlyph](repeating: 0, count: characters.count)
      if CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) {
        for glyph in glyphs where glyph != 0 { output.insert(Int(glyph)) }
      }
    }
    return output
  }

  private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) << 8 | UInt16(data[offset + 1]) }
  private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 { UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3]) }
  private static func writeUInt16(_ data: inout Data, _ offset: Int, _ value: UInt16) { data[offset] = UInt8((value >> 8) & 255); data[offset + 1] = UInt8(value & 255) }
  private static func appendUInt16(_ data: inout Data, _ value: UInt16) { data.append(UInt8((value >> 8) & 255)); data.append(UInt8(value & 255)) }
  private static func appendInt16(_ data: inout Data, _ value: Int16) { appendUInt16(&data, UInt16(bitPattern: value)) }
  private static func appendUInt32(_ data: inout Data, _ value: UInt32) { data.append(UInt8((value >> 24) & 255)); data.append(UInt8((value >> 16) & 255)); data.append(UInt8((value >> 8) & 255)); data.append(UInt8(value & 255)) }
}

private enum NativeNameFontProcessor {
  static func apply(data: Data, family: String, subfamily: String, fullName: String, postScript: String) throws -> Data {
    let unique = "\(postScript);\(Int(Date().timeIntervalSince1970))"
    let values: [(UInt16, String)] = [(1, family), (2, subfamily), (3, unique), (4, fullName), (6, postScript), (16, family), (17, subfamily)]
    let encoded = values.map { (id: $0.0, data: utf16BE($0.1)) }
    let headerSize = 6 + encoded.count * 12
    var table = Data()
    appendUInt16(&table, 0); appendUInt16(&table, UInt16(encoded.count)); appendUInt16(&table, UInt16(headerSize))
    var offset = 0
    for record in encoded {
      appendUInt16(&table, 3); appendUInt16(&table, 1); appendUInt16(&table, 0x0409)
      appendUInt16(&table, record.id); appendUInt16(&table, UInt16(record.data.count)); appendUInt16(&table, UInt16(offset))
      offset += record.data.count
    }
    for record in encoded { table.append(record.data) }
    var tables = try NativeTTFProcessor.readTables(data)
    tables["name"] = FontTable(tag: "name", checksum: 0, data: table)
    return NativeTTFProcessor.serializeTables(tables, sfntVersion: 0x00010000)
  }

  private static func utf16BE(_ value: String) -> Data {
    var data = Data()
    for unit in value.utf16 { data.append(UInt8((unit >> 8) & 255)); data.append(UInt8(unit & 255)) }
    return data
  }
  private static func appendUInt16(_ data: inout Data, _ value: UInt16) { data.append(UInt8((value >> 8) & 255)); data.append(UInt8(value & 255)) }
}

private struct OutlinePoint {
  var x: Int
  var y: Int
  var onCurve: Bool
}

private struct RasterColorLayer {
  let color: (UInt8, UInt8, UInt8, UInt8)
  let contours: [[OutlinePoint]]
  let sourceWidth: Int
  let sourceHeight: Int
}

private enum RasterGlyphConverter {
  private struct ColorSample {
    let red: Double
    let green: Double
    let blue: Double
  }

  static func contours(from data: Data, unitsPerEm: Int) throws -> [[OutlinePoint]] {
    let canvasScale = sourceCanvasScale(data)
    let dimension = rasterDimension(base: 256, canvasScale: canvasScale)
    let raster = try rasterSamples(from: data, dimension: dimension)
    var samples = raster.samples
    let preserveBitmap = preservesOpaqueArtwork(data, samples: samples, width: dimension, height: dimension)
    if !preserveBitmap,
       let background = raster.background {
      removeConnectedBackground(
        &samples,
        color: background,
        width: dimension,
        height: dimension
      )
    }
    let mask = cleanMask(
      preserveBitmap ? alphaFallbackMask(samples) : monochromeFallbackMask(samples),
      width: dimension,
      height: dimension
    )
    var sourceContours = traceContours(mask, width: dimension, height: dimension)
    if sourceContours.isEmpty, preserveBitmap {
      sourceContours = traceContours(
        cleanMask(alphaFallbackMask(samples), width: dimension, height: dimension),
        width: dimension,
        height: dimension
      )
    }
    return mapContours(
      sourceContours,
      sourceWidth: dimension,
      sourceHeight: dimension,
      targetBox: CGRect(x: 0, y: 0, width: CGFloat(unitsPerEm), height: CGFloat(unitsPerEm)),
      userScale: canvasScale,
      offsetX: 0,
      offsetY: 0
    )
  }

  static func contours(
    from data: Data,
    unitsPerEm: Int,
    glyphBox: CGRect,
    userScale: Double,
    offsetX: Double,
    offsetY: Double
  ) throws -> [[OutlinePoint]] {
    let canvasScale = sourceCanvasScale(data)
    let dimension = rasterDimension(base: 256, canvasScale: canvasScale)
    let raster = try rasterSamples(from: data, dimension: dimension)
    var samples = raster.samples
    let preserveBitmap = preservesOpaqueArtwork(data, samples: samples, width: dimension, height: dimension)
    if !preserveBitmap,
       let background = raster.background {
      removeConnectedBackground(&samples, color: background, width: dimension, height: dimension)
    }
    let mask = cleanMask(
      preserveBitmap ? alphaFallbackMask(samples) : monochromeFallbackMask(samples),
      width: dimension,
      height: dimension
    )
    var sourceContours = traceContours(mask, width: dimension, height: dimension)
    if sourceContours.isEmpty, preserveBitmap {
      sourceContours = traceContours(
        cleanMask(alphaFallbackMask(samples), width: dimension, height: dimension),
        width: dimension,
        height: dimension
      )
    }
    return mapContours(
      sourceContours,
      sourceWidth: dimension,
      sourceHeight: dimension,
      targetBox: glyphBox,
      userScale: userScale * canvasScale,
      offsetX: offsetX,
      offsetY: offsetY
    )
  }

  static func colorLayers(
    from data: Data,
    unitsPerEm: Int,
    targetBox: CGRect,
    transform: NativeReplacementTransform
  ) throws -> [RasterColorLayer] {
    let canvasScale = sourceCanvasScale(data)
    let dimension = rasterDimension(
      base: 192,
      canvasScale: canvasScale
    )
    let raster = try rasterSamples(from: data, dimension: dimension)
    var samples = raster.samples
    let preserveBitmap = preservesOpaqueArtwork(
      data,
      samples: samples,
      width: dimension,
      height: dimension
    )
    if !preserveBitmap, let background = raster.background {
      removeConnectedBackground(&samples, color: background, width: dimension, height: dimension)
    }
    if preserveBitmap { return [] }
    var histogram: [Int: (red: Double, green: Double, blue: Double, count: Int)] = [:]
    for index in samples.indices {
      guard let sample = samples[index] else { continue }
      let key = (Int(sample.red) >> 3) << 10 | (Int(sample.green) >> 3) << 5 | (Int(sample.blue) >> 3)
      let old = histogram[key] ?? (0, 0, 0, 0)
      histogram[key] = (old.red + sample.red, old.green + sample.green, old.blue + sample.blue, old.count + 1)
    }
    let foregroundCount = samples.compactMap { $0 }.count
    guard foregroundCount > 0 else { return [] }
    if isGrayscaleImage(samples, foregroundCount: foregroundCount) { return [] }

    let ranked = histogram.values.sorted { $0.count > $1.count }
    var centers: [ColorSample] = []
    for bin in ranked {
      let candidate = ColorSample(
        red: bin.red / Double(bin.count),
        green: bin.green / Double(bin.count),
        blue: bin.blue / Double(bin.count)
      )
      if centers.allSatisfy({ colorDistance($0, candidate) >= 18 }) {
        centers.append(candidate)
      }
      if centers.count == 12 { break }
    }
    if centers.isEmpty, let first = ranked.first {
      centers = [ColorSample(red: first.red / Double(first.count), green: first.green / Double(first.count), blue: first.blue / Double(first.count))]
    }

    var labels = [Int](repeating: -1, count: samples.count)
    var counts = [Int](repeating: 0, count: centers.count)
    for _ in 0..<8 {
      var sums = Array(repeating: (red: 0.0, green: 0.0, blue: 0.0, count: 0), count: centers.count)
      for index in samples.indices {
        guard let sample = samples[index] else { continue }
        let label = nearestCenter(sample, centers: centers)
        labels[index] = label
        sums[label].red += sample.red
        sums[label].green += sample.green
        sums[label].blue += sample.blue
        sums[label].count += 1
      }
      for index in centers.indices where sums[index].count > 0 {
        centers[index] = ColorSample(
          red: sums[index].red / Double(sums[index].count),
          green: sums[index].green / Double(sums[index].count),
          blue: sums[index].blue / Double(sums[index].count)
        )
      }
      counts = sums.map(\.count)
    }

    let minimumPixels = max(8, Int(Double(foregroundCount) * 0.0015))
    let retained = centers.indices.filter { counts[$0] >= minimumPixels }
    guard !retained.isEmpty else { return [] }
    for index in samples.indices where labels[index] >= 0 && !retained.contains(labels[index]) {
      guard let sample = samples[index] else { continue }
      labels[index] = retained.min(by: {
        colorDistance(sample, centers[$0]) < colorDistance(sample, centers[$1])
      }) ?? retained[0]
    }

    var output: [RasterColorLayer] = []
    for label in retained.sorted(by: { counts[$0] > counts[$1] }) {
      let selectedMask = labels.map { $0 == label }
      let mask = cleanMask(selectedMask, width: dimension, height: dimension)
      let layerContours = traceContours(mask, width: dimension, height: dimension)
      guard !layerContours.isEmpty else { continue }
      let center = centers[label]
      let mappedContours = mapContours(
        layerContours,
        sourceWidth: dimension,
        sourceHeight: dimension,
        targetBox: targetBox,
        userScale: canvasScale * transform.scale,
        offsetX: transform.x / 100 * Double(unitsPerEm),
        offsetY: transform.y / 100 * Double(unitsPerEm)
      )
      guard !mappedContours.isEmpty else { continue }
      output.append(RasterColorLayer(
        color: (
          UInt8(max(0, min(255, center.red.rounded()))),
          UInt8(max(0, min(255, center.green.rounded()))),
          UInt8(max(0, min(255, center.blue.rounded()))),
          255
        ),
        contours: mappedContours,
        sourceWidth: dimension,
        sourceHeight: dimension
      ))
    }
    return output
  }

  private static func monochromeFallbackMask(
    _ samples: [ColorSample?]
  ) -> [Bool] {
    let colors = samples.compactMap { $0 }
    guard !colors.isEmpty else { return Array(repeating: false, count: samples.count) }
    if isGrayscaleImage(samples, foregroundCount: colors.count) {
      return samples.map { $0 != nil }
    }
    let luminance = colors.map {
      $0.red * 0.2126 + $0.green * 0.7152 + $0.blue * 0.0722
    }.sorted()
    let percentile = luminance[min(luminance.count - 1, luminance.count / 3)]
    let threshold = max(72.0, min(150.0, percentile))
    return samples.map { sample in
      guard let sample else { return false }
      return sample.red * 0.2126 + sample.green * 0.7152 + sample.blue * 0.0722 <= threshold
    }
  }

  private static func alphaFallbackMask(
    _ samples: [ColorSample?]
  ) -> [Bool] {
    samples.map { $0 != nil }
  }

  private static func sourceCanvasScale(_ data: Data) -> Double {
    guard let image = UIImage(data: data)?.cgImage else { return 1 }
    guard image.width == image.height, image.width >= 1536 else { return 1 }
    return Double(image.width) / 512.0
  }

  private static func preservesOpaqueArtwork(
    _ data: Data,
    samples: [ColorSample?],
    width: Int,
    height: Int
  ) -> Bool {
    guard sourceCanvasScale(data) > 1 else { return false }
    return opaqueBounds(samples, width: width, height: height) != nil
  }

  private static func rasterDimension(base: Int, canvasScale: Double) -> Int {
    max(base, min(1024, Int(round(Double(base) * canvasScale))))
  }

  private static func cleanMask(_ input: [Bool], width: Int, height: Int) -> [Bool] {
    guard input.count == width * height else { return input }
    var output = input
    for _ in 0..<2 {
      var next = output
      for y in 0..<height {
        for x in 0..<width {
          let index = y * width + x
          guard output[index] else { continue }
          var neighbours = 0
          for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
              let nx = x + dx
              let ny = y + dy
              if nx >= 0, nx < width, ny >= 0, ny < height,
                 output[ny * width + nx] { neighbours += 1 }
            }
          }
          if neighbours == 0 { next[index] = false }
        }
      }
      output = next
    }
    return output
  }

  private static func traceContours(
    _ mask: [Bool],
    width: Int,
    height: Int
  ) -> [[OutlinePoint]] {
    guard mask.count == width * height else { return [] }
    func key(_ x: Int, _ y: Int) -> Int64 {
      (Int64(x + 1) << 32) | Int64(UInt32(y + 1))
    }
    func point(_ value: Int64) -> OutlinePoint {
      OutlinePoint(
        x: Int(Int32(truncatingIfNeeded: value >> 32)) - 1,
        y: Int(Int32(truncatingIfNeeded: value & 0xffffffff)) - 1,
        onCurve: true
      )
    }
    var edges: [Int64: [Int64]] = [:]
    func addEdge(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
      edges[key(x0, y0), default: []].append(key(x1, y1))
    }
    for y in 0..<height {
      for x in 0..<width where mask[y * width + x] {
        if y == 0 || !mask[(y - 1) * width + x] { addEdge(x, y, x + 1, y) }
        if x + 1 == width || !mask[y * width + x + 1] { addEdge(x + 1, y, x + 1, y + 1) }
        if y + 1 == height || !mask[(y + 1) * width + x] { addEdge(x + 1, y + 1, x, y + 1) }
        if x == 0 || !mask[y * width + x - 1] { addEdge(x, y + 1, x, y) }
      }
    }

    var output: [[OutlinePoint]] = []
    while let start = edges.first(where: { !$0.value.isEmpty })?.key {
      var contour: [OutlinePoint] = []
      var current = start
      var guardCount = 0
      while guardCount <= width * height * 4 {
        guard var candidates = edges[current], !candidates.isEmpty else { break }
        let next = candidates.removeLast()
        edges[current] = candidates
        contour.append(point(current))
        current = next
        guardCount += 1
        if current == start { break }
      }
      if contour.count >= 3 {
        let epsilon = max(1.0, Double(max(width, height)) / 256.0)
        let simplified = rdpSimplify(contour, epsilon: epsilon)
        if simplified.count >= 3 { output.append(simplified) }
      }
    }
    return normalizeContourWinding(output)
  }

  private static func rdpSimplify(_ points: [OutlinePoint], epsilon: Double) -> [OutlinePoint] {
    guard points.count > 3 else { return points }
    let closed = points + [points[0]]
    func distance(_ point: OutlinePoint, _ start: OutlinePoint, _ end: OutlinePoint) -> Double {
      let px = Double(point.x), py = Double(point.y)
      let sx = Double(start.x), sy = Double(start.y)
      let ex = Double(end.x), ey = Double(end.y)
      let dx = ex - sx, dy = ey - sy
      if dx == 0, dy == 0 { return hypot(px - sx, py - sy) }
      let t = max(0, min(1, ((px - sx) * dx + (py - sy) * dy) / (dx * dx + dy * dy)))
      return hypot(px - (sx + t * dx), py - (sy + t * dy))
    }
    func simplify(_ values: ArraySlice<OutlinePoint>) -> [OutlinePoint] {
      guard values.count > 2, let first = values.first, let last = values.last else { return Array(values) }
      var farthest = 0.0
      var index = values.startIndex
      var candidateIndex = values.index(after: values.startIndex)
      while candidateIndex < values.index(before: values.endIndex) {
        let candidate = values[candidateIndex]
        let value = distance(candidate, first, last)
        if value > farthest {
          farthest = value
          index = candidateIndex
        }
        candidateIndex = values.index(after: candidateIndex)
      }
      guard farthest > epsilon else { return [first, last] }
      let left = simplify(values[...index])
      let right = simplify(values[index...])
      return Array(left.dropLast()) + right
    }
    var result = simplify(ArraySlice(closed))
    if result.last?.x == result.first?.x, result.last?.y == result.first?.y { result.removeLast() }
    return result.count >= 3 ? result : points
  }

  private static func mapContours(
    _ contours: [[OutlinePoint]],
    sourceWidth: Int,
    sourceHeight: Int,
    targetBox: CGRect,
    userScale: Double,
    offsetX: Double,
    offsetY: Double
  ) -> [[OutlinePoint]] {
    let targetHeight = max(1.0, Double(targetBox.height))
    let targetWidth = max(1.0, Double(targetBox.width))
    let heightScale = targetHeight / (0.8 * Double(max(1, sourceHeight)))
    let widthScale = targetWidth / Double(max(1, sourceWidth))
    // Fit the unscaled image inside both glyph dimensions. User scaling can
    // still enlarge it intentionally, but the default value cannot crop it.
    let scale = max(0.001, userScale) * min(heightScale, widthScale)
    let centerX = Double(targetBox.midX)
    let centerY = Double(targetBox.midY)
    let sourceCenterX = Double(sourceWidth) * 0.5
    let sourceCenterY = Double(sourceHeight) * 0.5
    let mapped = contours.map { contour in
      contour.map { point in
        OutlinePoint(
          x: clamp(Int(round(centerX + (Double(point.x) - sourceCenterX) * scale + offsetX))),
          y: clamp(Int(round(centerY - (Double(point.y) - sourceCenterY) * scale + offsetY))),
          onCurve: true
        )
      }
    }
    return normalizeContourWinding(fitContoursInsideTargetBox(mapped, targetBox: targetBox))
  }

  private static func fitContoursInsideTargetBox(
    _ contours: [[OutlinePoint]],
    targetBox: CGRect
  ) -> [[OutlinePoint]] {
    let points = contours.flatMap { $0 }
    guard !points.isEmpty else { return contours }
    let targetMinX = Double(targetBox.minX)
    let targetMaxX = Double(targetBox.maxX)
    let targetMinY = Double(targetBox.minY)
    let targetMaxY = Double(targetBox.maxY)
    let minX = Double(points.map(\.x).min() ?? 0)
    let maxX = Double(points.map(\.x).max() ?? 0)
    let minY = Double(points.map(\.y).min() ?? 0)
    let maxY = Double(points.map(\.y).max() ?? 0)
    let width = max(1.0, maxX - minX)
    let height = max(1.0, maxY - minY)
    let targetWidth = max(1.0, targetMaxX - targetMinX)
    let targetHeight = max(1.0, targetMaxY - targetMinY)
    let scale = min(1.0, min(targetWidth / width, targetHeight / height))
    let centerX = (minX + maxX) * 0.5
    let centerY = (minY + maxY) * 0.5
    let scaledMinX = centerX + (minX - centerX) * scale
    let scaledMaxX = centerX + (maxX - centerX) * scale
    let scaledMinY = centerY + (minY - centerY) * scale
    let scaledMaxY = centerY + (maxY - centerY) * scale
    var dx = 0.0
    var dy = 0.0
    if scaledMinX < targetMinX { dx = targetMinX - scaledMinX }
    if scaledMaxX + dx > targetMaxX { dx = targetMaxX - scaledMaxX }
    if scaledMinY < targetMinY { dy = targetMinY - scaledMinY }
    if scaledMaxY + dy > targetMaxY { dy = targetMaxY - scaledMaxY }
    return contours.map { contour in
      contour.map { point in
        OutlinePoint(
          x: clamp(Int(round(centerX + (Double(point.x) - centerX) * scale + dx))),
          y: clamp(Int(round(centerY + (Double(point.y) - centerY) * scale + dy))),
          onCurve: point.onCurve
        )
      }
    }
  }

  private static func clamp(_ value: Int) -> Int {
    max(-32768, min(32767, value))
  }

  private static func isGrayscaleImage(
    _ samples: [ColorSample?],
    foregroundCount: Int
  ) -> Bool {
    let colors = samples.compactMap { $0 }
    let neutralCount = colors.reduce(0) { count, sample in
      let high = max(sample.red, max(sample.green, sample.blue))
      let low = min(sample.red, min(sample.green, sample.blue))
      return count + (high - low <= 18 ? 1 : 0)
    }
    return foregroundCount > 0 && neutralCount * 100 >= foregroundCount * 98
  }

  private static func rasterSamples(
    from data: Data,
    dimension: Int
  ) throws -> (samples: [ColorSample?], background: ColorSample?) {
    guard let image = UIImage(data: data) else { throw NativeFontError.malformedFont }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let normalized = UIGraphicsImageRenderer(
      size: CGSize(width: dimension, height: dimension),
      format: format
    ).image { _ in
      image.draw(in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
    }
    guard let source = normalized.cgImage else { throw NativeFontError.malformedFont }
    var pixels = [UInt8](repeating: 0, count: dimension * dimension * 4)
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress,
        width: dimension,
        height: dimension,
        bitsPerComponent: 8,
        bytesPerRow: dimension * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        // Use an explicit little-endian BGRA buffer. This keeps the byte
        // order deterministic on both simulator and device.
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
      ) else { return false }
      context.draw(source, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
      return true
    }
    guard rendered else { throw NativeFontError.malformedFont }
    var samples: [ColorSample?] = Array(repeating: nil, count: dimension * dimension)
    for index in samples.indices {
      let offset = index * 4
      let alpha = Int(pixels[offset + 3])
      guard alpha >= 24 else { continue }
      let factor = 255.0 / Double(alpha)
      // The explicit bitmap format above stores bytes as BGRA. Unpremultiply
      // them after reading so CPAL receives the original RGB values.
      samples[index] = ColorSample(
        red: min(255, Double(pixels[offset + 2]) * factor),
        green: min(255, Double(pixels[offset + 1]) * factor),
        blue: min(255, Double(pixels[offset]) * factor)
      )
    }
    return (samples, dominantEdgeBackground(samples, width: dimension, height: dimension))
  }

  private static func dominantEdgeBackground(
    _ samples: [ColorSample?],
    width: Int,
    height: Int
  ) -> ColorSample? {
    guard let bounds = opaqueBounds(samples, width: width, height: height) else { return nil }
    var edgeIndices: [Int] = []
    edgeIndices.reserveCapacity((bounds.maxX - bounds.minX + bounds.maxY - bounds.minY + 2) * 2)
    for x in bounds.minX...bounds.maxX {
      edgeIndices.append(bounds.minY * width + x)
      if bounds.maxY != bounds.minY { edgeIndices.append(bounds.maxY * width + x) }
    }
    if bounds.maxY - bounds.minY > 1 {
      for y in (bounds.minY + 1)..<bounds.maxY {
        edgeIndices.append(y * width + bounds.minX)
        if bounds.maxX != bounds.minX { edgeIndices.append(y * width + bounds.maxX) }
      }
    }
    var bins: [Int: (red: Double, green: Double, blue: Double, count: Int)] = [:]
    var opaqueCount = 0
    for index in edgeIndices {
      guard let sample = samples[index] else { continue }
      opaqueCount += 1
      let key = (Int(sample.red) >> 4) << 8 | (Int(sample.green) >> 4) << 4 | (Int(sample.blue) >> 4)
      let old = bins[key] ?? (0, 0, 0, 0)
      bins[key] = (old.red + sample.red, old.green + sample.green, old.blue + sample.blue, old.count + 1)
    }
    guard opaqueCount >= edgeIndices.count / 2,
          let dominant = bins.values.max(by: { $0.count < $1.count }),
          dominant.count >= opaqueCount / 2 else { return nil }
    return ColorSample(
      red: dominant.red / Double(dominant.count),
      green: dominant.green / Double(dominant.count),
      blue: dominant.blue / Double(dominant.count)
    )
  }

  private static func opaqueBounds(
    _ samples: [ColorSample?],
    width: Int,
    height: Int
  ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
    var minX = width, minY = height, maxX = -1, maxY = -1
    for index in samples.indices where samples[index] != nil {
      let x = index % width
      let y = index / width
      minX = min(minX, x); minY = min(minY, y)
      maxX = max(maxX, x); maxY = max(maxY, y)
    }
    return maxX >= minX && maxY >= minY ? (minX, minY, maxX, maxY) : nil
  }

  private static func removeConnectedBackground(
    _ samples: inout [ColorSample?],
    color: ColorSample,
    width: Int,
    height: Int
  ) {
    var working = samples
    var queued = [Bool](repeating: false, count: working.count)
    var queue: [Int] = []
    func enqueue(_ index: Int) {
      guard !queued[index], let sample = working[index], colorDistance(sample, color) < 32 else { return }
      queued[index] = true
      queue.append(index)
    }
    guard let bounds = opaqueBounds(working, width: width, height: height) else { return }
    for x in bounds.minX...bounds.maxX {
      enqueue(bounds.minY * width + x)
      enqueue(bounds.maxY * width + x)
    }
    if bounds.maxY - bounds.minY > 1 {
      for y in (bounds.minY + 1)..<bounds.maxY {
        enqueue(y * width + bounds.minX)
        enqueue(y * width + bounds.maxX)
      }
    }
    var cursor = 0
    while cursor < queue.count {
      let index = queue[cursor]
      cursor += 1
      let x = index % width
      let y = index / width
      if x > 0 { enqueue(index - 1) }
      if x + 1 < width { enqueue(index + 1) }
      if y > 0 { enqueue(index - width) }
      if y + 1 < height { enqueue(index + width) }
      working[index] = nil
    }
    samples = working
  }

  private static func nearestCenter(_ sample: ColorSample, centers: [ColorSample]) -> Int {
    var best = 0
    var bestDistance = Double.greatestFiniteMagnitude
    for index in centers.indices {
      let distance = colorDistance(sample, centers[index])
      if distance < bestDistance { best = index; bestDistance = distance }
    }
    return best
  }

  private static func colorDistance(_ lhs: ColorSample, _ rhs: ColorSample) -> Double {
    let red = lhs.red - rhs.red
    let green = lhs.green - rhs.green
    let blue = lhs.blue - rhs.blue
    return sqrt(red * red * 0.30 + green * green * 0.59 + blue * blue * 0.11)
  }

  private static func normalizeContourWinding(
    _ contours: [[OutlinePoint]]
  ) -> [[OutlinePoint]] {
    let areas = contours.map(signedArea)
    return contours.indices.map { index in
      let contour = contours[index]
      guard contour.count >= 3, let sample = contour.first else { return contour }
      let depth = contours.indices.reduce(0) { value, otherIndex in
        guard otherIndex != index,
              abs(areas[otherIndex]) > abs(areas[index]),
              contains(sample, in: contours[otherIndex]) else { return value }
        return value + 1
      }
      let shouldBeClockwise = depth.isMultiple(of: 2)
      let isClockwise = areas[index] < 0
      return shouldBeClockwise == isClockwise ? contour : Array(contour.reversed())
    }
  }

  private static func signedArea(_ contour: [OutlinePoint]) -> Double {
    guard contour.count >= 3 else { return 0 }
    return contour.indices.reduce(0.0) { area, index in
      let point = contour[index]
      let next = contour[(index + 1) % contour.count]
      return area + Double(point.x * next.y - next.x * point.y) * 0.5
    }
  }

  private static func contains(
    _ point: OutlinePoint,
    in contour: [OutlinePoint]
  ) -> Bool {
    guard contour.count >= 3 else { return false }
    let x = Double(point.x) + 0.125
    let y = Double(point.y) + 0.125
    var inside = false
    var previous = contour.last!
    for current in contour {
      let currentY = Double(current.y)
      let previousY = Double(previous.y)
      if (currentY > y) != (previousY > y) {
        let crossing = Double(previous.x - current.x) * (y - currentY) /
          (previousY - currentY) + Double(current.x)
        if x < crossing { inside.toggle() }
      }
      previous = current
    }
    return inside
  }
}

private final class PathCollector {
  var contours: [[OutlinePoint]] = []
  var current: [OutlinePoint] = []
  var cursor = CGPoint.zero

  func move(to point: CGPoint) {
    finishContour()
    cursor = point
    current = [outlinePoint(point)]
  }

  func line(to point: CGPoint) {
    cursor = point
    current.append(outlinePoint(point))
  }

  func quad(control: CGPoint, end: CGPoint) {
    current.append(outlinePoint(control, onCurve: false))
    current.append(outlinePoint(end))
    cursor = end
  }

  func cubic(control1: CGPoint, control2: CGPoint, end: CGPoint) {
    let start = cursor
    let steps = max(1, min(12, Int(ceil(curveLength([start, control1, control2, end]) / 180))))
    var segmentStart = start
    for index in 0..<steps {
      let t0 = CGFloat(index) / CGFloat(steps)
      let t1 = CGFloat(index + 1) / CGFloat(steps)
      let segmentEnd = cubicPoint(start, control1, control2, end, t1)
      let middle = cubicPoint(start, control1, control2, end, (t0 + t1) / 2)
      let quadraticControl = CGPoint(
        x: 2 * middle.x - (segmentStart.x + segmentEnd.x) / 2,
        y: 2 * middle.y - (segmentStart.y + segmentEnd.y) / 2
      )
      current.append(outlinePoint(quadraticControl, onCurve: false))
      current.append(outlinePoint(segmentEnd))
      segmentStart = segmentEnd
    }
    cursor = end
  }

  func close() {
    finishContour()
  }

  func finish() -> [[OutlinePoint]] {
    finishContour()
    return contours
  }

  private func finishContour() {
    guard current.count >= 3 else {
      current.removeAll(keepingCapacity: true)
      return
    }
    if current.first?.x == current.last?.x && current.first?.y == current.last?.y {
      current.removeLast()
    }
    if current.count >= 3 { contours.append(simplify(current)) }
    current.removeAll(keepingCapacity: true)
  }

  private func simplify(_ points: [OutlinePoint]) -> [OutlinePoint] {
    guard points.count > 3, points.allSatisfy(\.onCurve) else { return points }
    var output: [OutlinePoint] = []
    for index in points.indices {
      let previous = points[(index - 1 + points.count) % points.count]
      let point = points[index]
      let next = points[(index + 1) % points.count]
      let cross = (point.x - previous.x) * (next.y - point.y) - (point.y - previous.y) * (next.x - point.x)
      if abs(cross) > 1 || output.isEmpty { output.append(point) }
    }
    return output.count >= 3 ? output : points
  }

  private func curveLength(_ points: [CGPoint]) -> CGFloat {
    var length: CGFloat = 0
    for index in 1..<points.count {
      length += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
    }
    return length
  }

  private func cubicPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
    let mt = 1 - t
    return CGPoint(
      x: mt * mt * mt * p0.x + 3 * mt * mt * t * p1.x + 3 * mt * t * t * p2.x + t * t * t * p3.x,
      y: mt * mt * mt * p0.y + 3 * mt * mt * t * p1.y + 3 * mt * t * t * p2.y + t * t * t * p3.y
    )
  }

  private func outlinePoint(_ point: CGPoint, onCurve: Bool = true) -> OutlinePoint {
    OutlinePoint(x: clamp(Int(round(point.x))), y: clamp(Int(round(point.y))), onCurve: onCurve)
  }

  private func clamp(_ value: Int) -> Int {
    max(-32768, min(32767, value))
  }
}

private enum CoreTextOutlineConverter {
  static func convert(data: Data, selectedCharacters: String, characterAdjustments: [String: NativeGlyphAdjustment], replacements: [String: Data]) throws -> (data: Data, selectedGlyphs: Set<Int>, glyphAdjustments: [Int: NativeGlyphAdjustment]) {
    guard let provider = CGDataProvider(data: data as CFData),
          let cgFont = CGFont(provider) else {
      throw NativeFontError.unsupportedFont
    }
    var tables = try NativeTTFProcessor.readTables(data)
    guard let maxp = tables["maxp"], let head = tables["head"], let hhea = tables["hhea"] else {
      throw NativeFontError.malformedFont
    }
    let numGlyphs = max(1, Int(readUInt16(maxp.data, 4)))
    let unitsPerEm = max(1, Int(cgFont.unitsPerEm))
    let ctFont = CTFontCreateWithGraphicsFont(cgFont, CGFloat(unitsPerEm), nil, nil)
    let selectedGlyphs = glyphIDs(for: selectedCharacters, font: ctFont)
    var glyphAdjustments: [Int: NativeGlyphAdjustment] = [:]
    for (characters, adjustment) in characterAdjustments {
      for glyph in glyphIDs(for: characters, font: ctFont) { glyphAdjustments[glyph] = adjustment }
    }
    var replacementContours: [Int: [[OutlinePoint]]] = [:]
    for (characters, imageData) in replacements {
      let contours = try RasterGlyphConverter.contours(from: imageData, unitsPerEm: unitsPerEm)
      for glyph in glyphIDs(for: characters, font: ctFont) { replacementContours[glyph] = contours }
    }
    var offsets: [Int] = [0]
    var glyf = Data()
    var hmtx = Data()
    var globalMinX = Int.max
    var globalMinY = Int.max
    var globalMaxX = Int.min
    var globalMaxY = Int.min
    var advanceMax = 0

    for index in 0..<numGlyphs {
      let glyph = CGGlyph(index)
      let contours = replacementContours[index] ?? collectContours(CTFontCreatePathForGlyph(ctFont, glyph, nil))
      let encoded = encodeGlyph(contours)
      glyf.append(encoded.data)
      if glyf.count % 2 != 0 { glyf.append(0) }
      offsets.append(glyf.count)

      var mutableGlyph = glyph
      var advance = CGSize.zero
      withUnsafePointer(to: &mutableGlyph) { glyphPointer in
        withUnsafeMutablePointer(to: &advance) { advancePointer in
          _ = CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphPointer, advancePointer, 1)
        }
      }
      let width = max(0, min(65535, Int(round(advance.width))))
      advanceMax = max(advanceMax, width)
      appendUInt16(&hmtx, UInt16(width))
      appendInt16(&hmtx, Int16(clamp(encoded.minX)))
      if !contours.isEmpty {
        globalMinX = min(globalMinX, encoded.minX)
        globalMinY = min(globalMinY, encoded.minY)
        globalMaxX = max(globalMaxX, encoded.maxX)
        globalMaxY = max(globalMaxY, encoded.maxY)
      }
    }

    var loca = Data()
    for offset in offsets { appendUInt32(&loca, UInt32(offset)) }
    var newHead = head.data
    writeUInt16(&newHead, 18, UInt16(min(65535, unitsPerEm)))
    writeInt16(&newHead, 36, globalMinX == Int.max ? 0 : globalMinX)
    writeInt16(&newHead, 38, globalMinY == Int.max ? 0 : globalMinY)
    writeInt16(&newHead, 40, globalMaxX == Int.min ? 0 : globalMaxX)
    writeInt16(&newHead, 42, globalMaxY == Int.min ? 0 : globalMaxY)
    writeInt16(&newHead, 50, 1)

    var newHhea = hhea.data
    writeUInt16(&newHhea, 10, UInt16(min(65535, advanceMax)))
    writeUInt16(&newHhea, 34, UInt16(min(65535, numGlyphs)))
    var newMaxp = Data(repeating: 0, count: 32)
    writeUInt32(&newMaxp, 0, 0x00010000)
    writeUInt16(&newMaxp, 4, UInt16(min(65535, numGlyphs)))

    tables.removeValue(forKey: "CFF ")
    tables.removeValue(forKey: "CFF2")
    tables["head"] = FontTable(tag: "head", checksum: 0, data: newHead)
    tables["hhea"] = FontTable(tag: "hhea", checksum: 0, data: newHhea)
    tables["hmtx"] = FontTable(tag: "hmtx", checksum: 0, data: hmtx)
    tables["maxp"] = FontTable(tag: "maxp", checksum: 0, data: newMaxp)
    tables["glyf"] = FontTable(tag: "glyf", checksum: 0, data: glyf)
    tables["loca"] = FontTable(tag: "loca", checksum: 0, data: loca)
    return (NativeTTFProcessor.serializeTables(tables, sfntVersion: 0x00010000), selectedGlyphs, glyphAdjustments)
  }

  private static func glyphIDs(for text: String, font: CTFont) -> Set<Int> {
    guard !text.isEmpty else { return [] }
    var output = Set<Int>()
    for scalar in text.unicodeScalars {
      var characters: [UniChar]
      if scalar.value <= 0xffff {
        characters = [UniChar(scalar.value)]
      } else {
        let value = scalar.value - 0x10000
        characters = [UniChar(0xD800 + (value >> 10)), UniChar(0xDC00 + (value & 0x3ff))]
      }
      var glyphs = [CGGlyph](repeating: 0, count: characters.count)
      let mapped = characters.withUnsafeBufferPointer { characterPointer in
        glyphs.withUnsafeMutableBufferPointer { glyphPointer in
          CTFontGetGlyphsForCharacters(font, characterPointer.baseAddress!, glyphPointer.baseAddress!, characters.count)
        }
      }
      if mapped {
        for glyph in glyphs where glyph != 0 { output.insert(Int(glyph)) }
      }
    }
    return output
  }

  private static func collectContours(_ path: CGPath?) -> [[OutlinePoint]] {
    guard let path else { return [] }
    let collector = PathCollector()
    path.applyWithBlock { elementPointer in
      let element = elementPointer.pointee
      switch element.type {
      case .moveToPoint: collector.move(to: element.points[0])
      case .addLineToPoint: collector.line(to: element.points[0])
      case .addQuadCurveToPoint: collector.quad(control: element.points[0], end: element.points[1])
      case .addCurveToPoint: collector.cubic(control1: element.points[0], control2: element.points[1], end: element.points[2])
      case .closeSubpath: collector.close()
      @unknown default: break
      }
    }
    return collector.finish()
  }

  fileprivate static func encodeGlyph(_ contours: [[OutlinePoint]]) -> (data: Data, minX: Int, minY: Int, maxX: Int, maxY: Int) {
    let valid = contours.filter { $0.count >= 3 }
    guard !valid.isEmpty else { return (Data(), 0, 0, 0, 0) }
    let points = valid.flatMap { $0 }
    let minX = points.map(\.x).min() ?? 0
    let minY = points.map(\.y).min() ?? 0
    let maxX = points.map(\.x).max() ?? 0
    let maxY = points.map(\.y).max() ?? 0
    var out = Data()
    appendInt16(&out, Int16(valid.count))
    appendInt16(&out, Int16(clamp(minX)))
    appendInt16(&out, Int16(clamp(minY)))
    appendInt16(&out, Int16(clamp(maxX)))
    appendInt16(&out, Int16(clamp(maxY)))
    var endpoint = -1
    for contour in valid {
      endpoint += contour.count
      appendUInt16(&out, UInt16(endpoint))
    }
    appendUInt16(&out, 0)
    for point in points { out.append(point.onCurve ? UInt8(0x01) : UInt8(0x00)) }
    var previous = 0
    for point in points {
      appendInt16(&out, Int16(clamp(point.x - previous)))
      previous = point.x
    }
    previous = 0
    for point in points {
      appendInt16(&out, Int16(clamp(point.y - previous)))
      previous = point.y
    }
    return (out, minX, minY, maxX, maxY)
  }

  private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    guard offset + 2 <= data.count else { return 0 }
    return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
  }

  private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
  }

  private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8(value >> 8)); data.append(UInt8(value & 0xff))
  }

  private static func appendInt16(_ data: inout Data, _ value: Int16) {
    appendUInt16(&data, UInt16(bitPattern: value))
  }

  private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8(value >> 24)); data.append(UInt8((value >> 16) & 0xff)); data.append(UInt8((value >> 8) & 0xff)); data.append(UInt8(value & 0xff))
  }

  private static func writeUInt16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
    guard offset + 2 <= data.count else { return }
    data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 0xff)
  }

  private static func writeInt16(_ data: inout Data, _ offset: Int, _ value: Int) {
    writeUInt16(&data, offset, UInt16(bitPattern: Int16(clamp(value))))
  }

  private static func writeUInt32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
    guard offset + 4 <= data.count else { return }
    data[offset] = UInt8(value >> 24); data[offset + 1] = UInt8((value >> 16) & 0xff); data[offset + 2] = UInt8((value >> 8) & 0xff); data[offset + 3] = UInt8(value & 0xff)
  }

  private static func clamp(_ value: Int) -> Int { max(-32768, min(32767, value)) }
}
