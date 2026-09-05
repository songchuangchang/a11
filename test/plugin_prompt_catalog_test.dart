import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aichat/models/plugin_hint_config.dart';
import 'package:aichat/plugins/plugin_context.dart';
import 'package:aichat/plugins/plugin_interface.dart';
import 'package:aichat/services/plugin_prompt_catalog.dart';

/// 测试用最小 ReActPlugin 实现（手构造数据，不依赖真实服务）。
class _FakePlugin implements ReActPlugin {
  @override
  final String triggerType;
  @override
  final PluginSource source;
  @override
  final PluginMetadata metadata;

  _FakePlugin(this.triggerType, this.source, this.metadata);

  @override
  RegExp? get legacyTrigger => null;

  @override
  Future<void> handle(
          BuildContext context, PluginContext pluginContext, Map<String, dynamic> attrs) async {}
}

// ---- 构造器 ----

ReActPlugin _builtin(String id, String name, String trigger, String protocol,
    {Map<String, dynamic> extra = const {}}) {
  return _FakePlugin(
    trigger,
    PluginSource.system,
    PluginMetadata(
      id: id,
      name: name,
      version: '1.6.8',
      author: 'Nexus',
      description: '内置描述-$name',
      promptProtocol: protocol,
      extra: extra,
    ),
  );
}

ReActPlugin _mcp(String id, List<Map<String, dynamic>> tools) {
  return _FakePlugin(
    'mcp_call',
    PluginSource.installed,
    PluginMetadata(
      id: id,
      name: 'MCP $id',
      version: '1',
      author: 't',
      description: 'mcp desc',
      kind: PluginKind.mcpRemote,
      triggerType: 'mcp_call',
      extra: {'tools': tools},
    ),
  );
}

ReActPlugin _skill(String id, String name,
    {String? skillSummary, String protocol = 'skill-protocol'}) {
  return _FakePlugin(
    '__installed_$id',
    PluginSource.installed,
    PluginMetadata(
      id: id,
      name: name,
      version: '1',
      author: 't',
      description: 'skill desc',
      promptProtocol: protocol,
      kind: PluginKind.declarative,
      triggerType: '__installed_$id',
      extra: {if (skillSummary != null) 'skillSummary': skillSummary},
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('collectCatalog 内置插件', () {
    final plugins = [
      _builtin('nexus.builtin.search', '联网搜索', 'search', 'search-protocol'),
      _builtin('nexus.builtin.download', '文件下载', 'download', 'download-protocol'),
      _builtin('nexus.builtin.answer', '最终答案', 'answer', 'answer-protocol'),
    ];

    test('内置插件在 off/manual/auto 下都收集', () {
      for (final mode in PluginHintMode.values) {
        final entries =
            collectCatalog(plugins, PluginHintConfig(mode: mode));
        expect(entries.map((e) => e.id).toSet(),
            {'nexus.builtin.search', 'nexus.builtin.download', 'nexus.builtin.answer'},
            reason: 'mode=${mode.name} 内置插件应始终收集');
      }
    });

    test('目录摘要用 description，detail 为完整 promptProtocol', () {
      final entries = collectCatalog(plugins, const PluginHintConfig());
      final s = entries.firstWhere((e) => e.id == 'nexus.builtin.search');
      expect(s.summary, '内置描述-联网搜索');
      expect(s.detail, 'search-protocol');
      expect(s.format, contains('<search query='));
    });

    test('extra[catalogSummary] 覆盖 description', () {
      final p = _builtin('nexus.builtin.search', '联网搜索', 'search', 'p',
          extra: {'catalogSummary': '自定义摘要'});
      final entries = collectCatalog([p], const PluginHintConfig());
      expect(entries.single.summary, '自定义摘要');
    });
  });

  group('collectCatalog MCP/Skill 三态过滤', () {
    final mcpA = _mcp('mcp.a', [
      {'name': 'tool_a', 'description': 'A 工具', 'inputSchema': {'type': 'object'}},
    ]);
    final mcpB = _mcp('mcp.b', [
      {'name': 'tool_b', 'description': 'B 工具', 'inputSchema': {'type': 'object'}},
    ]);
    final skillX = _skill('skill.x', 'Skill X', skillSummary: 'X 摘要');
    final skillY = _skill('skill.y', 'Skill Y', skillSummary: 'Y 摘要');
    final builtin = _builtin('nexus.builtin.search', '联网搜索', 'search', 'p');
    final all = [builtin, mcpA, mcpB, skillX, skillY];

    test('off 只收集内置', () {
      final entries = collectCatalog(all, const PluginHintConfig());
      expect(entries.map((e) => e.id).toList(), ['nexus.builtin.search']);
    });

    test('manual 只收集 selectedIds 命中的 MCP/Skill', () {
      const hint = PluginHintConfig(
          mode: PluginHintMode.manual, selectedIds: ['mcp.a', 'skill.y']);
      final entries = collectCatalog(all, hint);
      final ids = entries.map((e) => e.id).toSet();
      expect(ids, {'nexus.builtin.search', 'mcp:mcp.a:tool_a', 'skill.y'});
    });

    test('auto 收集全部 enabled 的 MCP+Skill', () {
      final entries = collectCatalog(all, const PluginHintConfig(mode: PluginHintMode.auto));
      final ids = entries.map((e) => e.id).toSet();
      expect(ids, {
        'nexus.builtin.search',
        'mcp:mcp.a:tool_a',
        'mcp:mcp.b:tool_b',
        'skill.x',
        'skill.y',
      });
    });

    test('MCP 每个工具一个条目，summary 为 tool description', () {
      final multi = _mcp('mcp.multi', [
        {'name': 't1', 'description': 'd1', 'inputSchema': {}},
        {'name': 't2', 'description': 'd2', 'inputSchema': {}},
      ]);
      final entries = collectCatalog([multi],
          const PluginHintConfig(mode: PluginHintMode.auto));
      expect(entries.map((e) => e.name).toList(), ['t1', 't2']);
      expect(entries.first.summary, 'd1');
    });

    test('MCP summary 截断到 ~80 字符', () {
      final longDesc = 'A' * 120;
      final p = _mcp('mcp.long', [
        {'name': 't', 'description': longDesc, 'inputSchema': {}},
      ]);
      final entries = collectCatalog([p],
          const PluginHintConfig(mode: PluginHintMode.auto));
      expect(entries.single.summary.length, kSummaryMaxLen + 1);
      expect(entries.single.summary, endsWith('…'));
    });

    test('Skill summary 用 skillSummary，回退 name|type|触发', () {
      final noSummary = _skill('skill.n', '无摘要 Skill');
      final entries = collectCatalog([noSummary],
          const PluginHintConfig(mode: PluginHintMode.auto));
      expect(entries.single.summary, contains('无摘要 Skill | type='));
      expect(entries.single.summary, contains('触发'));
    });
  });

  group('buildDirectoryAndFormatLayer', () {
    test('输出目录层（名字+摘要）与去重的格式层', () {
      final entries = [
        const CatalogEntry(
            id: 'nexus.builtin.search',
            name: '联网搜索',
            summary: '摘要',
            format: '<search query="关键词" depth="basic|advanced" />',
            detail: 'p'),
        const CatalogEntry(
            id: 'nexus.builtin.answer',
            name: '最终答案',
            summary: '答案',
            format: '<answer>最终回复（支持 Markdown）</answer>',
            detail: 'p'),
      ];
      final text = buildDirectoryAndFormatLayer(entries);
      expect(text, contains('=== 可用插件目录 ==='));
      expect(text, contains('[nexus.builtin.search] 联网搜索: 摘要'));
      expect(text, contains('=== 调用格式骨架 ==='));
      expect(text, contains('<search query='));
      expect(text, contains('<answer>'));
    });

    test('两个 MCP 工具共享同一 mcp_call 格式骨架只输出一次', () {
      final entries = [
        const CatalogEntry(
            id: 'mcp:s:a', name: 'a', summary: 's', format: '<mcp_call plugin_id="..." tool="...">{JSON 参数对象}</mcp_call>', detail: ''),
        const CatalogEntry(
            id: 'mcp:s:b', name: 'b', summary: 's', format: '<mcp_call plugin_id="..." tool="...">{JSON 参数对象}</mcp_call>', detail: ''),
      ];
      final text = buildDirectoryAndFormatLayer(entries);
      expect('<mcp_call'.allMatches(text).length, 1);
    });

    test('空目录返回占位', () {
      final text = buildDirectoryAndFormatLayer(const []);
      expect(text, contains('（无）'));
    });
  });

  group('resolve 详情', () {
    final search = _builtin('nexus.builtin.search', '联网搜索', 'search', 'search-protocol');
    final mcp = _mcp('mcp.a', [
      {'name': 'echo', 'description': '回显', 'inputSchema': {'type': 'object', 'properties': {'x': {'type': 'string'}}}},
    ]);
    final skill = _skill('skill.x', 'Skill X', skillSummary: '摘要', protocol: 'skill-protocol');

    test('resolvePluginDetail 先 id 精确、退化 triggerType', () {
      expect(resolvePluginDetail('nexus.builtin.search', [search]), 'search-protocol');
      expect(resolvePluginDetail('search', [search]), 'search-protocol');
    });

    test('resolvePluginDetail 未知返回空串', () {
      expect(resolvePluginDetail('nope', [search]), '');
      expect(resolvePluginDetail('', [search]), '');
    });

    test('resolveMcpDetail 返回 description + schema', () {
      final text = resolveMcpDetail('mcp.a', 'echo', [mcp]);
      expect(text, contains('回显'));
      expect(text, contains('inputSchema'));
      expect(text, contains('"properties"'));
    });

    test('resolveMcpDetail 未知 pluginId/tool 返回空串', () {
      expect(resolveMcpDetail('mcp.unknown', 'echo', [mcp]), '');
      expect(resolveMcpDetail('mcp.a', 'missing', [mcp]), '');
      expect(resolveMcpDetail('', 'echo', [mcp]), '');
    });

    test('resolveSkillDetail 按 id 或 name 返回 promptProtocol', () {
      expect(resolveSkillDetail('skill.x', [skill]), 'skill-protocol');
      expect(resolveSkillDetail('Skill X', [skill]), 'skill-protocol');
    });

    test('resolveSkillDetail 未知 / 内置插件返回空串', () {
      expect(resolveSkillDetail('nope', [skill]), '');
      expect(resolveSkillDetail('nexus.builtin.search', [search, skill]), '');
    });
  });

  group('PluginHintConfig', () {
    test('默认值 + copyWith', () {
      const cfg = PluginHintConfig();
      expect(cfg.mode, PluginHintMode.off);
      expect(cfg.selectedIds, isEmpty);
      expect(cfg.extraHints, isEmpty);
      final copied = cfg.copyWith(mode: PluginHintMode.manual);
      expect(copied.mode, PluginHintMode.manual);
      expect(copied.selectedIds, isEmpty);
    });

    test('toMap/fromMap 往返', () {
      const cfg = PluginHintConfig(
        mode: PluginHintMode.auto,
        selectedIds: ['mcp.a', 'skill.x'],
        extraHints: ['h1', 'h2'],
      );
      final restored = PluginHintConfig.fromMap(cfg.toMap());
      expect(restored.mode, PluginHintMode.auto);
      expect(restored.selectedIds, ['mcp.a', 'skill.x']);
      expect(restored.extraHints, ['h1', 'h2']);
    });

    test('fromMap 非法 mode 回退 off', () {
      final restored = PluginHintConfig.fromMap({'mode': 'bogus'});
      expect(restored.mode, PluginHintMode.off);
    });

    test('新键优先读取', () async {
      SharedPreferences.setMockInitialValues({
        'plugin_hint_mode': 'manual',
        'plugin_hint_selected': ['mcp.a'],
        'plugin_hint_extra': ['h'],
        'plugin_hint_enabled': true, // 旧键应被忽略
        'plugin_hint_items': ['old'],
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = PluginHintConfig.fromPrefs(prefs);
      expect(cfg.mode, PluginHintMode.manual);
      expect(cfg.selectedIds, ['mcp.a']);
      expect(cfg.extraHints, ['h']);
    });

    test('旧键迁移：enabled=true → auto + items→extraHints', () async {
      SharedPreferences.setMockInitialValues({
        'plugin_hint_enabled': true,
        'plugin_hint_items': ['h1', 'h2'],
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = PluginHintConfig.fromPrefs(prefs);
      expect(cfg.mode, PluginHintMode.auto);
      expect(cfg.extraHints, ['h1', 'h2']);
    });

    test('旧键迁移：enabled=false → off', () async {
      SharedPreferences.setMockInitialValues({'plugin_hint_enabled': false});
      final prefs = await SharedPreferences.getInstance();
      final cfg = PluginHintConfig.fromPrefs(prefs);
      expect(cfg.mode, PluginHintMode.off);
    });

    test('save/saveTo 写入新键', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const cfg = PluginHintConfig(
          mode: PluginHintMode.manual, selectedIds: ['a'], extraHints: ['b']);
      await cfg.saveTo(prefs);
      expect(prefs.getString('plugin_hint_mode'), 'manual');
      expect(prefs.getStringList('plugin_hint_selected'), ['a']);
      expect(prefs.getStringList('plugin_hint_extra'), ['b']);
      expect(PluginHintConfig.fromPrefs(prefs).mode, PluginHintMode.manual);
    });
  });
}
