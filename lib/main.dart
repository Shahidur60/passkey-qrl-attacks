// lib/main.dart
// Passkey-only device-linking demo (Flutter app + Java RP)
// - Keygen: elliptic (exportable d/x/y)
// - Signing: PointyCastle "SHA-256/ECDSA" (pure Dart) + FortunaRandom
// - Storage: padded Base64 + flexible decoder
// - Scanner: robust (stops camera before pop + manual URL fallback)
// - Clear step-by-step status

import 'dart:convert';
import 'dart:math' as math;                    // <-- for Random.secure()
import 'dart:typed_data';

import 'package:elliptic/elliptic.dart' as elliptic; // P-256 keygen (exportable)
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pointycastle/export.dart' as pc;     // ECDSA + SHA-256

void main() {
  runApp(const MyApp());
}

const String userId = "user-123";

// ----- Set this to your Java server -----
// Emulator: "http://10.0.2.2:8889"
// Real phone: "http://<YOUR-PC-LAN-IP>:8889"
const String baseUrl = "http://10.247.158.70:8889";

// Informational in clientDataJSON (server doesn’t validate origin in this demo)
const String originForClientData = "http://localhost:8889";

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) =>
      const MaterialApp(title: 'Passkey Demo', home: Home());
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final storage = const FlutterSecureStorage();
  final auth = LocalAuthentication();

  String status = "Ready";

  // Base64url (no padding) — handy for network payloads
  String b64u(List<int> data) => base64Url.encode(data).replaceAll('=', '');

  // Flex decoder: accepts padded or unpadded Base64url
  Uint8List _b64UrlFlexDecode(String s) {
    s = s.trim();
    final pad = (4 - (s.length % 4)) % 4;
    return base64Url.decode(s + ('=' * pad));
  }

  // ---------------- REGISTER (generate d/x/y, store locally, send pub to server) ----------------
  Future<void> register() async {
    try {
      setState(() => status = "Generating passkey…");

      // Generate P-256 key with pure Dart (exportable)
      final curve = elliptic.getP256();
      final priv  = curve.generatePrivateKey(); // BigInt D
      final pub   = priv.publicKey;            // BigInt X/Y

      Uint8List _bi(BigInt v, int size) {
        final hex = v.toRadixString(16).padLeft(size * 2, '0');
        final out = Uint8List(size);
        for (int i = 0; i < size; i++) {
          out[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
        }
        return out;
      }

      final d = _bi(priv.D, 32);
      final x = _bi(pub.X, 32);
      final y = _bi(pub.Y, 32);

      // Uncompressed public key: 0x04 || X || Y  (65 bytes)
      final pubRaw = Uint8List(65)
        ..[0] = 0x04
        ..setRange(1, 33, x)
        ..setRange(33, 65, y);

      setState(() => status = "Saving key to secure storage…");

      // Store locally (padded Base64 => easy decode)
      await storage.write(key: 'passkey_priv_$userId', value: base64Url.encode(d));
      await storage.write(key: 'passkey_pub_$userId',  value: base64Url.encode(pubRaw));

      // Demo credentialId
      final credIdBytes = Uint8List.fromList(
        List<int>.generate(32, (i) => (DateTime.now().microsecondsSinceEpoch * (i + 7)) & 0xff),
      );
      final credId = b64u(credIdBytes);
      await storage.write(key: 'cred_$userId', value: credId);

      setState(() => status = "Sending public key to server…");

      final resp = await http.post(
        Uri.parse('$baseUrl/registerFinish'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "userId": userId,
          "credentialId": credId,
          "publicKeyFormat": "rawP256",
          "publicKey": b64u(pubRaw), // 0x04||X||Y (unpadded ok over wire)
        }),
      );

      if (resp.statusCode == 200) {
        setState(() => status = "✅ Registered passkey");
      } else {
        setState(() => status = "Register failed: ${resp.body}");
      }
    } catch (e) {
      setState(() => status = "Register error: $e");
    }
  }

  // ---------------- SCAN + LINK (scan/paste pair URL → fingerprint → sign → finish) -------------
  Future<void> scanAndLink() async {
    final qrUrl = await Navigator.push<String?>(
      context,
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (qrUrl == null) return;

    try {
      setState(() => status = "Fetching pair info…");

      final uri = Uri.parse(qrUrl);
      final sid = uri.queryParameters['sid'];
      if (sid == null || sid.isEmpty) {
        setState(() => status = "Bad QR: no sid");
        return;
      }

      final pairResp = await http.get(Uri.parse('$baseUrl/pair?sid=$sid'));
      if (pairResp.statusCode != 200) {
        setState(() => status = "Pair fetch failed: ${pairResp.body}");
        return;
      }
      final j = jsonDecode(pairResp.body) as Map<String, dynamic>;
      final challengeB64 = j['challenge'] as String;
      final rpId = j['rpId'] as String;
      final sessionId = j['sessionId'] as String;

      setState(() => status = "Awaiting biometric…");

      // Fingerprint (biometric only)
      final ok = await auth.authenticate(
        localizedReason: 'Approve linking',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      if (!ok) {
        setState(() => status = "Cancelled");
        return;
      }

      setState(() => status = "Loading key from storage…");

      // Load stored key material (flex decode handles padded/unpadded)
      final dBytes  = _b64UrlFlexDecode((await storage.read(key: 'passkey_priv_$userId'))!);
      final pubRaw  = _b64UrlFlexDecode((await storage.read(key: 'passkey_pub_$userId'))!);
      final credId  = (await storage.read(key: 'cred_$userId'))!;
      if (pubRaw.length != 65 || pubRaw[0] != 0x04) {
        setState(() => status = "Bad stored public key format");
        return;
      }

      // Build clientDataJSON (WebAuthn-like)
      setState(() => status = "Building clientDataJSON…");
      final clientData = jsonEncode({
        "type": "webauthn.get",
        "challenge": challengeB64,
        "origin": originForClientData,
        "crossOrigin": false,
      });
      final clientDataBytes = utf8.encode(clientData);

      // Hashes (SHA-256)
      setState(() => status = "Hashing components…");
      final rpHash      = _sha256(utf8.encode(rpId));
      final clientHash  = _sha256(clientDataBytes);

      // authenticatorData: flags || counter  (server prepends rpHash itself)
      final flags = <int>[0x05]; // UP=1, UV=1
      final counter = <int>[0, 0, 0, 1];
      final authenticatorData = Uint8List.fromList([...flags, ...counter]);

      // Message that server verifies: rpHash || authenticatorData || clientHash
      final toBeSigned = Uint8List.fromList([...rpHash, ...authenticatorData, ...clientHash]);

      // ECDSA P-256 with SHA-256 (PointyCastle) + FortunaRandom
      setState(() => status = "Signing with ECDSA…");
      final derSig = _ecdsaSignDerSha256P256(toBeSigned, dBytes);

      setState(() => status = "Sending assertion to server…");
      final finish = await http.post(
        Uri.parse('$baseUrl/assertionFinish'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "sessionId": sessionId,
          "credentialId": credId,
          "clientDataJSON": b64u(clientDataBytes),
          "authenticatorData": b64u(authenticatorData),
          "signature": b64u(derSig),
        }),
      );

      if (finish.statusCode == 200) {
        setState(() => status = "✅ Linked desktop");
      } else {
        setState(() => status = "Link failed: ${finish.body}");
      }
    } catch (e) {
      setState(() => status = "Link error: $e");
    }
  }

  // --- Helpers: SecureRandom + SHA-256 + ECDSA/DER (PointyCastle) ---

  // Seed a FortunaRandom with system-secure entropy
  pc.SecureRandom _secureRandom() {
    final rnd = pc.FortunaRandom();
    final seed = Uint8List(32);
    final rs = math.Random.secure();
    for (int i = 0; i < seed.length; i++) {
      seed[i] = rs.nextInt(256);
    }
    rnd.seed(pc.KeyParameter(seed));
    return rnd;
  }

  Uint8List _sha256(List<int> message) {
    final d = pc.SHA256Digest();
    return d.process(Uint8List.fromList(message));
  }

  // Sign 'message' with SHA-256/ECDSA over P-256, return DER-encoded (r,s).
  Uint8List _ecdsaSignDerSha256P256(Uint8List message, Uint8List dBytes) {
    // Domain + private key
    final params = pc.ECDomainParameters('prime256v1'); // secp256r1
    final dBI = _bigIntFromBytes(dBytes);
    final privKey = pc.ECPrivateKey(dBI, params);

    // High-level signer hashes internally (SHA-256/ECDSA).
    // Attach a FortunaRandom so no "SecureRandom not registered" error occurs.
    final signer = pc.Signer('SHA-256/ECDSA');
    signer.init(
      true,
      pc.ParametersWithRandom(
        pc.PrivateKeyParameter<pc.ECPrivateKey>(privKey),
        _secureRandom(),
      ),
    );

    final sig = signer.generateSignature(message) as pc.ECSignature;

    // Low-S normalization for compatibility
    final nHalf = params.n! >> 1;
    var r = sig.r;
    var s = sig.s;
    if (s.compareTo(nHalf) > 0) {
      s = params.n! - s;
    }

    return _encodeDerRStoBytes(r, s);
  }

  BigInt _bigIntFromBytes(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  // DER encode r and s: 30 | len | 02 | lenR | R | 02 | lenS | S
  Uint8List _encodeDerRStoBytes(BigInt r, BigInt s) {
    Uint8List _encodeInt(BigInt v) {
      var bytes = _toUnsignedBytes(v);
      if (bytes.isNotEmpty && (bytes[0] & 0x80) != 0) {
        bytes = Uint8List.fromList([0x00, ...bytes]); // ensure positive
      }
      return bytes;
    }

    final rBytes = _encodeInt(r);
    final sBytes = _encodeInt(s);

    final totalLen = 2 + rBytes.length + 2 + sBytes.length;
    final out = BytesBuilder();
    out.addByte(0x30);
    out.add(_encodeDerLen(totalLen));
    out.addByte(0x02);
    out.add(_encodeDerLen(rBytes.length));
    out.add(rBytes);
    out.addByte(0x02);
    out.add(_encodeDerLen(sBytes.length));
    out.add(sBytes);
    return out.toBytes();
  }

  // Minimal unsigned big-endian (trim leading zeros)
  Uint8List _toUnsignedBytes(BigInt v) {
    if (v == BigInt.zero) return Uint8List.fromList([0]);
    var hex = v.toRadixString(16);
    if (hex.length % 2 != 0) hex = '0$hex';
    final len = hex.length ~/ 2;
    final out = Uint8List(len);
    for (int i = 0; i < len; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    int i = 0;
    while (i < out.length - 1 && out[i] == 0) i++;
    return Uint8List.fromList(out.sublist(i));
  }

  // Encode DER length (short/long form)
  Uint8List _encodeDerLen(int len) {
    if (len < 0x80) return Uint8List.fromList([len]);
    final bytes = <int>[];
    var n = len;
    while (n > 0) {
      bytes.insert(0, n & 0xff);
      n >>= 8;
    }
    return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
  }

  Future<void> resetKeys() async {
    await storage.delete(key: 'passkey_priv_$userId');
    await storage.delete(key: 'passkey_pub_$userId');
    await storage.delete(key: 'cred_$userId');
    setState(() => status = "Cleared local keys. Register again.");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Passkey Demo')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Flow: Register → Scan QR & Link Desktop'),
          const SizedBox(height: 8),
          Text('User: $userId\nServer: $baseUrl'),
          const SizedBox(height: 16),
          Row(
            children: [
              ElevatedButton(onPressed: register, child: const Text('Register Passkey')),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: scanAndLink, child: const Text('Scan QR & Link Desktop')),
              const SizedBox(width: 8),
              TextButton(onPressed: resetKeys, child: const Text('Reset Keys')),
            ],
          ),
          const SizedBox(height: 16),
          Text(status),
        ]),
      ),
    );
  }
}

// ---------------- Scanner screen (stops camera before exit + manual URL fallback) ----------------
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    facing: CameraFacing.back,
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final TextEditingController _manualCtrl = TextEditingController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    _manualCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleRaw(String raw) async {
    if (_handled) return;
    _handled = true;
    try {
      await _controller.stop(); // release camera cleanly
      await Future.delayed(const Duration(milliseconds: 150));
    } catch (_) {}
    if (!mounted) return;
    Navigator.pop(context, raw);
  }

  void _onDetect(BarcodeCapture capture) {
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw != null && (raw.startsWith('http://') || raw.startsWith('https://'))) {
        _handleRaw(raw);
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Or paste pair URL (…/pair?sid=...)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    final raw = _manualCtrl.text.trim();
                    if (raw.startsWith('http://') || raw.startsWith('https://')) {
                      _handleRaw(raw);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Enter a valid http(s) URL')),
                      );
                    }
                  },
                  child: const Text('Use'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
