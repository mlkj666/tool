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
    expect(nativeEngine, contains('VNDetectContoursRequest'));
    expect(nativeEngine, contains('replacementContours'));
    expect(nativeEngine, contains('NativeColorFontProcessor'));
    expect(panel, contains("'characterColors': _characterColors.map"));
  });

  test('app version advances with native workspace release', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: 1.0.2+3'));
  });
}
