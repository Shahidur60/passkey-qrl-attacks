# 🔐 Passkey Device Linking Demo (Flutter + Java)

A minimal **passkey-only** cross-device flow replacing “scan a QR to log in” with **WebAuthn-style** device linking.  

- **Desktop:** Shows short-lived QR code  
- **Phone:** Scans QR, verifies fingerprint, signs a challenge using **P-256 passkey** whose private key never leaves the device  
- **Server:** Verifies signature before linking the desktop

---

## 🧠 What This Defends Against

- **QR screenshot/relay** — A captured QR alone isn’t enough; attacker needs user’s phone and biometric approval  
- **Headless automation** — Selenium/Puppeteer bots cannot link without the passkey signature  
- **Shoulder-surf proximity** — Remotely scanning a victim’s QR fails without fingerprint approval  

---

## 📁 Repository Layout

```
/server
  └── LinkServer.java    # Minimal HTTP server + RP logic (register/assertion)

/app
  ├── lib/main.dart      # Flutter app: register passkey, scan QR, link desktop
  ├── android/...        # Standard Flutter Android project
  └── pubspec.yaml
```

---

## ✨ Features

- **Passkey registration:** Generates a P‑256 keypair and registers public key with the server  
- **Biometric approval:** Fingerprint gated before signing  
- **Challenge signing:**  
  `SHA256(rpId)` + `authenticatorData(flags||counter)` + `SHA256(clientDataJSON)` → **ECDSA P‑256 (DER format)**  
- **Pure‑Dart crypto:**  
  - Keygen: [`elliptic`](https://pub.dev/packages/elliptic)  
  - Sign/Hash: [`pointycastle`](https://pub.dev/packages/pointycastle)  
- **Robust QR scanner:** Stops camera cleanly and supports manual URL fallback

---

## ⚙️ Prerequisites

- Java 11+ (JDK)  
- Flutter 3.x + Android SDK  
- Android device with fingerprint enrolled  
- Windows: allow **Java(TM) Platform SE binary** through Firewall (Private)

---

## 🚀 Quick Start

### 1️⃣ Run the Server

```
cd server
javac LinkServer.java
java LinkServer
```

Expected output:
```
Passkey demo server running on http://localhost:8889
```

Visit <http://localhost:8889/link> and check the QR image.  
If “Init failed”, open DevTools → Network → inspect `/assertionBegin`.

---

### 2️⃣ Flutter App Setup

```
cd app
flutter pub get
```

**Configure server URL in `lib/main.dart`:**

```
// Emulator:
const String baseUrl = "http://10.0.2.2:8889";

// Real phone:
const String baseUrl = "http://192.168.1.50:8889";
```

> Ensure PC and phone are on the same LAN/Wi-Fi and firewall permits Java on port 8889.

---

### 3️⃣ Android Wiring

**MainActivity must extend FlutterFragmentActivity:**

```
package com.example.passkey_mobile_app
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity()
```

**Manifest permissions (above `<application>`):**

```
<uses-permission android:name="android.permission.USE_BIOMETRIC"/>
<uses-permission android:name="android.permission.USE_FINGERPRINT"/>
<uses-permission android:name="android.permission.CAMERA"/>
```

**Enable cleartext HTTP (debug only):**

```
<application
    android:usesCleartextTraffic="true"
    ... >
```

---

### 4️⃣ Dependencies (`pubspec.yaml`)

```
dependencies:
  flutter:
    sdk: flutter
  elliptic: ^0.3.11
  pointycastle: ^4.0.0
  flutter_secure_storage: ^9.0.0
  http: ^1.2.0
  local_auth: ^2.1.7
  mobile_scanner: ^6.0.2
```

Run:
```
flutter clean
flutter pub get
flutter run
```

---

## 📱 Usage Flow

1. Start server → open `http://localhost:8889/link`
2. On phone:
   - Tap **Register Passkey** → ✅ registered
   - Tap **Scan QR & Link Desktop** → fingerprint → ✅ linked
3. Desktop shows ✅ **Linked**

---

## 🔄 Protocol Flow

**Register:**
- Phone uses `elliptic` to generate P‑256 keypair.  
- Private scalar `d` and pubkey `0x04||X||Y` stored securely (Base64url padded).  
- Sends public key → `/registerFinish`.

**Desktop → Begin assertion:**
- `/assertionBegin` returns `{sessionId, challenge, rpId}` → QR rendered.

**Phone → Scan & link:**
- Fetch `/pair?sid=...` → `{challenge, rpId, sessionId}`  
- Prompt fingerprint  
- Build `clientDataJSON`, compute `SHA256(rpId)` and `SHA256(clientDataJSON)`  
- Create `authenticatorData = flags(UP|UV)||counter(00000001)`  
- Sign  
  ```
  SHA256(rpId) || authenticatorData || SHA256(clientDataJSON)
  ```  
  via ECDSA P‑256 (DER, low‑S)  
- POST to `/assertionFinish` with `clientDataJSON`, `authenticatorData`, and `signature`.

**Server verification:**
- Verifies signature with stored public key.
- Marks session linked when valid.

---

## 🧩 Troubleshooting

- **LocalAuth error:** Use `FlutterFragmentActivity`  
- **After fingerprint → UnimplementedError:** verify `pointycastle` import  
  ```
  import 'package:pointycastle/export.dart' as pc;
  ```
- **SecureRandom error:** Ensure `FortunaRandom` seeded correctly.  
- **Base64 length error:** Tap *Reset Keys* → re‑register passkey.  
- **QR scans but idle:** Check `baseUrl`, QR rendering, firewall.  
- **Desktop “Init failed”:** confirm `/registerFinish` hit successfully.  
- **Real device unreachable:** test `http://<PC-IP>:8889/link` in phone browser.

---

## 🛡️ Security Notes (Demo vs. Production)

This repo demonstrates WebAuthn‑like behavior. For production:

- Use platform **WebAuthn APIs** with RP ID + origin checks  
- Prefer **BLE / caBLE / Nearby** transport for proximity  
- Add device management (list/revoke), counters, short TTLs, rate limits  
- Require **TLS**; disable cleartext HTTP  
- Harden RP logic (CSRF/XSS protection)

---

## 🖼️ Screenshots

| App Home | Desktop QR | Linked |
|-----------|-------------|--------|
| `docs/app_home.png` | `docs/desktop_qr.png` | `docs/linked.png` |

---

## 🧾 License

Demonstration and educational use only — illustrates passkey‑based linking concepts.
```

***

To download it:

1. Copy the entire content above.  
2. Save as a file named **`README.md`**.  
3. (Optional) Use:  
   ```bash
   curl -O https://yourdownloadpath/README.md
   ```
   if hosting it on your own repo or server.

Would you like me to provide this as a downloadable `.zip` bundle with the folder structure stubbed out?
