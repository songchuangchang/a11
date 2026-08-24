import 'package:flutter_test/flutter_test.dart';
import 'package:aichat/main.dart';

void main() {
  testWidgets('App boots without error', (WidgetTester tester) async {
    await tester.pumpWidget(const AIChatApp());
    // Just verify no crash on startup. The app shows either onboarding
    // (language picker) or a loading indicator while SharedPreferences loads.
    expect(find.byType(AIChatApp), findsOneWidget);
  });
}
