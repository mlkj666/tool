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
      case "processFont":
        self.processFont(arguments: call.arguments, result: result)
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

  private func processFont(arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let base64 = args["base64"] as? String,
          let data = Data(base64Encoded: base64) else {
      result(FlutterError(code: "bad_args", message: "字体数据无效", details: nil))
      return
    }
    do {
      let params = NativeFontAdjustParams(
        size: args["size"] as? Double ?? 36,
        weight: args["weight"] as? Double ?? 0,
        letter: args["letter"] as? Double ?? 0,
        line: args["line"] as? Double ?? 1.4,
        rise: args["rise"] as? Double ?? 0
      )
      let processed = try NativeTTFProcessor.adjust(data: data, params: params)
      result(["base64": processed.base64EncodedString()])
    } catch {
      result(FlutterError(code: "process_failed", message: error.localizedDescription, details: nil))
    }
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

private struct NativeFontAdjustParams {
  let size: Double
  let weight: Double
  let letter: Double
  let line: Double
  let rise: Double
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
  static func adjust(data: Data, params: NativeFontAdjustParams) throws -> Data {
    var tables = try readTables(data)
    guard let head = tables["head"], let maxp = tables["maxp"], let loca = tables["loca"], let glyf = tables["glyf"] else {
      throw NativeFontError.unsupportedFont
    }

    let upm = max(1, Int(readUInt16(head.data, 18)))
    let scale = max(0.2, min(4.0, params.size / 36.0))
    let riseUnits = Int((params.rise / max(1, params.size)) * Double(upm))
    let weightUnits = Int((params.weight / 100.0) * Double(upm) * 0.16)
    let spacingUnits = Int((params.letter / max(1, params.size)) * Double(upm))

    if abs(scale - 1.0) > 0.001 || riseUnits != 0 || weightUnits != 0 {
      let patched = patchGlyf(head: head.data, maxp: maxp.data, loca: loca.data, glyf: glyf.data, scale: scale, riseUnits: riseUnits, weightUnits: weightUnits)
      if let patched {
        tables["glyf"]?.data = patched.glyf
        tables["loca"]?.data = patched.loca
        tables["head"]?.data = patched.head
      }
    }

    if spacingUnits != 0, let hmtx = tables["hmtx"], let hhea = tables["hhea"] {
      tables["hmtx"]?.data = patchHmtx(hmtx: hmtx.data, hhea: hhea.data, spacingUnits: spacingUnits)
    }

    if abs(params.line - 1.4) > 0.01 {
      if let hhea = tables["hhea"] {
        tables["hhea"]?.data = patchHhea(hhea.data, lineHeight: params.line, upm: upm)
      }
      if let os2 = tables["OS/2"] {
        tables["OS/2"]?.data = patchOS2(os2.data, lineHeight: params.line, upm: upm)
      }
    }

    return serializeTables(tables, sfntVersion: readUInt32(data, 0))
  }

  private static func readTables(_ data: Data) throws -> [String: FontTable] {
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

  private static func patchGlyf(head: Data, maxp: Data, loca: Data, glyf: Data, scale: Double, riseUnits: Int, weightUnits: Int) -> (glyf: Data, loca: Data, head: Data)? {
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
    for i in 0..<numGlyphs {
      newOffsets[i] = current
      var start = min(max(0, offsets[i]), glyf.count)
      var end = min(max(0, offsets[i + 1]), glyf.count)
      if start > end { swap(&start, &end) }
      var chunk = Data(glyf[start..<end])
      if let transformed = transformSimpleGlyph(chunk, scale: scale, riseUnits: riseUnits, weightUnits: weightUnits) {
        chunk = transformed
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
    return (newGlyf, newLoca, newHead)
  }

  private static func transformSimpleGlyph(_ chunk: Data, scale: Double, riseUnits: Int, weightUnits: Int) -> Data? {
    guard chunk.count >= 10 else { return nil }
    let contours = Int(readInt16(chunk, 0))
    if contours <= 0 { return nil }
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

    let xMid = Double(readInt16(chunk, 2) + readInt16(chunk, 6)) / 2.0
    let yMid = Double(readInt16(chunk, 4) + readInt16(chunk, 8)) / 2.0
    var start = 0
    var boxes: [(start: Int, end: Int, cx: Double, cy: Double, limit: Double)] = []
    for end in endPts {
      var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
      for i in start...end {
        minX = min(minX, xs[i]); maxX = max(maxX, xs[i])
        minY = min(minY, ys[i]); maxY = max(maxY, ys[i])
      }
      let width = max(1, maxX - minX)
      let height = max(1, maxY - minY)
      boxes.append((start, end, Double(minX + maxX) / 2.0, Double(minY + maxY) / 2.0, max(6.0, Double(min(width, height)) * 0.36)))
      start = end + 1
    }

    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
    for box in boxes {
      let safeWeight = max(-box.limit, min(box.limit, Double(weightUnits)))
      for i in box.start...box.end {
        let vx = Double(xs[i]) - box.cx
        let vy = Double(ys[i]) - box.cy
        let len = max(1.0, sqrt(vx * vx + vy * vy))
        let nx = vx / len
        let ny = vy / len
        xs[i] = clampInt16(Int(round(xMid + (Double(xs[i]) - xMid) * scale + nx * safeWeight)))
        ys[i] = clampInt16(Int(round(yMid + (Double(ys[i]) - yMid) * scale + ny * safeWeight * 0.30 + Double(riseUnits))))
        minX = min(minX, xs[i]); maxX = max(maxX, xs[i])
        minY = min(minY, ys[i]); maxY = max(maxY, ys[i])
      }
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
    return out
  }

  private static func patchHmtx(hmtx: Data, hhea: Data, spacingUnits: Int) -> Data {
    guard hhea.count >= 36 else { return hmtx }
    let count = min(Int(readUInt16(hhea, 34)), hmtx.count / 4)
    var out = hmtx
    for i in 0..<count {
      let p = i * 4
      let width = Int(readUInt16(out, p)) + spacingUnits
      writeUInt16(&out, p, UInt16(max(0, min(65535, width))))
    }
    return out
  }

  private static func patchHhea(_ hhea: Data, lineHeight: Double, upm: Int) -> Data {
    guard hhea.count >= 10 else { return hhea }
    var out = hhea
    let asc = Int(readInt16(out, 4))
    let desc = Int(readInt16(out, 6))
    let body = max(1, asc - desc)
    let target = max(body, Int(round(Double(upm) * lineHeight)))
    writeInt16(&out, 8, clampInt16(target - body))
    return out
  }

  private static func patchOS2(_ os2: Data, lineHeight: Double, upm: Int) -> Data {
    guard os2.count >= 74 else { return os2 }
    var out = os2
    let asc = Int(readInt16(out, 68))
    let desc = Int(readInt16(out, 70))
    let body = max(1, asc - desc)
    let target = max(body, Int(round(Double(upm) * lineHeight)))
    writeInt16(&out, 72, clampInt16(target - body))
    return out
  }

  private static func serializeTables(_ tables: [String: FontTable], sfntVersion: UInt32) -> Data {
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
}
