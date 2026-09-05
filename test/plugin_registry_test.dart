import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aichat/models/chat_message.dart';
import 'package:aichat/models/mcp_market_models.dart';
import 'package:aichat/models/web_search_config.dart';
import 'package:aichat/plugins/installed_dynamic_plugin.dart';
import 'package:aichat/plugins/installed_mcp_plugin.dart';
import 'package:aichat/plugins/plugin_context.dart';
import 'package:aichat/plugins/plugin_interface.dart';
import 'package:aichat/plugins/plugin_registry.dart';
import 'package:aichat/services/mcp_client_service.dart';

void main() {
  testWidgets('routes mcp_call only to matching enabled MCP plugin',
      (tester) async {
    final client = McpClientService(client: MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      if (payload['method'] == 'notifications/initialized') {
        return http.Response('', 202);
      }
      final result = payload['method'] == 'tools/list'
          ? {
              'tools': [_tool('ping')]
            }
          : {'content': 'pong'};
      return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': payload['id'], 'result': result}),
          200,
          headers: {'content-type': 'application/json'});
    }));
    await client.discoverTools('https://example.com/mcp');
    final plugin = InstalledMcpPlugin(metadata: _metadata(), client: client);
    final registry = PluginRegistry();
    registry.register(plugin);
    final pc = _context();

    expect(
        await registry.dispatch(
            tester.element(find.byType(Container)),
            pc,
            'mcp_call',
            {'pluginId': 'mcp.registry', 'tool': 'ping', 'arguments': '{}'}),
        isFalse);
    registry.register(_EnabledMcpPlugin(
        metadata: _metadata().copyWith(id: 'other'), client: client));
    expect(
        await registry.dispatch(
            tester.element(find.byType(Container)),
            pc,
            'mcp_call',
            {'pluginId': 'other', 'tool': 'ping', 'arguments': '{}'}),
        isTrue);
    expect(pc.workingMessages, hasLength(1));

    expect(
        await registry.dispatch(
            tester.element(find.byType(Container)),
            pc,
            'mcp_call',
            {'pluginId': 'missing', 'tool': 'ping', 'arguments': '{}'}),
        isFalse);
    await tester.pump(const Duration(milliseconds: 300));
  });

  test('protects system plugins from uninstall', () async {
    final registry = PluginRegistry();
    registry.register(_SystemMcpPlugin());
    await expectLater(
        registry.uninstall('system.mcp'), throwsA(isA<StateError>()));
    expect(registry.getById('system.mcp'), isNotNull);
  });

  test('installRemoteMcp rejects a conflicting non-MCP plugin', () async {
    final registry = PluginRegistry();
    registry.register(InstalledDynamicPlugin(
      metadata: const PluginMetadata(
          id: 'mcp.conflict',
          name: 'Conflict',
          version: '1',
          author: 'test',
          description: 'declarative'),
    ));
    final server = McpRegistryServer(
      name: 'mcp.conflict',
      title: 'Conflict',
      description: 'declarative conflict',
      version: '1',
      status: 'active',
      endpoint: Uri.parse('https://example.com/mcp'),
      transportType: 'streamable-http',
    );
    await expectLater(
        registry.installRemoteMcp(server), throwsA(isA<FormatException>()));
    expect(registry.getById('mcp.conflict'), isNotNull);
  });
}

PluginContext _context() => PluginContext(
      workingMessages: [],
      assistantMsg: ChatMessage.create(
          conversationId: 'c', role: MessageRole.assistant, content: ''),
      webSearchCfg: WebSearchConfig(),
    );

PluginMetadata _metadata() => PluginMetadata(
      id: 'mcp.registry',
      name: 'Registry MCP',
      version: '1',
      author: 'test',
      description: 'test',
      kind: PluginKind.mcpRemote,
      triggerType: 'mcp_call',
      extra: {
        'endpoint': 'https://example.com/mcp',
        'tools': [_tool('ping')]
      },
    );
Map<String, dynamic> _tool(String name) => {
      'name': name,
      'inputSchema': {'type': 'object'}
    };

class _EnabledMcpPlugin extends InstalledMcpPlugin {
  _EnabledMcpPlugin({required super.metadata, required super.client});

  @override
  PluginSource get source => PluginSource.system;
}

class _SystemMcpPlugin extends InstalledMcpPlugin {
  _SystemMcpPlugin()
      : super(
            metadata: PluginMetadata(
          id: 'system.mcp',
          name: 'System MCP',
          version: '1',
          author: 'system',
          description: 'system',
          kind: PluginKind.mcpRemote,
          triggerType: 'mcp_call',
          extra: {
            'endpoint': 'https://example.com/mcp',
            'tools': [_tool('ping')]
          },
        ));
  @override
  PluginSource get source => PluginSource.system;
}
