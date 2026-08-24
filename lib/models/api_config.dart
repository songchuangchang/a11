import 'dart:convert';
import 'package:uuid/uuid.dart';

class ApiConfig {
  final String id;
  String name;
  String baseUrl;
  String apiKey;
  String model;
  String systemPrompt;
  double temperature;
  double topP;
  int maxTokens;

  /// v1.5.0：缓存从 `GET {baseUrl}/v1/models` 拉取的模型 id 列表（JSON 字符串）
  ///
  /// 数据库存储为 TEXT（JSON 序列化的 List<String>）；为空字符串或 null 表示未缓存。
  /// UI 上展示时用 `cachedModelsList` getter 解码。
  ///
  /// 失败兜底：listModels 调用失败时保留旧 cachedModels 不覆盖，
  /// UI 提示「拉取失败，已用上次缓存的列表」。
  String cachedModels;

  ApiConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.systemPrompt = '',
    this.temperature = 0.7,
    this.topP = 1.0,
    this.maxTokens = 2048,
    this.cachedModels = '',
  });

  factory ApiConfig.create({
    String name = 'New API',
    String baseUrl = 'https://api.openai.com',
    String apiKey = '',
    String model = 'gpt-4o-mini',
  }) {
    return ApiConfig(
      id: const Uuid().v4(),
      name: name,
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
    );
  }

  /// v1.5.0：把 cachedModels JSON 字符串解码成 List<String>
  ///
  /// 反序列化失败 / 空字符串 → 返回空列表（不抛异常，避免 UI 渲染崩溃）
  List<String> get cachedModelsList {
    if (cachedModels.isEmpty) return const [];
    try {
      final list = json.decode(cachedModels);
      if (list is List) {
        return list.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return const [];
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'baseUrl': baseUrl,
      'apiKey': apiKey,
      'model': model,
      'systemPrompt': systemPrompt,
      'temperature': temperature,
      'topP': topP,
      'maxTokens': maxTokens,
      'cachedModels': cachedModels,
    };
  }

  factory ApiConfig.fromMap(Map<String, dynamic> map) {
    return ApiConfig(
      id: map['id'] as String,
      name: map['name'] as String,
      baseUrl: map['baseUrl'] as String,
      apiKey: map['apiKey'] as String,
      model: map['model'] as String,
      systemPrompt: (map['systemPrompt'] as String?) ?? '',
      temperature: (map['temperature'] as num?)?.toDouble() ?? 0.7,
      topP: (map['topP'] as num?)?.toDouble() ?? 1.0,
      maxTokens: (map['maxTokens'] as int?) ?? 2048,
      cachedModels: (map['cachedModels'] as String?) ?? '',
    );
  }

  String toJson() => json.encode(toMap());

  factory ApiConfig.fromJson(String source) =>
      ApiConfig.fromMap(json.decode(source) as Map<String, dynamic>);

  ApiConfig copyWith({
    String? name,
    String? baseUrl,
    String? apiKey,
    String? model,
    String? systemPrompt,
    double? temperature,
    double? topP,
    int? maxTokens,
    String? cachedModels,
  }) {
    return ApiConfig(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      maxTokens: maxTokens ?? this.maxTokens,
      cachedModels: cachedModels ?? this.cachedModels,
    );
  }

  String get chatEndpoint {
    String url = baseUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (_isVersionedBase(url)) {
      return '$url/chat/completions';
    }
    return '$url/v1/chat/completions';
  }

  /// v1.5.0：拼接 `GET {baseUrl}/v1/models` 端点
  ///
  /// OpenAI 兼容服务都支持；本地模型（Ollama `http://localhost:11434/v1/models`）也兼容
  String get modelsEndpoint {
    String url = baseUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (_isVersionedBase(url)) {
      return '$url/models';
    }
    return '$url/v1/models';
  }

  /// v1.5.2：判断 baseUrl 是否已经带了版本路径（末尾一段以 `v`+数字开头，如 /v1、/v4）
  ///
  /// 修复 v1.5.0~v1.5.1 的 bug：智谱 GLM 的 baseUrl 是 `.../api/paas/v4`（末尾 /v4，不是 /v1），
  /// 旧逻辑只识别 /v1，导致 models 端点被错误拼成 `.../v4/v1/models`（多一个 /v1），
  /// 智谱刷新模型返回 401。
  ///
  /// 现在统一识别 `/v\d+` 结尾：
  ///   - DeepSeek `.../v1` → 直接拼 /models ✅
  ///   - 阿里云 `.../compatible-mode/v1` → 直接拼 /models ✅
  ///   - 智谱 `.../paas/v4` → 直接拼 /models ✅（修复点）
  ///   - Ollama `...:11434/v1` → 直接拼 /models ✅
  ///   - OpenAI 裸域名 `api.openai.com`（无版本）→ 拼 /v1/models ✅
  static bool _isVersionedBase(String url) {
    final last = url.split('/').last;
    return RegExp(r'^v\d').hasMatch(last);
  }
}
