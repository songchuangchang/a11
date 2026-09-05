import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:aichat/plugins/plugin_registry.dart';
import 'package:aichat/screens/plugin_market_screen.dart';

void main() {
  testWidgets('renders plugin market built-in catalog and search field',
      (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => PluginRegistry(),
        child: const MaterialApp(home: PluginMarketScreen()),
      ),
    );
    await tester.pump();
    expect(find.textContaining('插件市场'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('AI 实时翻译助手'), findsOneWidget);
    expect(find.text('超级计算器'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '计算');
    await tester.pump();
    expect(find.text('超级计算器'), findsOneWidget);
    expect(find.text('AI 实时翻译助手'), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
  });
}
