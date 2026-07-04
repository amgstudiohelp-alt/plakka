import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plakka/main.dart';

void main() {
  testWidgets('shows offline screen when internet is unavailable', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PlakkaApp(connectivityCheck: () async => false));
    await tester.pumpAndSettle();

    expect(find.text('Internet baglantisi yok'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
  });
}
