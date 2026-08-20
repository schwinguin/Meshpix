# MeshPix

Schlanker MeshCore-Companion für **iOS und Android** (eine Flutter-Codebase). Die **Preview** bleibt ein Mini-Bild im eigenen **MP1**-Format (ein LoRa-Paket). Der optionale **Nachzug** im Direct Message ist ein kleines **JPEG** (~160×160), das in Chunks nur auf Anfrage kommt.

## Warum Mini-Bilder?

Ein MeshCore-Channel-Datagramm hat **163 Byte** Nutzlast. Ein Handyfoto passt nicht in ein Paket. MeshPix skaliert und quantisiert die **Vorschau** (4 oder 16 Farben), damit sie in **einem** Paket bleibt. Wer *Nachladen* tippt, bekommt danach ein JPEG — gleicher Chunk-Budget, aber echte Fotodetails statt 96×96 Pixelart.

| Ziel | Typisch | Routing |
| --- | --- | --- |
| Preview | 24×24, 4 Farben (immer 1 Paket) oder 16×16 / 24×24 mit 16 Farben wenn es passt | Channel: Flood. DM: Direct |
| Nachzug | JPEG bis ~160×160 in ≤32 Chunks; Fallback 96/80/64/48 Indexed | nur DM nach *Nachladen*, nie Public-Flood |

`data_type` für MeshPix-Datagramme: `0xFF50`.

## Simulator ohne Funkgerät

Die App startet im **Simulator** mit zwei Identitäten (Anna und Ben). So lassen sich Codec, Chat und Nachzug ohne LoRa-Node testen.

Bluetooth koppelt an einen echten MeshCore-Companion (Nordic UART, Prefix z. B. `MeshCore-`, `HT-`).

## Protokoll (Companion-Subset)

Handshake und Traffic folgen der [Companion Radio Protocol](https://docs.meshcore.io/companion_protocol/)-Doku:

- `CMD_DEVICE_QUERY`, `CMD_APP_START`
- Kontakte / Channels laden
- Text: `CMD_SEND_TXT_MSG`, `CMD_SEND_CHANNEL_TXT_MSG`
- Bilder Channel: `CMD_SEND_CHANNEL_DATA` (`0x3E`)
- Bilder DM: `CMD_SEND_RAW_DATA` (`0x19`)
- Empfang: `RESP_CODE_CHANNEL_DATA_RECV`, `PUSH_CODE_RAW_DATA`, Message-Sync

Unbekannte `data_type`-Werte werden ignoriert.

## Bauen

Voraussetzung: [Flutter](https://docs.flutter.dev/get-started/install) 3.16+ (getestet mit 3.47).

```bash
flutter pub get
flutter test
flutter analyze
```

### Android

```bash
flutter build apk
```

BLE braucht auf dem Gerät Standort/Nearby- bzw. Bluetooth-Rechte (Android 12+).

### iOS

Das Xcode-Projekt liegt unter `ios/`. Ein IPA geht nur auf einem Mac:

```bash
flutter build ios --no-codesign
```

Dann in Xcode Team/Signing setzen. Info.plist enthält bereits Bluetooth-, Kamera- und Mediathek-Texte.

## Kein App-Store-Build

Signing, Provisioning und Play/App-Store-Release sind nicht Teil dieses MVP.

## Limits (bewusst)

Keine Karte, kein Repeater-Login, kein Firmware-Flash, keine MCOimg-`im3:`-Kompatibilität, kein Wi‑Fi/USB-Companion.
