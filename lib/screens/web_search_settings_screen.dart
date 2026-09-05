// v1.7.15：拆分自 settings_screen.dart 的 _buildWebSearchSection（原 L750-L1178）
//
// 目的：把 WebSearch 设置从主 SettingsScreen 拆到独立 sub-screen，让 Switch 切换的
// 高度突变只发生在本页面里，主 SettingsScreen 不再受高度突变影响（白窗口根因消除）。
//
// 数据流：通过 Provider<StorageService> 直接读写 web_search_configs 表，不再依赖
// 主 SettingsScreenState 的 _searchCfg / _saveSearchConfig。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../models/web_search_config.dart';
import '../services/biometric_service.dart';
import '../services/storage_service.dart';
import '../services/web_search_service.dart';

class WebSearchSettingsScreen extends StatefulWidget {
  const WebSearchSettingsScreen({super.key});

  @override
  State<WebSearchSettingsScreen> createState() =>
      _WebSearchSettingsScreenState();
}

class _WebSearchSettingsScreenState extends State<WebSearchSettingsScreen> {
  // 自有 controller（不再共享主 SettingsScreenState 的 11 个 controller）
  final _tavilyCtrl = TextEditingController();
  final _searxngCtrl = TextEditingController();
  final _ghProxyCtrl = TextEditingController();
  final _serpApiKeyCtrl = TextEditingController();
  final _serpApiEngineCtrl = TextEditingController();
  final _braveApiKeyCtrl = TextEditingController();
  final _googleCseKeyCtrl = TextEditingController();
  final _googleCseIdCtrl = TextEditingController();

  // 自有状态
  WebSearchConfig? _searchCfg;
  int _tavilyMaxResults = 5;
  bool _testingSearch = false;
  String? _testSearchMsg;
  bool? _testSearchOk;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _tavilyCtrl.dispose();
    _searxngCtrl.dispose();
    _ghProxyCtrl.dispose();
    _serpApiKeyCtrl.dispose();
    _serpApiEngineCtrl.dispose();
    _braveApiKeyCtrl.dispose();
    _googleCseKeyCtrl.dispose();
    _googleCseIdCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final storage = context.read<StorageService>();
    final cfg = await storage.getWebSearchConfig();
    if (!mounted) return;
    setState(() {
      _searchCfg = cfg;
      _tavilyMaxResults = cfg.tavilyMaxResults;
      _tavilyCtrl.text = cfg.tavilyApiKey;
      _searxngCtrl.text = cfg.searxngInstanceUrl;
      _ghProxyCtrl.text = cfg.githubProxyUrl;
      _serpApiKeyCtrl.text = cfg.serpApiKey;
      _serpApiEngineCtrl.text = cfg.serpapiEngine;
      _braveApiKeyCtrl.text = cfg.braveApiKey;
      _googleCseKeyCtrl.text = cfg.googleCseApiKey;
      _googleCseIdCtrl.text = cfg.googleCseId;
    });
  }

  Future<void> _saveConfig() async {
    final cfg = _searchCfg;
    if (cfg == null) return;
    final newCfg = cfg.copyWith(
      tavilyApiKey: _tavilyCtrl.text,
      searxngInstanceUrl: _searxngCtrl.text,
      githubProxyUrl: _ghProxyCtrl.text,
      serpApiKey: _serpApiKeyCtrl.text,
      serpapiEngine: _serpApiEngineCtrl.text,
      braveApiKey: _braveApiKeyCtrl.text,
      googleCseApiKey: _googleCseKeyCtrl.text,
      googleCseId: _googleCseIdCtrl.text,
      tavilyMaxResults: _tavilyMaxResults,
    );
    setState(() => _searchCfg = newCfg);
    await context.read<StorageService>().saveWebSearchConfig(newCfg);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final cfg = _searchCfg;
    return Scaffold(
      appBar: AppBar(title: Text(l.tr('webSearch'))),
      body: cfg == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: _buildSection(l, colorScheme, cfg),
            ),
    );
  }

  Widget _buildSection(
    AppLocalizations l,
    ColorScheme colorScheme,
    WebSearchConfig cfg,
  ) {
    final zh = l.locale.languageCode == 'zh';
    final usable = cfg.isProviderUsable();
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题 + 总开关
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.travel_explore_outlined, color: colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.tr('webSearch'),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                      cfg.webSearchEnabled
                          ? l.tr('webSearchMasterSubtitleOn')
                          : l.tr('webSearchMasterSubtitleOff'),
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              // v1.7.36：联网搜索内置为默认能力，始终开启，不再提供关闭开关
              const Switch(
                value: true,
                onChanged: null,
              ),
            ],
          ),
          if (!cfg.webSearchEnabled) const SizedBox(height: 2)
          else ...[
            const SizedBox(height: 10),
            // Provider 选择
            Text('${l.tr('webSearchProvider')}:',
                style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _providerChip(l, WebSearchProvider.bing, cfg),
                _providerChip(l, WebSearchProvider.duckduckgo, cfg),
                _providerChip(l, WebSearchProvider.tavily, cfg),
                _providerChip(l, WebSearchProvider.serpapi, cfg),
                _providerChip(l, WebSearchProvider.brave, cfg),
                _providerChip(l, WebSearchProvider.googlecse, cfg),
                _providerChip(l, WebSearchProvider.searxng, cfg),
              ],
            ),
            if (!usable) ...[
              const SizedBox(height: 6),
              Text('⚠️ ${l.tr('providerNotUsable')}',
                  style: TextStyle(fontSize: 12, color: colorScheme.tertiary)),
            ],
            // v1.5.2：当前服务商官网链接
            InkWell(
              onTap: () => _openProviderUrl(cfg.provider.officialUrl),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_new, size: 14, color: colorScheme.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        zh ? '访问官网（注册 / 查 API Key）' : 'Official site (signup / API key)',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Tavily 配置
            if (cfg.provider == WebSearchProvider.tavily) ...[
              TextField(
                controller: _tavilyCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: l.tr('tavilyApiKey'),
                  hintText: l.tr('tavilyApiKeyHint'),
                  prefixIcon: const Icon(Icons.key_outlined, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
              const SizedBox(height: 8),
              Text(
                  '${l.tr('tavilyDepth')}: ${cfg.tavilySearchDepth == 'auto' ? (zh ? '自动（AI 决定）' : 'Auto (AI decides)') : cfg.tavilySearchDepth}',
                  style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
              Wrap(
                spacing: 6,
                children: [
                  ChoiceChip(
                    label: Text(zh ? '自动（推荐）' : 'Auto (Recommended)'),
                    selected: cfg.tavilySearchDepth == 'auto',
                    onSelected: (_) {
                      setState(() =>
                          _searchCfg = cfg.copyWith(tavilySearchDepth: 'auto'));
                      _saveConfig();
                    },
                  ),
                  ChoiceChip(
                    label: Text(l.tr('tavilyDepthBasic')),
                    selected: cfg.tavilySearchDepth == 'basic',
                    onSelected: (_) {
                      setState(() =>
                          _searchCfg = cfg.copyWith(tavilySearchDepth: 'basic'));
                      _saveConfig();
                    },
                  ),
                  ChoiceChip(
                    label: Text(l.tr('tavilyDepthAdvanced')),
                    selected: cfg.tavilySearchDepth == 'advanced',
                    onSelected: (_) {
                      setState(() =>
                          _searchCfg = cfg.copyWith(tavilySearchDepth: 'advanced'));
                      _saveConfig();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('${l.tr('tavilyMaxResults')}: $_tavilyMaxResults',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
                  Expanded(
                    child: Slider(
                      value: _tavilyMaxResults.toDouble(),
                      min: 3,
                      max: 10,
                      divisions: 7,
                      label: '$_tavilyMaxResults',
                      onChanged: (v) =>
                          setState(() => _tavilyMaxResults = v.round()),
                      onChangeEnd: (_) => _saveConfig(),
                    ),
                  ),
                ],
              ),
            ],
            // SearXNG 配置
            if (cfg.provider == WebSearchProvider.searxng) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _searxngCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: l.tr('searxngInstance'),
                  hintText: l.tr('searxngInstanceHint'),
                  prefixIcon: const Icon(Icons.dns_outlined, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
            ],
            // DuckDuckGo 提示
            if (cfg.provider == WebSearchProvider.duckduckgo) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 16, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        zh
                            ? 'DuckDuckGo 直爬模式，无需 API Key，国内可访问。结果可能被反爬限制。'
                            : 'DuckDuckGo direct scraping, no API Key needed. May be rate-limited.',
                        style: TextStyle(
                            fontSize: 12, color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // SerpAPI 配置
            if (cfg.provider == WebSearchProvider.serpapi) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _serpApiKeyCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: 'SerpAPI API Key',
                  hintText: zh
                      ? '到 serpapi.com 注册免费获取（100次/月免费）'
                      : 'Sign up at serpapi.com (100 free/month)',
                  prefixIcon: const Icon(Icons.key_outlined, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _serpApiEngineCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: zh ? '搜索引擎（默认 google）' : 'Engine (default google)',
                  hintText: zh
                      ? '可选: google / bing / baidu / duckduckgo / yandex'
                      : 'Options: google / bing / baidu / duckduckgo / yandex',
                  prefixIcon: const Icon(Icons.search, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
            ],
            // Brave Search API 配置
            if (cfg.provider == WebSearchProvider.brave) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _braveApiKeyCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: 'Brave Search API Key',
                  hintText: zh
                      ? '到 brave.com/search/api 注册（2000次/月免费）'
                      : 'Sign up at brave.com/search/api (2000 free/month)',
                  prefixIcon: const Icon(Icons.key_outlined, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
            ],
            // Google CSE 配置
            if (cfg.provider == WebSearchProvider.googlecse) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _googleCseKeyCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: 'Google CSE API Key',
                  hintText: zh
                      ? 'Google Cloud Console 启用 Custom Search API'
                      : 'Enable Custom Search API in Google Cloud Console',
                  prefixIcon: const Icon(Icons.key_outlined, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _googleCseIdCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  labelText: 'Google CSE 搜索引擎 ID (cx)',
                  hintText: zh
                      ? '到 cse.google.com 创建自定义搜索引擎获取 cx'
                      : 'Create a Custom Search Engine at cse.google.com to get cx',
                  prefixIcon: const Icon(Icons.tag, size: 18),
                ),
                onChanged: (_) => _saveConfig(),
              ),
            ],
            const SizedBox(height: 8),
            // GitHub 下载加速代理
            TextField(
              controller: _ghProxyCtrl,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                labelText: zh ? 'GitHub 下载加速代理（可选）' : 'GitHub download proxy (optional)',
                hintText: zh
                    ? '留空=直连；国内建议填下面推荐代理之一'
                    : 'Empty=direct; CN users should pick one below',
                prefixIcon: const Icon(Icons.speed_outlined, size: 18),
                suffixIcon: _ghProxyCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        tooltip: zh ? '清空（改回直连）' : 'Clear (use direct)',
                        onPressed: () {
                          setState(() => _ghProxyCtrl.clear());
                          _saveConfig();
                        },
                      )
                    : null,
              ),
              onChanged: (_) => _saveConfig(),
            ),
            const SizedBox(height: 6),
            // 推荐 chip：点一下自动填入
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _buildGhProxyChip('ghproxy.com', 'https://ghproxy.com', zh, colorScheme),
                _buildGhProxyChip('ghproxy.net', 'https://ghproxy.net', zh, colorScheme),
                _buildGhProxyChip(
                    'mirror.ghproxy.com', 'https://mirror.ghproxy.com', zh, colorScheme),
                _buildGhProxyChip(
                    'kkgithub (域名替换)', 'https://kkgithub.com', zh, colorScheme),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(
                zh
                    ? '国内访问 github.com/.../releases/download/ 慢或超时，填代理后下载会走代理加速。'
                        '前缀型（如 ghproxy.com）拼在原 URL 前；'
                        '域名替换型（如 kkgithub.com）替换 github.com 域名。'
                        '代理失败会自动回退直连重试一次。'
                    : 'CN access to github.com release assets is slow; '
                        'proxy rewrites the download URL. Auto-fallback to direct on failure.',
                style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            // 测试搜索连接
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _testingSearch
                      ? null
                      : () async {
                          await _saveConfig();
                          final latest = _searchCfg;
                          if (latest != null && mounted) {
                            await _testSearchConnection(latest);
                          }
                        },
                  icon: _testingSearch
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.primary,
                          ),
                        )
                      : const Icon(Icons.network_check, size: 18),
                  label: Text(_testingSearch
                      ? (zh ? '测试中...' : 'Testing...')
                      : (zh ? '测试搜索连接' : 'Test search')),
                ),
                const SizedBox(width: 10),
                if (_testSearchMsg != null)
                  Expanded(
                    child: Text(
                      _testSearchMsg!,
                      style: TextStyle(
                        fontSize: 12,
                        color: _testSearchOk == true
                            ? colorScheme.primary
                            : _testSearchOk == false
                                ? colorScheme.error
                                : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // v1.7.15：从 settings_screen.dart L1316-L1350 搬过来的 _providerChip
  Widget _providerChip(AppLocalizations l, WebSearchProvider p, WebSearchConfig cfg) {
    String label;
    final zh = l.locale.languageCode == 'zh';
    switch (p) {
      case WebSearchProvider.bing:
        label = l.tr('webSearchProviderBing');
        break;
      case WebSearchProvider.duckduckgo:
        label = zh ? 'DuckDuckGo' : 'DuckDuckGo';
        break;
      case WebSearchProvider.tavily:
        label = l.tr('webSearchProviderTavily');
        break;
      case WebSearchProvider.serpapi:
        label = zh ? 'SerpAPI' : 'SerpAPI';
        break;
      case WebSearchProvider.brave:
        label = zh ? 'Brave' : 'Brave';
        break;
      case WebSearchProvider.googlecse:
        label = zh ? 'Google CSE' : 'Google CSE';
        break;
      case WebSearchProvider.searxng:
        label = l.tr('webSearchProviderSearxng');
        break;
    }
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
      selected: cfg.provider == p,
      onSelected: (_) {
        setState(() => _searchCfg = cfg.copyWith(provider: p));
        Future.microtask(_saveConfig);
      },
    );
  }

  // v1.7.15：从 settings_screen.dart L721-L738 搬过来的 _buildGhProxyChip
  Widget _buildGhProxyChip(
      String label, String url, bool zh, ColorScheme colorScheme) {
    final selected = _ghProxyCtrl.text.trim() == url;
    return ChoiceChip(
      showCheckmark: false,
      label: Text(label, style: const TextStyle(fontSize: 11.5)),
      selected: selected,
      selectedColor: colorScheme.primary.withValues(alpha: 0.18),
      side: selected
          ? BorderSide(color: colorScheme.primary.withValues(alpha: 0.6))
          : null,
      onSelected: (_) {
        setState(() {
          _ghProxyCtrl.text = url;
        });
        // v1.7.26 (E8)：与上方 provider / ghModels / maxResults 等 chip 保持
        // 一致，选择代理后立即落库，避免仅改文本框（重启后选择丢失）
        Future.microtask(_saveConfig);
      },
    );
  }

  // v1.7.15：从 settings_screen.dart L741-L747 搬过来的 _openProviderUrl
  Future<void> _openProviderUrl(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await BiometricService.guardActivityTransition(
        () => launchUrl(uri, mode: LaunchMode.externalApplication),
        fallbackDuration: const Duration(seconds: 120),
      );
    }
  }

  // v1.7.15：从 settings_screen.dart L436-L459 搬过来的 _testSearchConnection
  Future<void> _testSearchConnection(WebSearchConfig cfg) async {
    final zh = AppLocalizations.of(context).locale.languageCode == 'zh';
    setState(() {
      _testingSearch = true;
      _testSearchOk = null;
      _testSearchMsg = zh ? '测试中...' : 'Testing...';
    });
    final (ok, msg, ms) = await WebSearchService.testConnection(cfg);
    if (mounted) {
      setState(() {
        _testingSearch = false;
        _testSearchOk = ok;
        _testSearchMsg = msg;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: ok ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error,
          content: Text(ok ? '✅ $msg' : '❌ $msg'),
          duration: Duration(seconds: ok ? 3 : 6),
        ),
      );
    }
  }
}
