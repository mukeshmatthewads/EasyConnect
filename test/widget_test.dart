import 'package:flutter_test/flutter_test.dart';

import 'package:indian_nagish/main.dart';

void main() {
  testWidgets('App bar title is shown', (WidgetTester tester) async {
    await tester.pumpWidget(const DDConnectApp());

    // Check for the app bar title
    expect(find.text('D&D Login'), findsOneWidget);
  });
}