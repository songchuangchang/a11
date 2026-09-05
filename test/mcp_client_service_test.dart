import 'dart:convert';

import 'package:aichat/models/mcp_market_models.dart';
import 'package:aichat/services/mcp_client_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
      'discoverTools follows tools/list cursor pagination and preserves session',
      () async {
    final requests = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      requests.add(payload);
      if (payload['method'] == 'initialize') {
        return _rpcResponse(payload, {}, headers: {'mcp-session-id': 's1'});
      }
      if (payload['method'] == 'notifications/initialized') {
        return http.Response('', 202);
      }
      final cursor = (payload['params'] as Map)['cursor'];
      final result = cursor == null
          ? {
              'tools': [_tool('one')],
              'nextCursor': 'page-2',
            }
          : {
              'tools': [_tool('two')],
            };
      expect(request.headers['mcp-session-id'], 's1');
      return _rpcResponse(payload, result);
    });

    final service = McpClientService(client: client);
    final tools = await service.discoverTools('https://example.com/mcp');

    expect(tools.map((tool) => tool['name']), ['one', 'two']);
    expect(requests.where((request) => request['method'] == 'tools/list'),
        hasLength(2));
    expect((requests.last['params'] as Map)['cursor'], 'page-2');
  });

  test('decodes a multi-line SSE response', () async {
    final client = MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      if (payload['method'] == 'notifications/initialized') {
        return http.Response('', 202);
      }
      final result = payload['method'] == 'tools/list'
          ? {
              'tools': [_tool('known')]
            }
          : <String, dynamic>{};
      final encoded = jsonEncode({
        'jsonrpc': '2.0',
        'id': payload['id'],
        'result': result,
      });
      final splitAt = encoded.indexOf(',') + 1;
      return http.Response(
        'data: ${encoded.substring(0, splitAt)}\n'
        'data: ${encoded.substring(splitAt)}\n\n',
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    final service = McpClientService(client: client);
    final tools = await service.discoverTools('https://example.com/mcp');

    expect(tools.single['name'], 'known');
  });

  test('rejects JSON-RPC errors and mismatched response ids', () async {
    for (final responseBody in [
      {'jsonrpc': '2.0', 'id': 999, 'result': <String, dynamic>{}},
      {
        'jsonrpc': '2.0',
        'id': 1,
        'error': {'code': -32600, 'message': 'invalid request'}
      },
    ]) {
      final service = McpClientService(
        client: MockClient((_) async => http.Response(
              jsonEncode(responseBody),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );

      await expectLater(
        service.discoverTools('https://example.com/mcp'),
        throwsA(isA<Exception>()),
      );
    }
  });

  test('rejects an oversized response', () async {
    final service = McpClientService(
      client: MockClient((_) async => http.Response(
            'x' * (McpClientService.maxResponseBytes + 1),
            200,
            headers: {'content-type': 'application/json'},
          )),
    );

    await expectLater(
      service.discoverTools('https://example.com/mcp'),
      throwsA(isA<Exception>()),
    );
  });

  test('rejects invalid, duplicate, and excessive tool definitions', () async {
    final invalidTools = <List<dynamic>>[
      [
        {'name': 'bad tool', 'inputSchema': <String, dynamic>{}}
      ],
      [_tool('same'), _tool('same')],
      List.generate(
        McpToolDefinition.maxToolCount + 1,
        (index) => _tool('tool$index'),
      ),
    ];

    for (final tools in invalidTools) {
      final service = McpClientService(
        client: _discoveryClient({'tools': tools}),
      );
      await expectLater(
        service.discoverTools('https://example.com/mcp'),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('rejects deeply nested input schemas', () {
    dynamic nested = 'leaf';
    for (var index = 0; index < 14; index++) {
      nested = <String, dynamic>{'value': nested};
    }

    expect(
      () => McpToolDefinition.fromJson({
        'name': 'deep',
        'inputSchema': nested,
      }),
      throwsA(isA<McpModelFormatException>()),
    );
  });

  test('rejects invalid and repeated tools/list cursors', () async {
    for (final nextCursor in <dynamic>['', 42, 'x' * 501]) {
      final service = McpClientService(
        client: _discoveryClient({
          'tools': [_tool('known')],
          'nextCursor': nextCursor,
        }),
      );
      await expectLater(
        service.discoverTools('https://example.com/mcp'),
        throwsA(isA<FormatException>()),
      );
    }

    var page = 0;
    final service = McpClientService(
      client: _discoveryClient(() {
        page++;
        return {
          'tools': [_tool('tool$page')],
          'nextCursor': 'same',
        };
      }),
    );
    await expectLater(
      service.discoverTools('https://example.com/mcp'),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects toolsCall outside discovered schema', () async {
    final service = McpClientService(
      client: _discoveryClient({
        'tools': [_tool('known')]
      }),
    );
    await service.discoverTools('https://example.com/mcp');

    await expectLater(
      service.toolsCall('https://example.com/mcp', 'unknown', {}),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects non-public endpoints', () {
    final service = McpClientService(
      client: MockClient((_) async => http.Response('', 500)),
    );
    for (final endpoint in [
      'http://example.com',
      'https://localhost/mcp',
      'https://127.0.0.1/mcp',
      'https://10.0.0.1/mcp',
      'https://[::1]/mcp',
      'https://service.local/mcp',
      'https://example.com/a#fragment',
      'https://[::ffff:127.0.0.1]/mcp',
      'https://[::ffff:10.0.0.1]/mcp',
      'https://[::ffff:192.168.1.1]/mcp',
    ]) {
      expect(
        () => service.validateEndpointForTesting(endpoint),
        throwsFormatException,
      );
    }
  });

  test('rejects a private redirect target before sending the next hop',
      () async {
    var sendCount = 0;
    final client = MockClient((request) async {
      sendCount++;
      return http.Response(
        '',
        302,
        headers: {'location': 'https://127.0.0.1/mcp'},
      );
    });
    final service = McpClientService(client: client);

    await expectLater(
      service.discoverTools('https://example.com/mcp'),
      throwsA(isA<FormatException>()),
    );
    expect(sendCount, 1);
  });

  test('limits redirect hops', () async {
    var sendCount = 0;
    final client = MockClient((request) async {
      sendCount++;
      return http.Response(
        '',
        307,
        headers: {'location': '/hop$sendCount'},
      );
    });
    final service = McpClientService(client: client);

    await expectLater(
      service.discoverTools('https://example.com/mcp'),
      throwsA(isA<FormatException>()),
    );
    expect(sendCount, McpClientService.maxRedirects + 1);
  });

  test('closeSession sends DELETE with the current session id', () async {
    final methods = <String>[];
    final client = MockClient((request) async {
      methods.add(request.method);
      if (request.method == 'DELETE') {
        expect(request.headers['mcp-session-id'], 'session-1');
        return http.Response('', 204);
      }
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      if (payload['method'] == 'notifications/initialized') {
        return http.Response('', 202);
      }
      final result = payload['method'] == 'tools/list'
          ? {
              'tools': [_tool('known')]
            }
          : <String, dynamic>{};
      return _rpcResponse(
        payload,
        result,
        headers: payload['method'] == 'initialize'
            ? {'mcp-session-id': 'session-1'}
            : const {},
      );
    });
    final service = McpClientService(client: client);
    await service.discoverTools('https://example.com/mcp');

    await service.closeSession();
    await service.closeSession();

    expect(methods.where((method) => method == 'DELETE'), hasLength(1));
  });

  test('toolsCall performs initialize handshake before first call', () async {
    final methods = <String>[];
    final client = MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      methods.add(payload['method'] as String);
      if (payload['method'] == 'notifications/initialized') {
        return http.Response('', 202);
      }
      if (payload['method'] == 'initialize') {
        return _rpcResponse(payload, {}, headers: {'mcp-session-id': 's1'});
      }
      if (payload['method'] == 'tools/list') {
        return _rpcResponse(payload, {
          'tools': [
            {'name': 'any-tool', 'description': 'test', 'inputSchema': {'type': 'object'}}
          ]
        });
      }
      expect(request.headers['mcp-session-id'], 's1');
      return _rpcResponse(payload, {'content': 'ok'});
    });

    final service = McpClientService(client: client);
    final result =
        await service.toolsCall('https://example.com/mcp', 'any-tool', {});

    expect(result, 'ok');
    expect(methods, ['initialize', 'notifications/initialized', 'tools/list', 'tools/call']);
  });
}

MockClient _discoveryClient(dynamic toolsListResult) {
  return MockClient((request) async {
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    if (payload['method'] == 'notifications/initialized') {
      return http.Response('', 202);
    }
    final result = payload['method'] == 'tools/list'
        ? (toolsListResult is Function ? toolsListResult() : toolsListResult)
        : <String, dynamic>{};
    return _rpcResponse(payload, result as Map<String, dynamic>);
  });
}

http.Response _rpcResponse(
  Map<String, dynamic> request,
  Map<String, dynamic> result, {
  Map<String, String> headers = const {},
}) {
  return http.Response(
    jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    200,
    headers: {'content-type': 'application/json', ...headers},
  );
}

Map<String, dynamic> _tool(String name) => {
      'name': name,
      'description': 'test',
      'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
    };
