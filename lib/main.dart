import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'theme.dart';
import 'l10n/app_localizations.dart';
import 'providers/locale_provider.dart';
import 'services/storage_service.dart';
import 'services/api_service.dart';
import 'services/app_download_service.dart';
import 'services/logger_service.dart';
import 'screens/onboarding_language_screen.dart';
import 'screens/conversation_list_screen.dart';
import 'plugins/plugin_registry.dart';
import 'plugins/builtin_plugins.dart';

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

    // v1.6.9：PluginRegistry 已经在字段初始化时同步 createBuiltinPluginRegistry()，
    // 这里仅绑定 StorageService 实例（它的 _initFromStorage 会从 storage 读插件启用状态），
    // 给 30ms 让内部 await StorageService 完成，避免首屏渲染时还没读。
    // 因为 createBuiltinPluginRegistry(storage: null) 时会用 StorageService.instance 兜底，
    // 所以这里不需要再手动重绑，只需要等一下即可。
    await Future.delayed(const Duration(milliseconds: 30));
    _logger.app('PluginRegistry ready (${_pluginRegistry.plugins.length} plugins, total ${stopwatch.elapsedMilliseconds}ms)');

    final localeProvider = _localeProvider;
    await localeProvider.init();
    final done = await localeProvider.isOnboardingCompleted;
    stopwatch.stop();
    _logger.app('Init complete: onboarded=$done, total ${stopwatch.elapsedMilliseconds}ms');
    return done;
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _localeProvider),
        ChangeNotifierProvider.value(value: StorageService.instance),
        ChangeNotifierProvider(create: (_) => ApiService()),
        ChangeNotifierProvider(create: (_) => AppDownloadService()),
        ChangeNotifierProvider.value(value: LoggerService.instance),
        ChangeNotifierProvider.value(value: _pluginRegistry),
      ],
      child: Consumer<LocaleProvider>(
        builder: (context, lp, child) {
          return MaterialApp(
            title: 'Nexus',
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
                            const Icon(Icons.error_outline,
                                size: 48, color: Colors.redAccent),
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
                                  color: Colors.grey.shade600),
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
                return const ConversationListScreen();
              },
            ),
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
