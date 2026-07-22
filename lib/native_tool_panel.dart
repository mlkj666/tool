import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class NativeToolPanel extends StatefulWidget {
  const NativeToolPanel({
    super.key,
    required this.user,
    required this.cookie,
    required this.onLogout,
  });

  final dynamic user;
  final String? cookie;
  final Future<void> Function() onLogout;

  @override
  State<NativeToolPanel> createState() => _NativeToolPanelState();
}

class _NativeToolPanelState extends State<NativeToolPanel>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _channel = MethodChannel('bs_font/native');
  final _textController = TextEditingController(text: '爆闪 STUDIO 字体 修符工具');
  final _drawPoints = <Offset>[];
  final List<List<Offset>> _drawUndo = [];
  final List<List<Offset>> _drawRedo = [];
  double _drawSize = 5;
  Color _drawColor = Colors.black;
  bool _drawGrid = false;
  Uint8List? _fontBytes;
  Uint8List? _originalFontBytes;
  String _fontName = '未加载字体';
  String? _fontFamily;
  String? _originalFontFamily;
  Uint8List? _imageBytes;
  double _size = 0;
  double _weight = 0;
  double _spacing = 0;
  double _rise = 0;
  double _line = 0;
  bool _busy = false;
  bool _pickingImage = false;
  int _tab = 0;
  bool _targetAll = true;
  final _targetCharsController = TextEditingController();
  final _colorCharsController = TextEditingController();
  Color _globalColor = Colors.black;
  Color _selectedColor = const Color(0xFF2563EB);
  int _randomPoolSize = 30;
  final Map<String, Color> _characterColors = {};
  final List<Color> _randomPalette = [];
  double _imageScale = 1;
  double _imageSpacing = 0;
  double _imageX = 0;
  double _imageY = 0;
  bool _imageSmoothing = true;
  final _singleCharController = TextEditingController();
  final _replacementCharController = TextEditingController();
  final _drawBoundaryKey = GlobalKey();
  final Map<String, Uint8List> _replacements = {};
  final Map<String, Map<String, double>> _characterAdjustments = {};
  double _singleSize = 0;
  double _singleSpacing = 0;
  double _singleX = 0;
  double _singleY = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _showAnnouncement());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _singleCharController.dispose();
    _replacementCharController.dispose();
    _targetCharsController.dispose();
    _colorCharsController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkAccess();
  }

  Future<void> _checkAccess() async {
    final expire = (widget.user.expireTime ?? '').toString();
    if (widget.user.role != 'admin' &&
        (expire.isEmpty ||
            DateTime.tryParse(
                  expire.replaceFirst(' ', 'T'),
                )?.isAfter(DateTime.now()) !=
                true)) {
      await widget.onLogout();
      return;
    }
    try {
      final response = await http
          .post(
            Uri.parse(
              'https://tool.uxgzs.icu/api.php',
            ).replace(queryParameters: {'action': 'check_auth'}),
            headers: {
              if (widget.cookie != null && widget.cookie!.isNotEmpty)
                'Cookie': widget.cookie!,
              'Content-Type': 'application/x-www-form-urlencoded',
            },
          )
          .timeout(const Duration(seconds: 10));
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map || data['success'] != true) {
        await widget.onLogout();
      }
    } catch (_) {
      // Keep the valid local session during temporary network failures.
    }
  }

  Future<void> _showAnnouncement() async {
    try {
      final response = await http.post(
        Uri.parse(
          'https://tool.uxgzs.icu/api.php',
        ).replace(queryParameters: {'action': 'get_announcement'}),
        headers: {
          if (widget.cookie != null && widget.cookie!.isNotEmpty)
            'Cookie': widget.cookie!,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      );
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map || data['success'] != true || !mounted) return;
      final raw = data['announcement'] is Map
          ? data['announcement'] as Map
          : data;
      final content = (raw['content'] ?? raw['message'] ?? '')
          .toString()
          .trim();
      if (content.isEmpty) return;
      final id = (raw['id'] ?? raw['updated_at'] ?? content.hashCode)
          .toString();
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString('dismissed_announcement_id') == id || !mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text((raw['title'] ?? '公告').toString()),
          content: Text(content),
          actions: [
            FilledButton(
              onPressed: () async {
                await prefs.setString('dismissed_announcement_id', id);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (_) {}
  }

  Future<void> _pickFont() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'pickFont',
      );
      if (result == null) return;
      final encoded = result['base64']?.toString() ?? '';
      if (encoded.isEmpty) return;
      final bytes = base64Decode(encoded);
      final family = 'BSFont_${DateTime.now().microsecondsSinceEpoch}';
      final loader = FontLoader(family)
        ..addFont(
          Future.value(
            ByteData.view(
              bytes.buffer,
              bytes.offsetInBytes,
              bytes.lengthInBytes,
            ),
          ),
        );
      await loader.load();
      if (!mounted) return;
      setState(() {
        _fontBytes = bytes;
        _originalFontBytes = Uint8List.fromList(bytes);
        _fontName = result['name']?.toString() ?? '字体文件';
        _fontFamily = family;
        _originalFontFamily = family;
      });
    } catch (error) {
      _message('字体导入失败：$error');
    }
  }

  Future<void> _pickImage() async {
    if (_pickingImage) return;
    if (mounted) setState(() => _pickingImage = true);
    try {
      final result = await _channel.invokeMethod<List<Object?>>('pickImages', {
        'source': 'photo',
      });
      final first = result?.whereType<Map>().isEmpty == false
          ? result!.whereType<Map>().first
          : null;
      final encoded = first?['base64']?.toString() ?? '';
      if (encoded.isEmpty || !mounted) return;
      setState(() => _imageBytes = base64Decode(encoded));
    } catch (error) {
      _message('图片导入失败：$error');
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  Future<void> _applyAdjustments() async {
    if (_fontBytes == null) {
      _message('请先导入字体');
      return;
    }
    if (_imageBytes != null && _replacementCharacter() != null) {
      await _bindImportedImage(notify: false);
    }
    setState(() => _busy = true);
    try {
      final response = await _channel
          .invokeMethod<Map<Object?, Object?>>('processFont', {
            'base64': base64Encode(_fontBytes!),
            'size': _size,
            'weight': _weight,
            'letter': _spacing,
            'rise': _rise,
            'line': _line,
            'targetAll': _targetAll,
            'chars': _targetCharsController.text,
            'characterAdjustments': _characterAdjustments,
            'replacements': _replacements.map(
              (key, value) => MapEntry(key, base64Encode(value)),
            ),
            'globalColor': _hex(_globalColor),
            'characterColors': _characterColors.map(
              (key, value) => MapEntry(key, _hex(value)),
            ),
            'randomColors': _randomPalette.map(_hex).toList(),
          });
      final encoded = response?['base64']?.toString() ?? '';
      if (encoded.isEmpty) throw Exception('未生成字体数据');
      final processed = base64Decode(encoded);
      final family = 'BSFont_${DateTime.now().microsecondsSinceEpoch}';
      final loader = FontLoader(family)
        ..addFont(
          Future.value(
            ByteData.view(
              processed.buffer,
              processed.offsetInBytes,
              processed.lengthInBytes,
            ),
          ),
        );
      await loader.load();
      if (!mounted) return;
      setState(() {
        _fontBytes = processed;
        _fontFamily = family;
        _size = _weight = _spacing = _rise = _line = 0;
        _characterAdjustments.clear();
        _singleSize = _singleSpacing = _singleX = _singleY = 0;
      });
      _message('调整已应用，当前预览就是导出效果');
    } catch (error) {
      _message('处理失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportFont() async {
    if (_fontBytes == null) return _message('请先导入字体');
    try {
      await _channel.invokeMethod('saveFont', {
        'filename': _fontName.replaceFirst(
          RegExp(r'\.(ttf|otf|ttc)$', caseSensitive: false),
          '_modified.ttf',
        ),
        'base64': base64Encode(_fontBytes!),
      });
    } catch (error) {
      _message('文件保存页面打开失败：$error');
    }
  }

  Future<void> _exportConfig() async {
    final config = {
      'version': 2,
      'fontName': _fontName,
      'fontBase64': _fontBytes == null ? null : base64Encode(_fontBytes!),
      'previewText': _textController.text,
      'size': _size,
      'weight': _weight,
      'spacing': _spacing,
      'rise': _rise,
      'line': _line,
      'targetAll': _targetAll,
      'targetChars': _targetCharsController.text,
      'characterAdjustments': _characterAdjustments,
      'characterColors': _characterColors.map(
        (key, value) => MapEntry(key, _hex(value)),
      ),
      'globalColor': _hex(_globalColor),
      'randomColors': _randomPalette.map(_hex).toList(),
      'replacements': _replacements.map(
        (key, value) => MapEntry(key, base64Encode(value)),
      ),
    };
    await _channel.invokeMethod('saveFont', {
      'filename': 'font-config.json',
      'base64': base64Encode(utf8.encode(jsonEncode(config))),
    });
  }

  Future<void> _importConfig() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'pickConfig',
    );
    final encoded = result?['base64']?.toString() ?? '';
    if (encoded.isEmpty) return;
    try {
      final config =
          jsonDecode(utf8.decode(base64Decode(encoded)))
              as Map<String, dynamic>;
      final fontEncoded = config['fontBase64']?.toString() ?? '';
      if (fontEncoded.isNotEmpty) {
        await _loadImportedBytes(
          base64Decode(fontEncoded),
          config['fontName']?.toString() ?? '字体文件',
        );
      }
      setState(() {
        _textController.text =
            config['previewText']?.toString() ?? _textController.text;
        _size = (config['size'] as num?)?.toDouble() ?? 0;
        _weight = (config['weight'] as num?)?.toDouble() ?? 0;
        _spacing = (config['spacing'] as num?)?.toDouble() ?? 0;
        _rise = (config['rise'] as num?)?.toDouble() ?? 0;
        _line = (config['line'] as num?)?.toDouble() ?? 0;
        _targetAll = config['targetAll'] != false;
        _targetCharsController.text = config['targetChars']?.toString() ?? '';
        _characterAdjustments
          ..clear()
          ..addAll(
            (config['characterAdjustments'] as Map? ?? {}).map(
              (key, value) => MapEntry(
                key.toString(),
                Map<String, double>.from(
                  (value as Map).map(
                    (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
                  ),
                ),
              ),
            ),
          );
        _replacements
          ..clear()
          ..addAll(
            (config['replacements'] as Map? ?? {}).map(
              (key, value) =>
                  MapEntry(key.toString(), base64Decode(value.toString())),
            ),
          );
        _characterColors
          ..clear()
          ..addAll(
            (config['characterColors'] as Map? ?? {}).map(
              (key, value) =>
                  MapEntry(key.toString(), _parseColor(value.toString())),
            ),
          );
        _globalColor = _parseColor(
          config['globalColor']?.toString() ?? '#000000',
        );
        _randomPalette
          ..clear()
          ..addAll(
            (config['randomColors'] as List? ?? []).map(
              (value) => _parseColor(value.toString()),
            ),
          );
      });
      _message('配置读取成功');
    } catch (error) {
      _message('配置读取失败：$error');
    }
  }

  Future<void> _importZip() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'pickZip',
    );
    final encoded = result?['base64']?.toString() ?? '';
    if (encoded.isEmpty) return;
    try {
      final archive = ZipDecoder().decodeBytes(base64Decode(encoded));
      var count = 0;
      for (final file in archive.files.where(
        (file) => file.isFile && file.name.toLowerCase().endsWith('.png'),
      )) {
        final chars = file.name.split('/').last.characters;
        if (chars.isEmpty) continue;
        final char = chars.first;
        _replacements[char] = Uint8List.fromList(file.content as List<int>);
        count++;
      }
      setState(() {});
      _message(count == 0 ? 'ZIP 中没有找到 PNG 图片' : '已导入 $count 个图片字符');
    } catch (error) {
      _message('ZIP 解析失败：$error');
    }
  }

  Future<void> _renameFont() async {
    if (_fontBytes == null) return _message('请先导入字体');
    final family = TextEditingController(
      text: _fontName.replaceFirst(
        RegExp(r'\.(ttf|otf|ttc)$', caseSensitive: false),
        '',
      ),
    );
    final subfamily = TextEditingController(text: 'Regular');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('字体改名'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: family,
              decoration: const InputDecoration(labelText: '字体家族名称'),
            ),
            TextField(
              controller: subfamily,
              decoration: const InputDecoration(labelText: '样式名称'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (accepted != true || family.text.trim().isEmpty) return;
    final safePostScript = '${family.text}-${subfamily.text}'.replaceAll(
      RegExp(r'[^A-Za-z0-9-]'),
      '-',
    );
    final result = await _channel
        .invokeMethod<Map<Object?, Object?>>('renameFont', {
          'base64': base64Encode(_fontBytes!),
          'family': family.text.trim(),
          'subfamily': subfamily.text.trim(),
          'fullName': '${family.text.trim()} ${subfamily.text.trim()}',
          'postScript': safePostScript,
        });
    final encoded = result?['base64']?.toString() ?? '';
    if (encoded.isEmpty) return;
    final bytes = base64Decode(encoded);
    final fontFamily = 'BSFont_${DateTime.now().microsecondsSinceEpoch}';
    final loader = FontLoader(fontFamily)
      ..addFont(
        Future.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
        ),
      );
    await loader.load();
    if (!mounted) return;
    setState(() {
      _fontBytes = bytes;
      _fontFamily = fontFamily;
      _fontName = '${family.text.trim()}.ttf';
    });
    _message('字体名称已更新');
  }

  Future<void> _loadImportedBytes(Uint8List bytes, String name) async {
    final family = 'BSFont_${DateTime.now().microsecondsSinceEpoch}';
    final loader = FontLoader(family)
      ..addFont(
        Future.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
        ),
      );
    await loader.load();
    if (!mounted) return;
    setState(() {
      _fontBytes = bytes;
      _originalFontBytes = Uint8List.fromList(bytes);
      _fontName = name;
      _fontFamily = family;
      _originalFontFamily = family;
    });
  }

  Color _parseColor(String value) {
    final hex = value.replaceFirst('#', '');
    final number = int.tryParse(hex, radix: 16) ?? 0;
    return Color(0xFF000000 | number);
  }

  Future<void> _resetFont() async {
    final bytes = _originalFontBytes;
    if (bytes == null) return;
    final family = 'BSFont_${DateTime.now().microsecondsSinceEpoch}';
    final loader = FontLoader(family)
      ..addFont(
        Future.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
        ),
      );
    await loader.load();
    if (!mounted) return;
    setState(() {
      _fontBytes = Uint8List.fromList(bytes);
      _fontFamily = family;
      _size = _weight = _spacing = _rise = _line = 0;
      _characterAdjustments.clear();
      _characterColors.clear();
      _randomPalette.clear();
      _replacements.clear();
      _globalColor = Colors.black;
      _singleSize = _singleSpacing = _singleX = _singleY = 0;
    });
  }

  String _hex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  void _generateRandomColors() {
    final random = Random.secure();
    setState(() {
      _randomPalette
        ..clear()
        ..addAll(
          List.generate(
            _randomPoolSize,
            (_) => Color.fromARGB(
              255,
              35 + random.nextInt(196),
              35 + random.nextInt(196),
              35 + random.nextInt(196),
            ),
          ),
        );
    });
  }

  Future<void> _chooseColor({
    required Color initial,
    required ValueChanged<Color> onSelected,
  }) async {
    const colors = [
      Colors.black,
      Color(0xFFE11D48),
      Color(0xFFF97316),
      Color(0xFFEAB308),
      Color(0xFF16A34A),
      Color(0xFF0891B2),
      Color(0xFF2563EB),
      Color(0xFF7C3AED),
      Color(0xFFDB2777),
      Color(0xFF64748B),
    ];
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Wrap(
            spacing: 16,
            runSpacing: 16,
            children: colors
                .map(
                  (color) => InkWell(
                    onTap: () {
                      onSelected(color);
                      Navigator.pop(context);
                    },
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color == initial
                              ? Colors.white
                              : Colors.transparent,
                          width: 3,
                        ),
                        boxShadow: const [
                          BoxShadow(color: Color(0x22000000), blurRadius: 5),
                        ],
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }

  void _updateSingle(String key, double value) {
    final chars = _singleCharController.text.characters;
    if (chars.isEmpty) return;
    final char = chars.first;
    final values = _characterAdjustments.putIfAbsent(
      char,
      () => {'size': 0, 'spacing': 0, 'x': 0, 'y': 0},
    );
    values[key] = value;
    setState(() {
      if (key == 'size') _singleSize = value;
      if (key == 'spacing') _singleSpacing = value;
      if (key == 'x') _singleX = value;
      if (key == 'y') _singleY = value;
    });
  }

  void _selectSingleCharacter(String value) {
    final chars = value.characters;
    final adjustment = chars.isEmpty
        ? const <String, double>{}
        : (_characterAdjustments[chars.first] ?? const <String, double>{});
    setState(() {
      _singleSize = adjustment['size'] ?? 0;
      _singleSpacing = adjustment['spacing'] ?? 0;
      _singleX = adjustment['x'] ?? 0;
      _singleY = adjustment['y'] ?? 0;
    });
  }

  String? _replacementCharacter() {
    final chars = _replacementCharController.text.characters;
    return chars.isEmpty ? null : chars.first;
  }

  Future<void> _bindImportedImage({bool notify = true}) async {
    final char = _replacementCharacter();
    if (char == null || _imageBytes == null) {
      if (notify) _message('请输入目标字符并导入图片');
      return;
    }
    final codec = await ui.instantiateImageCodec(_imageBytes!);
    final frame = await codec.getNextFrame();
    const side = 512.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()
      ..filterQuality = _imageSmoothing
          ? FilterQuality.high
          : FilterQuality.none;
    final drawSize = side * _imageScale.clamp(.2, 1.6);
    final rect = Rect.fromLTWH(
      (side - drawSize) / 2 + _imageX * 3,
      (side - drawSize) / 2 - _imageY * 3,
      drawSize,
      drawSize,
    );
    canvas.drawImageRect(
      frame.image,
      Rect.fromLTWH(
        0,
        0,
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      ),
      rect,
      paint,
    );
    final rendered = await recorder.endRecording().toImage(512, 512);
    final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null || !mounted) return;
    setState(() {
      _replacements[char] = bytes.buffer.asUint8List();
      _characterAdjustments.putIfAbsent(
        char,
        () => {'size': 0, 'spacing': 0, 'x': 0, 'y': 0},
      )['spacing'] = _imageSpacing;
    });
    if (notify) _message('图片已绑定到字符 $char');
  }

  Future<void> _bindDrawing() async {
    final char = _replacementCharacter();
    if (char == null || _drawPoints.isEmpty) return _message('请输入目标字符并完成手绘');
    final restoreGrid = _drawGrid;
    if (restoreGrid) {
      setState(() => _drawGrid = false);
      await WidgetsBinding.instance.endOfFrame;
    }
    final boundary =
        _drawBoundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) {
      if (restoreGrid && mounted) setState(() => _drawGrid = true);
      return;
    }
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || !mounted) return;
    setState(() => _replacements[char] = data.buffer.asUint8List());
    if (restoreGrid) setState(() => _drawGrid = true);
    _message('手绘已绑定到字符 $char');
  }

  void _undoDrawing() {
    if (_drawUndo.isEmpty) return;
    setState(() {
      _drawRedo.add(List<Offset>.of(_drawPoints));
      _drawPoints
        ..clear()
        ..addAll(_drawUndo.removeLast());
    });
  }

  void _redoDrawing() {
    if (_drawRedo.isEmpty) return;
    setState(() {
      _drawUndo.add(List<Offset>.of(_drawPoints));
      _drawPoints
        ..clear()
        ..addAll(_drawRedo.removeLast());
    });
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  String _accountLine() {
    final username = widget.user.username.toString();
    if (widget.user.role.toString() == 'admin') return '$username · 永久有效';
    final expire = widget.user.expireTime?.toString().trim() ?? '';
    return '$username · 到期 ${expire.isEmpty ? '未知' : expire}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('BS字体修符', style: TextStyle(fontWeight: FontWeight.w800)),
            Text(
              _accountLine(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _pickFont,
            tooltip: '导入字体',
            icon: const Icon(Icons.font_download_outlined),
          ),
          IconButton(
            onPressed: _pickingImage ? null : _pickImage,
            tooltip: '导入图片',
            icon: const Icon(Icons.image_outlined),
          ),
          IconButton(
            onPressed: _busy ? null : _exportFont,
            tooltip: '导出字体',
            icon: const Icon(Icons.ios_share_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'restore') _resetFont();
              if (value == 'rename') _renameFont();
              if (value == 'import_config') _importConfig();
              if (value == 'export_config') _exportConfig();
              if (value == 'import_zip') _importZip();
              if (value == 'logout') widget.onLogout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'restore', child: Text('还原字体')),
              PopupMenuItem(value: 'rename', child: Text('字体改名')),
              PopupMenuItem(value: 'import_zip', child: Text('导入 ZIP 图片包')),
              PopupMenuItem(value: 'import_config', child: Text('导入配置')),
              PopupMenuItem(value: 'export_config', child: Text('导出配置')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _preview(),
            NavigationBar(
              height: 62,
              selectedIndex: _tab,
              onDestinationSelected: (value) => setState(() => _tab = value),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.tune), label: '排版'),
                NavigationDestination(
                  icon: Icon(Icons.palette_outlined),
                  label: '颜色',
                ),
                NavigationDestination(
                  icon: Icon(Icons.image_outlined),
                  label: '图片',
                ),
                NavigationDestination(
                  icon: Icon(Icons.draw_outlined),
                  label: '手绘',
                ),
              ],
            ),
            Expanded(
              child: ColoredBox(
                color: Colors.white,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: switch (_tab) {
                    0 => _fontControls(),
                    1 => _colorControls(),
                    2 => _imageControls(),
                    _ => _drawControls(),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview() => Container(
    height: 330,
    margin: const EdgeInsets.fromLTRB(12, 10, 12, 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE5E7EB)),
    ),
    child: Column(
      children: [
        SizedBox(
          height: 44,
          child: TextField(
            controller: _textController,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '输入预览文字',
              prefixIcon: Icon(Icons.edit_outlined),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _previewBand('当前效果', false)),
        const Divider(height: 1),
        Expanded(child: _previewBand('修改前', true)),
        Text(
          _fontName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
        ),
      ],
    ),
  );

  Widget _previewBand(String label, bool original) => Stack(
    children: [
      Positioned(
        left: 0,
        top: 5,
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Color(0xFF6B7280),
          ),
        ),
      ),
      Center(
        child: original
            ? Text(
                _textController.text.isEmpty ? '预览文字' : _textController.text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: _originalFontFamily,
                  fontSize: 27,
                  color: const Color(0xFF6B7280),
                ),
              )
            : _modifiedText(),
      ),
    ],
  );

  Widget _modifiedText() {
    final text = _textController.text.isEmpty ? '预览文字' : _textController.text;
    final baseSize = (28 * (1 + _size / 100)).clamp(8, 72).toDouble();
    return Wrap(
      alignment: WrapAlignment.center,
      runAlignment: WrapAlignment.center,
      spacing: 0,
      children: text.characters.map((char) {
        final adjustment = _characterAdjustments[char] ?? const {};
        final size = (baseSize * (1 + (adjustment['size'] ?? 0) / 100))
            .clamp(6, 96)
            .toDouble();
        final liveImage =
            _imageBytes != null && char == _replacementCharacter();
        final replacement = liveImage ? _imageBytes : _replacements[char];
        final color =
            _characterColors[char] ??
            (_randomPalette.isNotEmpty
                ? _randomPalette[char.codeUnitAt(0) % _randomPalette.length]
                : _globalColor);
        final textStyle = TextStyle(
          fontFamily: _fontFamily,
          fontSize: size,
          color: color,
          fontWeight: _previewWeight(),
        );
        final child = replacement != null
            ? liveImage
                  ? _liveReplacementImage(replacement, size)
                  : Image.memory(replacement, width: size, height: size)
            : Text(char, style: textStyle);
        final painter = TextPainter(
          text: TextSpan(text: char, style: textStyle),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        final naturalWidth = replacement != null ? size : painter.width;
        final characterSpacing = liveImage
            ? _imageSpacing
            : (adjustment['spacing'] ?? 0);
        final layoutWidth = max(
          1.0,
          naturalWidth + _spacing * .25 + characterSpacing * .2,
        );
        return Transform.translate(
          offset: Offset(
            (adjustment['x'] ?? 0) * .25,
            -(_rise + (adjustment['y'] ?? 0)) * .25,
          ),
          child: SizedBox(
            width: layoutWidth,
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: double.infinity,
              child: child,
            ),
          ),
        );
      }).toList(),
    );
  }

  FontWeight _previewWeight() {
    final value = _weight.clamp(-50, 50).toDouble();
    if (value == 0) return FontWeight.w400;
    if (value < 0) {
      return FontWeight.lerp(FontWeight.w400, FontWeight.w100, -value / 50) ??
          FontWeight.w400;
    }
    return FontWeight.lerp(FontWeight.w400, FontWeight.w900, value / 50) ??
        FontWeight.w400;
  }

  Widget _liveReplacementImage(Uint8List bytes, double size) => SizedBox(
    width: size,
    height: size,
    child: ClipRect(
      child: Transform.translate(
        offset: Offset(_imageX * size * 3 / 512, -_imageY * size * 3 / 512),
        child: Transform.scale(
          scale: _imageScale,
          child: Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.fill,
            filterQuality: _imageSmoothing
                ? FilterQuality.high
                : FilterQuality.none,
          ),
        ),
      ),
    ),
  );

  Widget _fontControls() => ListView(
    key: const ValueKey('layout'),
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    children: [
      _sectionTitle('全局排版'),
      _slider('大小', _size, (v) => setState(() => _size = v)),
      _slider('粗细', _weight, (v) => setState(() => _weight = v)),
      _slider('字距', _spacing, (v) => setState(() => _spacing = v)),
      _slider('上下', _rise, (v) => setState(() => _rise = v)),
      _slider('行距', _line, (v) => setState(() => _line = v)),
      const SizedBox(height: 8),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, label: Text('全部字符')),
          ButtonSegment(value: false, label: Text('指定字符')),
        ],
        selected: {_targetAll},
        onSelectionChanged: (value) => setState(() => _targetAll = value.first),
      ),
      if (!_targetAll)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: TextField(
            controller: _targetCharsController,
            decoration: const InputDecoration(
              labelText: '需要调整的字符',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
      _sectionTitle('单字微调'),
      TextField(
        controller: _singleCharController,
        maxLength: 1,
        onChanged: _selectSingleCharacter,
        decoration: const InputDecoration(
          labelText: '单字调整',
          hintText: '输入一个字符',
          prefixIcon: Icon(Icons.text_fields),
          border: OutlineInputBorder(),
        ),
      ),
      _slider('单字大小', _singleSize, (v) => _updateSingle('size', v)),
      _slider('单字字距', _singleSpacing, (v) => _updateSingle('spacing', v)),
      _slider('单字左右', _singleX, (v) => _updateSingle('x', v)),
      _slider('单字上下', _singleY, (v) => _updateSingle('y', v)),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _resetFont,
              icon: const Icon(Icons.restart_alt),
              label: const Text('重置字体'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              onPressed: _busy ? null : _applyAdjustments,
              icon: const Icon(Icons.check_circle_outline),
              label: Text(_busy ? '处理中...' : '应用调整'),
            ),
          ),
        ],
      ),
    ],
  );

  Widget _slider(
    String label,
    double value,
    ValueChanged<double> onChanged, {
    double min = -50,
    double max = 50,
    double step = 1,
    String Function(double value)? valueLabel,
  }) {
    double stepped(double next) {
      final snapped = (next / step).round() * step;
      return snapped.clamp(min, max).toDouble();
    }

    final divisions = ((max - min) / step).round().clamp(1, 10000).toInt();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 62, child: Text(label)),
          IconButton(
            onPressed: value > min
                ? () => onChanged(stepped(value - step))
                : null,
            tooltip: '减少 $label',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            iconSize: 18,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          IconButton(
            onPressed: value < max
                ? () => onChanged(stepped(value + step))
                : null,
            tooltip: '增加 $label',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            iconSize: 18,
            icon: const Icon(Icons.add_circle_outline),
          ),
          SizedBox(
            width: 48,
            child: Text(
              valueLabel?.call(value) ?? '${value.round()}%',
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
    ),
  );

  Widget _colorControls() => ListView(
    key: const ValueKey('colors'),
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    children: [
      _sectionTitle('全局颜色'),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('全部字符颜色'),
        trailing: _colorSwatch(
          _globalColor,
          () => _chooseColor(
            initial: _globalColor,
            onSelected: (color) => setState(() => _globalColor = color),
          ),
        ),
      ),
      _sectionTitle('随机改色'),
      _slider(
        '色值',
        _randomPoolSize.toDouble(),
        (value) => setState(() => _randomPoolSize = value.round()),
        min: 2,
        max: 64,
        valueLabel: (value) => '${value.round()}色',
      ),
      Row(
        children: [
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: _generateRandomColors,
              icon: const Icon(Icons.casino_outlined),
              label: const Text('生成随机颜色'),
            ),
          ),
          IconButton(
            onPressed: () => setState(_randomPalette.clear),
            tooltip: '清除随机颜色',
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      if (_randomPalette.isNotEmpty)
        Wrap(
          spacing: 5,
          runSpacing: 5,
          children: _randomPalette
              .map(
                (color) => Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              )
              .toList(),
        ),
      _sectionTitle('单字 / 多字改色'),
      TextField(
        controller: _colorCharsController,
        decoration: const InputDecoration(
          labelText: '输入一个或多个字符',
          hintText: '例如：你好ABC',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _chooseColor(
                initial: _selectedColor,
                onSelected: (color) => setState(() => _selectedColor = color),
              ),
              icon: _colorSwatch(_selectedColor, () {}),
              label: const Text('选择颜色'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: _applyCharacterColor,
              child: const Text('应用到字符'),
            ),
          ),
        ],
      ),
      ..._characterColors.entries.map(
        (entry) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: _colorSwatch(entry.value, () {}),
          title: Text(entry.key),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _characterColors.remove(entry.key)),
          ),
        ),
      ),
    ],
  );

  Widget _colorSwatch(Color color, VoidCallback onTap) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(20),
    child: Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFD1D5DB)),
      ),
    ),
  );

  void _applyCharacterColor() {
    if (_colorCharsController.text.isEmpty) return;
    setState(() {
      for (final char in _colorCharsController.text.characters) {
        _characterColors[char] = _selectedColor;
      }
    });
  }

  Widget _imageControls() => ListView(
    key: const ValueKey('images'),
    padding: const EdgeInsets.all(16),
    children: [
      TextField(
        controller: _replacementCharController,
        maxLength: 1,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: '绑定字符',
          hintText: '输入一个字符',
          prefixIcon: Icon(Icons.link),
          border: OutlineInputBorder(),
        ),
      ),
      FilledButton.icon(
        onPressed: _pickingImage ? null : _pickImage,
        icon: const Icon(Icons.photo_library_outlined),
        label: Text(_pickingImage ? '正在打开相册...' : '从相册导入图片'),
      ),
      if (_imageBytes != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(child: _liveReplacementImage(_imageBytes!, 120)),
        ),
      _sectionTitle('图片参数'),
      _slider(
        '大小',
        _imageScale,
        (value) => setState(() => _imageScale = value),
        min: .3,
        max: 1.5,
        step: .05,
        valueLabel: (value) => '${(value * 100).round()}%',
      ),
      _slider(
        '字距',
        _imageSpacing,
        (value) => setState(() => _imageSpacing = value),
      ),
      _slider('左右', _imageX, (value) => setState(() => _imageX = value)),
      _slider('上下', _imageY, (value) => setState(() => _imageY = value)),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('平滑轮廓'),
        value: _imageSmoothing,
        onChanged: (value) => setState(() => _imageSmoothing = value),
      ),
      FilledButton.tonalIcon(
        onPressed: _imageBytes == null ? null : _bindImportedImage,
        icon: const Icon(Icons.link),
        label: const Text('把图片绑定到字符'),
      ),
      ..._replacements.entries.map(
        (entry) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Image.memory(entry.value, width: 44, height: 44),
          title: Text('绑定字符：${entry.key}'),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() => _replacements.remove(entry.key)),
          ),
        ),
      ),
    ],
  );

  Widget _drawControls() => ListView(
    key: const ValueKey('draw'),
    padding: const EdgeInsets.all(16),
    children: [
      TextField(
        controller: _replacementCharController,
        maxLength: 1,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: '绑定字符',
          hintText: '输入一个字符',
          prefixIcon: Icon(Icons.link),
          border: OutlineInputBorder(),
        ),
      ),
      RepaintBoundary(
        key: _drawBoundaryKey,
        child: Container(
          height: 180,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFD1D5DB)),
          ),
          child: GestureDetector(
            onPanStart: (_) {
              _drawUndo.add(List<Offset>.of(_drawPoints));
              _drawRedo.clear();
            },
            onPanUpdate: (details) =>
                setState(() => _drawPoints.add(details.localPosition)),
            onPanEnd: (_) => setState(() => _drawPoints.add(Offset.infinite)),
            child: CustomPaint(
              painter: _DrawPainter(
                List<Offset>.of(_drawPoints),
                color: _drawColor,
                strokeWidth: _drawSize,
                showGrid: _drawGrid,
              ),
            ),
          ),
        ),
      ),
      Row(
        children: [
          IconButton(
            onPressed: _undoDrawing,
            tooltip: '撤销',
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            onPressed: _redoDrawing,
            tooltip: '重做',
            icon: const Icon(Icons.redo),
          ),
          _colorSwatch(
            _drawColor,
            () => _chooseColor(
              initial: _drawColor,
              onSelected: (color) => setState(() => _drawColor = color),
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: () => setState(() => _drawGrid = !_drawGrid),
            tooltip: '网格',
            icon: Icon(
              Icons.grid_4x4,
              color: _drawGrid ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
        ],
      ),
      _slider(
        '笔刷',
        _drawSize,
        (value) => setState(() => _drawSize = value),
        min: 1,
        max: 24,
        valueLabel: (value) => '${value.round()}',
      ),
      FilledButton.tonalIcon(
        onPressed: _bindDrawing,
        icon: const Icon(Icons.link),
        label: const Text('把手绘绑定到字符'),
      ),
      if (_replacements.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            '已绑定：${_replacements.keys.join('、')}',
            textAlign: TextAlign.center,
          ),
        ),
      TextButton.icon(
        onPressed: () => setState(_drawPoints.clear),
        icon: const Icon(Icons.delete_outline),
        label: const Text('清空手绘'),
      ),
    ],
  );
}

class _DrawPainter extends CustomPainter {
  const _DrawPainter(
    this.points, {
    required this.color,
    required this.strokeWidth,
    required this.showGrid,
  });
  final List<Offset> points;
  final Color color;
  final double strokeWidth;
  final bool showGrid;
  @override
  void paint(Canvas canvas, Size size) {
    if (showGrid) {
      final gridPaint = Paint()
        ..color = const Color(0xFFE5E7EB)
        ..strokeWidth = 1;
      for (double value = 30; value < size.width; value += 30) {
        canvas.drawLine(
          Offset(value, 0),
          Offset(value, size.height),
          gridPaint,
        );
      }
      for (double value = 30; value < size.height; value += 30) {
        canvas.drawLine(Offset(0, value), Offset(size.width, value), gridPaint);
      }
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    var previous = Offset.zero;
    for (final point in points) {
      if (point == Offset.infinite) {
        previous = Offset.zero;
        continue;
      }
      if (previous != Offset.zero) canvas.drawLine(previous, point, paint);
      previous = point;
    }
  }

  @override
  bool shouldRepaint(covariant _DrawPainter oldDelegate) => true;
}
