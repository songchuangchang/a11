/// APP 更新检查服务（v1.7.12）
///
/// 从 GitHub Releases 查询最新版本，支持手动 + 启动自动检查。
/// 查询接口：https://api.github.com/repos/songchuangchang/a11/releases/latest
library app_update_service;

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import '../constants.dart' show kAppVersionConst;
import 'biometric_service.dart';
import 'logger_service.dart';
import 'app_download_service.dart';

/// APP 更新信息
class AppUpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String latestTag;
  final String releaseNotes;
  final String apkUrl;
  final int apkSize; // bytes
  final bool hasUpdate;
  final String? publishedAt;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.latestTag,
    required this.releaseNotes,
    required this.apkUrl,
    required this.apkSize,
    required this.hasUpdate,
    this.publishedAt,
  });
}

/// APP 更新检查服务
class AppUpdateService {
  static final LoggerService _logger = LoggerService.instance;
  static const _repoApiLatest =
      'https://api.github.com/repos/songchuangchang/a11/releases/latest';

  /// v1.7.13：启动静默检查 one-shot 守卫
  ///
  /// 触发背景：v1.7.12 把静默检查写在 main.dart FutureBuilder 的 builder 闭包里，
  /// 每次 rebuild 都注册新的 addPostFrameCallback，导致启动后 5 秒内重复打 5 次
  /// GitHub API（nexus_export_2026-08-25T10-51-47 日志可见）。
  ///
  /// 修复：用 static 标志保证「每次 app 进程只跑一次」启动静默检查。
  static bool _hasRunStartupSilentCheck = false;

  /// 启动静默检查是否已跑过（true=已跑过，不再重复）
  static bool get hasRunStartupSilentCheck => _hasRunStartupSilentCheck;

  /// 标记启动静默检查已跑（幂等：多次调用只生效一次）
  /// 调用方应在调 checkForUpdate 之前先调本方法判断是否需要继续。
  static void markStartupSilentCheckRun() {
    _hasRunStartupSilentCheck = true;
  }

  /// 仅供测试用：重置 one-shot 守卫，让单测之间互不影响
  static void resetSilentCheckGuardForTest() {
    _hasRunStartupSilentCheck = false;
  }

  /// GitHub 代理镜像前缀列表（按顺序尝试，失败自动回落）
  /// 用户网络可能直连 GitHub 失败，但代理可用
  static const List<String> _proxyPrefixes = [
    '', // 直连（先试直连，成功不走代理省流量）
    'https://ghproxy.net/',
    'https://mirror.ghproxy.com/',
    'https://gh-proxy.com/',
  ];

  /// 解析 pubspec 格式版本字符串 "1.7.11+58" → 语义化比较用 "1.7.11.58"
  /// 返回纯数字段列表
  static List<int> _parseVersion(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    // 去掉 -beta 等预发布后缀
    final dash = s.indexOf('-');
    if (dash >= 0) s = s.substring(0, dash);
    // pubspec 的 +build 分隔："1.7.11+58" → ["1.7.11", "58"]
    final plus = s.indexOf('+');
    String mainPart;
    String buildPart = '';
    if (plus >= 0) {
      mainPart = s.substring(0, plus);
      buildPart = s.substring(plus + 1);
    } else {
      mainPart = s;
    }
    final parts = mainPart.split('.').map((e) => int.tryParse(e.trim()) ?? 0).toList();
    if (buildPart.isNotEmpty) {
      final buildNum = int.tryParse(buildPart.trim());
      if (buildNum != null) parts.add(buildNum);
    }
    return parts;
  }

  /// 版本比较：>0 表示 v1 > v2
  static int compareVersions(String v1, String v2) {
    final p1 = _parseVersion(v1);
    final p2 = _parseVersion(v2);
    final maxLen = p1.length > p2.length ? p1.length : p2.length;
    for (int i = 0; i < maxLen; i++) {
      final a = i < p1.length ? p1[i] : 0;
      final b = i < p2.length ? p2[i] : 0;
      if (a > b) return 1;
      if (a < b) return -1;
    }
    return 0;
  }

  /// 从最新 Release 的 assets 里找 .apk 结尾的
  static Map<String, dynamic>? _findApkAsset(List<dynamic> assets) {
    for (final a in assets) {
      final m = a as Map<String, dynamic>;
      final name = (m['name'] as String? ?? '').toLowerCase();
      if (name.endsWith('.apk')) return m;
    }
    return null;
  }

  /// 带代理回落的 HTTP GET
  static Future<http.Response> _getWithProxyFallback(String url) async {
    Object? lastErr;
    for (final prefix in _proxyPrefixes) {
      final effective = prefix.isEmpty ? url : '$prefix$url';
      try {
        final r = await http
            .get(Uri.parse(effective))
            .timeout(const Duration(seconds: 15));
        if (r.statusCode >= 200 && r.statusCode < 300) {
          if (prefix.isNotEmpty) {
            _logger.info('AppUpdate: 通过代理 $prefix 成功拉取 Release 元数据',
                tag: 'AppUpdate');
          }
          return r;
        }
        lastErr = Exception('HTTP ${r.statusCode} (via $prefix)');
      } catch (e) {
        lastErr = e;
        _logger.warn('AppUpdate: 拉取 Release 失败 via $prefix: $e',
            tag: 'AppUpdate');
      }
    }
    throw lastErr ?? Exception('所有路径均失败');
  }

  /// 检查 APP 是否有新版本
  static Future<AppUpdateInfo> checkForUpdate() async {
    const current = kAppVersionConst;
    _logger.info('AppUpdate: 开始检查更新，当前版本 $current', tag: 'AppUpdate');

    try {
      final resp = await _getWithProxyFallback(_repoApiLatest);
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;

      final tag = data['tag_name'] as String? ?? ''; // e.g. "v1.7.11+58"
      final releaseNotes = data['body'] as String? ?? '';
      final publishedAt = data['published_at'] as String?;
      final assets = data['assets'] as List<dynamic>? ?? [];
      final apk = _findApkAsset(assets);

      if (apk == null) {
        throw Exception('Release 中未找到 APK 资产');
      }

      final apkUrl = apk['browser_download_url'] as String? ?? '';
      final apkSize = apk['size'] as int? ?? 0;

      // tag 中解析出版本号："v1.7.11+58" → "1.7.11+58"
      var latest = tag;
      if (latest.startsWith('v') || latest.startsWith('V')) {
        latest = latest.substring(1);
      }
      final hasUpdate = latest.isNotEmpty && compareVersions(latest, current) > 0;

      _logger.info(
          'AppUpdate: 最新 $latest, 当前 $current, hasUpdate=$hasUpdate, '
          'apk=$apkUrl (${(apkSize / 1024 / 1024).toStringAsFixed(2)}MB)',
          tag: 'AppUpdate');

      return AppUpdateInfo(
        currentVersion: current,
        latestVersion: latest,
        latestTag: tag,
        releaseNotes: releaseNotes,
        apkUrl: apkUrl,
        apkSize: apkSize,
        hasUpdate: hasUpdate,
        publishedAt: publishedAt,
      );
    } catch (e, st) {
      _logger.error('AppUpdate: 检查更新失败: $e',
          error: e, stack: st, tag: 'AppUpdate');
      return const AppUpdateInfo(
        currentVersion: current,
        latestVersion: current,
        latestTag: '',
        releaseNotes: '',
        apkUrl: '',
        apkSize: 0,
        hasUpdate: false,
      );
    }
  }

  /// 下载并安装更新 APK
  ///
  /// 返回下载结果 Map（含 fullPath / success 等字段）
  static Future<Map<String, dynamic>> downloadAndInstall(
    AppUpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    _logger.info(
        'AppUpdate: 开始下载更新 v${info.latestVersion} → ${info.apkUrl}',
        tag: 'AppUpdate');
    try {
      // AppDownloadService 是 Provider 级 ChangeNotifier，这里后台下载新建临时实例即可
      // （Provider 里的那个主要给 UI 监听，后台下载不需要共享它的监听）
      final dlSvc = AppDownloadService();
      final fileName = 'Nexus_v${info.latestVersion}_release.apk';
      final result = await dlSvc.downloadFileFromUrl(
        url: info.apkUrl,
        fileName: fileName,
        onProgress: onProgress,
        taskId: 'app_update_${DateTime.now().millisecondsSinceEpoch}',
      );

      final success = result['success'] == true;
      final fullPath = result['fullPath'] as String? ?? '';
      _logger.info(
          'AppUpdate: 下载结束 success=$success, path=$fullPath',
          tag: 'AppUpdate');

      if (success && fullPath.isNotEmpty) {
        // 尝试拉起 APK 安装器
        try {
          final r = await BiometricService.guardActivityTransition(
            () => OpenFilex.open(fullPath,
                type: 'application/vnd.android.package-archive'),
            fallbackDuration: const Duration(seconds: 120),
          );
          _logger.info(
              'AppUpdate: 调安装器结果 type=${r.type} msg=${r.message}',
              tag: 'AppUpdate');
        } catch (e) {
          _logger.warn('AppUpdate: 拉起安装器失败: $e', tag: 'AppUpdate');
        }
      }
      return result;
    } catch (e, st) {
      _logger.error('AppUpdate: 下载更新失败: $e',
          error: e, stack: st, tag: 'AppUpdate');
      return {'success': false, 'error': e.toString()};
    }
  }
}
