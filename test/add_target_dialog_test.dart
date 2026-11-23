import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:netstudio/core/i18n/app_strings.dart';
import 'package:netstudio/models/ping_target.dart';
import 'package:netstudio/views/ping_matrix/widgets/add_target_dialog.dart';

void main() {
  setUpAll(() async {
    await AppStrings.ensureLoaded();
  });

  Future<void> openDialog(
    WidgetTester tester, {
    void Function(PingTarget)? onAdd,
    PingTarget? initial,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => AddTargetDialog(
                    onAdd: onAdd ?? (_) {},
                    initial: initial,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  void useDesktopSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('renders an editable timeout field with the 1500 default',
      (tester) async {
    useDesktopSurface(tester);
    await openDialog(tester);

    expect(find.text('Timeout (ms)'), findsOneWidget);
    final field = tester.widget<TextFormField>(
      find.byKey(const Key('targetTimeoutField')),
    );
    expect(field.controller?.text, '1500');
  });

  testWidgets('rejects timeouts outside 100-10000 and submits a valid value',
      (tester) async {
    useDesktopSurface(tester);
    PingTarget? added;
    await openDialog(tester, onAdd: (target) => added = target);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Test target');
    await tester.enterText(fields.at(1), '1.1.1.1');
    final timeoutField = find.byKey(const Key('targetTimeoutField'));

    await tester.enterText(timeoutField, '99');
    await tester.tap(find.text('Add to matrix'));
    await tester.pumpAndSettle();
    expect(find.text('100-10000'), findsOneWidget);
    expect(added, isNull);

    await tester.enterText(timeoutField, '10001');
    await tester.tap(find.text('Add to matrix'));
    await tester.pumpAndSettle();
    expect(added, isNull);

    await tester.enterText(timeoutField, '5000');
    await tester.tap(find.text('Add to matrix'));
    await tester.pumpAndSettle();
    expect(added, isNotNull);
    expect(added!.timeoutMs, 5000);
  });

  testWidgets('editing pre-fills the existing timeout', (tester) async {
    useDesktopSurface(tester);
    await openDialog(
      tester,
      initial: const PingTarget(
        id: 1,
        name: 'Existing',
        host: '1.1.1.1',
        timeoutMs: 4200,
      ),
    );

    final field = tester.widget<TextFormField>(
      find.byKey(const Key('targetTimeoutField')),
    );
    expect(field.controller?.text, '4200');
  });
}
