import 'dart:io';

/// Leaf TCP connect used by the Warp Dart-fallback prober.
/// Kept in its own file so warp_controller.dart stays analyzer-clean.
Future<Socket> warpSocketConnectImpl(String host, int port, int ms) {
  return Socket.connect(host, port,
      timeout: Duration(milliseconds: ms));
}
