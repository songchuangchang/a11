import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../plugins/plugin_interface.dart';
import '../plugins/plugin_registry.dart';
import '../services/mcp_registry_service.dart';
import '../services/skill_registry_service.dart';
import '../services/skill_parser.dart';
import '../services/security_scan_service.dart';
import '../services/local_scan_service.dart';
import '../services/storage_service.dart';
import '../models/mcp_market_models.dart';
import '../models/skill_models.dart';

class PluginMarketScreen extends StatefulWidget {
  const PluginMarketScreen({super.key});

  @override
  State<PluginMarketScreen> createState() => _PluginMarketScreenState();
}

class _MarketPluginItem {
  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String iconEmoji;
  final List<String> tags;
  final String homepage;
  final String promptProtocol;

  const _MarketPluginItem({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.iconEmoji,
    required this.tags,
    required this.homepage,
    required this.promptProtocol,
  });
}

class _PluginMarketScreenState extends State<PluginMarketScreen> {
  static const _catalog = [
    _MarketPluginItem(
      id: 'nexus.market.translator',
      name: 'AI 实时翻译助手',
      version: '1.0.1',
      author: 'Nexus Team',
      description: '聊天中输入"翻译：XXX"或"translate: XXX"时，AI 直接输出译文，支持 20+ 语言互译。',
      iconEmoji: '🌐',
      tags: ['官方', '翻译', '多语言'],
      homepage: 'https://nexus.local/plugins/translator',
      promptProtocol: '【翻译工具】当用户请求翻译内容时，直接用 <answer> 标签输出翻译结果。',
    ),
    _MarketPluginItem(
      id: 'nexus.market.calculator',
      name: '超级计算器',
      version: '1.0.2',
      author: 'Nexus Team',
      description: '遇到数学/金融/统计/单位换算问题时，AI 直接心算给出结果。',
      iconEmoji: '🧮',
      tags: ['官方', '工具', '数学'],
      homepage: 'https://nexus.local/plugins/calc',
      promptProtocol: '【计算器工具】当用户需要计算时，用 <answer> 标签输出结果和简要过程。',
    ),
    _MarketPluginItem(
      id: 'nexus.market.weather',
      name: '实时天气查询',
      version: '1.0.3',
      author: 'Community',
      description: '当用户问天气时，AI 自动联网搜索实时天气并整理回复。',
      iconEmoji: '🌤️',
      tags: ['社区', '天气', 'LBS'],
      homepage: 'https://nexus.local/plugins/weather',
      promptProtocol: '【天气工具】当用户询问天气时，使用 <search> 查找最新天气信息。',
    ),
  ];

  final _searchCtrl = TextEditingController();
  final _registryService = McpRegistryService();
  String _query = '';
  int _tab = 0;
  McpRegistryPage? _mcpPage;
  Object? _mcpError;
  bool _loading = false;
  bool _loadingMore = false;
  
  // Skill 市场状态
  List<SkillMarketItem> _skills = [];
  Object? _skillError;
  bool _loadingSkills = false;

  // 搜索防抖与请求序列号，防止旧响应覆盖新结果
  Timer? _searchDebounce;
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _loadMcp();
    _loadSkills();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _registryService.close();
    super.dispose();
  }

  Future<void> _loadMcp({bool refresh = false}) async {
    final seq = _searchSeq;
    if (_loading || _loadingMore) return;
    setState(() {
      _loading = true;
      if (refresh) _mcpError = null;
    });
    try {
      final page = await _registryService.fetchPage(
        search: _query,
        allowCacheFallback: true,
      );
      if (!mounted || _searchSeq != seq) return;
      setState(() {
        _mcpPage = page;
        _mcpError = null;
      });
    } catch (error) {
      if (!mounted || _searchSeq != seq) return;
      setState(() => _mcpError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    final page = _mcpPage;
    if (_loadingMore || page?.nextCursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final next = await _registryService.fetchPage(
        cursor: page!.nextCursor,
        search: _query,
        allowCacheFallback: false,
      );
      if (mounted) {
        setState(() => _mcpPage = McpRegistryPage(
              servers: [...page.servers, ...next.servers],
              nextCursor: next.nextCursor,
              fromCache: page.fromCache,
              cachedAt: page.cachedAt,
            ));
      }
    } catch (error) {
      if (mounted) {
        final isZh = Localizations.localeOf(context).languageCode == 'zh';
        _showMessage(isZh ? '加载下一页失败：$error' : 'Failed to load next page: $error', error: true);
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadSkills() async {
    final seq = _searchSeq;
    setState(() {
      _loadingSkills = true;
      _skillError = null;
    });
    try {
      final skills = await SkillRegistryService.fetchSkills(search: _query);
      if (!mounted || _searchSeq != seq) return;
      setState(() {
        _skills = skills;
        _skillError = null;
      });
    } catch (error) {
      if (!mounted || _searchSeq != seq) return;
      setState(() => _skillError = error);
    } finally {
      if (mounted && _searchSeq == seq) setState(() => _loadingSkills = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final registry = context.watch<PluginRegistry>();
    return DefaultTabController(
      length: 3,
      initialIndex: _tab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isZh ? '插件市场 / Plugin Market' : 'Plugin Market / 插件市场'),
          bottom: TabBar(
            isScrollable: true,
            onTap: (value) => setState(() => _tab = value),
            tabs: [
              Tab(text: isZh ? '内置推荐' : 'Built-in'),
              Tab(text: isZh ? '公开 MCP' : 'Public MCP'),
              Tab(text: isZh ? 'Skill 市场' : 'Skill Market'),
            ],
          ),
        ),
        body: _tab == 0
            ? _buildBuiltin(context, registry, isZh)
            : _tab == 1
                ? _buildMcp(context, registry, isZh)
                : _buildSkills(context, registry, isZh),
      ),
    );
  }

  Widget _buildBuiltin(
      BuildContext context, PluginRegistry registry, bool isZh) {
    final query = _query.toLowerCase().trim();
    final shown = _catalog
        .where((item) =>
            query.isEmpty ||
            item.name.toLowerCase().contains(query) ||
            item.description.toLowerCase().contains(query) ||
            item.tags.any((tag) => tag.toLowerCase().contains(query)))
        .toList();
    return _withSearch(
      context,
      isZh,
      ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 96),
        itemCount: shown.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, index) =>
            _builtinCard(context, shown[index], registry, isZh),
      ),
    );
  }

  Widget _buildMcp(BuildContext context, PluginRegistry registry, bool isZh) {
    final page = _mcpPage;
    final content = _loading && page == null
        ? const Center(child: CircularProgressIndicator())
        : _mcpError != null && page == null
            ? _errorView(isZh)
            : RefreshIndicator(
                onRefresh: () => _loadMcp(refresh: true),
                child: page == null || page.servers.isEmpty
                    ? ListView(children: [
                        SizedBox(height: 220),
                        Center(
                            child: Text(isZh
                                ? '没有可用的公开 MCP 服务'
                                : 'No compatible public MCP servers'))
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 96),
                        itemCount: page.servers.length +
                            (page.nextCursor == null ? 0 : 1),
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, index) {
                          if (index == page.servers.length) {
                            return Center(
                                child: _loadingMore
                                    ? const CircularProgressIndicator()
                                    : OutlinedButton.icon(
                                        onPressed: _loadMore,
                                        icon: const Icon(Icons.expand_more),
                                        label: Text(isZh ? '加载下一页' : 'Load More')));
                          }
                          return _mcpCard(
                              context, page.servers[index], registry, isZh);
                        },
                      ),
              );
    return _withSearch(
        context,
        isZh,
        Column(children: [
          if (page?.fromCache == true) _cacheBanner(page!, isZh),
          Expanded(child: content)
        ]));
  }

  Widget _buildSkills(BuildContext context, PluginRegistry registry, bool isZh) {
    final content = _loadingSkills
        ? const Center(child: CircularProgressIndicator())
        : _skillError != null
            ? _skillErrorView(isZh)
            : RefreshIndicator(
                onRefresh: _loadSkills,
                child: _skills.isEmpty
                    ? ListView(children: [
                        SizedBox(height: 220),
                        Center(
                            child: Text(isZh
                                ? '没有可用的 Skill'
                                : 'No skills available'))
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 96),
                        itemCount: _skills.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, index) =>
                            _skillCard(context, _skills[index], registry, isZh),
                      ),
              );
    return _withSearch(
        context,
        isZh,
        Expanded(child: content));
  }

  Widget _withSearch(BuildContext context, bool isZh, Widget child) =>
      Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText:
                    isZh ? '搜索名称 / 标签 / 描述' : 'Search name / tag / description',
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(vertical: 0)),
            onChanged: (value) {
              setState(() => _query = value);
              _searchDebounce?.cancel();
              _searchDebounce = Timer(const Duration(milliseconds: 300), () {
                _searchSeq++;
                if (_tab == 1) _loadMcp();
                if (_tab == 2) _loadSkills();
              });
            },
          ),
        ),
        if (child is Expanded) child else Expanded(child: child),
      ]);

  Widget _cacheBanner(McpRegistryPage page, bool isZh) => Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.tertiaryContainer,
      padding: const EdgeInsets.all(8),
      child: Text(
          isZh
              ? '当前显示缓存（${page.cachedAt?.toLocal()}），下拉可刷新'
              : 'Showing cached results (${page.cachedAt?.toLocal()}); pull to refresh',
          style: const TextStyle(fontSize: 12)));

  Widget _errorView(bool isZh) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off, size: 48),
        const SizedBox(height: 8),
        Text(isZh ? '公开 MCP 加载失败' : 'Public MCP loading failed'),
        const SizedBox(height: 8),
        FilledButton.icon(
            onPressed: _loadMcp,
            icon: const Icon(Icons.refresh),
            label: Text(isZh ? '重试' : 'Retry'))
      ]));

  Widget _skillErrorView(bool isZh) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off, size: 48),
        const SizedBox(height: 8),
        Text(isZh ? 'Skill 市场加载失败' : 'Skill market loading failed'),
        const SizedBox(height: 8),
        FilledButton.icon(
            onPressed: _loadSkills,
            icon: const Icon(Icons.refresh),
            label: Text(isZh ? '重试' : 'Retry'))
      ]));

  Widget _builtinCard(BuildContext context, _MarketPluginItem item,
      PluginRegistry registry, bool isZh) {
    final installed =
        registry.plugins.any((plugin) => plugin.metadata.id == item.id);
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Text(item.iconEmoji,
                      style: const TextStyle(fontSize: 28)),
                  title: Text(item.name),
                  subtitle: Text('v${item.version} · ${item.author}')),
              Text(item.description,
                  maxLines: 3, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              Wrap(
                  spacing: 4,
                  children: item.tags
                      .map((tag) => Chip(
                          label: Text(tag),
                          visualDensity: VisualDensity.compact))
                      .toList()),
              Row(children: [
                OutlinedButton.icon(
                    onPressed: () => _showBuiltinDetails(context, item, isZh),
                    icon: const Icon(Icons.info_outline),
                    label: Text(isZh ? '详情' : 'Details')),
                const Spacer(),
                FilledButton.icon(
                    onPressed: installed
                        ? null
                        : () => _installBuiltin(item, registry, isZh),
                    icon: Icon(installed ? Icons.check : Icons.install_mobile),
                    label: Text(installed ? '已安装' : '安装'))
              ]),
            ])));
  }

  Widget _mcpCard(BuildContext context, McpRegistryServer server,
      PluginRegistry registry, bool isZh) {
    final installed =
        registry.plugins.any((plugin) => plugin.metadata.id == server.name);
    return Card(
        child: ListTile(
            contentPadding: const EdgeInsets.all(12),
            leading: const CircleAvatar(child: Icon(Icons.hub_outlined)),
            title: Text(server.title),
            subtitle: Text(
                '${server.name}\nv${server.version} · ${server.transportType} · ${server.endpoint.host}\n${server.description}',
                maxLines: 4,
                overflow: TextOverflow.ellipsis),
            isThreeLine: true,
            trailing: FilledButton(
                onPressed: installed
                    ? null
                    : () => _installMcp(server, registry, isZh),
                child: Text(installed ? '已安装' : '安装')),
            onTap: () => _showMcpDetails(context, server, registry, isZh)));
  }

  Widget _skillCard(BuildContext context, SkillMarketItem skill,
      PluginRegistry registry, bool isZh) {
    // v1.7.9 (M12 修复)：与安装流程用同一 ID 算法（ParsedSkill.pluginIdFor）
    // 之前卡片本地拼 ID、安装用 SKILL.md 解析的 name 拼 → 不一致时装完仍显示可安装
    final pluginId = ParsedSkill.pluginIdFor(skill.name);
    final installed =
        registry.plugins.any((plugin) => plugin.metadata.id == pluginId);
    return Card(
        child: ListTile(
            contentPadding: const EdgeInsets.all(12),
            leading: const CircleAvatar(child: Icon(Icons.auto_awesome)),
            title: Text(skill.name),
            subtitle: Text(
                '${skill.description}\n\n${skill.author ?? "Unknown"}${skill.version != null ? " · v${skill.version}" : ""}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
            isThreeLine: true,
            trailing: FilledButton(
                onPressed: installed
                    ? null
                    : () => _installSkill(skill, registry, isZh),
                child: Text(installed ? '已安装' : '安装')),
            onTap: () => _showSkillDetails(context, skill, registry, isZh)));
  }

  void _showBuiltinDetails(
          BuildContext context, _MarketPluginItem item, bool isZh) =>
      showDialog(
          context: context,
          builder: (_) => AlertDialog(
                  title: Text('${item.iconEmoji} ${item.name}'),
                  content: Text(
                      isZh
                          ? '${item.description}\n\n${item.promptProtocol}\n\n版本：${item.version}\n作者：${item.author}'
                          : '${item.description}\n\n${item.promptProtocol}\n\nVersion: ${item.version}\nAuthor: ${item.author}'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(isZh ? '关闭' : 'Close'))
                  ]));

  void _showMcpDetails(BuildContext context, McpRegistryServer server,
          PluginRegistry registry, bool isZh) {
    // v1.7.2 安全改进：增强安装警告，显示源码仓库和维护者信息
    final hasHomepage = server.homepage != null;
    final homepageInfo = hasHomepage
        ? (isZh ? '源码仓库：${server.homepage}\n' : 'Source: ${server.homepage}\n')
        : (isZh ? '源码仓库：未知（无法审查代码）\n' : 'Source: Unknown (cannot audit code)\n');

    showDialog(
          context: context,
          builder: (_) => AlertDialog(
                  title: Text(server.title),
                  content: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              isZh
                                  ? 'Registry 状态：${server.status}\n版本：${server.version}\n传输：${server.transportType}\nEndpoint：${server.endpoint.host}\n\n$homepageInfo\n${server.description}\n\n⚠️ 安全提示：\n• 仅支持公开 HTTPS 远程服务\n• 安装时会连接服务并读取工具清单\n• 不会下载或执行第三方代码\n• 请确认你信任此服务及其返回的数据'
                                  : 'Registry Status: ${server.status}\nVersion: ${server.version}\nTransport: ${server.transportType}\nEndpoint: ${server.endpoint.host}\n\n$homepageInfo\n${server.description}\n\n⚠️ Security Notice:\n• Only public HTTPS remote services are supported\n• Installation connects to the service and reads the tool list\n• No third-party code is downloaded or executed\n• Only continue if you trust this service and its data'),
                        ],
                      )),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(isZh ? '关闭' : 'Close')),
                    FilledButton(
                        onPressed: registry.plugins
                                .any((p) => p.metadata.id == server.name)
                            ? null
                            : () {
                                Navigator.pop(context);
                                _installMcp(server, registry, isZh);
                              },
                        child: Text(isZh ? '安装' : 'Install'))
                  ]));
  }

  void _showSkillDetails(BuildContext context, SkillMarketItem skill,
          PluginRegistry registry, bool isZh) {
    final hasHomepage = skill.homepage != null && skill.homepage!.isNotEmpty;
    final homepageInfo = hasHomepage
        ? (isZh ? '源码仓库：${skill.homepage}\n' : 'Source: ${skill.homepage}\n')
        : (isZh ? '源码仓库：未知（无法审查代码）\n' : 'Source: Unknown (cannot audit code)\n');

    showDialog(
          context: context,
          builder: (_) => AlertDialog(
                  title: Text(skill.name),
                  content: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              isZh
                                  ? '版本：${skill.version ?? "Unknown"}\n作者：${skill.author ?? "Unknown"}\n\n$homepageInfo\n${skill.description}\n\n⚠️ 安全提示：\n• Skill 是 Markdown 格式的指令文件\n• 安装后会作为 AI 的提示词协议\n• 不会下载或执行第三方代码\n• 请确认你信任此 Skill 的内容'
                                  : 'Version: ${skill.version ?? "Unknown"}\nAuthor: ${skill.author ?? "Unknown"}\n\n$homepageInfo\n${skill.description}\n\n⚠️ Security Notice:\n• Skills are Markdown-format instruction files\n• After installation, they serve as AI prompt protocols\n• No third-party code is downloaded or executed\n• Only continue if you trust this skill\'s content'),
                        ],
                      )),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(isZh ? '关闭' : 'Close')),
                    FilledButton(
                        onPressed: () {
                          Navigator.pop(context);
                          _installSkill(skill, registry, isZh);
                        },
                        child: Text(isZh ? '安装' : 'Install'))
                  ]));
  }

  Future<void> _installMcp(
      McpRegistryServer server, PluginRegistry registry, bool isZh) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
                title: Text(isZh ? '确认连接并安装？' : 'Connect and install?'),
                content: Text(isZh
                    ? '将连接 ${server.endpoint.host}，发现工具并保存远程配置。请确认你信任此服务及其返回的数据。'
                    : 'Nexus will connect to ${server.endpoint.host}, discover tools, and save the remote configuration. Only continue if you trust this service.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(isZh ? '取消' : 'Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(isZh ? '确认' : 'Confirm'))
                ]));
    if (confirmed != true || !mounted) return;
    
    // v1.7.5: MCP 安全审查；v1.7.10: 本地规则扫描优先（零配置默认生效），
    // SkillSpector 端点配置了才作为远程深度扫描
    try {
      final storage = context.read<StorageService>();
      final cfg = await storage.getWebSearchConfig();
      if (!mounted) return;

      // v1.7.10：本地扫描（enableLocalScan 默认开，无需任何端点/Key）
      if (cfg.enableLocalScan) {
        final toolsJsonLocal = jsonEncode({
          'server_name': server.name,
          'endpoint': server.endpoint.toString(),
          'transport': server.transportType,
          'description': server.description,
        });
        final localResult = await LocalScanService.scanMcp(
          toolsJson: toolsJsonLocal,
          serverName: server.name,
          endpoint: server.endpoint.toString(),
          rulesUrl: cfg.localScanRulesUrl,
        );
        if (!mounted) return;
        if (localResult.success && !localResult.safeToInstall) {
          final scanConfirmed = await _showSecurityScanDialog(
              localResult, server.name, isZh, isLocal: true);
          if (!scanConfirmed) {
            _showMessage(isZh ? '已取消安装' : 'Installation cancelled', error: true);
            return;
          }
        }
      }

      // SkillSpector 远程深度扫描（可选，配置了端点+开关才跑）
      if (cfg.enableMcpSecurityScan && cfg.skillspectorEndpoint.isNotEmpty) {
        _showMessage(isZh ? '正在进行深度安全审查...' : 'Running deep security scan...');

        // 构建工具定义 JSON（从 server 信息中提取）
        final toolsJson = jsonEncode({
          'server_name': server.name,
          'endpoint': server.endpoint.toString(),
          'transport': server.transportType,
          'description': server.description,
        });

        final scanResult = await SecurityScanService.scanMcp(
          skillspectorEndpoint: cfg.skillspectorEndpoint,
          toolsJson: toolsJson,
          serverName: server.name,
          endpoint: server.endpoint.toString(),
        );

        if (scanResult.success && !scanResult.safeToInstall) {
          final scanConfirmed = await _showSecurityScanDialog(scanResult, server.name, isZh);
          if (!scanConfirmed) {
            _showMessage(isZh ? '已取消安装' : 'Installation cancelled', error: true);
            return;
          }
        }
      }
    } catch (e) {
      // 审查失败不阻止安装，只记录日志
      debugPrint('MCP security scan failed: $e');
    }
    
    _showMessage(isZh ? '正在连接并发现工具…' : 'Connecting and discovering tools…');
    try {
      await registry.installRemoteMcp(server);
      _showMessage(isZh ? '安装成功，已启用。' : 'Installed and enabled.');
    } catch (error) {
      _showMessage(isZh ? '安装失败：$error' : 'Installation failed: $error', error: true);
    }
  }

  Future<void> _installBuiltin(
      _MarketPluginItem item, PluginRegistry registry, bool isZh) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
                title: Text(isZh ? '确认安装 ${item.name}？' : 'Install ${item.name}?'),
                content: Text(item.promptProtocol),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(isZh ? '取消' : 'Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(isZh ? '安装' : 'Install'))
                ]));
    if (confirmed != true) return;
    final metadata = PluginMetadata(
        id: item.id,
        name: item.name,
        version: item.version,
        author: item.author,
        description: item.description,
        homepage: item.homepage,
        promptProtocol: item.promptProtocol,
        tags: item.tags);
    await registry.installDeclarative(metadata);
    if (mounted) _showMessage(isZh ? '安装成功，已启用。' : 'Installed and enabled.');
  }

  Future<void> _installSkill(
      SkillMarketItem skill, PluginRegistry registry, bool isZh) async {
    try {
      _showMessage(isZh ? '正在下载 Skill...' : 'Downloading skill...');

      // v1.7.9 (M10 修复)：下载前缓存 storage（await 后 context.read 会因页面退出崩溃）
      final storage = context.read<StorageService>();

      // 下载 SKILL.md 内容
      final content = await SkillRegistryService.downloadSkillContent(skill.downloadUrl);
      if (!mounted) return;

      // 解析 SKILL.md
      final parsedSkill = SkillParser.parse(content);

      // 生成 plugin id
      final pluginId = parsedSkill.pluginId;

      // 检查是否已安装
      if (registry.plugins.any((p) => p.metadata.id == pluginId)) {
        _showMessage(isZh ? '此 Skill 已安装' : 'This skill is already installed', error: true);
        return;
      }

      // v1.7.10：本地规则扫描（零配置默认生效，纯 Dart 离线）
      final cfg = await storage.getWebSearchConfig();
      if (cfg.enableLocalScan) {
        final localResult = await LocalScanService.scanSkill(
          skillContent: content,
          skillName: skill.name,
          rulesUrl: cfg.localScanRulesUrl,
        );
        if (!mounted) return;

        if (localResult.success && !localResult.safeToInstall) {
          final confirmedLocal = await _showSecurityScanDialog(
              localResult, skill.name, isZh, isLocal: true);
          if (!confirmedLocal) {
            _showMessage(isZh ? '已取消安装' : 'Installation cancelled', error: true);
            return;
          }
        }
      }

      // v1.7.5: SkillSpector 远程深度扫描（可选，配置了端点+开关才跑）
      if (cfg.enableSkillSecurityScan && cfg.skillspectorEndpoint.isNotEmpty) {
        _showMessage(isZh ? '正在进行安全审查...' : 'Running security scan...');
        final scanResult = await SecurityScanService.scanSkill(
          skillspectorEndpoint: cfg.skillspectorEndpoint,
          skillContent: content,
          skillName: skill.name,
        );
        if (!mounted) return;

        if (scanResult.success && !scanResult.safeToInstall) {
          final confirmed = await _showSecurityScanDialog(scanResult, skill.name, isZh);
          if (!confirmed) {
            _showMessage(isZh ? '已取消安装' : 'Installation cancelled', error: true);
            return;
          }
        }
      }
      
      // 创建 PluginMetadata
      final metadata = PluginMetadata(
        id: pluginId,
        name: parsedSkill.metadata.name,
        version: parsedSkill.metadata.version ?? '1.0.0',
        author: parsedSkill.metadata.author ?? 'Unknown',
        description: parsedSkill.metadata.description,
        homepage: parsedSkill.metadata.homepage ?? skill.homepage ?? '',
        promptProtocol: parsedSkill.instruction,
        tags: parsedSkill.metadata.tags,
        kind: PluginKind.declarative,
        triggerType: 'answer', // Skill 默认使用 answer 触发
        // v1.7.8：保存 SKILL.md 直链，供插件更新检查使用（homepage 可能是市场页面）
        extra: {'downloadUrl': skill.downloadUrl},
      );
      
      // 安装
      await registry.installDeclarative(metadata);
      
      if (mounted) {
        _showMessage(isZh ? '安装成功，已启用。' : 'Installed and enabled.');
      }
    } catch (error) {
      _showMessage(isZh ? '安装失败：$error' : 'Installation failed: $error', error: true);
    }
  }
  
  /// v1.7.5: 显示安全审查结果对话框
  Future<bool> _showSecurityScanDialog(
    SecurityScanResult result,
    String pluginName,
    bool isZh, {
    bool isLocal = false,
  }) async {
    // v1.7.9 (M10 修复)：本方法在多个 await 之后被调用，context 可能已失效
    if (!mounted) return false;
    final colorScheme = Theme.of(context).colorScheme;
    final riskColor = result.riskScore <= 20
        ? Colors.green
        : result.riskScore <= 50
            ? Colors.orange
            : result.riskScore <= 80
                ? Colors.red
                : Colors.red.shade900;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(
          children: [
            Icon(
              result.safeToInstall ? Icons.check_circle : Icons.warning_amber_rounded,
              color: result.safeToInstall ? Colors.green : riskColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isLocal
                    ? (isZh ? '本地安全扫描结果' : 'Local Scan Result')
                    : (isZh ? '安全审查结果' : 'Security Scan Result'),
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isZh ? '插件：$pluginName' : 'Plugin: $pluginName',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    isZh ? '风险评分：' : 'Risk Score: ',
                    style: const TextStyle(fontSize: 14),
                  ),
                  Text(
                    '${result.riskScore}/100',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: riskColor,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: riskColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      isZh ? result.riskLabelZh : result.riskLabelEn,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: riskColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (result.findings.isNotEmpty) ...[
                Text(
                  isZh ? '发现的问题：' : 'Findings:',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 8),
                ...result.findings.map((finding) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        finding.severity == SecuritySeverity.critical ||
                                finding.severity == SecuritySeverity.high
                            ? Icons.error
                            : finding.severity == SecuritySeverity.medium
                                ? Icons.warning
                                : Icons.info,
                        size: 16,
                        color: finding.severity == SecuritySeverity.critical
                            ? Colors.red.shade900
                            : finding.severity == SecuritySeverity.high
                                ? Colors.red
                                : finding.severity == SecuritySeverity.medium
                                    ? Colors.orange
                                    : Colors.blue,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              finding.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            if (finding.description.isNotEmpty)
                              Text(
                                finding.description,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                )),
              ],
              const SizedBox(height: 12),
              if (isLocal)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    isZh
                        ? '⚠️ 本地规则扫描仅供参考，不能保证查出所有问题。请结合插件来源和声誉综合判断。'
                        : '⚠️ Local rule-based scan is for reference only and cannot guarantee detection of all issues. Judge with the plugin source and reputation.',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (!result.safeToInstall)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning, color: Colors.red.shade700, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isZh
                              ? '此插件存在安全风险，建议谨慎安装'
                              : 'This plugin has security risks, install with caution',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.red.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: result.safeToInstall ? Colors.green : Colors.orange,
            ),
            child: Text(isZh ? '继续安装' : 'Continue'),
          ),
        ],
      ),
    );
    
    return confirmed ?? false;
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.redAccent : null));
  }
}
