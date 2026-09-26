import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/core/i18n/app_strings.dart';
import 'package:netstudio/core/theme/app_colors.dart';
import 'package:netstudio/models/ping_metric.dart';
import 'package:netstudio/views/ping_matrix/widgets/latency_heatmap_indicator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AppStrings.ensureLoaded());

  const translations = {
    'en': (
      loss: 'LOSS',
      pending: 'Pending, round-trip time not yet available',
      offline: 'Offline, packet loss, round-trip time unavailable',
      online: 'Online, round-trip time 42.3 milliseconds',
      degraded: 'Degraded, round-trip time 42.3 milliseconds',
    ),
    'fa': (
      loss: 'اتلاف',
      pending: 'در انتظار، زمان رفت و برگشت هنوز در دسترس نیست',
      offline: 'آفلاین، اتلاف بسته، زمان رفت و برگشت در دسترس نیست',
      online: 'آنلاین، زمان رفت و برگشت 42.3 میلی‌ثانیه',
      degraded: 'کند، زمان رفت و برگشت 42.3 میلی‌ثانیه',
    ),
    'ru': (
      loss: 'ПОТЕРЯ',
      pending: 'Ожидание, время приёма-передачи пока недоступно',
      offline: 'Не в сети, потеря пакета, время приёма-передачи недоступно',
      online: 'В сети, время приёма-передачи 42.3 миллисекунд',
      degraded: 'Деградация, время приёма-передачи 42.3 миллисекунд',
    ),
    'zh': (
      loss: '丢包',
      pending: '等待中，往返时间尚不可用',
      offline: '离线，丢包，往返时间不可用',
      online: '在线，往返时间 42.3 毫秒',
      degraded: '降级，往返时间 42.3 毫秒',
    ),
  };

  for (final locale in translations.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('${locale.key} $brightness badge and semantics', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        try {
          final cases = [
            (
              status: TargetStatus.pending,
              rtt: 0.0,
              text: '---',
              label: locale.value.pending,
            ),
            (
              status: TargetStatus.pending,
              rtt: -1.0,
              text: '---',
              label: locale.value.pending,
            ),
            (
              status: TargetStatus.offline,
              rtt: -1.0,
              text: locale.value.loss,
              label: locale.value.offline,
            ),
            (
              status: TargetStatus.online,
              rtt: 42.34,
              text: '42.3 ms',
              label: locale.value.online,
            ),
            (
              status: TargetStatus.degraded,
              rtt: 42.34,
              text: '42.3 ms',
              label: locale.value.degraded,
            ),
          ];
          for (final sample in cases) {
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(locale.key),
                supportedLocales: AppStrings.supportedLocales,
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                theme: ThemeData(brightness: brightness),
                home: Scaffold(
                  body: Center(
                    child: LatencyHeatmapIndicator(
                      status: sample.status,
                      latencyMs: sample.rtt,
                      lossRate: 0,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text(sample.text), findsOneWidget);
            final labelFinder = find.bySemanticsLabel(sample.label);
            expect(labelFinder, findsOneWidget);
            final node = tester.getSemantics(labelFinder);
            expect(node.label, sample.label);
            expect(
              node.childrenCount,
              0,
              reason: 'Badge text must not be read twice',
            );
            expect(
              node.textDirection,
              locale.key == 'fa' ? TextDirection.rtl : TextDirection.ltr,
            );
            final text = tester.widget<Text>(find.text(sample.text));
            expect(
              text.style!.color,
              sample.status == TargetStatus.pending
                  ? AppColors.pending
                  : AppColors.getLatencyColor(sample.rtt, 0),
            );
            expect(tester.takeException(), isNull);
          }
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
