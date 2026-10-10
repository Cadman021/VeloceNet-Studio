import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Key-value secret storage abstraction (webhook tokens and the like).
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// In-memory implementation for unit tests.
class FakeSecretStore implements SecretStore {
  final Map<String, String> vault = {};

  @override
  Future<String?> read(String key) async => vault[key];

  @override
  Future<void> write(String key, String value) async {
    vault[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    vault.remove(key);
  }
}

// ---------------------------------------------------------------------------
// Windows DPAPI (crypt32.dll) via dart:ffi.
//
// Rationale: flutter_secure_storage was dropped because its Windows backend
// requires ATL headers (atlstr.h) missing from default Visual Studio
// installs, which broke `flutter run`/`flutter build windows` outright.
// DPAPI user-scope protection is exactly what Credential Manager builds on,
// it needs no extra headers (crypt32.dll ships with Windows), and the FFI
// surface is two functions.
// ---------------------------------------------------------------------------

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _ProtectNative = Bool Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Utf16> descr,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  Uint32 flags,
  Pointer<_DataBlob> dataOut,
);
typedef _ProtectDart = bool Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Utf16> descr,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  int flags,
  Pointer<_DataBlob> dataOut,
);

typedef _FreeNative = Pointer<Void> Function(Pointer<Void> mem);
typedef _FreeDart = Pointer<Void> Function(Pointer<Void> mem);

typedef _GetErrorNative = Uint32 Function();
typedef _GetErrorDart = int Function();

/// Values are stored as `dpapi1:<base64>` so protected blobs are
/// distinguishable from legacy plaintext during migration.
const String kDpapiPrefix = 'dpapi1:';
const int _cryptProtectUiForbidden = 0x1;

class DpapiBindings {
  DynamicLibrary? _crypt32;
  DynamicLibrary? _kernel32;
  _ProtectDart? _protect;
  _ProtectDart? _unprotect;
  _FreeDart? _localFree;
  _GetErrorDart? _getLastError;

  bool get available {
    if (!Platform.isWindows) return false;
    try {
      _crypt32 ??= DynamicLibrary.open('crypt32.dll');
      _kernel32 ??= DynamicLibrary.open('kernel32.dll');
      _protect ??= _crypt32!
          .lookupFunction<_ProtectNative, _ProtectDart>('CryptProtectData');
      _unprotect ??= _crypt32!
          .lookupFunction<_ProtectNative, _ProtectDart>('CryptUnprotectData');
      _localFree ??= _kernel32!
          .lookupFunction<_FreeNative, _FreeDart>('LocalFree');
      _getLastError ??= _kernel32!
          .lookupFunction<_GetErrorNative, _GetErrorDart>('GetLastError');
      return true;
    } catch (_) {
      return false;
    }
  }

  int get lastError {
    try {
      return _getLastError?.call() ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// Encrypts bytes for the current user. Returns null on failure.
  Uint8List? protect(Uint8List plain) {
    if (!available) return null;
    final inBytes = calloc<Uint8>(plain.length);
    final inBlob = calloc<_DataBlob>();
    final outBlob = calloc<_DataBlob>();
    try {
      inBytes.asTypedList(plain.length).setAll(0, plain);
      inBlob.ref.cbData = plain.length;
      inBlob.ref.pbData = inBytes;
      final ok = _protect!(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _cryptProtectUiForbidden,
        outBlob,
      );
      if (!ok) return null;
      final outPtr = outBlob.ref.pbData;
      final outLen = outBlob.ref.cbData;
      if (outPtr == nullptr || outLen <= 0) return null;
      return Uint8List.fromList(outPtr.asTypedList(outLen));
    } catch (_) {
      return null;
    } finally {
      try {
        final p = outBlob.ref.pbData;
        if (p != nullptr) _localFree?.call(p.cast());
      } catch (_) {}
      calloc.free(inBytes);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }

  /// Decrypts bytes produced by [protect]. Returns null on failure
  /// (wrong user/machine, corrupted data, ...).
  Uint8List? unprotect(Uint8List cipher) {
    if (!available) return null;
    final inBytes = calloc<Uint8>(cipher.length);
    final inBlob = calloc<_DataBlob>();
    final outBlob = calloc<_DataBlob>();
    try {
      inBytes.asTypedList(cipher.length).setAll(0, cipher);
      inBlob.ref.cbData = cipher.length;
      inBlob.ref.pbData = inBytes;
      final ok = _unprotect!(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _cryptProtectUiForbidden,
        outBlob,
      );
      if (!ok) return null;
      final outPtr = outBlob.ref.pbData;
      final outLen = outBlob.ref.cbData;
      if (outPtr == nullptr || outLen <= 0) return null;
      return Uint8List.fromList(outPtr.asTypedList(outLen));
    } catch (_) {
      return null;
    } finally {
      try {
        final p = outBlob.ref.pbData;
        if (p != nullptr) _localFree?.call(p.cast());
      } catch (_) {}
      calloc.free(inBytes);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }
}

/// Secret store used in production. Ciphertext (or plaintext fallback)
/// lives in shared_preferences under the same keys.
///
/// - Windows: values are DPAPI-protected (current-user scope) before
///   persistence. Reading needs no network, no headers, no service.
/// - Other platforms: transparent plaintext passthrough — documented
///   limitation (macOS Keychain / Linux libsecret backends are follow-up
///   work tracked in the repo issues, not silent insecurity).
///
/// Legacy plaintext values (no `dpapi1:` prefix, e.g. written by older
/// builds) are returned as-is on first read and transparently upgraded to
/// protected form on the next write. A protected blob that fails to
/// decrypt (different user/machine) yields null WITHOUT deleting the
/// stored value, so nothing is ever lost by a failed read.
class PlatformSecretStore implements SecretStore {
  final Future<SharedPreferences> Function() _prefsOf;
  final DpapiBindings _dpapi = DpapiBindings();

  PlatformSecretStore(
      {Future<SharedPreferences> Function()? prefsProvider})
      : _prefsOf = prefsProvider ?? SharedPreferences.getInstance;

  /// Translates stored values: `dpapi1:<base64>` → plaintext,
  /// anything else → legacy plaintext returned as-is.
  String? decodeStored(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    if (!stored.startsWith(kDpapiPrefix)) return stored;
    if (!Platform.isWindows) return null;
    try {
      final cipher = base64Decode(stored.substring(kDpapiPrefix.length));
      final plain = _dpapi.unprotect(cipher);
      if (plain == null) return null;
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  /// Encodes for storage: DPAPI-protected on Windows, plaintext elsewhere.
  String encodeForStorage(String value) {
    if (Platform.isWindows) {
      try {
        final cipher =
            _dpapi.protect(Uint8List.fromList(utf8.encode(value)));
        if (cipher != null) return kDpapiPrefix + base64Encode(cipher);
      } catch (_) {}
    }
    return value;
  }

  @override
  Future<String?> read(String key) async {
    final prefs = await _prefsOf();
    return decodeStored(prefs.getString(key));
  }

  @override
  Future<void> write(String key, String value) async {
    final prefs = await _prefsOf();
    await prefs.setString(key, encodeForStorage(value));
  }

  @override
  Future<void> delete(String key) async {
    final prefs = await _prefsOf();
    await prefs.remove(key);
  }
}
