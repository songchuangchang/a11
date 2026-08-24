import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants.dart' show kAppVersionConst;
import '../l10n/app_localizations.dart';
import '../plugins/plugin_registry.dart';
import '../providers/locale_provider.dart';
import '../services/backup_service.dart';
import '../services/logger_service.dart';
import '../services/self_check_service.dart';
import '../services/storage_service.dart';
import '../services/web_search_service.dart';
import '../services/security_scan_service.dart';
import '../models/web_search_config.dart';
import 'api_config_screen.dart';
import 'log_viewer_screen.dart';
import 'regression_test_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _exporting = false;
  bool _selfChecking = false;
  bool _aiBehaviorTestEnabled = false;

  Future<void> _exportLogs() async {
    final l = AppLocalizations.of(context);
    final logger = context.read<LoggerService>();
    setState(() => _exporting = true);
    try {
      final path = await logger.exportToSingleFile();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${l.tr('logExportedTo')}:\n$path'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: l.tr('open'),
              onPressed: () async {
                try {
                  await OpenFilex.open(path);
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${l.tr('openFailed')}: $e')),
                    );
                  }
                }
              },
            ),
          ),
        );
      }
    } catch (e, st) {
      logger.error('Export logs failed', error: e, stack: st, tag: 'LoggerUI');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l.tr('exportFailed')}: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _clearLogs() async {
    final l = AppLocalizations.of(context);
    final logger = context.read<LoggerService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.tr('clearLogs')),
        content: Text(l.tr('clearLogsConfirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.tr('clear'))),
        ],
      ),
    );
    if (confirmed != true) return;
    await logger.clearAll();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.tr('logsCleared'))),
      );
    }
  }

  /// v1.4.2 新增：一键自检，把「手动测试 checklist」可自动化部分内置化
  Future<void> _runSelfCheck() async {
    if (_selfChecking) return;
    setState(() => _selfChecking = true);
    // v1.4.6：对话测试已合并到「AI 行为测试」开关的 RegressionTestScreen，
    // 自检不再跑消耗 token 的真实对话测试，只做离线 + 网络连通检查
    final zh = AppLocalizations.of(context).locale.languageCode == 'zh';
    final results = await SelfCheckService.runAll(
        runDialogTest: false,
        isZh: zh,
        pluginRegistry: context.read<PluginRegistry>());
    if (!mounted) return;
    setState(() => _selfChecking = false);

    final manualItems = SelfCheckService.manualCheckItems(isZh: zh);
    final passCount = results.where((r) => r.pass).length;
    final allPass = passCount == results.length;
    final colorScheme = Theme.of(context).colorScheme;
    final manualResults = List<bool?>.filled(manualItems.length, null);

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final doneCount = manualResults.where((r) => r != null).length;
          final okCount = manualResults.where((r) => r == true).length;
          return AlertDialog(
            title: Row(children: [
              Icon(
                allPass ? Icons.check_circle : Icons.warning_amber_rounded,
                color: allPass ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              Text(zh
                  ? '自检结果：$passCount/${results.length} 通过'
                  : 'Self-check: $passCount/${results.length} passed'),
            ]),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: [
                  // ===== 自动检查结果 =====
                  for (final r in results)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            r.pass ? Icons.check_circle : Icons.cancel,
                            color: r.pass ? Colors.green : Colors.red,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(r.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                if (r.detail.isNotEmpty)
                                  Text(r.detail,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color:
                                              colorScheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Divider(),
                  // ===== 人工确认项 =====
                  Text(
                      zh
                          ? '人工确认（$doneCount/${manualItems.length} 已确认，$okCount 正常）'
                          : 'Manual checks ($doneCount/${manualItems.length} done, $okCount OK)',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  for (int i = 0; i < manualItems.length; i++)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer
                            .withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(manualItems[i].title,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                              ),
                              if (manualResults[i] != null)
                                Icon(
                                  manualResults[i] == true
                                      ? Icons.check_circle
                                      : Icons.cancel,
                                  color: manualResults[i] == true
                                      ? Colors.green
                                      : Colors.red,
                                  size: 18,
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(manualItems[i].description,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant)),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              OutlinedButton(
                                onPressed: () => setDialogState(
                                    () => manualResults[i] = true),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.green,
                                  minimumSize: const Size(0, 32),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                ),
                                child: Text(zh ? '正常' : 'OK',
                                    style: const TextStyle(fontSize: 12)),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: () => setDialogState(
                                    () => manualResults[i] = false),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.red,
                                  minimumSize: const Size(0, 32),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                ),
                                child: Text(zh ? '异常' : 'Issue',
                                    style: const TextStyle(fontSize: 12)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(zh ? '关闭' : 'Close')),
            ],
          );
        },
      ),
    );
  }

  /// v1.3.4：切换详细日志模式
  /// 开启时弹隐私警告对话框（聊天内容/搜索结果会被记录），确认后才真正开启
  /// 关闭时直接关。API Key 明文永远不记（由调用方 mask）
  Future<void> _toggleVerboseLogging(bool value) async {
    final l = AppLocalizations.of(context);
    final logger = context.read<LoggerService>();
    if (!value) {
      // 关闭：直接关，无需警告
      final storage = context.read<StorageService>();
      final newCfg = _searchCfg!.copyWith(verboseLogging: false);
      await storage.saveWebSearchConfig(newCfg);
      if (mounted) setState(() => _searchCfg = newCfg);
      logger.verboseEnabled = false;
      return;
    }
    // 开启：先弹隐私警告
    final zh = l.locale.languageCode == 'zh';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700),
          const SizedBox(width: 8),
          Text(zh ? '开启详细日志？' : 'Enable verbose logging?'),
        ]),
        content: Text(zh
            ? '开启后将记录以下敏感信息到日志文件，仅用于调试找问题：\n\n'
                '• 聊天消息全文\n'
                '• AI 思考步骤详情\n'
                '• 联网搜索结果全文\n'
                '• 下载 URL 详情\n\n'
                '⚠️ API Key 明文不会被记录。\n\n'
                '请勿在公共场合导出/分享日志，可能包含你的对话内容。\n确认开启？'
            : 'The following sensitive info will be written to log files, for debugging only:\n\n'
                '• Full chat messages\n'
                '• AI reasoning step details\n'
                '• Full web search results\n'
                '• Download URL details\n\n'
                '⚠️ API keys are never logged in plain text.\n\n'
                'Do not export/share logs in public - they may contain your conversations.\nConfirm?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.tr('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(zh ? '确认开启' : 'Enable')),
        ],
      ),
    );
    if (confirmed != true) return;
    final storage = context.read<StorageService>();
    final newCfg = _searchCfg!.copyWith(verboseLogging: true);
    await storage.saveWebSearchConfig(newCfg);
    if (mounted) setState(() => _searchCfg = newCfg);
    logger.verboseEnabled = true;
  }

  // v1.6.9 build42 修复 F2：从全局常量引用（pubspec.yaml + constants.dart 单点更新后自动同步），不再写死避免遗漏
  static String get _appVersionFull => kAppVersionConst;

  WebSearchConfig? _searchCfg;
  final TextEditingController _tavilyCtrl = TextEditingController();
  final TextEditingController _searxngCtrl = TextEditingController();
  final TextEditingController _ghProxyCtrl = TextEditingController();
  // v1.3.9 新增搜索服务商 controllers
  final TextEditingController _serpApiKeyCtrl = TextEditingController();
  final TextEditingController _serpApiEngineCtrl = TextEditingController();
  final TextEditingController _braveApiKeyCtrl = TextEditingController();
  final TextEditingController _googleCseKeyCtrl = TextEditingController();
  final TextEditingController _googleCseIdCtrl = TextEditingController();
  // v1.7.5 新增安全审查 controllers
  final TextEditingController _skillspectorEndpointCtrl = TextEditingController();
  final TextEditingController _mobsfEndpointCtrl = TextEditingController();
  // v1.7.10 本地扫描规则源
  final TextEditingController _localScanRulesUrlCtrl = TextEditingController();
  // v1.7.11 VirusTotal + MobSF API Key
  final TextEditingController _virusTotalApiKeyCtrl = TextEditingController();
  final TextEditingController _mobsfApiKeyCtrl = TextEditingController();
  int _tavilyMaxResults = 5;
  bool _testingSearch = false;
  String? _testSearchMsg;
  bool? _testSearchOk;
  bool _testingSkillSpector = false;
  bool _testingMobSF = false;
  bool _testingVirusTotal = false;

  @override
  void initState() {
    super.initState();
    _loadSearchConfig();
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
    _skillspectorEndpointCtrl.dispose();
    _mobsfEndpointCtrl.dispose();
    _localScanRulesUrlCtrl.dispose();
    _virusTotalApiKeyCtrl.dispose();
    _mobsfApiKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSearchConfig() async {
    final storage = context.read<StorageService>();
    final cfg = await storage.getWebSearchConfig();
    if (mounted) {
      setState(() {
        _searchCfg = cfg;
        _tavilyCtrl.text = cfg.tavilyApiKey;
        _searxngCtrl.text = cfg.searxngInstanceUrl;
        _ghProxyCtrl.text = cfg.githubProxyUrl;
        _serpApiKeyCtrl.text = cfg.serpApiKey;
        _serpApiEngineCtrl.text = cfg.serpapiEngine;
        _braveApiKeyCtrl.text = cfg.braveApiKey;
        _googleCseKeyCtrl.text = cfg.googleCseApiKey;
        _googleCseIdCtrl.text = cfg.googleCseId;
        _skillspectorEndpointCtrl.text = cfg.skillspectorEndpoint;
        _mobsfEndpointCtrl.text = cfg.mobsfEndpoint;
        _localScanRulesUrlCtrl.text = cfg.localScanRulesUrl;
        _virusTotalApiKeyCtrl.text = cfg.virusTotalApiKey;
        _mobsfApiKeyCtrl.text = cfg.mobsfApiKey;
        _tavilyMaxResults = cfg.tavilyMaxResults;
      });
    }
  }

  Future<void> _saveSearchConfig() async {
    if (_searchCfg == null) return;
    final storage = context.read<StorageService>();
    final newCfg = _searchCfg!.copyWith(
      tavilyApiKey: _tavilyCtrl.text.trim(),
      searxngInstanceUrl: _searxngCtrl.text.trim(),
      tavilyMaxResults: _tavilyMaxResults,
      githubProxyUrl: _ghProxyCtrl.text.trim(),
      serpApiKey: _serpApiKeyCtrl.text.trim(),
      serpapiEngine: _serpApiEngineCtrl.text.trim().isEmpty
          ? 'google'
          : _serpApiEngineCtrl.text.trim(),
      braveApiKey: _braveApiKeyCtrl.text.trim(),
      googleCseApiKey: _googleCseKeyCtrl.text.trim(),
      googleCseId: _googleCseIdCtrl.text.trim(),
      skillspectorEndpoint: _skillspectorEndpointCtrl.text.trim(),
      mobsfEndpoint: _mobsfEndpointCtrl.text.trim(),
      localScanRulesUrl: _localScanRulesUrlCtrl.text.trim(),
      virusTotalApiKey: _virusTotalApiKeyCtrl.text.trim(),
      enableVirusTotalScan: _searchCfg!.enableVirusTotalScan,
      mobsfApiKey: _mobsfApiKeyCtrl.text.trim(),
    );
    await storage.saveWebSearchConfig(newCfg);
    final l = AppLocalizations.of(context);
    if (mounted) {
      setState(() => _searchCfg = newCfg);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(newCfg.tavilyApiKey.isNotEmpty &&
                         newCfg.provider == WebSearchProvider.tavily
              ? l.tr('tavilyKeyMasked')
              : l.tr('webSearchSaved')),
        ),
      );
    }
  }

  Future<void> _testSearchConnection(WebSearchConfig cfg) async {
    final zh = AppLocalizations.of(context).locale.languageCode == 'zh';
    setState(() {
      _testingSearch = true;
      _testSearchOk = null;
      _testSearchMsg = zh ? '测试中...' : 'Testing...';
    });
    final (ok, msg, _ms) = await WebSearchService.testConnection(cfg);
    if (mounted) {
      setState(() {
        _testingSearch = false;
        _testSearchOk = ok;
        _testSearchMsg = msg;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700,
          content: Text(ok ? '✅ $msg' : '❌ $msg'),
          duration: Duration(seconds: ok ? 3 : 6),
        ),
      );
    }
  }

  /// v1.3.4：GitHub 代理推荐 chip（点一下自动填入输入框）
  // ==========================================================================
  // v1.3.8：导出 / 导入 Section
  // ==========================================================================
  Widget _buildBackupSection(AppLocalizations l, ColorScheme colorScheme) {
    final zh = l.locale.languageCode == 'zh';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Row(
              children: [
                Icon(Icons.backup_outlined, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  zh ? '数据备份' : 'Data Backup',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.file_upload_outlined),
            title: Text(zh ? '导出数据' : 'Export Data'),
            subtitle: Text(
              zh
                  ? '导出所有对话、API 配置、搜索设置为 JSON 文件'
                  : 'Export all conversations, API configs and settings to a JSON file',
              style: const TextStyle(fontSize: 12),
            ),
            onTap: _onExportTap,
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.file_download_outlined),
            title: Text(zh ? '导入数据' : 'Import Data'),
            subtitle: Text(
              zh
                  ? '从 JSON 文件导入数据（合并到现有或覆盖）'
                  : 'Import from JSON file (merge or overwrite)',
              style: const TextStyle(fontSize: 12),
            ),
            onTap: _onImportTap,
          ),
        ],
      ),
    );
  }

  /// 导出：弹窗问是否包含 API key → 选保存目录 → 写文件 → SnackBar 显示路径
  Future<void> _onExportTap() async {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';

    bool includeKeys = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(zh ? '导出选项' : 'Export Options'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(zh ? '将导出：' : 'Will export:',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              Text(zh
                  ? '• 所有 API 配置（endpoint / 模型 / 参数）\n'
                    '• 所有对话和消息（含附件元数据）\n'
                    '• 联网搜索 / ReAct 设置'
                  : '• All API configs (endpoint / model / params)\n'
                    '• All conversations & messages (with attachment metadata)\n'
                    '• Web search / ReAct settings'),
              const SizedBox(height: 12),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: includeKeys,
                onChanged: (v) => setSt(() => includeKeys = v ?? false),
                title: Text(zh ? '包含 API Key 等敏感信息' : 'Include API keys'),
                subtitle: Text(
                  zh
                      ? '⚠️ 勾选后 apiKey / tavilyApiKey 会以明文写入 JSON 文件，'
                        '请妥善保管导出文件'
                      : '⚠️ apiKey / tavilyApiKey will be written in plaintext. '
                        'Keep the exported file safe',
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
                activeColor: cs.primary,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.tr('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(zh ? '导出' : 'Export'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    if (mounted) setState(() => _exporting = true);

    try {
      final storage = context.read<StorageService>();
      final backup = BackupService(storage);
      final json = await backup.exportAll(includeKeys: includeKeys);

      // 选保存目录（file_picker 的 pickDirectory 在 Android 上是 SAF，返回的是 tree URI，
      // 不便写文件；改用 getDownloadsDirectory 自动落盘 + 弹路径给用户）
      final outPath = await backup.writeExportToFile(json);

      // 用 OpenFilex.open 弹分享/打开（不直接打开文件，让用户知道位置）
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(zh ? '已导出到：$outPath' : 'Exported to: $outPath'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: zh ? '打开' : 'Open',
              onPressed: () async {
                try {
                  await OpenFilex.open(outPath);
                } catch (_) {}
              },
            ),
          ),
        );
      }
    } catch (e, st) {
      LoggerService.instance.error('Export failed', error: e, stack: st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(zh ? '导出失败：$e' : 'Export failed: $e'),
            backgroundColor: cs.errorContainer,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 导入：选 JSON 文件 → 弹窗问合并/覆盖 → 执行 → SnackBar 显示统计
  Future<void> _onImportTap() async {
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;
    final filePath = picked.files.first.path;
    if (filePath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(zh ? '无法获取文件路径' : 'Cannot get file path')),
        );
      }
      return;
    }

    // 弹窗：合并 / 覆盖 / 取消
    final mode = await showDialog<_ImportMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '导入策略' : 'Import Strategy'),
        content: Text(zh
            ? '合并：保留现有数据，追加导入的对话和 API（冲突时生成新 ID）\n\n覆盖：清空当前所有数据后导入'
            : 'Merge: keep existing data, append imported items (new IDs on conflict)\n\nOverwrite: clear all current data, then import'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: Text(l.tr('cancel')),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, _ImportMode.merge),
            child: Text(zh ? '合并' : 'Merge'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _ImportMode.overwrite),
            style: FilledButton.styleFrom(
              backgroundColor: cs.errorContainer,
              foregroundColor: cs.onErrorContainer,
            ),
            child: Text(zh ? '覆盖' : 'Overwrite'),
          ),
        ],
      ),
    );
    if (mode == null) return;

    try {
      final storage = context.read<StorageService>();
      final backup = BackupService(storage);
      final stats = await backup.importFromFile(
        filePath,
        merge: mode == _ImportMode.merge,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(zh
                ? '✅ 导入完成（${mode == _ImportMode.merge ? "合并" : "覆盖"}模式）：'
                    '${stats.apiConfigs} 个 API / '
                    '${stats.conversations} 个对话 / '
                    '${stats.messages} 条消息'
                : '✅ Imported (${mode == _ImportMode.merge ? "merge" : "overwrite"}): '
                    '${stats.apiConfigs} APIs / '
                    '${stats.conversations} conversations / '
                    '${stats.messages} messages'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e, st) {
      LoggerService.instance.error('Import failed', error: e, stack: st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(zh ? '导入失败：$e' : 'Import failed: $e'),
            backgroundColor: cs.errorContainer,
            duration: const Duration(seconds: 8),
          ),
        );
      }
    }
  }

  /// v1.3.4：GitHub 代理推荐 chip（点一下自动填入输入框）
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
      },
    );
  }

  /// v1.5.2：用系统浏览器打开联网搜索服务商官网
  Future<void> _openProviderUrl(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ===== 联网搜索设置 (v1.3.0) =====
  Widget _buildWebSearchSection(AppLocalizations l, ColorScheme colorScheme) {
    final cfg = _searchCfg;
    if (cfg == null) {
      return const ListTile(
        leading: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
        title: Text('...'),
      );
    }
    final zh = l.locale.languageCode == 'zh';
    final usable = cfg.isProviderUsable();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
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
              Switch(
                value: cfg.webSearchEnabled,
                onChanged: (v) {
                  setState(() => _searchCfg = cfg.copyWith(webSearchEnabled: v));
                  _saveSearchConfig();
                  // v1.6.9 build42 修复问题2：联网搜索开关 → 同步插件开关（双向同步闭环）
                  context.read<PluginRegistry>().setEnabled(PluginRegistry.kSearchPluginId, v);
                },
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
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade700)),
            ],
            // v1.5.2：当前服务商官网链接（点击跳转去注册 / 查 API Key）
            InkWell(
              onTap: () => _openProviderUrl(cfg.provider.officialUrl),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_new,
                        size: 14, color: colorScheme.primary),
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
                onChanged: (_) {},
              ),
              const SizedBox(height: 8),
              Text('${l.tr('tavilyDepth')}: ${cfg.tavilySearchDepth == 'auto' ? (zh ? '自动（AI 决定）' : 'Auto (AI decides)') : cfg.tavilySearchDepth}',
                  style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
              // v1.3.5：搜索深度三选 — 自动(默认) / 基本 / 高级
              Wrap(
                spacing: 6,
                children: [
                  ChoiceChip(
                    label: Text(zh ? '自动（推荐）' : 'Auto (Recommended)'),
                    selected: cfg.tavilySearchDepth == 'auto',
                    onSelected: (_) {
                      setState(() => _searchCfg =
                          cfg.copyWith(tavilySearchDepth: 'auto'));
                      _saveSearchConfig();
                    },
                  ),
                  ChoiceChip(
                    label: Text(l.tr('tavilyDepthBasic')),
                    selected: cfg.tavilySearchDepth == 'basic',
                    onSelected: (_) {
                      setState(() => _searchCfg =
                          cfg.copyWith(tavilySearchDepth: 'basic'));
                      _saveSearchConfig();
                    },
                  ),
                  ChoiceChip(
                    label: Text(l.tr('tavilyDepthAdvanced')),
                    selected: cfg.tavilySearchDepth == 'advanced',
                    onSelected: (_) {
                      setState(() => _searchCfg =
                          cfg.copyWith(tavilySearchDepth: 'advanced'));
                      _saveSearchConfig();
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
                      min: 3, max: 10, divisions: 7,
                      label: '$_tavilyMaxResults',
                      onChanged: (v) => setState(() => _tavilyMaxResults = v.round()),
                      onChangeEnd: (_) => _saveSearchConfig(),
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
              ),
            ],
            // v1.3.9：DuckDuckGo 无需 Key，仅展示提示
            if (cfg.provider == WebSearchProvider.duckduckgo) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 16, color: Colors.green.shade700),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        zh
                            ? 'DuckDuckGo 直爬模式，无需 API Key，国内可访问。结果可能被反爬限制。'
                            : 'DuckDuckGo direct scraping, no API Key needed. May be rate-limited.',
                        style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // v1.3.9：SerpAPI 配置（Key + 引擎）
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
              ),
            ],
            // v1.3.9：Brave Search API 配置
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
              ),
            ],
            // v1.3.9：Google CSE 自定义搜索配置（API Key + cx）
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
              ),
            ],
            const SizedBox(height: 8),

            // =================================================================
            // build 14：GitHub Release 下载加速代理（国内访问 github.com 慢/超时）
            // =================================================================
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
                        },
                      )
                    : null,
              ),
              onChanged: (_) {
                // 触发 suffixIcon 刷新（清空按钮显示/隐藏）
                setState(() {});
              },
            ),
            const SizedBox(height: 6),
            // 推荐 chip：点一下自动填入
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _buildGhProxyChip(
                  'ghproxy.com',
                  'https://ghproxy.com',
                  zh,
                  colorScheme,
                ),
                _buildGhProxyChip(
                  'ghproxy.net',
                  'https://ghproxy.net',
                  zh,
                  colorScheme,
                ),
                _buildGhProxyChip(
                  'mirror.ghproxy.com',
                  'https://mirror.ghproxy.com',
                  zh,
                  colorScheme,
                ),
                _buildGhProxyChip(
                  'kkgithub (域名替换)',
                  'https://kkgithub.com',
                  zh,
                  colorScheme,
                ),
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

            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _testingSearch
                      ? null
                      : () async {
                          // 先保存一次（用当前表单里的 Key / URL 来测，避免用户"刚填完没保存导致测的是旧值"）
                          await _saveSearchConfig();
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
                            ? Colors.green.shade700
                            : _testSearchOk == false
                                ? Colors.red.shade700
                                : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            // 保存按钮（Bing/DuckDuckGo 自动保存无需按钮；其他需要 Key 的服务商保留）
            if (cfg.provider != WebSearchProvider.bing &&
                cfg.provider != WebSearchProvider.duckduckgo) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _saveSearchConfig,
                  icon: const Icon(Icons.save, size: 18),
                  label: Text(l.tr('save')),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  // v1.6.10 build43 修复问题3：独立思考（ReAct）独立成 section，与联网搜索解耦。
  Widget _buildReActSection(AppLocalizations l, ColorScheme colorScheme) {
    final cfg = _searchCfg;
    if (cfg == null) return const SizedBox.shrink();
    final zh = l.locale.languageCode == 'zh';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.psychology_alt_outlined, color: colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(zh ? '独立思考 (ReAct)' : 'Autonomous Thinking (ReAct)',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                      zh ? 'AI 自主多轮思考后给出答复（与联网搜索相互独立）'
                         : 'AI thinks autonomously over multiple rounds (independent of web search)',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Switch(
                value: cfg.reactEnabled,
                onChanged: (v) {
                  setState(() => _searchCfg = cfg.copyWith(reactEnabled: v));
                  _saveSearchConfig();
                },
              ),
            ],
          ),
          if (cfg.reactEnabled) ...[
            const SizedBox(height: 8),
            Text(
              zh ? '思考程度（越大 = 思考轮次越多）：' : 'Reasoning effort (higher = more thinking rounds):',
              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            LayoutBuilder(
              builder: (context, constraints) {
                // v1.3.4：5 档精简（删默认），每行 5 列
                final width = constraints.maxWidth / 5 - 5;
                final opts = const [
                  (label: '关 Off',     rounds: 0,  auto: false),
                  (label: '低 Low',     rounds: 2,  auto: false),
                  (label: '中 Medium',  rounds: 5,  auto: false),
                  (label: '高 High',    rounds: 8,  auto: false),
                  (label: '自动 Auto',  rounds: 30, auto: true),
                ];
                return Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final opt in opts)
                      SizedBox(
                        width: width,
                        child: ChoiceChip(
                          showCheckmark: false,
                          label: Text(opt.label, style: const TextStyle(fontSize: 11)),
                          selected: opt.auto
                              ? cfg.reactAutoMode
                              : (!cfg.reactAutoMode &&
                                  (opt.rounds == 0
                                      ? cfg.reactMaxRounds == 0
                                      : opt.rounds == 2
                                          ? cfg.reactMaxRounds <= 2
                                          : opt.rounds == 5
                                              ? cfg.reactMaxRounds >= 3 && cfg.reactMaxRounds <= 6
                                              : opt.rounds == 8
                                                  ? cfg.reactMaxRounds >= 7
                                                  : false)),
                          selectedColor: colorScheme.primary.withValues(alpha: 0.12),
                          onSelected: (_) {
                            setState(() => _searchCfg = opt.auto
                                ? cfg.copyWith(reactAutoMode: true, reactMaxRounds: 30)
                                : cfg.copyWith(reactAutoMode: false, reactMaxRounds: opt.rounds));
                            _saveSearchConfig();
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
            Row(
              children: [
                Text(zh ? '自定义' : 'Custom', style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
                Expanded(
                  child: Slider(
                    min: 0,
                    max: 100,
                    divisions: 100,
                    value: cfg.reactMaxRounds.toDouble().clamp(0, 100),
                    label: cfg.reactAutoMode
                        ? '自动上限 ${cfg.reactMaxRounds} 轮'
                        : '${cfg.reactMaxRounds} 轮',
                    onChanged: (v) {
                      setState(() => _searchCfg =
                          cfg.copyWith(reactMaxRounds: v.round()));
                      // 拖完再保存（onChanged 频繁，避免每次都写库）
                    },
                    onChangeEnd: (_) => _saveSearchConfig(),
                  ),
                ),
                Text('${cfg.reactMaxRounds}', style: TextStyle(fontSize: 12, color: colorScheme.primary, fontWeight: FontWeight.bold)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                zh
                    ? '当前：${cfg.reactLevelLabel} → 最多思考 ${cfg.reactMaxRounds} 轮${cfg.reactAutoMode ? "（AI 自决轮次，上限可拖滑块调高）" : ""}'
                    : 'Current: ${cfg.reactLevelLabelEn} → up to ${cfg.reactMaxRounds} thinking rounds',
                style: TextStyle(fontSize: 11, color: colorScheme.primary),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

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
        Future.microtask(_saveSearchConfig);
      },
    );
  }

  /// v1.6.5：设置页语言切换弹窗（跟随系统 / 简体中文 / English）
  /// 选中即生效并落盘 SharedPreferences，重启后由 main.dart 的
  /// 全局 LocaleProvider.init() 恢复（修复：选英文后重启回落中文）。
  Future<void> _showLanguagePicker() async {
    final l = AppLocalizations.of(context);
    final current = context.read<LocaleProvider>().locale?.languageCode;
    await showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l.tr('language')),
        children: [
          _languageOption(ctx, null, l.tr('systemLanguage'), current),
          _languageOption(ctx, 'zh', '简体中文', current),
          _languageOption(ctx, 'en', 'English', current),
        ],
      ),
    );
  }

  Widget _languageOption(
      BuildContext ctx, String? code, String label, String? current) {
    final selected = code == current;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      title: Text(label),
      onTap: () async {
        final lp = ctx.read<LocaleProvider>();
        if (code == null) {
          await lp.setSystemLocale();
        } else {
          await lp.setLocale(Locale(code));
        }
        if (ctx.mounted) Navigator.pop(ctx);
      },
    );
  }

  /// v1.7.5：安全审查设置 Section
  Widget _buildSecurityScanSection(AppLocalizations l, ColorScheme colorScheme) {
    final cfg = _searchCfg;
    if (cfg == null) return const SizedBox.shrink();
    final zh = l.locale.languageCode == 'zh';
    
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Row(
            children: [
              Icon(Icons.security_outlined, color: colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      zh ? '安全审查' : 'Security Scan',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      zh ? '本地规则扫描（默认开启，零配置）+ 可选 SkillSpector/MobSF 深度审查' : 'Local rule scan (on by default, zero-config) + optional SkillSpector/MobSF deep scan',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // v1.7.10：本地规则扫描开关（默认开，零配置）
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(zh ? '启用本地规则扫描' : 'Enable Local Rule Scan'),
            subtitle: Text(
              zh
                  ? '安装 Skill/MCP 前用内置规则离线检查（无需部署服务，仅供参考）'
                  : 'Offline rule-based check before installing Skill/MCP (no service needed, for reference)',
              style: TextStyle(fontSize: 12),
            ),
            value: cfg.enableLocalScan,
            onChanged: (v) {
              setState(() => _searchCfg = cfg.copyWith(enableLocalScan: v));
              _saveSearchConfig();
            },
          ),
          const SizedBox(height: 4),

          // v1.7.10：远程规则源 URL（预留，留空走内置规则）
          Text(
            zh ? '远程规则源 URL（可选，预留）' : 'Remote rules URL (optional, reserved)',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _localScanRulesUrlCtrl,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: zh ? '规则 JSON 地址' : 'Rules JSON URL',
              hintText: zh ? '留空使用内置规则；填写后自动合并远程规则' : 'Empty = builtin rules only; fill to merge remote rules',
              prefixIcon: const Icon(Icons.rule_outlined, size: 18),
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) {},
          ),
          const SizedBox(height: 12),

          // SkillSpector 配置
          Text(
            zh ? 'SkillSpector 服务地址' : 'SkillSpector Endpoint',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _skillspectorEndpointCtrl,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: zh ? 'SkillSpector 服务地址' : 'SkillSpector Endpoint',
              hintText: zh ? '例如：http://192.168.1.100:8000' : 'e.g., http://192.168.1.100:8000',
              prefixIcon: const Icon(Icons.dns_outlined, size: 18),
              suffixIcon: _testingSkillSpector
                  ? Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) {},
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _testingSkillSpector
                    ? null
                    : () async {
                        await _saveSearchConfig();
                        if (!mounted) return; // v1.7.9 (M9)：await 后 context 失效保护
                        final endpoint = _skillspectorEndpointCtrl.text.trim();
                        if (endpoint.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(zh ? '请先填写 SkillSpector 地址' : 'Please enter SkillSpector endpoint first'),
                              backgroundColor: Colors.orange.shade700,
                            ),
                          );
                          return;
                        }
                        setState(() => _testingSkillSpector = true);
                        final (ok, msg, _) = await SecurityScanService.testSkillSpectorConnection(endpoint);
                        if (mounted) {
                          setState(() => _testingSkillSpector = false);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(ok ? '✅ $msg' : '❌ $msg'),
                              backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700,
                            ),
                          );
                        }
                      },
                icon: const Icon(Icons.network_check, size: 18),
                label: Text(zh ? '测试 SkillSpector' : 'Test SkillSpector'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // Skill 审查开关
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(zh ? '启用 Skill 安全审查' : 'Enable Skill Security Scan'),
            subtitle: Text(
              zh ? '安装 Skill 前自动检查安全性' : 'Auto-check security before installing Skill',
              style: TextStyle(fontSize: 12),
            ),
            value: cfg.enableSkillSecurityScan,
            onChanged: (v) {
              setState(() => _searchCfg = cfg.copyWith(enableSkillSecurityScan: v));
              _saveSearchConfig();
            },
          ),
          
          // MCP 审查开关
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(zh ? '启用 MCP 安全审查' : 'Enable MCP Security Scan'),
            subtitle: Text(
              zh ? '安装 MCP 前自动检查安全性' : 'Auto-check security before installing MCP',
              style: TextStyle(fontSize: 12),
            ),
            value: cfg.enableMcpSecurityScan,
            onChanged: (v) {
              setState(() => _searchCfg = cfg.copyWith(enableMcpSecurityScan: v));
              _saveSearchConfig();
            },
          ),
          
          const Divider(height: 20),
          
          // MobSF 配置
          Text(
            zh ? 'MobSF 服务地址' : 'MobSF Endpoint',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _mobsfEndpointCtrl,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: zh ? 'MobSF 服务地址' : 'MobSF Endpoint',
              hintText: zh ? '例如：http://192.168.1.100:8080' : 'e.g., http://192.168.1.100:8080',
              prefixIcon: const Icon(Icons.phone_android_outlined, size: 18),
              suffixIcon: _testingMobSF
                  ? Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) {},
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _testingMobSF
                    ? null
                    : () async {
                        await _saveSearchConfig();
                        if (!mounted) return; // v1.7.9 (M9)：await 后 context 失效保护
                        final endpoint = _mobsfEndpointCtrl.text.trim();
                        if (endpoint.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(zh ? '请先填写 MobSF 地址' : 'Please enter MobSF endpoint first'),
                              backgroundColor: Colors.orange.shade700,
                            ),
                          );
                          return;
                        }
                        setState(() => _testingMobSF = true);
                        final (ok, msg, _) = await SecurityScanService.testMobSFConnection(endpoint);
                        if (mounted) {
                          setState(() => _testingMobSF = false);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(ok ? '✅ $msg' : '❌ $msg'),
                              backgroundColor: ok ? Colors.green.shade700 : Colors.red.shade700,
                            ),
                          );
                        }
                      },
                icon: const Icon(Icons.network_check, size: 18),
                label: Text(zh ? '测试 MobSF' : 'Test MobSF'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // APK 审查开关
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(zh ? '启用 APK 安全审查' : 'Enable APK Security Scan'),
            subtitle: Text(
              zh ? '下载 APK 后自动检查安全性' : 'Auto-check security after downloading APK',
              style: TextStyle(fontSize: 12),
            ),
            value: cfg.enableApkSecurityScan,
            onChanged: (v) {
              setState(() => _searchCfg = cfg.copyWith(enableApkSecurityScan: v));
              _saveSearchConfig();
            },
          ),

          // v1.7.11: MobSF API Key（P0 修复：自部署 MobSF 也可配认证）
          const SizedBox(height: 8),
          TextField(
            controller: _mobsfApiKeyCtrl,
            decoration: InputDecoration(
              isDense: true,
              labelText: zh ? 'MobSF API Key（可选）' : 'MobSF API Key (optional)',
              hintText: zh ? '自部署通常留空' : 'Usually empty for self-deployed',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.vpn_key, size: 18),
            ),
          ),

          // v1.7.11: VirusTotal 云端查毒
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              zh ? 'VirusTotal 云端查毒' : 'VirusTotal Cloud Scan',
              style: TextStyle(fontWeight: FontWeight.bold, color: colorScheme.primary),
            ),
          ),
          TextField(
            controller: _virusTotalApiKeyCtrl,
            decoration: InputDecoration(
              isDense: true,
              labelText: zh ? 'VirusTotal API Key' : 'VirusTotal API Key',
              hintText: zh ? '免费注册：virustotal.com → 500次/天' : 'Free at virustotal.com → 500 req/day',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.key, size: 18),
              suffixIcon: _testingVirusTotal
                  ? const SizedBox(width: 20, height: 20, child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      tooltip: zh ? '测试 Key' : 'Test Key',
                      onPressed: _testingVirusTotal
                          ? null
                          : () async {
                              final key = _virusTotalApiKeyCtrl.text.trim();
                              if (key.isEmpty) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(zh ? '请先填写 API Key' : 'Please enter API Key first')),
                                );
                                return;
                              }
                              await _saveSearchConfig();
                              if (!mounted) return;
                              setState(() => _testingVirusTotal = true);
                              final (ok, msg, _) = await SecurityScanService.testVirusTotalConnection(key);
                              if (!mounted) return;
                              setState(() => _testingVirusTotal = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(msg), backgroundColor: ok ? Colors.green : Colors.red),
                              );
                            },
                    ),
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(zh ? '启用 VirusTotal 查毒' : 'Enable VirusTotal Scan'),
            subtitle: Text(
              zh ? 'APK/文档/EXE 下载后自动查 SHA-256 哈希（秒回、不上传文件）' : 'Auto SHA-256 hash check after downloading APK/docs/EXE',
              style: TextStyle(fontSize: 12),
            ),
            value: cfg.enableVirusTotalScan,
            onChanged: (v) {
              setState(() => _searchCfg = cfg.copyWith(enableVirusTotalScan: v));
              _saveSearchConfig();
            },
          ),

          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 4),
            child: Text(
              zh
                  ? '💡 本地规则扫描开箱即用（离线、零配置、仅供参考，不能保证查出所有问题）。'
                      '\nVirusTotal 云端查毒：填 API Key 即用（免费 500次/天），下载后自动查哈希。'
                      '\n深度审查为可选增强，需要在电脑或服务器上部署：'
                      '\n• SkillSpector: github.com/NVIDIA/SkillSpector'
                      '\n• MobSF: github.com/MobSF/Mobile-Security-Framework-MobSF'
                  : '💡 Local rule scan works out of the box (offline, zero-config, reference only, not exhaustive).'
                      '\nVirusTotal cloud scan: just enter API Key (free 500 req/day), auto hash check after download.'
                      '\nDeep scan is an optional enhancement requiring self-deployed services:'
                      '\n• SkillSpector: github.com/NVIDIA/SkillSpector'
                      '\n• MobSF: github.com/MobSF/Mobile-Security-Framework-MobSF',
              style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
            ),
          ),
          
          // 保存按钮
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _saveSearchConfig,
              icon: const Icon(Icons.save, size: 18),
              label: Text(l.tr('save')),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';
    // v1.6.5：watch 保证设置页语言切换后（locale 变化）本页立即重建
    final lp = context.watch<LocaleProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(l.tr('settings'))),
      body: ListView(
        children: [
          // ===== 版本号（显眼置顶，用户直接看系统/这里能识别） =====
          Container(
            margin: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Icon(Icons.new_releases_outlined,
                    color: colorScheme.onPrimaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Nexus',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      Text(
                        'Version $_appVersionFull',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: colorScheme.onPrimaryContainer,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(indent: 16, endIndent: 16),

          // ===== v1.6.5：语言切换（跟随系统 / 简体中文 / English） =====
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l.tr('language')),
            subtitle: Text(lp.locale == null
                ? l.tr('systemLanguage')
                : (lp.locale!.languageCode == 'zh' ? '简体中文' : 'English')),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showLanguagePicker,
          ),
          const Divider(indent: 16, endIndent: 16),

          // ===== Web Search Section (v1.3.0) =====
          _buildWebSearchSection(l, colorScheme),
          const Divider(),

          // ===== v1.6.10 build43：独立思考 (ReAct) 独立 Section =====
          _buildReActSection(l, colorScheme),
          const Divider(),

          // ===== v1.7.5：安全审查 Section =====
          _buildSecurityScanSection(l, colorScheme),
          const Divider(),

          // ===== v1.3.8：导出 / 导入 Section =====
          _buildBackupSection(l, colorScheme),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l.tr('about')),
            subtitle: Text(l.tr('aboutSubtitle')),
            onTap: () {
              showAboutDialog(
                context: context,
                applicationName: 'Nexus',
                applicationVersion: _appVersionFull,
                applicationIcon: const FlutterLogo(),
                applicationLegalese: '© 2026 Nexus',
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: Text(l.tr('apiConfigs')),
            subtitle: Text(l.tr('apiConfigsSubtitle')),
            // v1.6.8 修复 Bug#14：原 Navigator.pop(context) 仅关闭设置页，
            // 未跳转 ApiConfigScreen（同图标在 ConversationListScreen L191 是 push）。
            // 改为 push 让用户能进入 API 配置管理。
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const ApiConfigScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.storage),
            title: Text(l.tr('storage')),
            subtitle: Text(l.tr('storageSubtitle')),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(l.tr('supportedApis')),
            subtitle: Text(l.tr('supportedApisSubtitle')),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(l.tr('supportedApiProviders')),
                  content: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('• OpenAI: api.openai.com'),
                        const Text('• DeepSeek: api.deepseek.com'),
                        const Text('• Kimi: api.moonshot.cn'),
                        const Text('• Qwen: dashscope.aliyuncs.com'),
                        const Text('• Local Ollama: localhost:11434'),
                        Text('\n${l.tr('supportedApisSubtitle')}'),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l.tr('ok')),
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(),
          // ===== 日志区 =====
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text(l.tr('viewLogs')),
            subtitle: Text(l.tr('viewLogsSubtitle')),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LogViewerScreen()),
              );
            },
          ),
          ListTile(
            leading: _exporting
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_upload_outlined),
            title: Text(l.tr('exportLogs')),
            subtitle: Text(l.tr('exportLogsSubtitle')),
            onTap: _exporting ? null : _exportLogs,
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: Text(l.tr('clearLogs')),
            subtitle: Text(l.tr('clearLogsSubtitle')),
            onTap: _clearLogs,
          ),
          // v1.3.4：详细日志开关（开启时弹隐私警告）
          SwitchListTile(
            secondary: Icon(
              Icons.bug_report_outlined,
              color: (_searchCfg?.verboseLogging ?? false)
                  ? Colors.orange.shade700
                  : null,
            ),
            title: Text(zh ? '详细日志（调试用）' : 'Verbose logging (debug)'),
            subtitle: Text(zh
                ? '开启后记录聊天内容/搜索结果全文（API Key 不记）。仅用于找问题，请勿随意导出/分享'
                : 'Logs full chat/search content (never API keys). Debugging only - do not export/share'),
            value: _searchCfg?.verboseLogging ?? false,
            onChanged: _toggleVerboseLogging,
          ),
          const Divider(),
          // ===== v1.6.5：自检 + AI 行为测试 从顶部移到页面底部 =====
          ListTile(
            leading: _selfChecking
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.fact_check_outlined),
            title: Text(zh ? '运行自检' : 'Run Self-Check'),
            subtitle: Text(zh ? '检查数据库结构、日志脱敏等基础功能' : 'Check DB schema, log scrubbing and other basics'),
            onTap: _selfChecking ? null : _runSelfCheck,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.science_outlined),
            title: Text(zh ? 'AI 行为测试（消耗 token）' : 'AI Behavior Test (consumes tokens)'),
            subtitle: Text(zh
                ? '发送固定输入验证 AI 行为：对话链路 / 反问 / TXT / 图片'
                : 'Send fixed inputs to verify AI behavior: chat / ask-back / TXT / image'),
            value: _aiBehaviorTestEnabled,
            onChanged: (v) => setState(() => _aiBehaviorTestEnabled = v),
          ),
          if (_aiBehaviorTestEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: ListTile(
                leading: const Icon(Icons.open_in_new),
                title: Text(zh ? '进入 AI 行为测试页' : 'Open AI Behavior Test Page'),
                subtitle: Text(zh
                    ? '将发送 4 条真实消息验证 AI 行为，建议仅在回归验证时使用'
                    : 'Sends 4 real messages to verify AI behavior; for regression use only'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const RegressionTestScreen(),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// v1.3.8：导入策略选项（设置页 _onImportTap 内部使用）
enum _ImportMode { merge, overwrite }
