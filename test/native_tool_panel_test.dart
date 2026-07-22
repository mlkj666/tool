import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
    expect(nativeEngine, contains('tables.removeValue(forKey: "sbix")'));
    expect(nativeEngine, contains('imagesByGlyph'));
    expect(panel, contains("'characterColors': _characterColors.map"));
  });

  test('app version advances with native workspace release', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: 1.0.7+8'));
  });
}
