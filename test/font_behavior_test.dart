import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String toolHtml;
  late String nativeProcessor;

  setUpAll(() {
    toolHtml = File('assets/web/tool.html').readAsStringSync();
    nativeProcessor = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  });

  test('font adjustment controls use the required behavior contract', () {
    for (final id in [
      'rngSize',
      'rngWeight',
      'rngSpacing',
      'rngBaseline',
      'rngLineHeight',
    ]) {
      expect(
        toolHtml,
        contains('id="$id" min="-50" max="50" value="0" step="1"'),
      );
    }
    expect(nativeProcessor, contains('max(0.01, 1.0 + params.size / 100.0)'));
    expect(nativeProcessor, contains('params.rise / 100.0'));
    expect(nativeProcessor, contains('params.letter / 100.0'));
  });

  test('replacement controls and image defaults use the required contract', () {
    expect(
      toolHtml,
      contains('id="rngAdjustScale" min="0.3" max="1.5" step="0.05"'),
    );
    expect(
      toolHtml,
      contains('id="rngAdjustSpacing" min="0.5" max="2.0" step="0.05"'),
    );
    expect(toolHtml, contains('resizeImageDataUrl(sourceImage, 512)'));
    expect(toolHtml, contains('scale: 0.9, spacing: 1.0'));
    expect(
      toolHtml,
      contains('mask = smoothMask(mask, side, side, radius, 2)'),
    );
    expect(toolHtml, contains('(info.xOffset || 0) * upem / 100'));
  });

  test('export and native metadata use the required behavior contract', () {
    expect(toolHtml, contains("return `\${base}_modified.\${ext}`"));
    expect(toolHtml, contains('accept=".ttf,.otf,.ttc"'));
    expect(nativeProcessor, contains('max(1, min(1000'));
    expect(nativeProcessor, contains('* 400.0'));
    expect(nativeProcessor, contains('writeUInt16(&out, 4, UInt16(value))'));
  });

  test('per-character spacing is previewed and sent to the native engine', () {
    expect(toolHtml, contains('id="singleSpacingChars"'));
    expect(toolHtml, contains('id="singleSpacingValue"'));
    expect(toolHtml, contains('perCharSpacing: {}'));
    expect(toolHtml, contains('characterSpacing: state.perCharSpacing'));
    expect(nativeProcessor, contains('glyphSpacingPercent'));
  });

  test('random color values default to thirty', () {
    expect(
      toolHtml,
      contains('id="randomColorPool" min="1" max="256" step="1" value="30"'),
    );
    expect(toolHtml, contains('randomPool: 30'));
  });
}
