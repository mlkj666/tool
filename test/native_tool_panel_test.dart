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
    expect(panel, contains('Future<void> _applyAdjustments()'));
    expect(panel, contains('Future<void> _exportFont()'));
    expect(panel, contains("'processFont'"));
    expect(panel, contains("'saveFont'"));
  });

  test('image and drawing replacements reach the native outline engine', () {
    expect(panel, contains("'replacements': _replacements.map"));
    expect(panel, contains('RenderRepaintBoundary'));
    expect(panel, contains('_liveReplacementImage'));
    expect(panel, contains('_selectSingleCharacter'));
    expect(panel, contains('_tryParseCustomColor'));
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
    expect(panel, contains('_prepareImportedImage'));
    expect(panel, contains('_foregroundBounds'));
    expect(panel, contains('Icons.remove_circle_outline'));
    expect(panel, contains('Icons.add_circle_outline'));
    expect(panel, contains('_accountLine'));
    expect(nativeEngine, contains('VNDetectContoursRequest'));
    expect(nativeEngine, contains('replacementContours'));
    expect(nativeEngine, contains('NativeColorFontProcessor'));
    expect(nativeEngine, contains('appendImageLayers'));
    expect(nativeEngine, contains('RasterGlyphConverter.colorLayers'));
    expect(nativeEngine, contains('makeCOLR'));
    expect(nativeEngine, contains('makeCPAL'));
    expect(nativeEngine, contains('tables["sbix"] = FontTable'));
    expect(nativeEngine, contains('imagesByGlyph'));
    expect(nativeEngine, contains('isGrayscaleImage'));
    expect(nativeEngine, contains('normalizeContourWinding'));
    expect(nativeEngine, contains('replacementGlyphs: replacementGlyphs'));
    expect(nativeEngine, contains('tables.removeValue(forKey: "COLR")'));
    expect(nativeEngine, contains('makeSBIX(imagesByGlyph: imagesByGlyph'));
    expect(nativeEngine, contains('appendUInt16(&table, 1)'));
    expect(
      nativeEngine,
      contains('let ppems = [16, 24, 32, 48, 64, 96, 128, 256, 512]'),
    );
    expect(nativeEngine, contains('!imageGlyphs.contains(glyph)'));
    expect(panel, contains("'characterColors': _characterColors.map"));
  });

  test('app version advances with native workspace release', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: 1.0.13+14'));
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
