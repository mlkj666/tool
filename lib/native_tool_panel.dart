import 'dart:convert';
import 'dart:ui' as ui;
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
  Uint8List? _fontBytes;
  Uint8List? _originalFontBytes;
  String _fontName = '未加载字体';
  String? _fontFamily;
  Uint8List? _imageBytes;
  double _size = 0;
  double _weight = 0;
  double _spacing = 0;
  double _rise = 0;
  double _line = 0;
  bool _busy = false;
  int _tab = 0;
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
      });
    } catch (error) {
      _message('字体导入失败：$error');
    }
  }

  Future<void> _pickImage() async {
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
    }
  }

  Future<void> _applyAdjustments() async {
    if (_fontBytes == null) {
      _message('请先导入字体');
      return;
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
            'targetAll': true,
            'chars': '',
            'characterAdjustments': _characterAdjustments,
            'replacements': _replacements.map(
              (key, value) => MapEntry(key, base64Encode(value)),
            ),
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
      _singleSize = _singleSpacing = _singleX = _singleY = 0;
    });
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

  String? _replacementCharacter() {
    final chars = _replacementCharController.text.characters;
    return chars.isEmpty ? null : chars.first;
  }

  void _bindImportedImage() {
    final char = _replacementCharacter();
    if (char == null || _imageBytes == null) return _message('请输入目标字符并导入图片');
    setState(() => _replacements[char] = Uint8List.fromList(_imageBytes!));
    _message('图片已绑定到字符 $char');
  }

  Future<void> _bindDrawing() async {
    final char = _replacementCharacter();
    if (char == null || _drawPoints.isEmpty) return _message('请输入目标字符并完成手绘');
    final boundary =
        _drawBoundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || !mounted) return;
    setState(() => _replacements[char] = data.buffer.asUint8List());
    _message('手绘已绑定到字符 $char');
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text(
          'BS字体修符',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            onPressed: _pickFont,
            tooltip: '导入字体',
            icon: const Icon(Icons.font_download_outlined),
          ),
          IconButton(
            onPressed: _pickImage,
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
              if (value == 'logout') widget.onLogout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _preview(scheme),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  label: Text('字体排版'),
                  icon: Icon(Icons.text_fields),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text('图片与手绘'),
                  icon: Icon(Icons.brush_outlined),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (value) => setState(() => _tab = value.first),
            ),
          ),
          Expanded(child: _tab == 0 ? _fontControls() : _imageControls()),
        ],
      ),
    );
  }

  Widget _preview(ColorScheme scheme) {
    final fontSize = (34 * (1 + _size / 100)).clamp(8, 160).toDouble();
    return Expanded(
      flex: 5,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: _textController,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: '输入预览文字',
                  prefixIcon: Icon(Icons.edit_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              if (_imageBytes != null)
                Image.memory(_imageBytes!, height: 120, fit: BoxFit.contain),
              Transform.translate(
                offset: Offset(0, -_rise * 0.35),
                child: Text(
                  _textController.text.isEmpty ? '预览文字' : _textController.text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: _fontFamily,
                    fontSize: fontSize,
                    height: (1.25 * (1 + _line / 100)).clamp(.4, 3),
                    letterSpacing: _spacing * .34,
                    fontWeight: FontWeight.lerp(
                      FontWeight.w300,
                      FontWeight.w900,
                      ((_weight + 50) / 100).clamp(0, 1),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _fontName,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fontControls() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
    children: [
      _slider('大小', _size, (v) => setState(() => _size = v)),
      _slider('粗细', _weight, (v) => setState(() => _weight = v)),
      _slider('字距', _spacing, (v) => setState(() => _spacing = v)),
      _slider('上下', _rise, (v) => setState(() => _rise = v)),
      _slider('行距', _line, (v) => setState(() => _line = v)),
      const SizedBox(height: 8),
      TextField(
        controller: _singleCharController,
        maxLength: 1,
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

  Widget _slider(String label, double value, ValueChanged<double> onChanged) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(label),
                  Text(
                    '${value.round()}%',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              Slider(
                value: value,
                min: -50,
                max: 50,
                divisions: 100,
                onChanged: onChanged,
              ),
            ],
          ),
        ),
      );

  Widget _imageControls() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      TextField(
        controller: _replacementCharController,
        maxLength: 1,
        decoration: const InputDecoration(
          labelText: '绑定字符',
          hintText: '输入一个字符',
          prefixIcon: Icon(Icons.link),
          border: OutlineInputBorder(),
        ),
      ),
      FilledButton.icon(
        onPressed: _pickImage,
        icon: const Icon(Icons.photo_library_outlined),
        label: const Text('从相册导入图片'),
      ),
      if (_imageBytes != null)
        OutlinedButton.icon(
          onPressed: _bindImportedImage,
          icon: const Icon(Icons.link),
          label: const Text('把图片绑定到字符'),
        ),
      const SizedBox(height: 12),
      RepaintBoundary(
        key: _drawBoundaryKey,
        child: Container(
          height: 180,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: GestureDetector(
            onPanUpdate: (details) =>
                setState(() => _drawPoints.add(details.localPosition)),
            onPanEnd: (_) => setState(() => _drawPoints.add(Offset.infinite)),
            child: CustomPaint(
              painter: _DrawPainter(List<Offset>.of(_drawPoints)),
            ),
          ),
        ),
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
  const _DrawPainter(this.points);
  final List<Offset> points;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 5
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
