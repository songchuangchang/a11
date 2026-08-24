import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/web_search_config.dart';
import 'github_search_service.dart';
import 'logger_service.dart';
import 'web_search_service.dart';

enum SourceTrustLevel { official, trustedThirdParty, unknown }

class AppDownloadSource {
  final String sourceName;
  final String sourceDomain;
  final SourceTrustLevel trustLevel;
  final String version;
  final String size;
  final String arch;
  final String downloadUrl;
  final String? sha256;
  final String? changelog;
  final String? referer;

  /// v1.3.4 新增：原始下载 URL（仅 GitHub source 有，代理重写前的 github.com 直链）
  /// 用于代理下载失败时自动回退直连重试。null = 没走代理（downloadUrl 就是原始 URL）
  final String? originalDownloadUrl;

  /// v1.5.0 新增：来源版本发布日期（ISO 8601 日期字符串，如 "2026-08-21"）
  ///
  /// 语义：catalog 条目的版本号/直链最近一次被验证为"当前可用"的日期。
  /// - "最新版"类条目（URL 永远指向最新版）：填最近一次验证的日期
  /// - 版本号锁定类条目（如 8.0.76）：填该版本发布日期或上次核对日期
  ///
  /// UI（_SourceCard）会据此计算"距今 N 天"，>90 天显示黄色⚠️"数据较旧"徽章。
  /// 解析失败/空字符串按"今天"处理（不显示警告），避免格式错误导致 UI 崩溃。
  final String releaseDate;

  AppDownloadSource({
    required this.sourceName,
    required this.sourceDomain,
    required this.trustLevel,
    required this.version,
    required this.size,
    required this.arch,
    required this.downloadUrl,
    this.sha256,
    this.changelog,
    this.referer,
    this.originalDownloadUrl,
    this.releaseDate = '2026-08-21',
  });

  String get trustLabel {
    switch (trustLevel) {
      case SourceTrustLevel.official:
        return 'Official / 官方';
      case SourceTrustLevel.trustedThirdParty:
        return 'Trusted 3rd Party / 可信第三方';
      case SourceTrustLevel.unknown:
        return 'Unknown / 未知来源';
    }
  }

  /// v1.3.4：是否走了代理（downloadUrl 与 originalDownloadUrl 不同）
  bool get isProxied =>
      originalDownloadUrl != null &&
      originalDownloadUrl!.isNotEmpty &&
      originalDownloadUrl != downloadUrl;

  /// v1.3.1：按域名白名单（由 LLM 判断）提升信任级别
  AppDownloadSource copyWithTrustLevel(SourceTrustLevel tl) {
    return AppDownloadSource(
      sourceName: sourceName,
      sourceDomain: sourceDomain,
      trustLevel: tl,
      version: version,
      size: size,
      arch: arch,
      downloadUrl: downloadUrl,
      sha256: sha256,
      changelog: changelog,
      referer: referer,
      originalDownloadUrl: originalDownloadUrl,
      releaseDate: releaseDate,
    );
  }

  /// v1.5.0：返回 releaseDate 距今多少天。解析失败返回 0（视作"今天"，不触发警告）。
  int get daysSinceRelease {
    if (releaseDate.isEmpty) return 0;
    try {
      final parsed = DateTime.parse(releaseDate);
      return DateTime.now().difference(parsed).inDays;
    } catch (_) {
      return 0;
    }
  }
}

class DownloadTask {
  final String appName;

  /// v1.3.4：改为可变，GitHub 代理失败回退直连时会替换 source
  AppDownloadSource source;
  final String fileName;
  final String saveDir;
  String fullPath = '';
  int receivedBytes = 0;
  int totalBytes = 0;
  bool get isComplete =>
      totalBytes > 0 && receivedBytes >= totalBytes && fullPath.isNotEmpty;
  double get progress => totalBytes == 0 ? 0 : receivedBytes / totalBytes;
  String? error;

  DownloadTask({
    required this.appName,
    required this.source,
    required this.fileName,
    required this.saveDir,
  });
}

class _DownloadCancelledException implements Exception {
  final String reason;
  _DownloadCancelledException(this.reason);
  @override
  String toString() => reason;
}

class AppDownloadService extends ChangeNotifier {
  static const _androidUA =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';

  /// v1.5.0：活动下载的取消标志 Map
  ///
  /// key = taskId，value = true（用户已点取消）
  /// downloadFileFromUrl 循环内每轮检查此 Map，true 则 break + 删除已写入的部分文件 + 抛 _DownloadCancelledException
  /// cancelDownload(taskId) 把对应 key 置为 true
  final Map<String, bool> _cancelFlags = {};

  /// v1.5.0：取消指定 taskId 的下载
  ///
  /// 调用后，目标 downloadFileFromUrl 在下一次循环检查时会被中断。
  /// 如果 taskId 不存在（下载已结束），无操作。
  void cancelDownload(String taskId) {
    if (_cancelFlags.containsKey(taskId)) {
      _cancelFlags[taskId] = true;
      _logger.info('[Download] Cancel requested for taskId=$taskId');
      notifyListeners();
    }
  }

  /// v1.5.0：查询某 taskId 是否被取消（UI 层展示用）
  bool isCancelled(String taskId) => _cancelFlags[taskId] == true;

  // --- Built-in known APP catalog (fallback when LLM not available).
  // 直链必须真实可下，CDN 无 Referer/UA 限制，否则加 referer 字段。
  static final Map<String, List<AppDownloadSource>> _catalog = {
    '微信': [
      AppDownloadSource(
        sourceName: '腾讯官网',
        sourceDomain: 'dldir1v6.qq.com',
        trustLevel: SourceTrustLevel.official,
        version: '8.0.76',
        size: '约 250 MB',
        arch: 'arm64-v8a (多数安卓机)',
        downloadUrl:
            'https://dldir1v6.qq.com/weixin/android/weixin8076android3141_0x28004c31_arm64.apk',
        changelog: '微信官方最新版 8.0.76 · 腾讯 CDN 直链',
      ),
      AppDownloadSource(
        sourceName: '腾讯官网(32位)',
        sourceDomain: 'dldir1.qq.com',
        trustLevel: SourceTrustLevel.official,
        version: '8.0.76',
        size: '约 250 MB',
        arch: 'armeabi-v7a (老机型)',
        downloadUrl:
            'https://dldir1.qq.com/weixin/android/weixin8042android2460.apk',
        changelog: '微信 32 位老机型版本',
        // 文件名 weixin8042android2460.apk → 8.0.42 build2460，是 2024 年老版本
        releaseDate: '2024-12-01',
      ),
    ],
    'wechat': [
      AppDownloadSource(
        sourceName: 'Tencent Official',
        sourceDomain: 'dldir1v6.qq.com',
        trustLevel: SourceTrustLevel.official,
        version: '8.0.76',
        size: '~250 MB',
        arch: 'arm64-v8a',
        downloadUrl:
            'https://dldir1v6.qq.com/weixin/android/weixin8076android3141_0x28004c31_arm64.apk',
      ),
    ],
    'qq': [
      AppDownloadSource(
        sourceName: '腾讯官网',
        sourceDomain: 'downv6.qq.com',
        trustLevel: SourceTrustLevel.official,
        version: '9.0.60',
        size: '约 345 MB',
        arch: 'arm64-v8a',
        downloadUrl:
            'https://downv6.qq.com/qqweb/QQ_1/android_apk/QQ_9.0.60.20106_64.apk',
      ),
    ],
    '抖音': [
      AppDownloadSource(
        sourceName: '抖音官网下载页',
        sourceDomain: 'douyin.com',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 350 MB',
        arch: 'universal (通用)',
        downloadUrl: 'https://www.douyin.com/download',
        changelog: '抖音官方下载页 · 自动识别设备推送 APK',
      ),
      AppDownloadSource(
        sourceName: 'APKPure (需翻墙)',
        sourceDomain: 'd.apkpure.com',
        trustLevel: SourceTrustLevel.trustedThirdParty,
        version: '32.5.0',
        size: '约 198 MB',
        arch: 'universal (通用)',
        downloadUrl:
            'https://d.apkpure.com/b/APK/com.ss.android.ugc.aweme?version=latest',
        referer: 'https://apkpure.com/',
        changelog: 'APKPure 镜像 · 国内可能无法访问',
        // 32.5.0 是 2026 年 5 月版本，距今已超 90 天
        releaseDate: '2026-05-15',
      ),
    ],
    'tiktok': [
      AppDownloadSource(
        sourceName: 'APKPure',
        sourceDomain: 'd.apkpure.com',
        trustLevel: SourceTrustLevel.trustedThirdParty,
        version: '32.5.0',
        size: '约 190 MB',
        arch: 'universal',
        downloadUrl:
            'https://d.apkpure.com/b/APK/com.ss.android.ugc.trill?version=latest',
        referer: 'https://apkpure.com/',
        // 32.5.0 是 2026 年 5 月版本，距今已超 90 天
        releaseDate: '2026-05-15',
      ),
    ],
    'telegram': [
      AppDownloadSource(
        sourceName: 'Telegram Official',
        sourceDomain: 'telegram.org',
        trustLevel: SourceTrustLevel.official,
        version: '11.2.0',
        size: '约 85 MB',
        arch: 'arm64-v8a',
        downloadUrl: 'https://telegram.org/dl/android/apk',
      ),
    ],
    '电报': [
      AppDownloadSource(
        sourceName: 'Telegram 官网',
        sourceDomain: 'telegram.org',
        trustLevel: SourceTrustLevel.official,
        version: '11.2.0',
        size: '约 85 MB',
        arch: 'arm64-v8a',
        downloadUrl: 'https://telegram.org/dl/android/apk',
      ),
    ],
    'whatsapp': [
      AppDownloadSource(
        sourceName: 'WhatsApp Official',
        sourceDomain: 'whatsapp.com',
        trustLevel: SourceTrustLevel.official,
        version: '2.24.16',
        size: '约 78 MB',
        arch: 'arm64-v8a',
        downloadUrl: 'https://www.whatsapp.com/android/current/WhatsApp.apk',
      ),
    ],
    // ============== 新增：办公/娱乐/支付常用 APP ==============
    'wps': [
      AppDownloadSource(
        sourceName: 'WPS 官网下载页',
        sourceDomain: 'wps.cn',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 120 MB',
        arch: 'universal (通用)',
        downloadUrl: 'https://www.wps.cn/product/android/',
        changelog: 'WPS Office 官方下载页 · 支持查看/编辑 Word/Excel/PPT/PDF',
      ),
    ],
    'wps office': [
      AppDownloadSource(
        sourceName: 'WPS 官网下载页',
        sourceDomain: 'wps.cn',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 120 MB',
        arch: 'universal (通用)',
        downloadUrl: 'https://www.wps.cn/product/android/',
        changelog: 'WPS Office 官方下载页',
      ),
    ],
    '金山办公': [
      AppDownloadSource(
        sourceName: 'WPS 官网下载页',
        sourceDomain: 'wps.cn',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 120 MB',
        arch: 'universal (通用)',
        downloadUrl: 'https://www.wps.cn/product/android/',
      ),
    ],
    'bilibili': [
      AppDownloadSource(
        sourceName: 'B站官网',
        sourceDomain: 'bilibili.com',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 150 MB',
        arch: 'arm64-v8a',
        downloadUrl: 'https://app.bilibili.com/',
        changelog: '哔哩哔哩官方下载页',
      ),
    ],
    '哔哩哔哩': [
      AppDownloadSource(
        sourceName: 'B站官网',
        sourceDomain: 'bilibili.com',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 150 MB',
        arch: 'arm64-v8a',
        downloadUrl: 'https://app.bilibili.com/',
        changelog: '哔哩哔哩官方下载页',
      ),
    ],
    'b站': [
      AppDownloadSource(
        sourceName: 'B站官网',
        sourceDomain: 'bilibili.com',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 150 MB',
        arch: 'arm64-v8a',
        downloadUrl: 'https://app.bilibili.com/',
      ),
    ],
    '网易云音乐': [
      AppDownloadSource(
        sourceName: '网易云音乐官网',
        sourceDomain: 'music.163.com',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 90 MB',
        arch: 'arm64-v8a',
        downloadUrl: 'https://music.163.com/#/download',
        changelog: '网易云音乐官方下载页',
      ),
    ],
    'qq音乐': [
      AppDownloadSource(
        sourceName: 'QQ音乐官网',
        sourceDomain: 'y.qq.com',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 85 MB',
        arch: 'arm64-v8a',
        downloadUrl: 'https://y.qq.com/download/download.html',
        changelog: 'QQ音乐官方下载页',
      ),
    ],
    '支付宝': [
      AppDownloadSource(
        sourceName: '支付宝官网',
        sourceDomain: 'alipay.com',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 140 MB',
        arch: 'arm64-v8a',
        downloadUrl: 'https://render.alipay.com/p/s/download',
        changelog: '支付宝官方下载页',
      ),
    ],
    '淘宝': [
      AppDownloadSource(
        sourceName: '淘宝官网',
        sourceDomain: 'taobao.com',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 200 MB',
        arch: 'arm64-v8a',
        downloadUrl: 'https://www.taobao.com/go/act/appcenter/index.php',
        changelog: '手机淘宝官方下载页',
      ),
    ],
    '京东': [
      AppDownloadSource(
        sourceName: '京东官网',
        sourceDomain: 'jd.com',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 180 MB',
        arch: 'arm64-v8a',
        downloadUrl: 'https://shouji.jd.com/',
        changelog: '京东APP官方下载页',
      ),
    ],
    '百度': [
      AppDownloadSource(
        sourceName: '百度官网',
        sourceDomain: 'baidu.com',
        trustLevel: SourceTrustLevel.official,
        version: '最新版',
        size: '约 130 MB',
        arch: 'arm64-v8a',
        downloadUrl: 'https://mb.baidu.com/appcenter/',
        changelog: '百度APP官方下载页',
      ),
    ],
  };

  DownloadTask? currentTask;
  final List<DownloadTask> history = [];

  final LoggerService _logger = LoggerService.instance;

  // --- Intent detection
  static String? detectDownloadIntent(String userText) {
    final text = userText.toLowerCase().trim();
    final patterns = [
      RegExp(
          r'(帮我|我要|给我)?下载\s*(安装包|apk)?\s*[：:]?\s*(.+?)(安装包|apk)?\s*[。.!！?？]$',
          caseSensitive: false),
      RegExp(r'download\s+(the\s+)?(apk\s+for\s+)?(.+?)(\s*apk)?\s*$',
          caseSensitive: false),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(text);
      if (m != null) {
        final kw = m.groupCount >= 3 ? (m.group(3) ?? '') : (m.group(2) ?? '');
        var result = kw
            .trim()
            .replaceAll(RegExp(r'(安装包|apk)$', caseSensitive: false), '')
            .trim();
        // 过滤前导中文标点（逗号、顿号、冒号等），修 "，抖音" 问题
        result = result.replaceAll(RegExp(r'^[，,、：:；;。\s]+'), '').trim();
        if (result.isNotEmpty) return result;
      }
    }
    if (text.contains('下载') || text.contains('download')) {
      final cleaned = text
          .replaceAll('帮我', '')
          .replaceAll('给我', '')
          .replaceAll('我要', '')
          .replaceAll('please', '')
          .replaceAll('下载', '')
          .replaceAll('download', '')
          .replaceAll('apk', '')
          .replaceAll('安装包', '')
          .trim();
      if (cleaned.isNotEmpty && cleaned.length <= 30) return cleaned;
    }
    return null;
  }

  // --- Search sources (更宽容的模糊匹配)
  Future<List<AppDownloadSource>> searchSources(String keyword) async {
    var kw = keyword.toLowerCase().trim();
    // 去除空格、下划线等符号，让 "wpsoffice" 也能匹配 "wps office"
    final kwNorm = kw.replaceAll(RegExp(r'[\s\-_]'), '');

    // 1) 精确匹配
    for (final entry in _catalog.entries) {
      final keyNorm =
          entry.key.toLowerCase().replaceAll(RegExp(r'[\s\-_]'), '');
      if (entry.key.toLowerCase() == kw || keyNorm == kwNorm) {
        return entry.value;
      }
    }
    // 2) 包含匹配（双向）
    for (final entry in _catalog.entries) {
      final key = entry.key.toLowerCase();
      final keyNorm =
          entry.key.toLowerCase().replaceAll(RegExp(r'[\s\-_]'), '');
      if (key.contains(kw) ||
          kw.contains(key) ||
          keyNorm.contains(kwNorm) ||
          kwNorm.contains(keyNorm)) {
        return entry.value;
      }
    }
    // 3) 已知别名（中英混合，比如 "wps" = "金山办公" 其实已经在 catalog 里了）
    //    如果还没命中，这里兜底
    final aliasMap = <String, List<String>>{
      'wps': ['wpsoffice', '金辦公'],
      '微信': ['weixin'],
      '支付宝': ['alipay'],
      '淘宝': ['taobao'],
      '京东': ['jd'],
      '哔哩哔哩': ['bilibili', 'bili'],
      '网易云音乐': ['neteasemusic', 'cloudmusic'],
      'qq音乐': ['qqmusic'],
      '百度': ['baidu'],
    };
    for (final aliasEntry in aliasMap.entries) {
      final primaryKey = aliasEntry.key;
      for (final alias in aliasEntry.value) {
        if (kwNorm.contains(alias) || alias.contains(kwNorm)) {
          // 把 primaryKey 的 catalog 返回
          for (final e in _catalog.entries) {
            if (e.key.toLowerCase() == primaryKey.toLowerCase()) {
              return e.value;
            }
          }
        }
      }
    }
    return [];
  }

  // ==========================================================================
  // v1.4.2：通用文件下载搜索（视频/图片/音频/文档等）
  // ==========================================================================

  /// 通用文件下载搜索：搜索 web 查找文件直链
  /// [query]：搜索关键词
  /// [fileType]：video/image/audio/document/any
  /// 返回简化的下载源列表
  Future<List<Map<String, String>>> searchFileDownloads(
    String query, [
    WebSearchConfig? webCfg,
    String fileType = 'any',
  ]) async {
    _logger.info('[Download] File search: query="$query" type=$fileType');

    final searchResults =
        await WebSearchService.searchFileDownloads(query, webCfg, fileType);
    if (searchResults.isEmpty) {
      _logger.warn('[Download] File search returned no results for "$query"');
      return [];
    }

    final sources = <Map<String, String>>[];
    final seenUrls = <String>{};

    for (final result in searchResults.take(10)) {
      final url = result.url;
      if (seenUrls.contains(url)) continue;
      seenUrls.add(url);

      // 尝试从搜索结果中提取文件名
      final fileName = _extractFileNameFromSearchResult(result);
      final domain = _extractDomain(url);

      sources.add({
        'sourceName': result.title.isNotEmpty ? result.title : fileName,
        'sourceDomain': domain,
        'downloadUrl': url,
        'fileName': fileName,
        'snippet': result.snippet,
      });
    }

    _logger.info(
      '[Download] File search: ${sources.length} sources for "$query"',
    );
    return sources;
  }

  /// 从搜索结果提取文件名
  String _extractFileNameFromSearchResult(SearchResultItem result) {
    final url = result.url;
    try {
      final path = Uri.parse(url).path;
      final seg = path.split('/').last;
      if (seg.isNotEmpty && !seg.contains('?') && !seg.contains('#')) {
        final ext = p.extension(seg);
        if (ext.isNotEmpty && ext.length <= 5) {
          return Uri.decodeComponent(seg);
        }
      }
    } catch (_) {}
    // fallback：从标题推断
    final title = result.title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    if (title.isNotEmpty) return '${title.substring(0, title.length > 40 ? 40 : title.length)}.file';
    return 'download.file';
  }

  // --- 联网搜索下载链接（通过 Bing 中国搜索 APK 直链）
  Future<List<AppDownloadSource>> searchOnline(
    String appName, [
    WebSearchConfig? webCfg,
  ]) async {
    _logger.info('[Download] Online search for: "$appName"');

    final searchResults =
        await WebSearchService.searchApkLinks(appName, webCfg);
    _logger.verbose(
        '[Download] searchOnline: ${searchResults.length} raw results for "$appName":\n${searchResults.take(8).map((r) => '  - ${r.title}\n    ${r.url}').join('\n')}',
        tag: 'DL');
    if (searchResults.isEmpty) {
      _logger.warn('[Download] Web search returned no results');
      return [];
    }

    final apkSources = <AppDownloadSource>[]; // 直链 .apk（严格验证）
    final pageSources = <AppDownloadSource>[]; // 下载页/官网 HTML（宽松保留，标红）
    final seenUrls = <String>{};

    for (final result in searchResults.take(10)) {
      final url = result.url;
      if (seenUrls.contains(url)) continue;
      seenUrls.add(url);

      // v1.5.1：跳过国内应用商店诱导下载页（应用宝/360/豌豆荚/小米/华为/OPPO/vivo/百度等）
      if (_isBlockedStore(url)) {
        _logger.info(
            '[Download] Skip blocked app store URL: $url',
            tag: 'DL');
        continue;
      }

      final lowerUrl = url.toLowerCase();
      final looksLikeApk = lowerUrl.endsWith('.apk') ||
          lowerUrl.contains('.apk?') ||
          lowerUrl.contains('/apk/') ||
          lowerUrl.contains('download') &&
              (lowerUrl.contains('cdn') ||
                  lowerUrl.contains('android') ||
                  lowerUrl.contains('dldir'));

      // 判断来源可信度（先按域名预判定）
      final trustLevel = _judgeTrustLevel(url);
      final sourceName = _extractSourceName(url, result.title);
      final domain = _extractDomain(url);

      if (looksLikeApk || trustLevel != SourceTrustLevel.unknown) {
        // 【严格路径】看起来像 APK 直链，或者是官网/可信三方 → 必须验证通过
        final validateErr = await WebSearchService.validateUrl(url);
        if (validateErr != null) {
          _logger.info('[Download] APK-like URL invalid ($validateErr): $url');
          continue;
        }
        apkSources.add(AppDownloadSource(
          sourceName: sourceName,
          sourceDomain: domain,
          trustLevel: trustLevel,
          version: '搜索结果 · 直链',
          size: '未知',
          arch: '未知 (需验证)',
          downloadUrl: url,
          changelog:
              result.snippet.isNotEmpty ? result.snippet : 'Bing 搜索 APK 直链',
        ));
        _logger.info('[Download] Valid APK source: $sourceName -> $url');
      } else {
        // 【宽松路径】普通下载页 / HTML 页面
        // v1.3.6：自动 fetch HTML → 解析 .apk 直链 → 升级为正式 APK 源
        final reachable = await WebSearchService.checkReachable(url);
        if (!reachable) {
          _logger.info('[Download] Page unreachable, skip: $url');
          continue;
        }
        // 尝试从下载页 HTML 中提取 .apk 直链
        final apkDirectUrl = await _fetchAndParseDownloadPage(url);
        if (apkDirectUrl != null) {
          _logger.info(
              '[Download] Extracted APK from page: $sourceName -> $apkDirectUrl',
              tag: 'DL');
          apkSources.add(AppDownloadSource(
            sourceName: '$sourceName (页面解析)',
            sourceDomain: domain,
            trustLevel: trustLevel, // 继承原域名信任等级
            version: '搜索结果 · 页面解析',
            size: '未知',
            arch: '未知 (需验证)',
            downloadUrl: apkDirectUrl,
            referer: url, // 原页面作为 Referer
            changelog: result.snippet.isNotEmpty
                ? '${result.snippet}（从下载页自动提取直链）'
                : '从下载页 HTML 自动提取 APK 直链',
          ));
        } else {
          // 解析不到直链 → 保留为下载页源（🔴）
          pageSources.add(AppDownloadSource(
            sourceName: '$sourceName (下载页)',
            sourceDomain: domain,
            trustLevel: SourceTrustLevel.unknown,
            version: '官网/网页',
            size: '—',
            arch: '—',
            downloadUrl: url,
            changelog: result.snippet.isNotEmpty
                ? '${result.snippet}（网页下载页，需手动点击下载按钮）'
                : '搜索结果 · 网页下载页（浏览器打开后点按钮下载）',
          ));
          _logger.info(
              '[Download] Page source (no APK found): $sourceName -> $url',
              tag: 'DL');
        }
      }

      // 最多保留 5 个 APK 直链 + 3 个下载页
      if (apkSources.length >= 5 && pageSources.length >= 3) break;
    }

    // APK 直链排前面，下载页排后面
    return [...apkSources, ...pageSources];
  }

  // --- GitHub Releases APK 搜索通道
  /// v1.3.4：新增 proxyUrl 参数，会把 release asset 的 downloadUrl 用代理重写
  ///         原始 github.com 直链存到 originalDownloadUrl 字段，下载失败时自动回退
  Future<List<AppDownloadSource>> searchGitHub(String appName,
      {int maxRepos = 3, String proxyUrl = ''}) async {
    _logger.info('[Download] GitHub search for: "$appName"');

    final ghSources =
        await GitHubSearchService.searchApk(appName, maxRepos: maxRepos);
    if (ghSources.isEmpty) {
      _logger.info('[Download] GitHub returned no APKs for $appName');
      return [];
    }

    final useProxy = proxyUrl.trim().isNotEmpty;
    final result = <AppDownloadSource>[];
    for (final s in ghSources.take(6)) {
      // GitHub Releases = 作者自己上传，一律算🟢官方（除非 prerelease 就降成 trustedThirdParty）
      final trust = s.release.prerelease
          ? SourceTrustLevel.trustedThirdParty
          : SourceTrustLevel.official;
      final arch = s.asset.arch;

      final originalUrl = s.asset.browserDownloadUrl;
      final rewrittenUrl = useProxy
          ? GitHubSearchService.rewriteDownloadUrl(originalUrl, proxyUrl)
          : originalUrl;
      final proxied = useProxy && rewrittenUrl != originalUrl;

      result.add(AppDownloadSource(
        sourceName: 'GitHub · ${s.repo.fullName}'
            '${s.repo.stars > 0 ? ' ⭐${s.repo.stars}' : ''}'
            '${arch.isNotEmpty ? ' ($arch)' : ''}'
            '${proxied ? ' · 已代理加速' : ''}',
        sourceDomain: 'github.com/${s.repo.owner}',
        trustLevel: trust,
        version: s.displayVersion,
        size: s.sizeMB,
        arch: arch.isEmpty ? '—' : arch,
        downloadUrl: rewrittenUrl,
        originalDownloadUrl: proxied ? originalUrl : null,
        changelog: s.changelog,
      ));

      _logger
          .info('[Download] GitHub APK: ${s.repo.fullName}@${s.displayVersion}'
              ' ${s.asset.name} ${s.sizeMB}'
              ' -> ${proxied ? "proxied" : "direct"}: $rewrittenUrl');
    }

    return result;
  }

  SourceTrustLevel _judgeTrustLevel(String url) {
    final lower = url.toLowerCase();
    // 官方域名
    const officialDomains = [
      'dldir1.qq.com',
      'dldir1v6.qq.com',
      'downv6.qq.com',
      'weixin.qq.com',
      'im.qq.com',
      'telegram.org',
      'telegram-cdn.org',
      'whatsapp.com',
      'whatsapp.net',
      'douyin.com',
      'aweme.com',
      'bytedance.com',
      'apple.com',
      'google.com',
      // v1.5.1：F-Droid 是开源官方仓库（签名验证、开源透明），按官方级对待
      'f-droid.org',
      'fdroid.org',
    ];
    for (final d in officialDomains) {
      if (lower.contains(d)) return SourceTrustLevel.official;
    }
    // 已知第三方（可信 APK 镜像站，无诱导下载）
    const trustedDomains = [
      'apkpure.com',
      'apkmirror.com',
      'coolapk.com',
      'shouji.com.cn',
      // v1.6.8 修复 Bug#10：appchina.com 从白名单移除（已在 _blockedStoreDomains 黑名单中，
      // 黑名单先执行导致白名单条目永不生效，是死代码）
      // v1.5.1：新增直链源（用户反馈：国内应用商店诱导下自家商店）
      'uptodown.com', // Uptodown，西班牙公司，国内可访问，APK 直链
      'apkmonk.com', // APKMonk，老牌 APK 镜像
      'apksos.com', // APKSOS
      // 注意：wandoujia.com(豌豆荚) v1.5.1 从可信移到黑名单，因为豌豆荚现在强推自家应用商店
    ];
    for (final d in trustedDomains) {
      if (lower.contains(d)) return SourceTrustLevel.trustedThirdParty;
    }
    return SourceTrustLevel.unknown;
  }

  /// v1.5.1：国内应用商店诱导下载域名黑名单。
  ///
  /// 这些站点搜出来常常是"请先下载 XX 应用商店才能下载 APP"的诱导页，
  /// 不是真正的 APK 直链，用户点进去只能下到他们的应用商店，浪费流量。
  /// 搜索结果中直接过滤掉这些域名，同时给官方/可信第三方直链源更高优先级。
  static const _blockedStoreDomains = [
    // 腾讯应用宝
    'sj.qq.com',
    'android.myapp.com',
    'softcna.qq.com',
    // 360 手机助手
    'zhushou.360.cn',
    'apk.360.cn',
    'down.360.cn',
    // 豌豆荚（被阿里收购后强推自家商店）
    'wandoujia.com',
    'wdjcdn.com',
    // 小米应用商店
    'app.mi.com',
    'market.xiaomi.com',
    // 华为应用市场
    'appgallery.huawei.com',
    'appgallery.cloud.huawei.com',
    // OPPO 软件商店
    'store.oppomobile.com',
    'oppomobile.com',
    // vivo 应用商店
    'appstore.vivo.com.cn',
    'vivo.com.cn',
    // 百度手机助手
    'shouji.baidu.com',
    'gdown.baidu.com',
    // 91 手机助手
    'zs.91.com',
    // 安卓市场
    'apk.hiapk.com',
    'hiapk.com',
    // 应用汇（v1.6.8 已从 trustedDomains 白名单移除，黑名单唯一生效）
    'appchina.com',
    // 搜狗手机助手
    'zhushou.sogou.com',
    // 联通沃商店 / 移动 MM 商场
    'club.wostore.cn',
    'mm.10086.cn',
    // 机锋市场
    'gfan.com',
    // 当乐
    'd.cn',
    // 拇指玩
    'muzhiwan.com',
  ];

  /// v1.5.1：判断 URL 是否命中国内应用商店黑名单。
  /// 在搜索结果处理时调用，命中则跳过（continue）。
  bool _isBlockedStore(String url) {
    final lower = url.toLowerCase();
    for (final d in _blockedStoreDomains) {
      if (lower.contains(d)) return true;
    }
    return false;
  }

  String _extractSourceName(String url, String title) {
    final domain = _extractDomain(url);
    // 用标题前 20 字做名字
    final shortTitle =
        title.length > 20 ? '${title.substring(0, 20)}...' : title;
    return '$shortTitle ($domain)';
  }

  String _extractDomain(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host;
    } catch (_) {
      return url;
    }
  }

  // --- 真实可写入的公共保存目录（优先公共 Download）
  Future<String> getSaveDirectory(String appName) async {
    // v1.6.8 修复 Bug#9：原 `late Directory base` 在 getDownloadsDirectory() 返回 null 时
    // 永远未赋值，后续 `if (!await _existsWritable(base))` 抛 LateInitializationError，
    // 被 catch 接住后三级回退链（downloads→externals→appSupport）完全失效，只能落到
    // Directory.current。改为 nullable，按回退顺序逐级赋值。
    Directory? base;
    try {
      // Android 上返回 /storage/emulated/0/Android/data/<pkg>/files/Download
      final downloads = await getDownloadsDirectory();
      if (downloads != null) base = downloads;
    } catch (e) {
      _logger.warn('[Download] getDownloadsDirectory failed: $e');
    }
    // fallback: external app dir
    if (!await _existsWritable(base)) {
      try {
        final externals = await getExternalStorageDirectories();
        if (externals != null && externals.isNotEmpty) base = externals.first;
      } catch (e) {
        _logger.warn('[Download] getExternalStorageDirectories failed: $e');
      }
    }
    // final fallback: app support dir (private)
    if (!await _existsWritable(base)) {
      try {
        base = await getApplicationSupportDirectory();
      } catch (_) {
        base = Directory.current;
      }
    }

    // v1.6.8：base 经过三级回退（最后一级 Directory.current 永远不会抛），
    // 执行到这里必然非空，用 ! 断言。
    final dir = Directory(p.join(base!.path, 'AIChat-APP下载', appName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _logger.info('[Download] save dir: ${dir.path}');
    return dir.path;
  }

  Future<bool> _existsWritable(Directory? d) async {
    if (d == null) return false;
    try {
      if (!await d.exists()) await d.create(recursive: true);
      final probe = File(p.join(d.path, '.probe'));
      await probe.writeAsString('ok');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// v1.3.5：从 HTML 下载页面中提取 .apk 直链
  /// 支持多种常见模式：href、data-url、JS redirect、meta refresh
  String? _extractApkLinkFromHtml(String html, String pageUrl) {
    // 解析页面 URL 用于补全相对路径
    Uri? pageUri;
    try {
      pageUri = Uri.parse(pageUrl);
    } catch (_) {}

    // 各种正则模式，按优先级排序
    final patterns = <RegExp>[
      // 1. href="xxx.apk" 或 href='xxx.apk'（最常见）
      RegExp(r'''href=["']([^"']*/[^"']*\.apk(?:\?[^"']*)?)["']''',
          caseSensitive: false),
      // 2. data-url="xxx.apk"
      RegExp(r'''data-url=["']([^"']*\.apk(?:\?[^"']*)?)["']''',
          caseSensitive: false),
      // 3. data-href="xxx.apk"
      RegExp(r'''data-href=["']([^"']*\.apk(?:\?[^"']*)?)["']''',
          caseSensitive: false),
      // 4. JS: location.href = "xxx.apk" / window.location = "xxx.apk"
      RegExp(r'''location\.href\s*=\s*['"]([^']*.apk(?:\?[^']*)?)[\'"]''',
          caseSensitive: false),
      RegExp(r'''window\.location\s*=\s*['"]([^']*.apk(?:\?[^']*)?)[\'"]''',
          caseSensitive: false),
      // 5. meta refresh: url=xxx.apk
      RegExp(r'''content=["']\d+;\s*url=([^"']*.apk(?:\?[^"']*)?)["']''',
          caseSensitive: false),
      // 6. 下载站常见：data-download-url="xxx.apk"
      RegExp(r'''data-download-url=["']([^"']*.apk(?:\?[^"']*)?)["']''',
          caseSensitive: false),
      // 7. onclick="...location='xxx.apk'"
      RegExp(
          r'''onclick=["'][^']*?location\w*\s*[=(]\s*['"]([^'"]*\.apk(?:\?[^'"]*)?)['"]''',
          caseSensitive: false),
      // 8. 通用 .apk URL（在 JS 变量、JSON 等中）
      RegExp(r'''["']([^"'<>]*\.apk(?:\?[^"'<>]*)?)["']''',
          caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final matches = pattern.allMatches(html);
      for (final m in matches) {
        final url = m.group(1)!;
        // 跳过太短或明显无效的
        if (url.length < 10) continue;
        // 补全相对路径
        final resolved = _resolveUrl(url, pageUri);
        if (resolved != null) {
          _logger.verbose(
              '[Download] HTML parse: pattern=$pattern → $url → $resolved',
              tag: 'DL');
          return resolved;
        }
      }
    }

    // 9. 特殊站点：安智市场 goapk.com 的下载链接模式
    if (pageUrl.contains('goapk.com') || pageUrl.contains('anzhi.com')) {
      // 安智市场常见模式：/download/xxx 或 data-id
      final dlMatch = RegExp(
              r'''(?:href|data-url)=["']([^"']*/download/[^"']+)["']''',
              caseSensitive: false)
          .firstMatch(html);
      if (dlMatch != null) {
        final resolved = _resolveUrl(dlMatch.group(1)!, pageUri);
        if (resolved != null) return resolved;
      }
    }

    // 10. 特殊站点：Uptodown 的下载链接模式
    if (pageUrl.contains('uptodown.com')) {
      final dlMatch = RegExp(
              r'''(?:href|data-url)=["']([^"']*/post-download/[^"']+)["']''',
              caseSensitive: false)
          .firstMatch(html);
      if (dlMatch != null) {
        final resolved = _resolveUrl(dlMatch.group(1)!, pageUri);
        if (resolved != null) return resolved;
      }
    }

    // 11. 特殊站点：APKPure 下载链接模式 (d.apkpure.com/b/APK/...)
    final apkpureMatch = RegExp(
            r'''(https?://d\.apkpure\.com/b/APK/[^"'<>\s]+)''',
            caseSensitive: false)
        .firstMatch(html);
    if (apkpureMatch != null) {
      return apkpureMatch.group(1)!;
    }

    // 12. Aptoide 下载链接模式
    final aptoideMatch = RegExp(
            r'''(https?://[^"'<>\s]*\.aptoide\.com/[^"'<>\s]*\.apk[^"'<>\s]*)''',
            caseSensitive: false)
        .firstMatch(html);
    if (aptoideMatch != null) {
      return aptoideMatch.group(1)!;
    }

    return null;
  }

  /// 将相对 URL 补全为绝对 URL
  String? _resolveUrl(String url, Uri? pageUri) {
    url = url.trim();
    // 已经是绝对 URL
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    // 协议相对
    if (url.startsWith('//')) {
      if (pageUri != null) return '${pageUri.scheme}:$url';
      return null;
    }
    // 相对路径
    if (pageUri != null) {
      // 去掉 query/fragment
      final base = pageUri.replace(query: '', fragment: '');
      // 绝对路径 /xxx
      if (url.startsWith('/')) {
        return '${base.scheme}://${base.host}$url';
      }
      // 相对路径，从目录补全
      final dir = base.path.substring(0, base.path.lastIndexOf('/') + 1);
      return '${base.scheme}://${base.host}$dir$url';
    }
    return null;
  }

  /// v1.3.6：fetch 下载页 HTML → 解析 .apk 直链
  /// 用浏览器请求头避免 403，最多读取 512KB HTML
  /// v1.7.9 修复（M1/M2）：
  /// - M1: `await response.stream.drain()` 写在 await for 体内 → 对单订阅流二次
  ///   listen 抛 StateError 被 catch 吞掉 → ≥512KB 页面全部解析失败。改为直接 break
  ///   （await-for 退出自动 cancel 订阅）
  /// - M2: client 声明在 try 内 → 超时/异常路径不 close 泄漏连接池。提到 try 外 + finally close
  Future<String?> _fetchAndParseDownloadPage(String pageUrl) async {
    final client = http.Client();
    try {
      final uri = Uri.parse(pageUrl);
      final request = http.Request('GET', uri);
      // 完整浏览器头（避免 403）
      request.headers['User-Agent'] = _androidUA;
      request.headers['Accept'] =
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
      request.headers['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8';
      request.headers['Accept-Encoding'] = 'identity';
      request.followRedirects = true;
      request.maxRedirects = 5;

      final response = await client.send(request).timeout(
            const Duration(seconds: 12),
          );

      if (response.statusCode != 200) {
        _logger.info(
            '[Download] Page fetch HTTP ${response.statusCode}: $pageUrl',
            tag: 'DL');
        return null;
      }

      // 只读前 512KB（下载页 HTML 通常 < 256KB）
      final maxBytes = 512 * 1024;
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        if (bytes.length >= maxBytes) {
          // v1.7.9: 直接 break，await-for 退出自动 cancel 订阅
          // （此前 drain() 二次监听同一单订阅流抛 StateError 被吞，方法返回 null）
          break;
        }
      }

      final html = utf8.decode(bytes, allowMalformed: true);
      _logger.verbose(
          '[Download] Page fetched (${bytes.length} bytes), parsing for APK...',
          tag: 'DL');

      return _extractApkLinkFromHtml(html, pageUrl);
    } catch (e) {
      _logger.warn('[Download] Page fetch/parse failed: $e', tag: 'DL');
      return null;
    } finally {
      client.close();
    }
  }

  Map<String, String> _buildHeaders(AppDownloadSource source) {
    final headers = <String, String>{
      'User-Agent': _androidUA,
      // v1.3.5：完整浏览器头，避免 403（之前 Accept 只写 APK 类型，网站识别为爬虫）
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Accept-Encoding': 'identity',
      'Cache-Control': 'no-cache',
      'Sec-Fetch-Dest': 'document',
      'Sec-Fetch-Mode': 'navigate',
      'Sec-Fetch-Site': 'none',
      'Upgrade-Insecure-Requests': '1',
    };
    if (source.referer != null && source.referer!.isNotEmpty) {
      headers['Referer'] = source.referer!;
    } else if (source.downloadUrl.contains('apkpure.com')) {
      headers['Referer'] = 'https://apkpure.com/';
    }
    return headers;
  }

  String _guessFileName(AppDownloadSource source, String appName) {
    try {
      final uri = Uri.parse(source.downloadUrl);
      final path = uri.path;
      final apkName = path
          .split('/')
          .lastWhere((s) => s.toLowerCase().endsWith('.apk'), orElse: () => '');
      if (apkName.isNotEmpty) return apkName;
    } catch (_) {}
    // fallback: 取 URL 最后一段 + .apk
    final safeName = appName.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');
    final safeVer = source.version.replaceAll('.', '_');
    return '${safeName}_v${safeVer}.apk';
  }

  // --- 真正启动下载
  Future<DownloadTask> startDownload({
    required String appName,
    required AppDownloadSource source,
    void Function(int received, int total)? onProgress,
  }) async {
    final saveDir = await getSaveDirectory(appName);
    final fileName = _guessFileName(source, appName);

    final task = DownloadTask(
      appName: appName,
      source: source,
      fileName: fileName,
      saveDir: saveDir,
    );
    currentTask = task;
    notifyListeners();

    final fullPath = p.join(saveDir, fileName);
    task.fullPath = fullPath;

    _logger.info(
        '[Download] Start ${appName}(${source.version}): ${source.downloadUrl} -> $fullPath');

    try {
      await _doDownload(task, source, fullPath, onProgress);
      await _verifyChecksum(task, source, fullPath);
      history.insert(0, task);
      return task;
    } catch (e, st) {
      // v1.3.4：GitHub 代理下载失败 → 自动回退直连重试一次
      if (source.isProxied && source.originalDownloadUrl != null) {
        _logger.warn(
            '[Download] Proxied URL failed ($e), retrying with direct GitHub URL: ${source.originalDownloadUrl}',
            tag: 'DL');
        // 清掉半成品文件
        try {
          final f = File(fullPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
        task.receivedBytes = 0;
        task.totalBytes = 0;
        // 构造一个"直连版"source（不带 originalDownloadUrl，避免再次回退循环）
        final directSource = AppDownloadSource(
          sourceName: source.sourceName.replaceAll(' · 已代理加速', ''),
          sourceDomain: source.sourceDomain,
          trustLevel: source.trustLevel,
          version: source.version,
          size: source.size,
          arch: source.arch,
          downloadUrl: source.originalDownloadUrl!,
          sha256: source.sha256,
          changelog: source.changelog,
          referer: source.referer,
        );
        task.source = directSource;
        try {
          await _doDownload(task, directSource, fullPath, onProgress);
          await _verifyChecksum(task, directSource, fullPath);
          _logger.info('[Download] Direct GitHub URL retry succeeded',
              tag: 'DL');
          history.insert(0, task);
          return task;
        } catch (e2, st2) {
          _logger.error('[Download] Direct retry also failed',
              error: e2, stack: st2, tag: 'DL');
          task.error = '代理和直连都失败：\n代理错误：$e\n直连错误：$e2';
          rethrow;
        }
      }
      _logger.error('[Download] Failed', error: e, stack: st, tag: 'DL');
      task.error = e.toString();
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _verifyChecksum(
    DownloadTask task,
    AppDownloadSource source,
    String fullPath,
  ) async {
    final expected = source.sha256?.trim().toLowerCase();
    if (expected == null || expected.isEmpty) {
      _logger.warn('[Download] Source did not provide SHA-256: $fullPath',
          tag: 'DL');
      return;
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) {
      throw Exception('来源提供的 SHA-256 格式无效');
    }
    final actual =
        (await sha256.bind(File(fullPath).openRead()).first).toString();
    if (actual != expected) {
      try {
        await File(fullPath).delete();
      } catch (_) {}
      task.error = 'SHA-256 校验失败，已删除下载文件';
      _logger.error('[Download] SHA-256 mismatch for $fullPath', tag: 'DL');
      throw Exception(task.error);
    }
    _logger.info('[Download] SHA-256 verified: $fullPath', tag: 'DL');
  }

  /// v1.3.4：抽出真正的下载执行逻辑（不含错误处理），方便 startDownload 做"代理失败回退直连"重试
  Future<void> _doDownload(
    DownloadTask task,
    AppDownloadSource source,
    String fullPath,
    void Function(int received, int total)? onProgress,
  ) async {
    final client = http.Client();
    try {
      final headers = _buildHeaders(source);

      // --- 先跑一次不带 Range 的 GET 取 metadata（跟随 302）
      final request = http.Request('GET', Uri.parse(source.downloadUrl));
      request.headers.addAll(headers);
      request.followRedirects = true;
      request.maxRedirects = 5;

      final streamed =
          await client.send(request).timeout(const Duration(seconds: 30));
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        // 如果是 HEAD 不支持，用 GET
        _logger.error(
            '[Download] HTTP ${streamed.statusCode} for ${source.downloadUrl}');
        throw Exception(
            'HTTP ${streamed.statusCode} ${streamed.reasonPhrase ?? ''} — ${source.downloadUrl}');
      }

      final contentLength = streamed.contentLength ?? 0;
      task.totalBytes = contentLength;
      final contentType = streamed.headers['content-type'] ?? '';
      _logger.info(
          '[Download] Status=200, Content-Length=$contentLength ($contentType)');

      // v1.3.5：如果拿到的是 text/html（下载页面而非直链），解析 HTML 提取 .apk 直链
      if (contentType.contains('text/html')) {
        // 读取完整 HTML
        final htmlBytes = <int>[];
        await for (final part in streamed.stream) {
          htmlBytes.addAll(part);
        }
        final html = utf8.decode(htmlBytes, allowMalformed: true);
        final htmlLower = html.toLowerCase();

        // 检查是否真的是 HTML 页面
        if (!htmlLower.contains('<html') && !htmlLower.contains('<!doctype')) {
          // 不是 HTML，当二进制写入
          await File(fullPath).writeAsBytes(htmlBytes, flush: true);
          task.receivedBytes = htmlBytes.length;
          task.totalBytes = htmlBytes.length;
          return;
        }

        _logger.info(
            '[Download] Got HTML page (${htmlBytes.length} bytes), parsing for APK link...',
            tag: 'DL');

        // 尝试从 HTML 中提取 .apk 直链
        final apkUrl = _extractApkLinkFromHtml(html, source.downloadUrl);
        if (apkUrl != null) {
          _logger.info('[Download] Extracted APK link from HTML: $apkUrl',
              tag: 'DL');
          // 用提取到的直链重新下载
          final newSource = AppDownloadSource(
            sourceName: source.sourceName,
            version: source.version,
            downloadUrl: apkUrl,
            sourceDomain: source.sourceDomain,
            trustLevel: source.trustLevel,
            size: source.size,
            arch: source.arch,
            referer: source.downloadUrl, // 原页面作为 Referer
            releaseDate: source.releaseDate,
          );
          // v1.3.7 Bug #5：递归调用必须 await，否则 Future 未等待、异常栈可能丢失
          return await _doDownload(task, newSource, fullPath, onProgress);
        }

        _logger.error(
            '[Download] No APK link found in HTML page. URL=${source.downloadUrl}',
            tag: 'DL');
        throw Exception(
            '下载页面未找到 APK 直链。该网站可能需要 JavaScript 渲染或手动下载。\nURL: ${source.downloadUrl}');
      }

      // 写文件
      final sink = File(fullPath).openWrite();
      int written = 0;
      await for (final bytes in streamed.stream) {
        written += bytes.length;
        sink.add(bytes);
        task.receivedBytes = written;
        onProgress?.call(written, contentLength);
        notifyListeners();
      }
      await sink.close();

      // 写了但文件大小不到 256KB 且 .html 内容？→ 不合法
      final finalFile = File(fullPath);
      final finalLen = await finalFile.length();
      _logger.info(
          '[Download] File saved: $fullPath (${(finalLen / 1024 / 1024).toStringAsFixed(2)} MB)');

      if (finalLen < 512 * 1024) {
        // < 512KB 几乎一定是错误页面
        try {
          final headBytes =
              await finalFile.openRead(0, 512).expand((b) => b).toList();
          final head =
              utf8.decode(headBytes, allowMalformed: true).toLowerCase();
          if (head.contains('<html') || head.contains('<!doctype')) {
            throw Exception('下载的文件不是 APK（收到了网页/错误页面）。请换一个下载源试试。');
          }
        } catch (e) {
          rethrow;
        }
      }

      task.receivedBytes = finalLen;
      if (contentLength == 0) task.totalBytes = finalLen;
    } finally {
      client.close();
    }
  }

  // ==========================================================================
  // v1.4.2：通用文件下载（支持视频/图片/文档等任何 URL）
  // ==========================================================================

  /// 通用文件下载：接受任何 URL，保存到设备下载目录
  /// [url]：文件的直接下载 URL
  /// [fileName]：可选的文件名（不提供则从 URL 推断）
  /// [onProgress]：进度回调
  /// [taskId]：可选下载任务 id（用于 cancelDownload 取消；不传则内部生成）
  /// 返回完整文件路径 + taskId（result['taskId']）
  ///
  /// v1.5.0 新增：取消机制
  /// - 调用方拿到 taskId 后，可以调 cancelDownload(taskId)
  /// - downloadFileFromUrl 循环内每轮检查 _cancelFlags[taskId]
  /// - 被取消时：关闭 sink → 删除已写入的部分文件 → 抛 _DownloadCancelledException
  Future<Map<String, dynamic>> downloadFileFromUrl({
    required String url,
    String? fileName,
    void Function(int received, int total)? onProgress,
    String? taskId,
  }) async {
    // v1.5.0：生成 taskId 并初始化取消标志
    final effectiveTaskId = taskId ??
        'dl_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(0xFFFFFF).toRadixString(16)}';
    _cancelFlags[effectiveTaskId] = false;

    final client = http.Client();
    try {
      final uri = Uri.parse(url);
      final request = http.Request('GET', uri);
      request.headers['User-Agent'] = _androidUA;
      request.headers['Accept'] = '*/*';
      request.followRedirects = true;
      request.maxRedirects = 5;

      final streamed =
          await client.send(request).timeout(const Duration(seconds: 30));
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw Exception('HTTP ${streamed.statusCode} — ${streamed.reasonPhrase}');
      }

      final contentLength = streamed.contentLength ?? 0;
      final contentType = streamed.headers['content-type'] ?? '';
      final finalUrl = streamed.request!.url.toString();

      // v1.4.2 下载安全增强：下载前校验响应类型/大小，防止下到网页/超大文件
      final lowerCt = contentType.toLowerCase();
      if (lowerCt.contains('text/html')) {
        throw Exception('目标不是文件而是网页（HTML），已拒绝下载');
      }
      const maxBytes = 500 * 1024 * 1024; // 500MB 上限
      if (contentLength > maxBytes) {
        throw Exception(
            '文件过大（${(contentLength / 1024 / 1024).toStringAsFixed(1)}MB），已拒绝下载');
      }

      // 推断文件名（v1.4.2 安全加固：统一 sanitize，防路径遍历 '../'）
      String finalFileName;
      if (fileName != null && fileName.isNotEmpty) {
        finalFileName = _sanitizeFileName(fileName);
      } else {
        finalFileName = _sanitizeFileName(
            _extractFileNameFromUrl(finalUrl, contentType));
      }

      // 根据文件类型选择保存目录
      final saveDir = await _getFileSaveDirectory(finalFileName, contentType);
      if (!await saveDir.exists()) {
        await saveDir.create(recursive: true);
      }

      final fullPath = p.join(saveDir.path, finalFileName);

      _logger.info(
          '[Download] Generic download: $url ($contentLength bytes, $contentType) → $fullPath (taskId=$effectiveTaskId)');

      final sink = File(fullPath).openWrite();
      int written = 0;
      bool cancelled = false;
      // v1.6.8 修复 Bug#13：原 maxBytes 检查只看 contentLength 头，但 chunked 传输编码时
      // contentLength 为 null→0，限制被跳过，10GB 文件可下满耗尽存储。
      // 在流式循环内加运行时上限检查（与外层 maxBytes 同值，但作用域不同，重命名避免冲突）。
      const maxBytesRuntime = 500 * 1024 * 1024; // 500MB 上限
      bool oversize = false;
      try {
        await for (final bytes in streamed.stream) {
          // v1.5.0：每轮检查取消标志
          if (_cancelFlags[effectiveTaskId] == true) {
            cancelled = true;
            break;
          }
          written += bytes.length;
          // v1.6.8：运行时大小检查，覆盖 chunked 编码绕过场景
          if (written > maxBytesRuntime) {
            oversize = true;
            break;
          }
          sink.add(bytes);
          onProgress?.call(written, contentLength);
          notifyListeners();
        }
      } finally {
        await sink.close();
      }

      // v1.6.8：超限后删除部分文件并抛异常
      if (oversize) {
        try {
          await File(fullPath).delete();
        } catch (_) {}
        throw Exception('下载超过 500MB 上限（实际 $written 字节）');
      }

      // v1.5.0：被取消时删除已写入的部分文件
      if (cancelled) {
        try {
          final f = File(fullPath);
          if (await f.exists()) await f.delete();
          _logger.info('[Download] Cancelled, partial file deleted: $fullPath');
        } catch (_) {}
        throw _DownloadCancelledException('用户已取消下载');
      }

      final finalLen = await File(fullPath).length();
      _logger.info(
          '[Download] Generic download complete: $fullPath (${(finalLen / 1024 / 1024).toStringAsFixed(2)} MB)');

      return {
        'path': fullPath,
        'fileName': finalFileName,
        'size': finalLen,
        'contentType': contentType,
        'taskId': effectiveTaskId,
      };
    } catch (e) {
      _logger.error('[Download] Generic download failed (taskId=$effectiveTaskId)', error: e);
      rethrow;
    } finally {
      // v1.5.0：下载结束（成功/失败/取消）都清理取消标志
      _cancelFlags.remove(effectiveTaskId);
      client.close();
    }
  }

  /// 从 URL 推断文件名
  String _extractFileNameFromUrl(String url, String contentType) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final lastSegment = path.split('/').last;
      if (lastSegment.isNotEmpty && !lastSegment.contains('?')) {
        // 有扩展名
        final ext = p.extension(lastSegment);
        if (ext.isNotEmpty) return Uri.decodeComponent(lastSegment);
      }
    } catch (_) {}
    // fallback：根据 content-type 生成
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ext = _extensionFromContentType(contentType);
    return 'download_$timestamp.$ext';
  }

  /// v1.4.2 安全加固：文件名清洗，防路径遍历
  ///
  /// 攻击向量：AI 生成 `<download url=".../../../system/etc/passwd">` 或者
  /// `<download fileName="../../evil">` → 写文件到 saveDir 外部。
  /// 策略：
  ///   1. 用 basename 取最后一段，剥掉所有目录前缀
  ///   2. 禁止字符 < > : " / \ | ? * 全部替换为 _
  ///   3. 空文件名 fallback 到 download_<timestamp>
  ///   4. 长度限制 200 字符，避免超长文件名
  String _sanitizeFileName(String raw) {
    if (raw.isEmpty) return 'download_${DateTime.now().millisecondsSinceEpoch}';
    // 1) 仅保留 basename，剥掉所有目录片段（包括 '../' 等相对路径）
    var s = p.basename(raw);
    // 2) 替换非法 / 危险字符
    s = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    // 3) 去掉开头的点和空格，避免隐藏文件
    s = s.replaceAll(RegExp(r'^[\s\.]+'), '');
    // 4) 去掉结尾的点和空格，Windows 安全
    s = s.replaceAll(RegExp(r'[\s\.]+$'), '');
    // 5) 长度限制
    if (s.length > 200) s = s.substring(0, 200);
    if (s.isEmpty) s = 'download_${DateTime.now().millisecondsSinceEpoch}';
    return s;
  }

  /// 公开桥接：文件名清洗（供自检等生产代码复用同一套真实逻辑）
  static String sanitizeFileNameForCheck(String raw) =>
      AppDownloadService()._sanitizeFileName(raw);

  /// 根据 content-type 推断文件扩展名
  String _extensionFromContentType(String contentType) {
    final ct = contentType.toLowerCase();
    if (ct.contains('video/mp4')) return 'mp4';
    if (ct.contains('video/webm')) return 'webm';
    if (ct.contains('video/')) return 'mp4';
    if (ct.contains('image/jpeg')) return 'jpg';
    if (ct.contains('image/png')) return 'png';
    if (ct.contains('image/gif')) return 'gif';
    if (ct.contains('image/webp')) return 'webp';
    if (ct.contains('image/')) return 'img';
    if (ct.contains('audio/mpeg')) return 'mp3';
    if (ct.contains('audio/')) return 'audio';
    if (ct.contains('application/pdf')) return 'pdf';
    if (ct.contains('application/zip')) return 'zip';
    if (ct.contains('application/json')) return 'json';
    if (ct.contains('text/plain')) return 'txt';
    if (ct.contains('text/html')) return 'html';
    return 'bin';
  }

  /// 根据文件类型选择保存目录
  Future<Directory> _getFileSaveDirectory(String fileName, String contentType) async {
    final ext = p.extension(fileName).toLowerCase();
    String subDir;

    if (ext == 'mp4' || ext == 'webm' || ext == 'mov' || ext == 'mkv' ||
        contentType.contains('video/')) {
      subDir = 'Nexus-视频';
    } else if (ext == 'jpg' || ext == 'jpeg' || ext == 'png' || ext == 'gif' ||
        ext == 'webp' || contentType.contains('image/')) {
      subDir = 'Nexus-图片';
    } else if (ext == 'mp3' || ext == 'wav' || ext == 'ogg' || contentType.contains('audio/')) {
      subDir = 'Nexus-音频';
    } else if (ext == 'pdf' || ext == 'doc' || ext == 'docx' || ext == 'txt' ||
        ext == 'json' || ext == 'zip') {
      subDir = 'Nexus-文档';
    } else {
      subDir = 'Nexus-文件';
    }

    // 尝试获取公共下载目录
    try {
      final dirs = await getExternalStorageDirectories(type: StorageDirectory.downloads);
      if (dirs != null && dirs.isNotEmpty) {
        final d = Directory(p.join(dirs.first.path, subDir));
        if (await _existsWritable(d)) return d;
      }
    } catch (_) {}

    // fallback: app 内部下载目录
    final base = await getDownloadsDirectory() ??
        await getApplicationCacheDirectory();
    final d = Directory(p.join(base.path, subDir));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }
}
