import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../models/mcp_market_models.dart';
import '../services/logger_service.dart';
import '../services/mcp_client_service.dart';
import 'plugin_context.dart';
import 'plugin_interface.dart';

class InstalledMcpPlugin extends ReActPlugin {
  final PluginMetadata _meta;
  final McpClientService _client;
  final String _endpoint;

  InstalledMcpPlugin(
      {required PluginMetadata metadata, McpClientService? client})
      : _meta = metadata,
        _client = client ?? McpClientService(),
        _endpoint = metadata.extra['endpoint']?.toString() ?? '' {
    if (_endpoint.isEmpty) {
      throw const FormatException('MCP endpoint is required');
    }
  }

  factory InstalledMcpPlugin.fromMetadata(PluginMetadata metadata) {
    if (!metadata.kind.isRemote) {
      throw const FormatException('Plugin metadata is not an MCP plugin');
    }
    return InstalledMcpPlugin(metadata: metadata);
  }

  @override
  String get triggerType => 'mcp_call';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.installed;

  @override
  PluginMetadata get metadata => _meta;

  List<Map<String, dynamic>> get tools {
    final raw = _meta.extra['tools'];
    return raw is List
        ? raw.whereType<Map>().map(Map<String, dynamic>.from).toList()
        : const [];
  }

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    if (attrs['pluginId']?.toString() != _meta.id) return;
    final tool = attrs['tool']?.toString().trim() ?? '';
    final rawArgs = attrs['arguments']?.toString() ?? '{}';
    final startedAt = Stopwatch()..start();
    ReasoningStep? activity;
    void finish({required String status, String? summary, String? text}) {
      startedAt.stop();
      pc.updateReasoningStep(
        activity,
        latencyMs: startedAt.elapsedMilliseconds,
        status: status,
        resultSummary: summary ?? text,
      );
    }

    activity = pc.addReasoningStep(
      'mcp_call',
      'MCP ${_meta.name} · $tool',
      pluginId: _meta.id,
      pluginName: _meta.name,
      toolName: tool.isEmpty ? null : tool,
      arguments: rawArgs,
      status: 'running',
    );
    // v1.7.9 (M14 修复)：工具名不存在时不再 throw（此前异常被 dispatch 静默吞掉，
    // AI 收不到任何反馈 → 幻觉工具名反复重试耗尽轮次），改为注入错误 toolresult
    if (tool.isEmpty || !tools.any((t) => t['name']?.toString() == tool)) {
      LoggerService.instance.warn(
        '[MCP] 工具不存在: plugin=${_meta.id}, tool=$tool, available=${tools.map((t) => t['name']).join(',')}',
        tag: 'MCP',
      );
      final message = 'MCP tool "$tool" not found. Available tools: ${tools.map((t) => t['name']).join(', ')}. 请改用列表中的工具名。';
      finish(status: 'not_found', text: message);
      pc.addMessage(_toolMessage(pc, tool.isEmpty ? '(empty)' : tool, message));
      return;
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(rawArgs);
    } catch (_) {
      const message = 'MCP arguments must be a JSON object';
      finish(status: 'invalid', text: message);
      pc.addMessage(_toolMessage(pc, tool, message));
      return;
    }
    if (decoded is! Map) {
      const message = 'MCP arguments must be a JSON object';
      finish(status: 'invalid', text: message);
      pc.addMessage(_toolMessage(pc, tool, message));
      return;
    }

    // v1.7.2 安全改进：危险工具调用前弹窗确认
    if (McpDangerousTools.isDangerous(tool)) {
      final confirmed = await _showDangerousToolConfirmation(context, tool, rawArgs);
      if (!confirmed) {
        const message = '用户拒绝执行此危险操作';
        finish(status: 'rejected', text: message);
        pc.addMessage(_toolMessage(pc, tool, message));
        return;
      }
    }

    // v1.7.2 安全改进：MCP 日志记录
    LoggerService.instance.info(
      '[MCP] 调用工具: plugin=${_meta.id}, tool=$tool, args=$rawArgs',
      tag: 'MCP',
    );

    try {
      final result = await _client.toolsCall(
          _endpoint, tool, Map<String, dynamic>.from(decoded));
      final text = jsonEncode(result);
      // v1.7.1 fix C1: MCP 工具结果上限从 65536 改为 4000 字符，避免撑爆 LLM 上下文
      final limited =
          text.length > 4000 ? '${text.substring(0, 4000)}…[已截断，原始长度 ${text.length}]' : text;

      // v1.7.2 安全改进：MCP 日志记录
      LoggerService.instance.info(
        '[MCP] 工具调用成功: plugin=${_meta.id}, tool=$tool, result_length=${text.length}',
        tag: 'MCP',
      );

      finish(status: 'success', summary: limited);
      pc.addMessage(_toolMessage(pc, tool, limited));
    } catch (e) {
      // v1.7.2 安全改进：MCP 日志记录
      LoggerService.instance.error(
        '[MCP] 工具调用失败: plugin=${_meta.id}, tool=$tool, error=$e',
        tag: 'MCP',
      );

      // M-1 修复：工具调用失败要作为可读错误回传给 AI，避免静默无反馈导致反复重试。
      final message = 'MCP tool "$tool" failed: ${e.toString()}';
      finish(status: 'failed', text: message);
      pc.addMessage(_toolMessage(pc, tool, message));
    }
  }

  /// v1.7.2 安全改进：危险工具调用确认弹窗
  Future<bool> _showDangerousToolConfirmation(
      BuildContext context, String tool, String args) async {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: cs.tertiary, size: 28),
            const SizedBox(width: 8),
            Text(isZh ? '危险操作确认' : 'Dangerous Operation'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isZh
                    ? '⚠️ AI 想要调用一个危险工具：'
                    : '⚠️ AI wants to call a dangerous tool:',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.tertiary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.tertiary.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${isZh ? '工具名称' : 'Tool'}: $tool'),
                    const SizedBox(height: 4),
                    Text('${isZh ? '参数' : 'Arguments'}: $args'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                McpDangerousTools.getWarning(tool, isZh: isZh),
                style: TextStyle(
                  color: cs.tertiary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                isZh
                    ? '此操作可能执行破坏性行为（删除文件、执行命令、修改数据库等）。请确认你了解此操作的风险。'
                    : 'This operation may perform destructive actions (delete files, execute commands, modify databases, etc.). Please confirm you understand the risks.',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isZh ? '拒绝' : 'Deny'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: cs.tertiary,
            ),
            child: Text(isZh ? '允许一次' : 'Allow Once'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  ChatMessage _toolMessage(PluginContext pc, String tool, String text) {
    return ChatMessage.create(
      conversationId:
          pc.userMsg?.conversationId ?? pc.assistantMsg.conversationId,
      role: MessageRole.user,
      content:
          '<toolresult plugin_id="${_escape(_meta.id)}" tool="${_escape(tool)}">${_escape(text)}</toolresult>',
    );
  }

  String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  void close() => _client.close();
}
