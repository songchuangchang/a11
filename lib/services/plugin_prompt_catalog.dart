import 'dart:convert';

import '../models/plugin_hint_config.dart';
import '../plugins/plugin_interface.dart';
import 'builtin_prompt_catalog.dart';

/// v1.7.17：插件协议按需加载——接口契约层 + 目录构建器（纯函数，无副作用）。
///
/// 供 api_service（构建常驻 system 目录层/格式层）与 chat_screen（详情按需注入）共用。
///
/// 三层模型：
///   - 目录层：名字 + 摘要（常驻）
///   - 格式层：格式骨架（常驻，宿主协议语法，7 行集中常量表）
///   - 详情层：完整 promptProtocol / MCP description+schema（按需注入）
///
/// [collectCatalog] 只产出目录/格式/详情三层的结构化数据；
/// [buildDirectoryAndFormatLayer] 把前两层拼成常驻 system 文本；
/// [resolvePluginDetail]/[resolveMcpDetail]/[resolveSkillDetail] 按需返回详情文本。

/// 一键回退开关：true=按需加载（新行为）；false=回退旧全量注入。
const bool kLazyPluginProtocol = true;

/// 目录层每条摘要的最大字符数（预算截断，主要作用于 MCP 工具 description）。
const int kSummaryMaxLen = 80;

/// 目录层条目，同时承载目录/格式/详情三层所需文本。
class CatalogEntry {
  final String id;
  final String name;
  final String summary;
  final String format;
  final String detail;

  const CatalogEntry({
    required this.id,
    required this.name,
    required this.summary,
    required this.format,
    required this.detail,
  });
}

/// 格式层骨架常量表（宿主协议语法，7 行）。
/// key 为 triggerType 或 mcp_call/skill_call 特例；不进插件 metadata。
const Map<String, String> _kFormatByTrigger = {
  'search':
      '<search query="关键词" depth="basic|advanced" />',
  'download':
      '<download intent="true|false" canonical="应用名" keywords="k1,k2" domains="d1,d2" platform="android|pc" url="直链" type="app|pdf|mp4|jpg|doc|any" query="文件名" />',
  'ask_user': '<ask_user>问题||选项1||选项2</ask_user>',
  'self_check': '<self_check continue="true|false" reason="原因" />',
  'answer': '<answer>最终回复（支持 Markdown）</answer>',
  'mcp_call': '<mcp_call plugin_id="..." tool="...">{JSON 参数对象}</mcp_call>',
  'skill_call': '<skill_call name="skill.xxx">{可选 JSON}</skill_call>',
};

/// 收集目录层条目。
///
/// - 内置 5 插件（source==system）始终收集。
/// - MCP/Skill 按 [hint.mode] 过滤：
///   off 不收集；manual 只收集 [PluginHintConfig.selectedIds] 命中的；
///   auto 收集全部传入的 enabled 插件。
List<CatalogEntry> collectCatalog(
    Iterable<ReActPlugin> enabledPlugins, PluginHintConfig hint) {
  final ordered = enabledPlugins.toList();
  final entries = <CatalogEntry>[];

  // 1. 内置插件（source==system）
  for (final p in ordered) {
    if (p.source != PluginSource.system) continue;
    final m = p.metadata;
    if (m.promptProtocol.isEmpty) continue;
    entries.add(CatalogEntry(
      id: m.id,
      name: m.name,
      summary: _catalogSummary(m),
      format: BuiltinPromptCatalog.instance.resolveFormat(
          p.triggerType, _kFormatByTrigger[p.triggerType] ?? ''),
      detail: m.promptProtocol,
    ));
  }

  if (hint.mode == PluginHintMode.off) return entries;

  final manualSelected = hint.selectedIds.toSet();

  // 2. MCP 插件（每个工具一个条目）
  for (final p in ordered) {
    final m = p.metadata;
    if (!m.kind.isRemote) continue;
    if (hint.mode == PluginHintMode.manual && !manualSelected.contains(m.id)) {
      continue;
    }
    final tools = m.extra['tools'];
    if (tools is! List) continue;
    for (final raw in tools.whereType<Map>()) {
      final tool = Map<String, dynamic>.from(raw);
      final toolName = tool['name']?.toString() ?? '';
      if (toolName.isEmpty) continue;
      final description = (tool['description']?.toString() ?? '').trim();
      final schema = tool['inputSchema'] ?? tool['input_schema'];
      final schemaText = schema is Map ? jsonEncode(schema) : '{}';
      entries.add(CatalogEntry(
        id: 'mcp:${m.id}:$toolName',
        name: toolName,
        summary: _truncate(description.isEmpty ? '无描述' : description,
            kSummaryMaxLen),
        format: _kFormatByTrigger['mcp_call']!,
        detail: _buildMcpDetail(m.id, toolName, description, schemaText),
      ));
    }
  }

  // 3. Skill / 声明式插件（source!=system）
  for (final p in ordered) {
    final m = p.metadata;
    if (!m.kind.isDeclarative) continue;
    if (p.source == PluginSource.system) continue;
    if (hint.mode == PluginHintMode.manual && !manualSelected.contains(m.id)) {
      continue;
    }
    entries.add(CatalogEntry(
      id: m.id,
      name: m.name,
      summary: _skillSummary(m, p.triggerType),
      format: _kFormatByTrigger['skill_call']!,
      detail: m.promptProtocol,
    ));
  }

  return entries;
}

/// 生成「目录层（名字+摘要）+ 格式层（格式骨架）」的常驻 system 文本。
String buildDirectoryAndFormatLayer(List<CatalogEntry> entries) {
  final sb = StringBuffer();
  sb.writeln('=== 可用插件目录 ===');
  if (entries.isEmpty) {
    sb.writeln('（无）');
  } else {
    for (final e in entries) {
      sb.writeln('- [${e.id}] ${e.name}: ${e.summary}');
    }
  }
  // v1.7.36：明确告诉 AI 当前 MCP/Skill 的真实数量，杜绝臆造工具名
  final mcpCount = entries.where((e) => e.id.startsWith('mcp:')).length;
  final skillCount =
      entries.where((e) => !e.id.startsWith('mcp:') && !e.id.startsWith('nexus.builtin.')).length;
  sb.writeln('当前 MCP 工具数：$mcpCount；当前 Skill 数：$skillCount。');
  sb.writeln();
  sb.writeln('=== 调用格式骨架 ===');
  final seen = <String>{};
  var wrote = 0;
  for (final e in entries) {
    if (e.format.isEmpty || seen.contains(e.format)) continue;
    seen.add(e.format);
    sb.writeln(e.format);
    wrote++;
  }
  if (wrote == 0) sb.writeln('（无）');
  sb.writeln();
  // v1.7.36：防幻觉铁律——AI 曾多次臆造 mcp_list / skill_store 等不存在的工具
  sb.writeln('=== 工具真实性铁律 ===');
  sb.writeln('- 你只能使用上面目录中明确列出的插件、MCP 工具和 Skill。');
  sb.writeln('- 目录中不存在的名字（如 mcp_list、skill_store、skill_search 等）都不是真实工具，禁止臆造、禁止调用、禁止向用户声称它们存在。');
  sb.writeln('- 用户问你"装了哪些 MCP/Skill"时，只能依据上面目录如实回答；目录里没有就说没有，不要猜测。');
  return sb.toString();
}

/// 按 name 匹配（先 metadata.id 精确，退化 triggerType）返回完整 promptProtocol。
/// 找不到返回空串。
String resolvePluginDetail(
    String name, Iterable<ReActPlugin> enabledPlugins) {
  if (name.isEmpty) return '';
  final ordered = enabledPlugins.toList();
  for (final p in ordered) {
    if (p.metadata.id == name && p.metadata.promptProtocol.isNotEmpty) {
      return p.metadata.promptProtocol;
    }
  }
  for (final p in ordered) {
    if (p.triggerType == name && p.metadata.promptProtocol.isNotEmpty) {
      return p.metadata.promptProtocol;
    }
  }
  return '';
}

/// 返回该 MCP 工具的 description + inputSchema 文本；找不到返回空串。
String resolveMcpDetail(
    String pluginId, String tool, Iterable<ReActPlugin> enabledPlugins) {
  if (pluginId.isEmpty || tool.isEmpty) return '';
  for (final p in enabledPlugins) {
    if (!p.metadata.kind.isRemote) continue;
    if (p.metadata.id != pluginId) continue;
    final tools = p.metadata.extra['tools'];
    if (tools is! List) return '';
    for (final raw in tools.whereType<Map>()) {
      final t = Map<String, dynamic>.from(raw);
      if (t['name']?.toString() != tool) continue;
      final description = (t['description']?.toString() ?? '').trim();
      final schema = t['inputSchema'] ?? t['input_schema'];
      final schemaText = schema is Map ? jsonEncode(schema) : '{}';
      return _buildMcpDetail(pluginId, tool, description, schemaText);
    }
    return '';
  }
  return '';
}

/// 返回该 Skill 的完整 promptProtocol；找不到返回空串。
String resolveSkillDetail(
    String name, Iterable<ReActPlugin> enabledPlugins) {
  if (name.isEmpty) return '';
  for (final p in enabledPlugins) {
    final m = p.metadata;
    if (!m.kind.isDeclarative) continue;
    if (p.source == PluginSource.system) continue;
    if (m.id == name || m.name == name) return m.promptProtocol;
  }
  return '';
}

// ---- 私有 helper ----

String _catalogSummary(PluginMetadata m) {
  final override = m.extra['catalogSummary']?.toString() ?? '';
  if (override.isNotEmpty) return _truncate(override, kSummaryMaxLen);
  return _truncate(m.description, kSummaryMaxLen);
}

String _skillSummary(PluginMetadata m, String triggerType) {
  final extraSummary = m.extra['skillSummary']?.toString() ?? '';
  if (extraSummary.isNotEmpty) {
    return _truncate(extraSummary, kSummaryMaxLen);
  }
  return '${m.name} | type=$triggerType | 触发: 当涉及"${_truncate(m.description, 20)}"';
}

String _buildMcpDetail(
    String pluginId, String toolName, String description, String schemaText) {
  return 'MCP 工具 $toolName (plugin_id=$pluginId)\n'
      '说明: ${description.isEmpty ? '无描述' : description}\n'
      'inputSchema: $schemaText';
}

String _truncate(String s, int maxLen) {
  if (s.length <= maxLen) return s;
  return '${s.substring(0, maxLen)}…';
}
