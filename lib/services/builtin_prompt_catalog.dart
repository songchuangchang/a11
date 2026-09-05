import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// v1.7.24 (#5/#6)：内置插件 ReAct 协议目录 —— 内置默认 + 远程 JSON 覆盖。
///
/// 解决两个硬编码痛点：
///   #5 builtin_plugins 的 promptProtocol 硬编码在代码里（改提示词需发版）；
///   #6 ReAct prompt 模板 / 触发词需改代码才能加协议标签。
///
/// 方案：内置默认保留（离线兜底），运行时先查远程覆盖（按插件 id），
/// 命中则用远程文本，否则回落内置。这样「改协议 / 加标签」只需更新远程 JSON，无需发版。
///
/// 远程 JSON 格式（二选一）：
///   A. `{"plugins": [ {"id": "nexus.builtin.search", "promptProtocol": "..."}, ... ]}`
///   B. `{"prompts": {"nexus.builtin.search": "..."}, "triggerWords": {"download": ["..."]}}`
class BuiltinPromptCatalog {
  BuiltinPromptCatalog._();

  static final BuiltinPromptCatalog instance = BuiltinPromptCatalog._();

  final Map<String, String> _remotePrompts = {};
  final Map<String, String> _remoteFormats = {};
  final Map<String, List<String>> _remoteTriggerWords = {};

  String lastMessage = '';

  DateTime? lastUpdatedAt;

  bool get hasRemote => _remotePrompts.isNotEmpty;

  static const _urlKey = 'remote_builtin_prompts_url';
  static const _jsonKey = 'remote_builtin_prompts_json';
  static const _updatedKey = 'remote_builtin_prompts_updated_at';
  static const _retryKey = 'remote_builtin_prompts_retry_pending';
  static const _refreshInterval = Duration(days: 7);

  Future<void> initialize({String? url}) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_jsonKey);
    if (cached != null && applyJson(cached)) {
      lastUpdatedAt = DateTime.tryParse(prefs.getString(_updatedKey) ?? '');
    }
    final source = prefs.getString(_urlKey) ?? url;
    if (source == null || source.isEmpty) return;
    final updated = DateTime.tryParse(prefs.getString(_updatedKey) ?? '');
    final due = updated == null ||
        DateTime.now().difference(updated) >= _refreshInterval;
    final retry = prefs.getBool(_retryKey) ?? false;
    if (due || retry) await _refreshAndCache(source, prefs);
  }

  Future<bool> _refreshAndCache(String url, SharedPreferences prefs) async {
    final ok = await fetchRemote(url);
    if (ok) {
      await prefs.setString(_urlKey, url);
      await prefs.setString(
          _jsonKey,
          json.encode({
            'prompts': _remotePrompts,
            'formats': _remoteFormats,
            'triggerWords': _remoteTriggerWords,
          }));
      await prefs.setString(_updatedKey, DateTime.now().toIso8601String());
      await prefs.setBool(_retryKey, false);
    } else {
      await prefs.setBool(_retryKey, true);
    }
    return ok;
  }

  Future<bool> refreshOnline(String url) async {
    final prefs = await SharedPreferences.getInstance();
    return _refreshAndCache(url.trim(), prefs);
  }

  /// 解析生效协议：远程覆盖优先，否则内置默认。
  String resolve(String pluginId, String builtin) =>
      _remotePrompts[pluginId] ?? builtin;

  String resolveFormat(String triggerType, String builtin) =>
      _remoteFormats[triggerType] ?? builtin;

  List<String> triggerWords(String triggerType) =>
      List.unmodifiable(_remoteTriggerWords[triggerType] ?? const []);

  bool matchesTriggerWords(String triggerType, String raw) {
    final text = raw.trim().toLowerCase();
    return triggerWords(triggerType)
        .any((word) => text.contains(word.toLowerCase()));
  }

  /// 从远程 URL 拉取 JSON 协议并覆盖。
  Future<bool> fetchRemote(String url) async {
    if (url.trim().isEmpty) {
      lastMessage = '远程地址为空';
      return false;
    }
    final trimmed = url.trim();
    // v1.7.30: raw.githubusercontent.com 在部分地区被墙，失败后自动尝试 jsdelivr 镜像
    if (await _doFetch(trimmed)) return true;
    final mirror = _jsdelivrMirror(trimmed);
    if (mirror != null && mirror != trimmed) {
      if (await _doFetch(mirror)) return true;
    }
    return false;
  }

  Future<bool> _doFetch(String url) async {
    try {
      final resp = await http.get(Uri.parse(url), headers: {
        'Accept': 'application/json',
        'User-Agent': 'AIChat/1.7.24',
      }).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        lastMessage = 'HTTP ${resp.statusCode}';
        return false;
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      final prompts = _extractPrompts(decoded);
      final formats = _extractFormats(decoded);
      final triggerWords = _extractTriggerWords(decoded);
      if (prompts.isEmpty && formats.isEmpty && triggerWords.isEmpty) {
        lastMessage = 'JSON 中无有效协议、格式或触发词';
        return false;
      }
      _remotePrompts
        ..clear()
        ..addAll(prompts);
      _remoteFormats
        ..clear()
        ..addAll(formats);
      _remoteTriggerWords
        ..clear()
        ..addAll(triggerWords);
      lastUpdatedAt = DateTime.now();
      lastMessage = '已更新 ${prompts.length} 条协议';
      return true;
    } catch (e) {
      lastMessage = '拉取失败: $e';
      return false;
    }
  }

  /// 将 raw.githubusercontent.com URL 转换为 fastly.jsdelivr.net 镜像。
  static String? _jsdelivrMirror(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host != 'raw.githubusercontent.com') return null;
    final segs = uri.pathSegments;
    if (segs.length < 4) return null;
    final owner = segs[0];
    final repo = segs[1];
    final branch = segs[2];
    final filePath = segs.sublist(3).join('/');
    return 'https://fastly.jsdelivr.net/gh/$owner/$repo@$branch/$filePath';
  }

  /// 用原始 JSON 字符串更新（本地资产 / 测试复用）。
  bool applyJson(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      final prompts = _extractPrompts(decoded);
      final formats = _extractFormats(decoded);
      final triggerWords = _extractTriggerWords(decoded);
      if (prompts.isEmpty && formats.isEmpty && triggerWords.isEmpty) {
        return false;
      }
      _remotePrompts
        ..clear()
        ..addAll(prompts);
      _remoteFormats
        ..clear()
        ..addAll(formats);
      _remoteTriggerWords
        ..clear()
        ..addAll(triggerWords);
      lastUpdatedAt = DateTime.now();
      lastMessage = '已更新 ${prompts.length} 条协议';
      return true;
    } catch (e) {
      lastMessage = '解析失败: $e';
      return false;
    }
  }

  Map<String, String> _extractFormats(Object? decoded) {
    if (decoded is! Map || decoded['formats'] is! Map) return const {};
    final out = <String, String>{};
    (decoded['formats'] as Map).forEach((k, v) {
      final value = v?.toString() ?? '';
      if (value.isNotEmpty) out[k.toString()] = value;
    });
    return out;
  }

  Map<String, List<String>> _extractTriggerWords(Object? decoded) {
    if (decoded is! Map || decoded['triggerWords'] is! Map) return const {};
    final out = <String, List<String>>{};
    (decoded['triggerWords'] as Map).forEach((k, v) {
      if (v is List) {
        final words = v
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false);
        if (words.isNotEmpty) out[k.toString()] = words;
      }
    });
    return out;
  }

  Map<String, String> _extractPrompts(Object? decoded) {
    final out = <String, String>{};
    if (decoded is Map && decoded['plugins'] is List) {
      for (final p in (decoded['plugins'] as List).whereType<Map>()) {
        final id = p['id']?.toString();
        final pp = p['promptProtocol']?.toString();
        if (id != null && id.isNotEmpty && pp != null && pp.isNotEmpty) {
          out[id] = pp;
        }
      }
    } else if (decoded is Map && decoded['prompts'] is Map) {
      (decoded['prompts'] as Map).forEach((k, v) {
        final s = v.toString();
        if (s.isNotEmpty) out[k.toString()] = s;
      });
    }
    return out;
  }
}
