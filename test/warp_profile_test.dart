import 'package:flutter_test/flutter_test.dart';
import 'package:netstudio/models/warp_profile.dart';
import 'package:netstudio/views/warp/warp_controller.dart';

/// WireGuard's canonical example key pair (32-byte base64) — stable, not
/// a real deployed identity.
const _privateKey = 'yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=';
const _publicKey = 'xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=';

String _conf({
  String privateKey = _privateKey,
  String publicKey = _publicKey,
  String endpoint = 'engage.cloudflareclient.com:2408',
  String address = '172.16.0.2/32, 2606:4700:110:8a36:df92:102a:9602:fa18/128',
}) =>
    '''
[Interface]
PrivateKey = $privateKey
Address = $address
DNS = 1.1.1.1

[Peer]
PublicKey = $publicKey
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $endpoint
''';

void main() {
  group('WarpProfile.parse', () {
    test('parses a wgcf-style profile', () {
      final result = WarpProfile.parse(_conf());
      expect(result.ok, isTrue, reason: result.error);
      final p = result.profile!;
      expect(p.privateKey, _privateKey);
      expect(p.publicKey, _publicKey);
      expect(p.privateKeyBytes, hasLength(32));
      expect(p.publicKeyBytes, hasLength(32));
      expect(p.endpointHost, 'engage.cloudflareclient.com');
      expect(p.endpointPort, 2408);
      expect(p.displayEndpoint, 'engage.cloudflareclient.com:2408');
      expect(p.addresses, hasLength(2));
      expect(p.isCloudflareWarp, isFalse);
    });

    test('recognizes Cloudflare WARP peer key', () {
      final result = WarpProfile.parse(_conf(publicKey: kWarpDefaultPeerKey));
      expect(result.ok, isTrue, reason: result.error);
      expect(result.profile!.isCloudflareWarp, isTrue);
    });

    test('bracketed IPv6 endpoint loses brackets', () {
      final result =
          WarpProfile.parse(_conf(endpoint: '[2606:4700:d0::a29f:c001]:2408'));
      expect(result.ok, isTrue, reason: result.error);
      expect(result.profile!.endpointHost, '2606:4700:d0::a29f:c001');
      expect(result.profile!.endpointPort, 2408);
      expect(result.profile!.displayEndpoint, '[2606:4700:d0::a29f:c001]:2408');
    });

    test('bare IPv6 endpoint without port is rejected', () {
      final result =
          WarpProfile.parse(_conf(endpoint: '2606:4700:d0::a29f:c001'));
      expect(result.ok, isFalse);
      expect(result.error, contains('Endpoint'));
    });

    test('missing port defaults to 51820', () {
      final result = WarpProfile.parse(_conf(endpoint: 'vpn.example.com'));
      expect(result.ok, isTrue, reason: result.error);
      expect(result.profile!.endpointPort, 51820);
    });

    test('handles CRLF, BOM, case-insensitive keys and inline comments', () {
      final raw = '\uFEFF${_conf(endpoint: '1.2.3.4:51820 # primary')}'
          .replaceAll('\n', '\r\n')
          .replaceAll('PrivateKey', 'privatekey')
          .replaceAll('PublicKey', 'PUBLICKEY');
      final result = WarpProfile.parse(raw);
      expect(result.ok, isTrue, reason: result.error);
      expect(result.profile!.endpointHost, '1.2.3.4');
      expect(result.profile!.endpointPort, 51820);
    });

    test('missing sections and malformed keys are rejected with reasons', () {
      expect(WarpProfile.parse('PrivateKey = $_privateKey').error,
          contains('[Interface]'));
      expect(WarpProfile.parse('[Interface]\nPrivateKey = $_privateKey').error,
          contains('[Peer]'));
      expect(
          WarpProfile.parse(
                  '[Interface]\nPrivateKey = short\n\n[Peer]\nPublicKey = $_publicKey\nEndpoint = 1.2.3.4:51820')
              .error,
          contains('PrivateKey'));
      expect(
          WarpProfile.parse(
                  '[Interface]\nPrivateKey = $_privateKey\n\n[Peer]\nPublicKey = short\nEndpoint = 1.2.3.4:51820')
              .error,
          contains('PublicKey'));
      expect(
          WarpProfile.parse(
                  '[Interface]\nPrivateKey = $_privateKey\n\n[Peer]\nPublicKey = $_publicKey')
              .error,
          contains('Endpoint'));
      expect(WarpProfile.parse(_conf(endpoint: '1.2.3.4:0')).error,
          contains('Endpoint'));
    });

    test('private key never appears in public representations', () {
      final p = WarpProfile.parse(_conf()).profile!;
      expect(p.toString().contains(_privateKey), isFalse);
      expect(p.toMap().containsKey('privateKey'), isFalse);
      expect(p.toMap().containsValue(_privateKey), isFalse);
      expect(p.identityHint.contains(_privateKey), isFalse);
    });
  });

  group('WarpController profile state', () {
    test('imports, reports parse errors and clears without a scan', () {
      final controller = WarpController();
      addTearDown(controller.dispose);

      expect(controller.setProfile(_conf()), isTrue);
      expect(controller.profile, isNotNull);
      expect(controller.profile!.endpointPort, 2408);
      expect(controller.profileError, isNull);
      expect(controller.useProfileForScan, isTrue);

      controller.setUseProfileForScan(false);
      expect(controller.useProfileForScan, isFalse);

      expect(controller.setProfile('[Interface]\nPrivateKey = nope'), isFalse);
      expect(controller.profileError, isNotNull);

      controller.clearProfile();
      expect(controller.profile, isNull);
      expect(controller.profileError, isNull);
      expect(controller.profileValidation, isNull);
    });
  });
}
