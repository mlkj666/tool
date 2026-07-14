import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ),
  );
  runApp(const BsFontApp());
}

class BsFontApp extends StatelessWidget {
  const BsFontApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BS字体修符',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Arial',
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.black,
          brightness: Brightness.light,
        ),
      ),
      home: const AppGate(),
    );
  }
}

class SessionUser {
  const SessionUser({
    required this.username,
    required this.role,
    this.expireTime,
  });

  final String username;
  final String role;
  final String? expireTime;

  factory SessionUser.fromJson(Map<String, dynamic> json) {
    return SessionUser(
      username: (json['username'] ?? '').toString(),
      role: (json['role'] ?? 'user').toString(),
      expireTime: json['expire_time']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'username': username,
      'role': role,
      'expire_time': expireTime ?? '',
    };
  }
}

class AppGate extends StatefulWidget {
  const AppGate({super.key});

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  SessionUser? _user;
  String? _cookie;
  var _booting = true;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final userJson = prefs.getString('bs_user');
    final cookie = prefs.getString('bs_cookie');
    if (userJson != null) {
      try {
        _user = SessionUser.fromJson(jsonDecode(userJson));
        _cookie = cookie;
      } catch (_) {
        await prefs.remove('bs_user');
      }
    }
    if (mounted) setState(() => _booting = false);
  }

  Future<void> _saveSession(SessionUser user, String? cookie) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bs_user', jsonEncode(user.toJson()));
    if (cookie != null && cookie.isNotEmpty) {
      await prefs.setString('bs_cookie', cookie);
    }
    setState(() {
      _user = user;
      _cookie = cookie;
    });
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('bs_user');
    await prefs.remove('bs_cookie');
    setState(() {
      _user = null;
      _cookie = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_booting) return const SplashView();
    final user = _user;
    if (user == null) {
      return AuthScreen(onAuthenticated: _saveSession);
    }
    return ToolPanel(user: user, cookie: _cookie, onLogout: _logout);
  }
}

class SplashView extends StatelessWidget {
  const SplashView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
        ),
      ),
    );
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.onAuthenticated});

  final Future<void> Function(SessionUser user, String? cookie) onAuthenticated;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  static final Uri _api = Uri.parse('https://tool.uxgzs.icu/api.php');

  final _username = TextEditingController();
  final _password = TextEditingController();
  final _license = TextEditingController();
  final _focusPassword = FocusNode();
  final _focusLicense = FocusNode();

  var _registerMode = false;
  var _loading = false;
  var _obscure = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _license.dispose();
    _focusPassword.dispose();
    _focusLicense.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _callApi(
    String action,
    Map<String, String> body,
  ) async {
    final response = await http.post(
      _api.replace(queryParameters: {'action': action}),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: body,
    );
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    return {'success': false, 'msg': '服务器响应格式异常'};
  }

  String? _sessionCookie(http.Response response) {
    final raw = response.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return null;
    return raw.split(';').first;
  }

  Future<void> _submit() async {
    final username = _username.text.trim();
    final password = _password.text.trim();
    final license = _license.text.trim();

    if (username.isEmpty || password.isEmpty) {
      _toast('请输入账号和密码', isError: true);
      return;
    }
    if (_registerMode && license.isEmpty) {
      _toast('请输入授权卡密', isError: true);
      return;
    }

    setState(() => _loading = true);
    try {
      if (_registerMode) {
        final data = await _callApi('register', {
          'username': username,
          'password': password,
          'license_key': license,
        });
        if (data['success'] == true) {
          _toast('注册成功，请登录');
          setState(() => _registerMode = false);
        } else {
          _toast((data['msg'] ?? '注册失败').toString(), isError: true);
        }
      } else {
        final response = await http.post(
          _api.replace(queryParameters: {'action': 'login'}),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {'username': username, 'password': password},
        );
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data is Map<String, dynamic> && data['success'] == true) {
          final user = SessionUser.fromJson(data['user']);
          await widget.onAuthenticated(user, _sessionCookie(response));
        } else {
          _toast((data['msg'] ?? '登录失败').toString(), isError: true);
        }
      }
    } catch (_) {
      _toast('网络连接失败，请稍后再试', isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String message, {bool isError = false}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: isError ? const Color(0xFFEF4444) : Colors.white,
        margin: const EdgeInsets.fromLTRB(18, 0, 18, 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Text(
          message,
          style: TextStyle(
            color: isError ? Colors.white : Colors.black,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const _AuthBackdrop(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 24, 22, 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 30,
                          offset: Offset(0, 18),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _BrandHeader(),
                        const SizedBox(height: 22),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: Column(
                            key: ValueKey(_registerMode),
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _registerMode ? '创建账号' : '欢迎回来',
                                style: const TextStyle(
                                  fontSize: 28,
                                  height: 1.1,
                                  color: Colors.black,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _registerMode
                                    ? '输入授权卡密，开启字体修符工作台'
                                    : '登录后继续进入你的字符面板',
                                style: const TextStyle(
                                  color: Color(0xFF6B7280),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 24),
                              _InputField(
                                controller: _username,
                                hint: '账号',
                                icon: Icons.person_rounded,
                                textInputAction: TextInputAction.next,
                                onSubmitted: (_) =>
                                    _focusPassword.requestFocus(),
                              ),
                              const SizedBox(height: 12),
                              _InputField(
                                controller: _password,
                                focusNode: _focusPassword,
                                hint: '密码',
                                icon: Icons.lock_rounded,
                                obscureText: _obscure,
                                textInputAction: _registerMode
                                    ? TextInputAction.next
                                    : TextInputAction.done,
                                suffix: IconButton(
                                  onPressed: () {
                                    setState(() => _obscure = !_obscure);
                                  },
                                  icon: Icon(
                                    _obscure
                                        ? Icons.visibility_rounded
                                        : Icons.visibility_off_rounded,
                                  ),
                                ),
                                onSubmitted: (_) {
                                  if (_registerMode) {
                                    _focusLicense.requestFocus();
                                  } else {
                                    _submit();
                                  }
                                },
                              ),
                              AnimatedSize(
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                child: _registerMode
                                    ? Padding(
                                        padding: const EdgeInsets.only(top: 12),
                                        child: _InputField(
                                          controller: _license,
                                          focusNode: _focusLicense,
                                          hint: '授权卡密',
                                          icon: Icons.verified_user_rounded,
                                          textInputAction: TextInputAction.done,
                                          onSubmitted: (_) => _submit(),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                              const SizedBox(height: 20),
                              _PrimaryButton(
                                loading: _loading,
                                label: _registerMode ? '注册并验证' : '登录',
                                onPressed: _submit,
                              ),
                              const SizedBox(height: 14),
                              TextButton(
                                onPressed: _loading
                                    ? null
                                    : () {
                                        setState(
                                          () => _registerMode = !_registerMode,
                                        );
                                      },
                                child: Text(
                                  _registerMode ? '已有账号，返回登录' : '没有账号，使用卡密注册',
                                  style: const TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ToolPanel extends StatefulWidget {
  const ToolPanel({
    super.key,
    required this.user,
    required this.cookie,
    required this.onLogout,
  });

  final SessionUser user;
  final String? cookie;
  final Future<void> Function() onLogout;

  @override
  State<ToolPanel> createState() => _ToolPanelState();
}

class _ToolPanelState extends State<ToolPanel> {
  late final WebViewController _controller;
  var _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel(
        'AppBridge',
        onMessageReceived: (message) {
          if (message.message == 'logout') widget.onLogout();
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) => setState(() => _progress = progress),
          onPageStarted: (_) => setState(() => _error = null),
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) {
              setState(() => _error = error.description);
            }
          },
        ),
      );
    _loadTool();
  }

  Future<void> _loadTool() async {
    var html = await rootBundle.loadString('assets/web/tool.html');
    html = html.replaceFirst(
      '__BS_APP_USER_JSON__',
      jsonEncode(widget.user.toJson()),
    );
    await _controller.loadHtmlString(html);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Stack(
            children: [
              if (_error == null)
                WebViewWidget(controller: _controller)
              else
                _LoadErrorView(message: _error!, onRetry: _loadTool),
              if (_progress > 0 && _progress < 100)
                LinearProgressIndicator(
                  value: _progress / 100,
                  minHeight: 2,
                  color: Colors.black,
                  backgroundColor: Colors.transparent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthBackdrop extends StatelessWidget {
  const _AuthBackdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF050505), Color(0xFF18181B), Color(0xFF000000)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 70,
            right: -80,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x22FFFFFF), width: 28),
              ),
            ),
          ),
          Positioned(
            left: -70,
            bottom: 100,
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x18FFFFFF), width: 22),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Image.asset(
            'assets/images/app_icon.png',
            width: 64,
            height: 64,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'BS字体修符',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 4),
              Text(
                '字符面板 · 字体创作台',
                style: TextStyle(
                  color: Color(0xFF6B7280),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InputField extends StatelessWidget {
  const _InputField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.focusNode,
    this.obscureText = false,
    this.suffix,
    this.textInputAction,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final IconData icon;
  final bool obscureText;
  final Widget? suffix;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscureText,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      style: const TextStyle(fontWeight: FontWeight.w800),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon),
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFFF4F4F5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Colors.black, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.loading,
    required this.label,
    required this.onPressed,
  });

  final bool loading;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.black,
          disabledBackgroundColor: const Color(0xFF52525B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: loading
              ? const SizedBox(
                  key: ValueKey('loading'),
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(
                  label,
                  key: const ValueKey('label'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
        ),
      ),
    );
  }
}

class _LoadErrorView extends StatelessWidget {
  const _LoadErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 42),
            const SizedBox(height: 16),
            const Text(
              '字符面板加载失败',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onRetry, child: const Text('重新加载')),
          ],
        ),
      ),
    );
  }
}
