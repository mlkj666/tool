import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tool_iphone_app/native_tool_panel.dart';

class _TestUser {
  const _TestUser();

  String get username => 'tester';
  String get role => 'admin';
  String get expireTime => '';
}

void main() {
  late String panel;
  late String nativeEngine;

  setUpAll(() {
    panel = File('lib/native_tool_panel.dart').readAsStringSync();
    nativeEngine = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  });

  test('tool workspace is rendered with Flutter components', () {
    expect(panel, contains('class NativeToolPanel extends StatefulWidget'));
    expect(panel, contains('NavigationBar('));
    expect(panel, contains("label: '颜色'"));
    expect(panel, contains('CustomPaint'));
    expect(panel, contains('FontLoader'));
  });

  test('apply reloads processed font and export is separate', () {
    expect(panel, contains('Future<bool> _applyAdjustments()'));
    expect(panel, contains('Future<void> _exportFont()'));
    expect(panel, contains('await _applyAdjustments();'));
    expect(panel, contains("'processFont'"));
    expect(panel, contains("'saveFont'"));
  });

  test('image and drawing replacements reach the native outline engine', () {
    expect(panel, contains("'replacements': _replacements.map"));
    expect(panel, contains('RenderRepaintBoundary'));
    expect(panel, contains('_liveReplacementImage'));
    expect(panel, contains('_boundReplacementImage'));
    expect(panel, contains('clipBehavior: Clip.none'));
    expect(panel, isNot(contains('child: ClipRect(')));
    expect(panel, contains('_selectSingleCharacter'));
    expect(panel, contains('_tryParseCustomColor'));
    expect(panel, contains('_SaturationValuePicker'));
    expect(panel, contains('HSVColor.fromColor'));
    expect(panel, contains("hintText: '例如：爆闪字体修符'"));
    expect(panel, contains("labelText: '自定义色值'"));
    expect(panel, contains('bool _globalColorEnabled = false'));
    expect(panel, contains('height: naturalHeight'));
    expect(panel, contains('clipBehavior: Clip.none'));
    expect(
      panel,
      contains('naturalWidth + _spacing * .25 + characterSpacing * .2'),
    );
    expect(nativeEngine, contains('dominantEdgeBackground'));
    expect(nativeEngine, contains('removeConnectedBackground'));
    expect(panel, contains('bool _pickingImage = false'));
    expect(nativeEngine, contains('imageRequestToken'));
    expect(nativeEngine, contains('finishImageRequest'));
    expect(nativeEngine, contains('cancelImageRequest'));
    expect(panel, contains('_bindImportedImage(notify: false)'));
    expect(panel, contains('_renderReplacementWorkspace'));
    expect(panel, contains('_replacementTransforms'));
    expect(panel, contains('_nextReplacementTransforms'));
    expect(panel, contains('_editReplacement'));
    expect(panel, contains("tooltip: '继续调整'"));
    expect(panel, contains('_prepareImportedImage'));
    expect(panel, contains('_foregroundBounds'));
    expect(panel, contains('_hasTransparentPixels'));
    expect(
      panel,
      contains('static const double _replacementWorkspaceSide = 2048'),
    );
    expect(panel, contains('static const double _replacementOffsetScale ='));
    expect(panel, contains('_replacementReferenceSide / 100'));
    expect(panel, contains('.toImage('));
    expect(panel, contains('canvasSide.toInt()'));
    expect(panel, contains('ValueListenableBuilder<TextEditingValue>'));
    expect(panel, contains('alignment: WrapAlignment.start'));
    expect(panel, contains('Icons.remove_circle_outline'));
    expect(panel, contains('Icons.add_circle_outline'));
    expect(panel, contains('_accountLine'));
    expect(nativeEngine, contains('traceContours(mask'));
    expect(nativeEngine, contains('rdpSimplify(contour'));
    expect(nativeEngine, contains('Double(max(width, height)) / 256.0'));
    expect(nativeEngine, contains('targetHeight / (0.8 *'));
    expect(nativeEngine, contains('let widthScale = targetWidth /'));
    expect(nativeEngine, contains('min(heightScale, widthScale)'));
    expect(
      nativeEngine,
      contains('let spacingScale = max(0.01, appliedScale)'),
    );
    expect(nativeEngine, isNot(contains('VNDetectContoursRequest')));
    expect(nativeEngine, contains('replacementContours'));
    expect(nativeEngine, contains('NativeColorFontProcessor'));
    expect(nativeEngine, contains('prepareForAdjustment'));
    expect(nativeEngine, contains('replacementGlyphBox'));
    expect(nativeEngine, contains('CTFontGetBoundingRectsForGlyphs'));
    expect(nativeEngine, contains('let centerY = bounds.height > 0'));
    expect(nativeEngine, contains('tables["BSFT"]'));
    expect(nativeEngine, contains('removeConnectedBackground(&samples, color: background, width: dimension, height: dimension)'));
    expect(nativeEngine, contains('monochromeFallbackMask(samples)'));
    expect(nativeEngine, isNot(contains('preservesOpaqueArtwork')));
    expect(nativeEngine, isNot(contains('if preserveBitmap { return [] }')));
    expect(nativeEngine, isNot(contains('preserveBitmap ? alphaFallbackMask(samples)')));
    expect(nativeEngine, contains('alphaFallbackMask'));
    expect(nativeEngine, contains('presentationControllerDidDismiss'));
    expect(nativeEngine, contains('active?.dismiss(animated: true)'));
    expect(nativeEngine, contains('patchHheaVerticalBounds'));
    expect(nativeEngine, contains('patchOS2VerticalBounds'));
    expect(nativeEngine, contains('patchHheaHorizontalMetrics'));
    expect(nativeEngine, contains('writeInt16(&out, 16, xMaxExtent)'));
    expect(nativeEngine, contains('fitContoursInsideTargetBox'));
    expect(
      nativeEngine,
      contains('return normalizeContourWinding(fitContoursInsideTargetBox(mapped, targetBox: targetBox))'),
    );
    expect(nativeEngine, contains('replacementVerticalBounds'));
    expect(nativeEngine, contains('metrics.count == glyphCount'));
    expect(nativeEngine, contains('guard hasPalette || hasReplacements else'));
    expect(nativeEngine, contains('metrics.reserveCapacity'));
    expect(nativeEngine, contains('RasterGlyphConverter.colorLayers'));
    expect(nativeEngine, contains('makeCOLR'));
    expect(nativeEngine, contains('makeCPAL'));
    expect(nativeEngine, contains('let imageLayers = try appendImageLayers'));
    expect(
      nativeEngine,
      contains('glyphCount = max(1, Int(readUInt16(finalMaxp, 4)))'),
    );
    expect(nativeEngine, contains('isGrayscaleImage'));
    expect(
      nativeEngine,
      contains('red: min(255, Double(pixels[offset + 2]) * factor)'),
    );
    expect(
      nativeEngine,
      contains('blue: min(255, Double(pixels[offset]) * factor)'),
    );
    expect(nativeEngine, contains('normalizeContourWinding'));
    expect(nativeEngine, contains('replacementGlyphs: replacementGlyphs'));
    expect(
      nativeEngine,
      contains('for tag in ["COLR", "CPAL", "sbix", "CBDT", "CBLC", "SVG "]'),
    );
    expect(nativeEngine, isNot(contains('makeSBIX')));
    expect(nativeEngine, contains('tables["COLR"] = FontTable'));
    expect(nativeEngine, contains('tables["CPAL"] = FontTable'));
    expect(nativeEngine, contains('let imageLayers = try appendImageLayers'));
    expect(nativeEngine, isNot(contains('let strikeSizes = [512, 256, 128, 96, 64, 48, 32]')));
    expect(nativeEngine, isNot(contains('let sbixFlags: UInt16 = 1')));
    expect(nativeEngine, isNot(contains('bitmapAlphaBounds')));
    expect(nativeEngine, isNot(contains('bitmapData.append(bitmap.data)')));
    expect(nativeEngine, isNot(contains('offset += 8 + bitmap.data.count')));
    expect(nativeEngine, contains('transformsByGlyph: transformsByGlyph'));
    expect(nativeEngine, contains('transform: transformsByGlyph[baseGlyph] ?? .identity'));
    expect(nativeEngine, contains('targetBox: targetBox'));
    expect(nativeEngine, contains('guard !rasterLayers.isEmpty else { continue }'));
    expect(nativeEngine, contains('monochromeFallbackMask'));
    expect(nativeEngine, contains('let scale = max(0.001, userScale) * min(heightScale, widthScale)'));
    expect(nativeEngine, contains('userScale: canvasScale * transform.scale'));
    expect(nativeEngine, contains('offsetX: transform.x / 100 * Double(unitsPerEm)'));
    expect(nativeEngine, contains('offsetY: transform.y / 100 * Double(unitsPerEm)'));
    expect(
      nativeEngine,
      contains('let hasReplacements = !params.replacements.isEmpty'),
    );
    expect(panel, contains("'characterColors': _characterColors.map"));
    expect(panel, contains('_imageBytes = null'));
    expect(panel, contains("_message('还原失败：\$error')"));
    expect(panel, contains('onPressed: _busy ? null : _resetFont'));
  });

  test('app version advances with native workspace release', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: 1.0.40+41'));
  });

  testWidgets('current effect preview lays out without an exception', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NativeToolPanel(
          user: const _TestUser(),
          cookie: null,
          onLogout: () async {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('当前效果'), findsOneWidget);
    expect(find.text('爆'), findsOneWidget);
    final glyphSize = tester.getSize(find.text('爆'));
    expect(glyphSize.width, greaterThan(0));
    expect(glyphSize.height, greaterThan(0));
    expect(glyphSize.width.isFinite, isTrue);
    expect(glyphSize.height.isFinite, isTrue);
    expect(tester.takeException(), isNull);
  });
}
