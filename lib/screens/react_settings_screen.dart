// v1.7.15：拆分自 settings_screen.dart 的 _buildReActSection（原 L665-L798）
//
// 目的：把 ReAct 独立思考设置从主 SettingsScreen 拆到独立 sub-screen，让 Switch
// 切换的高度突变只发生在本页面里，主 SettingsScreen 不再受高度突变影响（白窗口根因消除）。
//
// 数据流：通过 Provider<StorageService> 直接读写 web_search_configs 表，不再依赖主
// SettingsScreenState 的 _searchCfg / _saveSearchConfig。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/web_search_config.dart';
import '../services/storage_service.dart';

class ReActSettingsScreen extends StatefulWidget {
  const ReActSettingsScreen({super.key});

  @override
  State<ReActSettingsScreen> createState() => _ReActSettingsScreenState();
}

class _ReActSettingsScreenState extends State<ReActSettingsScreen> {
  // 自有 _searchCfg（不再共享主 SettingsScreenState 的字段）
  WebSearchConfig? _searchCfg;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final storage = context.read<StorageService>();
    final cfg = await storage.getWebSearchConfig();
    if (!mounted) return;
    setState(() => _searchCfg = cfg);
  }

  Future<void> _saveConfig() async {
    final cfg = _searchCfg;
    if (cfg == null) return;
    await context.read<StorageService>().saveWebSearchConfig(cfg);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';
    final cfg = _searchCfg;
    return Scaffold(
      appBar: AppBar(title: Text(zh ? '独立思考 (ReAct)' : 'ReAct')),
      body: cfg == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: _buildSection(l, colorScheme, cfg, zh),
            ),
    );
  }

  Widget _buildSection(
    AppLocalizations l,
    ColorScheme colorScheme,
    WebSearchConfig cfg,
    bool zh,
  ) {
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
                  _saveConfig();
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
                const opts = [
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
                            _saveConfig();
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
                    onChangeEnd: (_) => _saveConfig(),
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
}
