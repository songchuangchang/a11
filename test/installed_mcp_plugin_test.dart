import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aichat/models/chat_message.dart';
import 'package:aichat/models/web_search_config.dart';
import 'package:aichat/plugins/installed_mcp_plugin.dart';
import 'package:aichat/plugins/plugin_context.dart';
import 'package:aichat/plugins/plugin_interface.dart';
import 'package:aichat/services/mcp_client_service.dart';

void main() {
  testWidgets('validates tool and escapes tool result XML', (tester) async {
    final client = McpClientService(client: MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      if (payload['method'] == 'notifications/initialized') {
        return http.Response('', 202);
      }
      final result = payload['method'] == 'tools/list'
          ? {
              'tools': [_tool('echo')]
            }
          : {'content': '<x attr="1">& ok'};
      return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': payload['id'], 'result': result}),
          200,
          headers: {'content-type': 'application/json'});
    }));
    await client.discoverTools('https://example.com/mcp');
    final plugin = InstalledMcpPlugin(
      metadata: _metadata(),
      client: client,
    );
    final assistant = ChatMessage.create(
        conversationId: 'c1', role: MessageRole.assistant, content: '');
    final pc = PluginContext(
        workingMessages: [],
        assistantMsg: assistant,
        webSearchCfg: WebSearchConfig());

    await plugin.handle(tester.element(find.byType(Container)), pc, {
      'pluginId': 'mcp.test',
      'tool': 'echo',
      'arguments': '{}',
    });

    expect(pc.workingMessages, hasLength(1));
    expect(pc.workingMessages.single.content,
        contains('&quot;&lt;x attr=\\&quot;1\\&quot;&gt;&amp; ok'));
    expect(pc.workingMessages.single.content, contains('plugin_id="mcp.test"'));
    await expectLater(
        plugin.handle(tester.element(find.byType(Container)), pc,
            {'pluginId': 'mcp.test', 'tool': 'missing', 'arguments': '{}'}),
        throwsA(isA<FormatException>()));
  });

  test('rejects non-MCP metadata and malformed arguments', () {
    expect(
        () => InstalledMcpPlugin.fromMetadata(const PluginMetadata(
            id: 'wrong',
            name: 'Wrong',
            version: '1',
            author: 'a',
            description: 'd')),
        throwsA(isA<FormatException>()));
  });

  testWidgets('appends a readable error when tool call fails', (tester) async {
    final client = McpClientService(client: MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      final method = payload['method'];
      if (method == 'notifications/initialized') {
        return http.Response('', 202);
      }
      if (method == 'initialize') {
        return http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': payload['id'], 'result': {}}),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (method == 'tools/call') {
        return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': payload['id'],
              'error': {'code': -32000, 'message': 'remote boom'}
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('', 500);
    }));
    final plugin = InstalledMcpPlugin(metadata: _metadata(), client: client);
    final assistant = ChatMessage.create(
        conversationId: 'c1', role: MessageRole.assistant, content: '');
    final pc = PluginContext(
        workingMessages: [],
        assistantMsg: assistant,
        webSearchCfg: WebSearchConfig());

    await plugin.handle(tester.element(find.byType(Container)), pc, {
      'pluginId': 'mcp.test',
      'tool': 'echo',
      'arguments': '{}',
    });

    expect(pc.workingMessages, hasLength(1));
    expect(pc.workingMessages.single.content, contains('remote boom'));
  });
}

PluginMetadata _metadata() => PluginMetadata(
      id: 'mcp.test',
      name: 'MCP Test',
      version: '1',
      author: 'test',
      description: 'test',
      kind: PluginKind.mcpRemote,
      triggerType: 'mcp_call',
      extra: {
        'endpoint': 'https://example.com/mcp',
        'tools': [_tool('echo')]
      },
    );

Map<String, dynamic> _tool(String name) => {
      'name': name,
      'description': 'test',
      'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
    };
