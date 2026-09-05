/// 联网搜索配置 & 搜索结果
///
/// v1.3.9 支持的搜索后端：
///   1) Bing 直爬（默认，无需 Key，国内可访问）
///   2) Tavily API（需 Key，结果结构化，质量高）
library web_search_config;
///   3) SearXNG（自建/公共实例，可选）
///   4) DuckDuckGo 直爬（无需 Key，国内可访问）
///   5) SerpAPI（需 Key，聚合 Google/Bing 等多引擎，100次/月免费）
///   6) Brave Search API（需 Key，2000次/月免费，质量好）
///   7) Google CSE 自定义搜索（需 Key + cx，100次/天免费）

import 'package:flutter/foundation.dart';

enum WebSearchProvider {
  bing, // 默认 Bing 直爬，无需 Key
  tavily, // Tavily API（付费+免费层）
  searxng, // SearXNG 公共/自建（可选）
  duckduckgo, // v1.3.9 新增：DuckDuckGo 直爬，无需 Key
  serpapi, // v1.3.9 新增：SerpAPI 聚合搜索，需 Key
  brave, // v1.3.9 新增：Brave Search API，需 Key
  googlecse, // v1.3.9 新增：Google CSE 自定义搜索，需 Key + cx
}

/// v1.5.2：联网搜索服务商的官网链接（用户点击跳转去注册 / 查 Key）
extension WebSearchProviderInfo on WebSearchProvider {
  String get officialUrl {
    switch (this) {
      case WebSearchProvider.bing:
        return 'https://www.bing.com/';
      case WebSearchProvider.tavily:
        return 'https://tavily.com/';
      case WebSearchProvider.searxng:
        return 'https://docs.searxng.org/';
      case WebSearchProvider.duckduckgo:
        return 'https://duckduckgo.com/';
      case WebSearchProvider.serpapi:
        return 'https://serpapi.com/';
      case WebSearchProvider.brave:
        return 'https://brave.com/search/api/';
      case WebSearchProvider.googlecse:
        return 'https://programmablesearchengine.google.com/';
    }
  }
}

/// 远程规则源默认 URL（用户 GitHub 仓库，自动同步）
const String _defaultRulesUrl =
    'https://fastly.jsdelivr.net/gh/songchuangchang/a11@main/rules.json';

/// 通用搜索配置（单一配置，简单 KV 存 SQLite 就够了）
class WebSearchConfig extends ChangeNotifier {
  /// 总开关：false 时所有联网搜索功能禁用
  bool webSearchEnabled;

  /// 选用的搜索服务商
  WebSearchProvider provider;

  /// Tavily API Key（Bearer Token 形式）
  String tavilyApiKey;

  /// Tavily 搜索深度：basic / advanced
  String tavilySearchDepth;

  /// Tavily 默认返回结果数（3-10）
  int tavilyMaxResults;

  /// SearXNG 自定义实例 URL（为空就用公共列表）
  String searxngInstanceUrl;

  /// v1.3.9 新增：SerpAPI Key（聚合 Google/Bing 等）
  String serpApiKey;

  /// v1.3.9 新增：SerpAPI 使用的引擎（google / bing / duckduckgo / baidu 等）
  String serpapiEngine;

  /// v1.3.9 新增：Brave Search API Key
  String braveApiKey;

  /// v1.3.9 新增：Google CSE API Key
  String googleCseApiKey;

  /// v1.3.9 新增：Google CSE 搜索引擎 ID（cx）
  String googleCseId;

  /// 每次搜索注入到 LLM 的最大摘要长度（字符）
  int maxSnippetCharsPerResult;

  /// 注入到 prompt 的最大结果数
  int maxResultsInject;

  // ==========================================================================
  // v1.3.1 build 11: 🌐 常驻开关 + ReAct 思考循环配置（全部持久化）
  // v1.3.3 build 13: 新增 reactAutoMode（AI 自动决定搜索轮次）
  // ==========================================================================

  /// 用户输入框 🌐 按钮上次是否开启（true=常驻，不用每次都点）
  bool persistentWebSearchToggle;

  /// 是否启用 ReAct 自主思考 + 搜索循环（类 Chatbox 思考模式）
  bool reactEnabled;

  /// 思考程度：控制 ReAct 最大搜索轮次（Low=2 / Default=3 / Medium=5 / High=8）
  /// v1.3.3：当 reactAutoMode=true 时，此值代表自动档的上限（默认 30，可调）
  int reactMaxRounds;

  /// v1.3.3 新增：是否为"自动"档位（AI 自己决定搜索轮次）
  bool reactAutoMode;

  /// v1.3.4 新增：GitHub release asset 下载加速代理 URL
  String githubProxyUrl;

  /// v1.3.4 新增：详细日志模式（默认 false）
  bool verboseLogging;

  // ==========================================================================
  // v1.7.5 新增：安全审查配置
  // ==========================================================================

  /// SkillSpector 服务地址（用于审查 Skill 和 MCP）
  String skillspectorEndpoint;

  /// 是否启用 Skill 安全审查
  bool enableSkillSecurityScan;

  /// 是否启用 MCP 安全审查
  bool enableMcpSecurityScan;

  /// MobSF 服务地址（用于审查 APK）
  String mobsfEndpoint;

  /// 是否启用 APK 安全审查
  bool enableApkSecurityScan;

  // ==========================================================================
  // v1.7.10 新增：本地安全扫描（零配置，默认开）
  // ==========================================================================

  /// 是否启用本地规则扫描（Skill/MCP 安装前，纯 Dart 离线扫描）
  bool enableLocalScan;

  /// 远程规则源 URL（预留：留空走内置规则；填 GitHub raw JSON 地址可热更新规则）
  String localScanRulesUrl;

  // ==========================================================================
  // v1.7.11 新增：VirusTotal 云端查毒 + MobSF API Key
  // ==========================================================================

  /// VirusTotal API Key（免费注册 500次/天，用于 APK/文件下载后哈希查毒）
  String virusTotalApiKey;

  /// 是否启用 VirusTotal 云端查毒（默认关，需填 API Key 后才开）
  bool enableVirusTotalScan;

  /// MobSF API Key（自部署 MobSF 也可配认证，v1.7.11 P0 修复）
  String mobsfApiKey;

  /// v1.7.22：生物识别锁开关（持久化到 web_search_configs）
  bool biometricLockEnabled;

  WebSearchConfig({
    this.webSearchEnabled = true,
    this.provider = WebSearchProvider.bing,
    this.tavilyApiKey = '',
    this.tavilySearchDepth = 'auto',
    this.tavilyMaxResults = 5,
    this.searxngInstanceUrl = '',
    this.serpApiKey = '',
    this.serpapiEngine = 'google',
    this.braveApiKey = '',
    this.googleCseApiKey = '',
    this.googleCseId = '',
    this.maxSnippetCharsPerResult = 400,
    this.maxResultsInject = 5,
    this.persistentWebSearchToggle = true,
    this.reactEnabled = true,
    this.reactMaxRounds = 3,
    this.reactAutoMode = false,
    this.githubProxyUrl = '',
    this.verboseLogging = false,
    this.skillspectorEndpoint = '',
    this.enableSkillSecurityScan = false,
    this.enableMcpSecurityScan = false,
    this.mobsfEndpoint = '',
    this.enableApkSecurityScan = false,
    this.enableLocalScan = true,
    this.localScanRulesUrl = _defaultRulesUrl,
    this.virusTotalApiKey = '',
    this.enableVirusTotalScan = false,
    this.mobsfApiKey = '',
    this.biometricLockEnabled = false,
  });

  factory WebSearchConfig.fromMap(Map<String, dynamic> m) => WebSearchConfig(
        // v1.7.36：联网搜索内置为默认能力，恒开启（忽略历史存储的 0）
        webSearchEnabled: true,
        provider: WebSearchProvider.values.firstWhere(
          (e) => e.name == (m['provider'] as String? ?? 'bing'),
          orElse: () => WebSearchProvider.bing,
        ),
        tavilyApiKey: m['tavilyApiKey'] as String? ?? '',
        tavilySearchDepth: m['tavilySearchDepth'] as String? ?? 'auto',
        tavilyMaxResults: m['tavilyMaxResults'] as int? ?? 5,
        searxngInstanceUrl: m['searxngInstanceUrl'] as String? ?? '',
        serpApiKey: m['serpApiKey'] as String? ?? '',
        serpapiEngine: m['serpapiEngine'] as String? ?? 'google',
        braveApiKey: m['braveApiKey'] as String? ?? '',
        googleCseApiKey: m['googleCseApiKey'] as String? ?? '',
        googleCseId: m['googleCseId'] as String? ?? '',
        maxSnippetCharsPerResult: m['maxSnippetCharsPerResult'] as int? ?? 400,
        maxResultsInject: m['maxResultsInject'] as int? ?? 5,
        persistentWebSearchToggle: (m['persistentWebSearchToggle'] as int? ?? 1) == 1,
        reactEnabled: (m['reactEnabled'] as int? ?? 1) == 1,
        reactMaxRounds: m['reactMaxRounds'] as int? ?? 3,
        reactAutoMode: (m['reactAutoMode'] as int? ?? 0) == 1,
        githubProxyUrl: m['githubProxyUrl'] as String? ?? '',
        verboseLogging: (m['verboseLogging'] as int? ?? 0) == 1,
        skillspectorEndpoint: m['skillspectorEndpoint'] as String? ?? '',
        enableSkillSecurityScan: (m['enableSkillSecurityScan'] as int? ?? 0) == 1,
        enableMcpSecurityScan: (m['enableMcpSecurityScan'] as int? ?? 0) == 1,
        mobsfEndpoint: m['mobsfEndpoint'] as String? ?? '',
        enableApkSecurityScan: (m['enableApkSecurityScan'] as int? ?? 0) == 1,
        enableLocalScan: (m['enableLocalScan'] as int? ?? 1) == 1,
        localScanRulesUrl: (m['localScanRulesUrl'] as String?)?.isEmpty == true || (m['localScanRulesUrl'] as String?) == null
            ? _defaultRulesUrl
            : m['localScanRulesUrl'] as String,
        virusTotalApiKey: m['virusTotalApiKey'] as String? ?? '',
        enableVirusTotalScan: (m['enableVirusTotalScan'] as int? ?? 0) == 1,
        mobsfApiKey: m['mobsfApiKey'] as String? ?? '',
        biometricLockEnabled: (m['biometricLockEnabled'] as int? ?? 0) == 1,
      );

  Map<String, dynamic> toMap() => {
        'id': 'singleton',
        'webSearchEnabled': webSearchEnabled ? 1 : 0,
        'provider': provider.name,
        'tavilyApiKey': tavilyApiKey,
        'tavilySearchDepth': tavilySearchDepth,
        'tavilyMaxResults': tavilyMaxResults,
        'searxngInstanceUrl': searxngInstanceUrl,
        'serpApiKey': serpApiKey,
        'serpapiEngine': serpapiEngine,
        'braveApiKey': braveApiKey,
        'googleCseApiKey': googleCseApiKey,
        'googleCseId': googleCseId,
        'maxSnippetCharsPerResult': maxSnippetCharsPerResult,
        'maxResultsInject': maxResultsInject,
        'persistentWebSearchToggle': persistentWebSearchToggle ? 1 : 0,
        'reactEnabled': reactEnabled ? 1 : 0,
        'reactMaxRounds': reactMaxRounds,
        'reactAutoMode': reactAutoMode ? 1 : 0,
        'githubProxyUrl': githubProxyUrl,
        'verboseLogging': verboseLogging ? 1 : 0,
        'skillspectorEndpoint': skillspectorEndpoint,
        'enableSkillSecurityScan': enableSkillSecurityScan ? 1 : 0,
        'enableMcpSecurityScan': enableMcpSecurityScan ? 1 : 0,
        'mobsfEndpoint': mobsfEndpoint,
        'enableApkSecurityScan': enableApkSecurityScan ? 1 : 0,
        'enableLocalScan': enableLocalScan ? 1 : 0,
        'localScanRulesUrl': localScanRulesUrl,
        'virusTotalApiKey': virusTotalApiKey,
        'enableVirusTotalScan': enableVirusTotalScan ? 1 : 0,
        'mobsfApiKey': mobsfApiKey,
        'biometricLockEnabled': biometricLockEnabled ? 1 : 0,
      };

  WebSearchConfig copyWith({
    bool? webSearchEnabled,
    WebSearchProvider? provider,
    String? tavilyApiKey,
    String? tavilySearchDepth,
    int? tavilyMaxResults,
    String? searxngInstanceUrl,
    String? serpApiKey,
    String? serpapiEngine,
    String? braveApiKey,
    String? googleCseApiKey,
    String? googleCseId,
    int? maxSnippetCharsPerResult,
    int? maxResultsInject,
    bool? persistentWebSearchToggle,
    bool? reactEnabled,
    int? reactMaxRounds,
    bool? reactAutoMode,
    String? githubProxyUrl,
    bool? verboseLogging,
    String? skillspectorEndpoint,
    bool? enableSkillSecurityScan,
    bool? enableMcpSecurityScan,
    String? mobsfEndpoint,
    bool? enableApkSecurityScan,
    bool? enableLocalScan,
    String? localScanRulesUrl,
    String? virusTotalApiKey,
    bool? enableVirusTotalScan,
    String? mobsfApiKey,
    bool? biometricLockEnabled,
  }) {
    return WebSearchConfig(
      webSearchEnabled: webSearchEnabled ?? this.webSearchEnabled,
      provider: provider ?? this.provider,
      tavilyApiKey: tavilyApiKey ?? this.tavilyApiKey,
      tavilySearchDepth: tavilySearchDepth ?? this.tavilySearchDepth,
      tavilyMaxResults: tavilyMaxResults ?? this.tavilyMaxResults,
      searxngInstanceUrl: searxngInstanceUrl ?? this.searxngInstanceUrl,
      serpApiKey: serpApiKey ?? this.serpApiKey,
      serpapiEngine: serpapiEngine ?? this.serpapiEngine,
      braveApiKey: braveApiKey ?? this.braveApiKey,
      googleCseApiKey: googleCseApiKey ?? this.googleCseApiKey,
      googleCseId: googleCseId ?? this.googleCseId,
      maxSnippetCharsPerResult: maxSnippetCharsPerResult ?? this.maxSnippetCharsPerResult,
      maxResultsInject: maxResultsInject ?? this.maxResultsInject,
      persistentWebSearchToggle: persistentWebSearchToggle ?? this.persistentWebSearchToggle,
      reactEnabled: reactEnabled ?? this.reactEnabled,
      reactMaxRounds: reactMaxRounds ?? this.reactMaxRounds,
      reactAutoMode: reactAutoMode ?? this.reactAutoMode,
      githubProxyUrl: githubProxyUrl ?? this.githubProxyUrl,
      verboseLogging: verboseLogging ?? this.verboseLogging,
      skillspectorEndpoint: skillspectorEndpoint ?? this.skillspectorEndpoint,
      enableSkillSecurityScan: enableSkillSecurityScan ?? this.enableSkillSecurityScan,
      enableMcpSecurityScan: enableMcpSecurityScan ?? this.enableMcpSecurityScan,
      mobsfEndpoint: mobsfEndpoint ?? this.mobsfEndpoint,
      enableApkSecurityScan: enableApkSecurityScan ?? this.enableApkSecurityScan,
      enableLocalScan: enableLocalScan ?? this.enableLocalScan,
      localScanRulesUrl: localScanRulesUrl ?? this.localScanRulesUrl,
      virusTotalApiKey: virusTotalApiKey ?? this.virusTotalApiKey,
      enableVirusTotalScan: enableVirusTotalScan ?? this.enableVirusTotalScan,
      mobsfApiKey: mobsfApiKey ?? this.mobsfApiKey,
      biometricLockEnabled: biometricLockEnabled ?? this.biometricLockEnabled,
    );
  }

  /// ReAct 思考程度 -> 中文 label
  String get reactLevelLabel =>
      reactAutoMode ? '自动 (Auto)' : estimateLevelLabel(reactMaxRounds);

  /// ReAct 思考程度 -> 英文 label（英文界面用，v1.6.7）
  String get reactLevelLabelEn =>
      reactAutoMode ? 'Auto' : estimateLevelLabelEn(reactMaxRounds);

  static String estimateLevelLabel(int rounds) {
    if (rounds <= 0) return '关 (Off)';
    if (rounds <= 2) return '低 (Low)';
    if (rounds <= 5) return '中 (Medium)';
    if (rounds <= 8) return '高 (High)';
    if (rounds <= 30) return '极高 (Max)';
    return '极限 (Xtreme)';
  }

  /// v1.6.7：纯英文档位名（英文界面用）
  static String estimateLevelLabelEn(int rounds) {
    if (rounds <= 0) return 'Off';
    if (rounds <= 2) return 'Low';
    if (rounds <= 5) return 'Medium';
    if (rounds <= 8) return 'High';
    if (rounds <= 30) return 'Max';
    return 'Xtreme';
  }

  int get effectiveMaxRounds => reactMaxRounds;

  /// 选中的 provider 实际是否可用（缺 Key/实例地址则视为不可用，回退 Bing）
  bool isProviderUsable() {
    switch (provider) {
      case WebSearchProvider.bing:
        return true; // 永远可用
      case WebSearchProvider.duckduckgo:
        return true; // v1.3.9：永远可用，无需 Key
      case WebSearchProvider.tavily:
        return tavilyApiKey.trim().isNotEmpty;
      case WebSearchProvider.searxng:
        return searxngInstanceUrl.trim().isNotEmpty;
      case WebSearchProvider.serpapi:
        return serpApiKey.trim().isNotEmpty;
      case WebSearchProvider.brave:
        return braveApiKey.trim().isNotEmpty;
      case WebSearchProvider.googlecse:
        return googleCseApiKey.trim().isNotEmpty &&
            googleCseId.trim().isNotEmpty;
    }
  }

  /// 当 provider 不可用时，推荐的 fallback（Bing 或 DuckDuckGo）
  WebSearchProvider effectiveProvider() =>
      isProviderUsable() ? provider : WebSearchProvider.bing;

  /// v1.3.9：provider 显示名（中文）
  String get providerDisplayNameZh {
    switch (provider) {
      case WebSearchProvider.bing:
        return 'Bing 直爬 (无需 Key)';
      case WebSearchProvider.duckduckgo:
        return 'DuckDuckGo 直爬 (无需 Key)';
      case WebSearchProvider.tavily:
        return 'Tavily API (需 Key)';
      case WebSearchProvider.searxng:
        return 'SearXNG 自建/公共 (需实例地址)';
      case WebSearchProvider.serpapi:
        return 'SerpAPI 聚合搜索 (需 Key, 100次/月免费)';
      case WebSearchProvider.brave:
        return 'Brave Search API (需 Key, 2000次/月免费)';
      case WebSearchProvider.googlecse:
        return 'Google CSE 自定义搜索 (需 Key + cx, 100次/天免费)';
    }
  }

  @override
  String toString() => 'WebSearchConfig(enabled=$webSearchEnabled, '
      'provider=${provider.name}, tavilyKey=${tavilyApiKey.isEmpty ? 'empty' : '***'}, '
      'serpApiKey=${serpApiKey.isEmpty ? 'empty' : '***'}, '
      'braveApiKey=${braveApiKey.isEmpty ? 'empty' : '***'})';
}
