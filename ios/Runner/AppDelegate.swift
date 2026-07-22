import Flutter
import CoreText
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {
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
      if activeImagePicker?.presentingViewController != nil {
        result([])
        return
      }
      cancelImageRequest()
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
  static func adjust(data: Data, params: NativeFontAdjustParams, selectedGlyphs: Set<Int>? = nil, glyphAdjustments: [Int: NativeGlyphAdjustment] = [:]) throws -> Data {
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
    if abs(scale - 1.0) > 0.001 || riseUnits != 0 || abs(params.weight) > 0.001 || hasIndividualTransforms {
      let patched = patchGlyf(head: head.data, maxp: maxp.data, loca: loca.data, glyf: glyf.data, scale: scale, riseUnits: riseUnits, weightPercent: params.weight, globalYMid: globalYMid, selectedGlyphs: selectedGlyphs, glyphAdjustments: glyphAdjustments, upm: upm)
      if let patched {
        tables["glyf"]?.data = patched.glyf
        tables["loca"]?.data = patched.loca
        tables["head"]?.data = patched.head
        averageBolden = patched.averageBolden
      }
    }

    if spacingUnits != 0 || abs(scale - 1.0) > 0.001 || abs(averageBolden) > 0.001 || !glyphAdjustments.isEmpty,
       let hmtx = tables["hmtx"], let hhea = tables["hhea"] {
      let patchedHmtx = patchHmtx(hmtx: hmtx.data, hhea: hhea.data, scale: scale, spacingUnits: spacingUnits, boldenUnits: averageBolden, selectedGlyphs: selectedGlyphs, glyphAdjustments: glyphAdjustments, upm: upm)
      tables["hmtx"]?.data = patchedHmtx
      tables["hhea"]?.data = patchAdvanceWidthMax(hhea: hhea.data, hmtx: patchedHmtx)
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
      tables["OS/2"]?.data = patched
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

  private static func patchGlyf(head: Data, maxp: Data, loca: Data, glyf: Data, scale: Double, riseUnits: Int, weightPercent: Double, globalYMid: Double, selectedGlyphs: Set<Int>?, glyphAdjustments: [Int: NativeGlyphAdjustment], upm: Int) -> (glyf: Data, loca: Data, head: Data, averageBolden: Double)? {
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
    var boldenTotal = 0.0
    var boldenCount = 0
    for i in 0..<numGlyphs {
      newOffsets[i] = current
      var start = min(max(0, offsets[i]), glyf.count)
      var end = min(max(0, offsets[i + 1]), glyf.count)
      if start > end { swap(&start, &end) }
      var chunk = Data(glyf[start..<end])
      let selected = selectedGlyphs == nil || selectedGlyphs!.contains(i)
      let adjustment = glyphAdjustments[i]
      let individualScale = max(0.01, 1.0 + (adjustment?.size ?? 0) / 100.0)
      let effectiveScale = (selected ? scale : 1.0) * individualScale
      let effectiveRise = (selected ? riseUnits : 0) + Int(round((adjustment?.y ?? 0) / 100.0 * Double(upm)))
      let xOffset = Int(round((adjustment?.x ?? 0) / 100.0 * Double(upm)))
      let effectiveWeight = selected ? weightPercent : 0
      if (selected || adjustment != nil), let transformed = transformSimpleGlyph(chunk, scale: effectiveScale, riseUnits: effectiveRise, xOffsetUnits: xOffset, weightPercent: effectiveWeight, globalYMid: globalYMid) {
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
    return (newGlyf, newLoca, newHead, boldenCount > 0 ? boldenTotal / Double(boldenCount) : 0)
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

  private static func patchHmtx(hmtx: Data, hhea: Data, scale: Double, spacingUnits: Int, boldenUnits: Double, selectedGlyphs: Set<Int>?, glyphAdjustments: [Int: NativeGlyphAdjustment], upm: Int) -> Data {
    guard hhea.count >= 36 else { return hmtx }
    let count = min(Int(readUInt16(hhea, 34)), hmtx.count / 4)
    var out = hmtx
    for i in 0..<count {
      let selected = selectedGlyphs == nil || selectedGlyphs!.contains(i)
      let adjustment = glyphAdjustments[i]
      let characterSpacingUnits = Int(round((adjustment?.spacing ?? 0) / 100.0 * Double(upm)))
      if !selected && adjustment == nil { continue }
      let p = i * 4
      let oldWidth = Int(readUInt16(out, p))
      let appliedScale = (selected ? scale : 1.0) * max(0.01, 1.0 + (adjustment?.size ?? 0) / 100.0)
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

  private static func patchAdvanceWidthMax(hhea: Data, hmtx: Data) -> Data {
    guard hhea.count >= 36 else { return hhea }
    var out = hhea
    let count = min(Int(readUInt16(hhea, 34)), hmtx.count / 4)
    var maximum = 0
    for index in 0..<count { maximum = max(maximum, Int(readUInt16(hmtx, index * 4))) }
    writeUInt16(&out, 10, UInt16(min(65535, maximum)))
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
    let converted = try CoreTextOutlineConverter.convert(data: data, selectedCharacters: params.targetAll ? "" : params.chars, characterAdjustments: params.characterAdjustments, replacements: params.replacements)
    let adjusted = try NativeTTFProcessor.adjust(data: converted.data, params: params, selectedGlyphs: params.targetAll ? nil : converted.selectedGlyphs, glyphAdjustments: converted.glyphAdjustments)
    return try NativeColorFontProcessor.apply(data: adjusted, params: params)
  }
}

private enum NativeColorFontProcessor {
  static func apply(data: Data, params: NativeFontAdjustParams) throws -> Data {
    let hasGlobal = params.globalColor != nil
    let hasPalette = hasGlobal || !params.characterColors.isEmpty || !params.randomColors.isEmpty
    let hasBitmaps = !params.replacements.isEmpty
    guard hasPalette || hasBitmaps else { return data }
    guard let provider = CGDataProvider(data: data as CFData), let cgFont = CGFont(provider) else { return data }
    var tables = try NativeTTFProcessor.readTables(data)
    guard let maxp = tables["maxp"] else { return data }
    let glyphCount = max(1, Int(readUInt16(maxp.data, 4)))
    let ctFont = CTFontCreateWithGraphicsFont(cgFont, CGFloat(max(1, cgFont.unitsPerEm)), nil, nil)
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
        for glyph in 1..<glyphCount { glyphColors[glyph] = global }
      }
      if !params.randomColors.isEmpty {
        for glyph in 1..<glyphCount { glyphColors[glyph] = params.randomColors[(glyph - 1) % params.randomColors.count] }
      }
      for (characters, color) in params.characterColors {
        for glyph in glyphIDs(for: characters, font: ctFont) { glyphColors[glyph] = color }
      }
      for (glyph, value) in glyphColors {
        layersByGlyph[glyph] = [(glyph, paletteIndex(for: parseColor(value)))]
      }
    }
    if hasBitmaps {
      var imagesByGlyph: [Int: Data] = [:]
      for (characters, imageData) in params.replacements {
        for glyph in glyphIDs(for: characters, font: ctFont) { imagesByGlyph[glyph] = imageData }
      }
      if !imagesByGlyph.isEmpty {
        let imageLayers = try appendImageLayers(
          to: &tables,
          imagesByGlyph: imagesByGlyph,
          params: params,
          font: ctFont
        )
        for (baseGlyph, layers) in imageLayers {
          layersByGlyph[baseGlyph] = layers.map { layer in
            (layer.glyph, paletteIndex(for: layer.color))
          }
        }
      }
      tables.removeValue(forKey: "sbix")
    }
    if !layersByGlyph.isEmpty && !palette.isEmpty {
      tables["COLR"] = FontTable(tag: "COLR", checksum: 0, data: makeCOLR(layersByGlyph))
      tables["CPAL"] = FontTable(tag: "CPAL", checksum: 0, data: makeCPAL(palette))
    }
    return NativeTTFProcessor.serializeTables(tables, sfntVersion: 0x00010000)
  }

  private static func appendImageLayers(
    to tables: inout [String: FontTable],
    imagesByGlyph: [Int: Data],
    params: NativeFontAdjustParams,
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
    let globalYMid = Double(Int(Int16(bitPattern: readUInt16(hhea, 4))) + Int(Int16(bitPattern: readUInt16(hhea, 6)))) * 0.5
    let selectedGlyphs = params.targetAll ? nil : glyphIDs(for: params.chars, font: font)
    var glyphAdjustments: [Int: NativeGlyphAdjustment] = [:]
    for (characters, adjustment) in params.characterAdjustments {
      for glyph in glyphIDs(for: characters, font: font) { glyphAdjustments[glyph] = adjustment }
    }
    let longLoca = Int16(bitPattern: readUInt16(head, 50)) == 1
    var offsets = [Int](repeating: 0, count: originalCount + 1)
    for index in 0...originalCount {
      let offset = index * (longLoca ? 4 : 2)
      offsets[index] = longLoca ? Int(readUInt32(loca, offset)) : Int(readUInt16(loca, offset)) * 2
    }
    var output: [Int: [(glyph: Int, color: (UInt8, UInt8, UInt8, UInt8))]] = [:]
    var glyphCount = originalCount
    for (baseGlyph, imageData) in imagesByGlyph.sorted(by: { $0.key < $1.key }) {
      let rasterLayers = try RasterGlyphConverter.colorLayers(from: imageData, unitsPerEm: upm)
      guard !rasterLayers.isEmpty else { continue }
      let selected = selectedGlyphs == nil || selectedGlyphs!.contains(baseGlyph)
      let adjustment = glyphAdjustments[baseGlyph]
      let globalScale = selected ? max(0.01, 1.0 + params.size / 100.0) : 1.0
      let individualScale = max(0.01, 1.0 + (adjustment?.size ?? 0) / 100.0)
      let scale = globalScale * individualScale
      let rise = (selected ? params.rise : 0) + (adjustment?.y ?? 0)
      let riseUnits = Int(round(rise / 100.0 * Double(upm)))
      let xUnits = Int(round((adjustment?.x ?? 0) / 100.0 * Double(upm)))
      let metricOffset = max(0, min(baseGlyph, originalCount - 1)) * 4
      let advance = readUInt16(hmtx, metricOffset)
      let leftBearing = readUInt16(hmtx, metricOffset + 2)
      var mapped: [(glyph: Int, color: (UInt8, UInt8, UInt8, UInt8))] = []
      for layer in rasterLayers where glyphCount < 65535 {
        let transformed = layer.contours.map { contour in
          contour.map { point in
            OutlinePoint(
              x: max(-32768, min(32767, Int(round(Double(point.x) * scale)) + xUnits)),
              y: max(-32768, min(32767, Int(round(globalYMid + (Double(point.y) - globalYMid) * scale)) + riseUnits)),
              onCurve: point.onCurve
            )
          }
        }
        let encoded = CoreTextOutlineConverter.encodeGlyph(transformed)
        guard !encoded.data.isEmpty else { continue }
        if glyf.count % 2 != 0 { glyf.append(0) }
        glyf.append(encoded.data)
        if glyf.count % 2 != 0 { glyf.append(0) }
        offsets.append(glyf.count)
        appendUInt16(&hmtx, advance)
        appendUInt16(&hmtx, leftBearing)
        mapped.append((glyphCount, layer.color))
        glyphCount += 1
      }
      if !mapped.isEmpty { output[baseGlyph] = mapped }
    }
    if glyphCount == originalCount { return output }
    loca = Data()
    for offset in offsets { appendUInt32(&loca, UInt32(offset)) }
    writeUInt16(&head, 50, 1)
    writeUInt16(&maxp, 4, UInt16(glyphCount))
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
}

private enum RasterGlyphConverter {
  private struct ColorSample {
    let red: Double
    let green: Double
    let blue: Double
  }

  static func contours(from data: Data, unitsPerEm: Int) throws -> [[OutlinePoint]] {
    let dimension = 256
    let raster = try rasterSamples(from: data, dimension: dimension)
    var labels = [Int](repeating: -1, count: raster.samples.count)
    for index in raster.samples.indices {
      guard let sample = raster.samples[index] else { continue }
      if let background = raster.background, colorDistance(sample, background) < 30 { continue }
      labels[index] = 0
    }
    guard let mask = makeMask(labels: labels, selected: 0, width: dimension, height: dimension) else {
      throw NativeFontError.malformedFont
    }
    return try contours(from: mask, unitsPerEm: unitsPerEm)
  }

  static func colorLayers(from data: Data, unitsPerEm: Int) throws -> [RasterColorLayer] {
    let dimension = 192
    let raster = try rasterSamples(from: data, dimension: dimension)
    var samples = raster.samples
    if let background = raster.background {
      removeConnectedBackground(&samples, color: background, width: dimension, height: dimension)
    }
    var histogram: [Int: (red: Double, green: Double, blue: Double, count: Int)] = [:]
    for index in samples.indices {
      guard let sample = samples[index] else { continue }
      let key = (Int(sample.red) >> 3) << 10 | (Int(sample.green) >> 3) << 5 | (Int(sample.blue) >> 3)
      let old = histogram[key] ?? (0, 0, 0, 0)
      histogram[key] = (old.red + sample.red, old.green + sample.green, old.blue + sample.blue, old.count + 1)
    }
    let foregroundCount = samples.compactMap { $0 }.count
    guard foregroundCount > 0 else { return [] }
    if let grayscale = try grayscaleLayers(
      samples: samples,
      foregroundCount: foregroundCount,
      width: dimension,
      height: dimension,
      unitsPerEm: unitsPerEm
    ) {
      return grayscale
    }

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
      guard let mask = makeMask(labels: labels, selected: label, width: dimension, height: dimension) else { continue }
      let layerContours = try contours(from: mask, unitsPerEm: unitsPerEm)
      guard !layerContours.isEmpty else { continue }
      let center = centers[label]
      output.append(RasterColorLayer(
        color: (
          UInt8(max(0, min(255, center.red.rounded()))),
          UInt8(max(0, min(255, center.green.rounded()))),
          UInt8(max(0, min(255, center.blue.rounded()))),
          255
        ),
        contours: layerContours
      ))
    }
    return output
  }

  private static func grayscaleLayers(
    samples: [ColorSample?],
    foregroundCount: Int,
    width: Int,
    height: Int,
    unitsPerEm: Int
  ) throws -> [RasterColorLayer]? {
    let colors = samples.compactMap { $0 }
    let neutralCount = colors.reduce(0) { count, sample in
      let high = max(sample.red, max(sample.green, sample.blue))
      let low = min(sample.red, min(sample.green, sample.blue))
      return count + (high - low <= 18 ? 1 : 0)
    }
    guard neutralCount * 100 >= foregroundCount * 95 else { return nil }

    var histogram = [Int](repeating: 0, count: 256)
    var totalLuminance = 0.0
    for sample in colors {
      let value = max(0, min(255, Int(round(luminance(sample)))))
      histogram[value] += 1
      totalLuminance += Double(value)
    }
    guard let minimum = histogram.firstIndex(where: { $0 > 0 }),
          let maximum = histogram.lastIndex(where: { $0 > 0 }),
          maximum - minimum >= 48 else { return nil }

    var darkCount = 0
    var darkSum = 0.0
    var bestThreshold = (minimum + maximum) / 2
    var bestVariance = -1.0
    for threshold in minimum..<maximum {
      darkCount += histogram[threshold]
      darkSum += Double(threshold * histogram[threshold])
      let lightCount = foregroundCount - darkCount
      guard darkCount > 0, lightCount > 0 else { continue }
      let darkMean = darkSum / Double(darkCount)
      let lightMean = (totalLuminance - darkSum) / Double(lightCount)
      let variance = Double(darkCount * lightCount) * pow(darkMean - lightMean, 2)
      if variance > bestVariance {
        bestVariance = variance
        bestThreshold = threshold
      }
    }

    var labels = [Int](repeating: -1, count: samples.count)
    var sums = Array(repeating: (red: 0.0, green: 0.0, blue: 0.0, count: 0), count: 2)
    for index in samples.indices {
      guard let sample = samples[index] else { continue }
      let label = luminance(sample) <= Double(bestThreshold) ? 0 : 1
      labels[index] = label
      sums[label].red += sample.red
      sums[label].green += sample.green
      sums[label].blue += sample.blue
      sums[label].count += 1
    }

    var output: [RasterColorLayer] = []
    let minimumPixels = max(8, Int(Double(foregroundCount) * 0.0015))
    for label in [1, 0] where sums[label].count >= minimumPixels {
      guard let mask = makeMask(
        labels: labels,
        selected: label,
        width: width,
        height: height
      ) else { continue }
      let layerContours = try contours(from: mask, unitsPerEm: unitsPerEm)
      guard !layerContours.isEmpty else { continue }
      let count = Double(sums[label].count)
      output.append(RasterColorLayer(
        color: (
          UInt8(max(0, min(255, (sums[label].red / count).rounded()))),
          UInt8(max(0, min(255, (sums[label].green / count).rounded()))),
          UInt8(max(0, min(255, (sums[label].blue / count).rounded()))),
          255
        ),
        contours: layerContours
      ))
    }
    return output.isEmpty ? nil : output
  }

  private static func luminance(_ sample: ColorSample) -> Double {
    sample.red * 0.299 + sample.green * 0.587 + sample.blue * 0.114
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
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
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
      samples[index] = ColorSample(
        red: min(255, Double(pixels[offset]) * factor),
        green: min(255, Double(pixels[offset + 1]) * factor),
        blue: min(255, Double(pixels[offset + 2]) * factor)
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

  private static func makeMask(labels: [Int], selected: Int, width: Int, height: Int) -> CGImage? {
    var mask = [UInt8](repeating: 255, count: width * height * 4)
    for index in labels.indices where labels[index] == selected {
      let offset = index * 4
      mask[offset] = 0
      mask[offset + 1] = 0
      mask[offset + 2] = 0
    }
    guard let provider = CGDataProvider(data: Data(mask) as CFData) else { return nil }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  private static func contours(from source: CGImage, unitsPerEm: Int) throws -> [[OutlinePoint]] {
    let request = VNDetectContoursRequest()
    request.contrastAdjustment = 1.2
    request.detectsDarkOnLight = true
    request.maximumImageDimension = max(source.width, source.height)
    try VNImageRequestHandler(cgImage: source).perform([request])
    guard let observation = request.results?.first else { return [] }
    let inset = Double(unitsPerEm) * 0.08
    let body = Double(unitsPerEm) - inset * 2
    var output: [[OutlinePoint]] = []
    func append(_ contour: VNContour) {
      var points = Array(contour.normalizedPoints)
      if points.count >= 3 {
        let step = max(1, Int(ceil(Double(points.count) / 2048.0)))
        if step > 1 { points = points.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil } }
        output.append(points.map { point in
        OutlinePoint(
          x: Int(round(inset + Double(point.x) * body)),
          y: Int(round(inset + Double(point.y) * body)),
          onCurve: true
        )
        })
      }
      for child in contour.childContours { append(child) }
    }
    for contour in observation.topLevelContours { append(contour) }
    return normalizeContourWinding(output)
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
