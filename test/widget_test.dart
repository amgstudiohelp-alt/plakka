import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plakka/main.dart';

void main() {
  testWidgets('applies only top safe area padding', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            padding: EdgeInsets.only(top: 44, bottom: 34),
            viewPadding: EdgeInsets.only(top: 44, bottom: 34),
          ),
          child: PlakkaWebView(connectivityCheck: () async => false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final safeBodyPadding = tester.widget<Padding>(
      find.byKey(const ValueKey('topSafeBodyPadding')),
    );

    expect(safeBodyPadding.padding, const EdgeInsets.only(top: 44));
  });

  testWidgets('shows offline screen when internet is unavailable', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PlakkaApp(connectivityCheck: () async => false));
    await tester.pumpAndSettle();

    expect(find.text('Internet baglantisi yok'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
  });
}
