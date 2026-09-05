import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'theme.dart';
import 'l10n/app_localizations.dart';
import 'providers/locale_provider.dart';
import 'providers/font_size_provider.dart';
import 'services/storage_service.dart';
import 'services/app_update_service.dart';
import 'services/biometric_service.dart';
import 'services/logger_service.dart';
import 'services/builtin_prompt_catalog.dart';
import 'models/api_provider_template.dart';
import 'di/providers.dart';
import 'screens/onboarding_language_screen.dart';
import 'screens/conversation_list_screen.dart';
import 'plugins/plugin_registry.dart';
import 'plugins/builtin_plugins.dart';

/// v1.7.12：全局 ScaffoldMessengerKey（启动后静默更新提示、全局 Toast 等场景需要脱离当前页面 context 弹 SnackBar）
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final logger = LoggerService.instance;
  // 先初始化 logger（后续所有埋点依赖它）
  logger.init().ignore();

  // v1.4.2：全局 Flutter 异常捕获（UI 线程同步错误）
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    logger.error(
      'FlutterError: ${details.exception}',
      stack: details.stack,
      cat: LogCat.error,
      tag: 'UI',
    );
  };

  // v1.4.2：全局异步异常捕获（async/await 链路上未被处理的 error）
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    logger.error(
      'PlatformDispatcher.uncaught: $error',
      error: error,
      stack: stack,
      cat: LogCat.error,
      tag: 'ASYNC',
    );
    return true;
  };

  runZonedGuarded(
    () => runApp(const AIChatApp()),
    (Object error, StackTrace stack) {
      logger.error(
        'runZonedGuarded: $error',
        error: error,
        stack: stack,
        cat: LogCat.error,
        tag: 'ZONE',
      );
    },
  );
}

class AIChatApp extends StatefulWidget {
  const AIChatApp({super.key});

  @override
  State<AIChatApp> createState() => _AIChatAppState();
}

class _AIChatAppState extends State<AIChatApp> with WidgetsBindingObserver {
  // v1.7.9 (M18)：去掉 late final，允许初始化失败后重试重赋值
  late Future<bool> _initFuture;
  final _logger = LoggerService.instance;

  // v1.6.5：全局唯一 LocaleProvider 实例（此前 _initApp 和 Provider 各建一个，
  // 后者从未 init() → 重启后 _locale 恒为 null → 回落系统语言，用户选的英文失效）
  late final LocaleProvider _localeProvider = LocaleProvider();
  late final FontSizeProvider _fontSizeProvider = FontSizeProvider();

  // v1.6.9：全局 PluginRegistry（插件化架构核心注册器）。
  // 用户要求：插件启用 → prompt 里加对应协议；禁用 → 不加；安装新插件 → 追加到后面。
  // **必须先同步创建**，否则 widget test 里 build 同步访问 MultiProvider 时会 LateInitializationError。
  // 构造函数内部会异步调用 _initFromStorage() 读启用状态，避免首屏读不到。
  final PluginRegistry _pluginRegistry = createBuiltinPluginRegistry();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _logger.app('initState: AIChatApp mounting, registering lifecycle observer');
    _initFuture = _initApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // v1.4.2：应用前后台生命周期埋点
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _logger.app('Lifecycle: ${state.name}');
  }

  Future<bool> _initApp() async {
    final stopwatch = Stopwatch()..start();
    await _logger.init();
    _logger.app('App starting (LoggerService ready in ${stopwatch.elapsedMilliseconds}ms)');

    await StorageService.instance.init();
    _logger.app('StorageService ready (total ${stopwatch.elapsedMilliseconds}ms)');

    // v1.7.32：远程模板/协议先加载本地成功缓存，再按 7 天策略在线更新。
    // 首次启动或上次失败会在本次启动重试一次，失败不清空旧缓存。
    await Future.wait([
      ApiProviderTemplateCatalog.instance.initialize(
        url: 'https://fastly.jsdelivr.net/gh/songchuangchang/a11@main/api_templates.json',
      ),
      BuiltinPromptCatalog.instance.initialize(
        url: 'https://fastly.jsdelivr.net/gh/songchuangchang/a11@main/builtin_prompts.json',
      ),
    ]);

    // v1.6.9：PluginRegistry 已经在字段初始化时同步 createBuiltinPluginRegistry()，
    // 这里仅绑定 StorageService 实例（它的 _initFromStorage 会从 storage 读插件启用状态），
    // 给 30ms 让内部 await StorageService 完成，避免首屏渲染时还没读。
    // 因为 createBuiltinPluginRegistry(storage: null) 时会用 StorageService.instance 兜底，
    // 所以这里不需要再手动重绑，只需要等一下即可。
    await Future.delayed(const Duration(milliseconds: 30));
    _logger.app('PluginRegistry ready (${_pluginRegistry.plugins.length} plugins, total ${stopwatch.elapsedMilliseconds}ms)');

    final localeProvider = _localeProvider;
    await _localeProvider.init();
    await _fontSizeProvider.init();
    final done = await localeProvider.isOnboardingCompleted;
    stopwatch.stop();
    _logger.app('Init complete: onboarded=$done, total ${stopwatch.elapsedMilliseconds}ms');
    return done;
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      // v1.7.24 (#12)：集中式 DI 层，见 lib/di/providers.dart + docs/DI_EVALUATION.md
      providers: buildAppProviders(
        localeProvider: _localeProvider,
        fontSizeProvider: _fontSizeProvider,
        pluginRegistry: _pluginRegistry,
      ),
      child: Consumer<LocaleProvider>(
        builder: (context, lp, child) {
          return Consumer<FontSizeProvider>(
            builder: (context, fsp, _) {
              return MaterialApp(
            // v1.7.29: textScaler 必须在 MaterialApp.builder 内注入；
            // 包在 MaterialApp 外层会被 WidgetsApp 内部 MediaQuery(fromView) 覆盖，字体缩放失效
            // v1.7.26: 生物识别锁全局门（builder 位于 Navigator 之上，覆盖所有路由/页面）
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(fsp.scale),
              ),
              child: _BiometricGate(child: child),
            ),
            title: 'Nexus',
            scaffoldMessengerKey: rootScaffoldMessengerKey,
            locale: lp.locale,
            navigatorObservers: [
              // v1.4.2：路由导航埋点 Observer（所有 push/pop/replace 都会落一条 NAV 日志）
              _LifecycleNavObserver(logger: _logger),
            ],
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [
              Locale('en'),
              Locale('zh'),
            ],
            localeResolutionCallback: (deviceLocale, supported) {
              if (lp.locale != null) return lp.locale;
              for (final s in supported) {
                if (deviceLocale?.languageCode == s.languageCode) {
                  return deviceLocale;
                }
              }
              return supported.first;
            },
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: ThemeMode.system,
            debugShowCheckedModeBanner: false,
            home: FutureBuilder<bool>(
              future: _initFuture,
              builder: (context, snapshot) {
                // v1.7.9 (M18 修复)：初始化抛异常时不再永久卡无按钮 loading 屏
                if (snapshot.hasError) {
                  _logger.error('App init failed: ${snapshot.error}',
                      error: snapshot.error);
                  return Scaffold(
                    body: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.error_outline,
                                size: 48, color: Theme.of(context).colorScheme.error),
                            const SizedBox(height: 16),
                            const Text(
                                '初始化失败 / Initialization failed',
                                style: TextStyle(fontSize: 16)),
                            const SizedBox(height: 8),
                            Text(
                              '${snapshot.error}',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: () {
                                // 重启进程级初始化
                                setState(() {
                                  _initFuture = _initApp();
                                });
                              },
                              child: const Text('重试 / Retry'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }
                final onboarded = snapshot.data!;
                if (!onboarded) {
                  _logger.nav('→ OnboardingLanguageScreen (first run)');
                  return const OnboardingLanguageScreen();
                }
                _logger.nav('→ ConversationListScreen');
                // v1.7.12 引入启动静默检查 / v1.7.13 加 one-shot 守卫
                // v1.7.13 修复：FutureBuilder 每次 rebuild 都会再注册一次 post-frame callback，
                //   导致启动后 5 秒内重复打 5 次 GitHub API（撞速率限制风险）。
                //   用 AppUpdateService.hasRunStartupSilentCheck 守卫保证每个进程只跑一次。
                if (!AppUpdateService.hasRunStartupSilentCheck) {
                  AppUpdateService.markStartupSilentCheckRun();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    Future<void>.delayed(const Duration(seconds: 3), () async {
                      try {
                        final ctx = rootScaffoldMessengerKey.currentContext;
                        final info = await AppUpdateService.checkForUpdate();
                        if (info.hasUpdate && ctx != null && ctx.mounted) {
                          final zh = Localizations.localeOf(ctx).languageCode == 'zh';
                          final sizeMb = (info.apkSize / 1024 / 1024).toStringAsFixed(1);
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text(zh
                                  ? '🎉 发现新版本 v${info.latestVersion}（${sizeMb}MB）\n去「设置 → 检查更新」下载安装'
                                  : '🎉 New version v${info.latestVersion} (${sizeMb}MB)\nGo to Settings → Check Update to install'),
                              duration: const Duration(seconds: 8),
                              action: SnackBarAction(
                                label: zh ? '知道了' : 'OK',
                                onPressed: () {},
                              ),
                            ),
                          );
                        }
                      } catch (_) {
                        // 静默忽略：网络不通 / 服务器 5xx 都不打扰用户
                      }
                    });
                  });
                }
                return const ConversationListScreen();
              },
            ),
          );
              },
            );
        },
      ),
    );
  }
}

/// 路由 Observer：所有页面进出都记一条 NAV 日志
/// 找 bug 时可以还原"用户按了什么 → 到了什么页面 → 然后崩了"的完整路径
class _LifecycleNavObserver extends NavigatorObserver {
  final LoggerService logger;
  _LifecycleNavObserver({required this.logger});

  String _name(Route<dynamic>? r) {
    if (r == null) return 'Route<null>';
    if (r.settings.name != null && r.settings.name!.isNotEmpty) return r.settings.name!;
    // Route.widget 不公开，fallback 用 runtimeType 字符串
    return r.runtimeType.toString();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    logger.nav('push: ${_name(previousRoute)} → ${_name(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    logger.nav('pop:  ${_name(route)} → ${_name(previousRoute)}');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    logger.nav('replace: ${_name(oldRoute)} → ${_name(newRoute)}');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    logger.nav('remove: ${_name(route)} (prev=${_name(previousRoute)})');
  }
}


// ===== v1.7.26：生物识别锁门 UI（启动画面 / 锁定页） =====
class _BiometricSplash extends StatelessWidget {
  const _BiometricSplash();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 56, color: colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Nexus',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

class _BiometricLockScreen extends StatelessWidget {
  final VoidCallback onUnlock;
  const _BiometricLockScreen({required this.onUnlock});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colorScheme.primaryContainer, colorScheme.surface],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 72, color: colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  'Nexus',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface),
                ),
                const SizedBox(height: 8),
                Text(
                  zh ? '应用已锁定 · 请验证身份' : 'App locked · Verify to continue',
                  style: TextStyle(
                      fontSize: 14, color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onUnlock,
                  icon: const Icon(Icons.fingerprint),
                  label: Text(zh ? '解锁 / Unlock' : 'Unlock'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ===== v1.7.26：生物识别锁全局门（MaterialApp.builder 挂载，覆盖所有路由） =====
//  - 监听 StorageService（ChangeNotifier）→ 开关切换实时生效，无需重启
//  - 验证通过前不渲染 child（含所有 push 页面）→ 修复"首页有锁、聊天页没锁"
//  - 回到前台立即重锁 + 自动验证（fail-closed：异常一律视为未验证）
class _BiometricGate extends StatefulWidget {
  final Widget? child;
  const _BiometricGate({this.child});

  @override
  State<_BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends State<_BiometricGate>
    with WidgetsBindingObserver {
  bool? _enabled; // null=检测中 / true=开启 / false=未开启
  bool _verified = false;
  bool _verifying = false; // 验证进行中：屏蔽 BiometricPrompt 弹/关触发的假 resumed
  bool _wasPaused = false; // 仅真正进入后台后，返回前台才重新验证
  bool _isZh = false;
  final _storage = StorageService.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _storage.addListener(_onStorageChanged);
    _apply();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _storage.removeListener(_onStorageChanged);
    super.dispose();
  }

  void _onStorageChanged() {
    // 设置页切开关 → saveWebSearchConfig notifyListeners → 这里实时响应
    _apply();
  }

  Future<void> _apply() async {
    try {
      final enabled = await _storage.getBiometricLockEnabled();
      if (!mounted) return;
      setState(() {
        final wasEnabled = _enabled;
        _enabled = enabled;
        if (!enabled) {
          _verified = true; // 关闭 → 直接解锁
        } else if (wasEnabled != true || !_verified) {
          _verified = false; // 开启（含刚打开/启动）→ 重置为需验证
        }
      });
      if (enabled == true && !_verified) {
        await _verify();
      }
    } catch (e) {
      LoggerService.instance.error('Biometric gate apply failed: $e', tag: 'BIOMETRIC');
      if (mounted) setState(() => _enabled = false);
    }
  }

  Future<void> _verify() async {
    // 防重入：BiometricPrompt 弹出/关闭会触发 spurious paused→resumed，
    // 若不拦截会导致 _verify 被叠加调用 → 解锁后立刻又弹一次。
    if (_verifying) return;
    _verifying = true;
    try {
      final authed = await BiometricService.authenticate(
        reason: _isZh ? '请验证身份以解锁应用' : 'Please authenticate to unlock the app',
      );
      LoggerService.instance.app('Biometric verify result: $authed');
      if (mounted) setState(() => _verified = authed);
    } catch (e) {
      LoggerService.instance.error('Biometric verify failed: $e', tag: 'BIOMETRIC');
      if (mounted) setState(() => _verified = false);
    } finally {
      // 保留 ~800ms 屏蔽期，吸收指纹框关闭瞬间产生的假 resumed 事件
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) _verifying = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _wasPaused = true;
      return;
    }
    // inactive 可能只是小窗、分屏或系统面板，不应在返回时强制验证。
    if (state != AppLifecycleState.resumed || !_wasPaused) return;
    _wasPaused = false;
    // v1.7.30：跳过 App 内原生 Activity 跳转（相机/相册/文档选择器）的 resumed
    if (BiometricService.inAppActivityTransition) {
      BiometricService.inAppActivityTransition = false;
      return;
    }
    if (_enabled == true && _verified && !_verifying) {
      if (mounted) setState(() => _verified = false);
      _verify();
    }
  }

  @override
  Widget build(BuildContext context) {
    _isZh = Localizations.localeOf(context).languageCode == 'zh';
    if (_enabled == null) {
      // 状态未确定：启动画面（不渲染任何聊天内容）
      return const _BiometricSplash();
    }
    if (_enabled == true && !_verified) {
      return _BiometricLockScreen(onUnlock: _verify);
    }
    return widget.child ?? const SizedBox.shrink();
  }
}
