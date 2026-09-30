import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/views/warp/warp_controller.dart';

void main() {
  group('WarpController scan cap', () {
    test('oversized selection is refused with an error, never scanned',
        () async {
      final controller = WarpController();
      // 4 ranges x 256 ips x 22 ports = way over the 4096 cap.
      for (int p = 1; p <= 22; p++) {
        controller.selectedPorts.add(1000 + p);
      }
      expect(controller.plannedCount, greaterThan(4096));

      controller.start();
      // Give any accidental async scan a chance to start.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(controller.isRunning, isFalse);
      expect(controller.progress.error, isNotNull);
      expect(controller.progress.tested, 0);
      controller.dispose();
    });
  });
}
