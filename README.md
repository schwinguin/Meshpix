# MeshPix

Schlanker MeshCore-Companion für **iOS und Android** (eine Flutter-Codebase). Die **Preview** bleibt ein Mini-Bild im eigenen **MP1**-Format (ein LoRa-Paket). Der optionale **Nachzug** im Direct Message ist ein kleines **JPEG** (~160×160), das in Chunks nur auf Anfrage kommt.

## Warum Mini-Bilder?

Ein MeshCore-Channel-Datagramm hat **163 Byte** Nutzlast. Ein Handyfoto passt nicht in ein Paket. MeshPix skaliert und quantisiert die **Vorschau** (4 oder 16 Farben), damit sie in **einem** Paket bleibt. Wer *Nachladen* tippt, bekommt danach ein JPEG — gleicher Chunk-Budget, aber echte Fotodetails statt 96×96 Pixelart.

| Ziel | Typisch | Routing |
| --- | --- | --- |
| Preview | 24×24, 4 Farben (immer 1 Paket) oder 16×16 / 24×24 mit 16 Farben wenn es passt | Channel: Flood. DM: Direct |
| Nachzug | JPEG bis ~160×160 in ≤32 Chunks; Fallback 96/80/64/48 Indexed | nur DM nach *Nachladen*, nie Public-Flood |

`data_type` für MeshPix-Bilder: `0xFF50`. Channel-Catch-up / Quittungen: `0xFF51`.

## Simulator ohne Funkgerät

Die App startet im **Simulator** mit zwei Identitäten (Anna und Ben). So lassen sich Codec, Chat, Delivery-Status, Advert und Nachzug ohne LoRa-Node testen.

Bluetooth koppelt an einen echten MeshCore-Companion (Nordic UART, Prefix z. B. `MeshCore-`, `HT-`).

## MeshCore-One-Features

Neben Bildern spricht MeshPix dasselbe Companion-Protokoll wie MeshCore One:

- **Chats / Kontakte / Funk / Pfad** als Tabs
- Direct Messages mit **Sending → Sent → Delivered** (ACK + RTT)
- Hop-Anzahl und SNR an der Blase
- Kontakte mit Typ (Chat, Repeater, Room, Sensor), Favorit, zuletzt gehört, Pfad
- **Zero-Hop- / Flood-Advert**, Auto-Discovery
- **Ping / Status** an bekannte Repeater und Kontakte (Laufzeit, SNR, Noise)
- Radio: Frequenz, SF, BW, CR, TX-Power + regionale **Presets** (EU/US/AU/UK)
- Batterie, Firmware, Advert-Name
- Kontaktkarte als **QR / `meshcore://contact/add?...`** (kompatibel mit MeshCore One)
- **Repeater / Room Admin**: Login, Status (Batterie, Uptime, SNR, Pakete), Nachbarn, CLI, ACL `setperm`, Pfad-Trace, Reboot mit Bestätigung
- **Channel-Nachreichen**: Flood bleibt ohne ACK. Der Sender merkt sich bekannte Chat-Kontakte (live / fehlt). Wer beim Flood off-grid war, bekommt die Nachricht per DM nachgereicht, sobald sein Advert wieder gehört wird — plus Quittung zurück an den Sender (`Flood · 1/2 gehört`). Bilder als kurzer `📷 Bild`-Hinweis, nicht als zweiter Flood.
- **Pfad-Tab**: Ping an alle bekannten Nodes, Noise-Floor-Bogen (dBm + Verlauf) und **Sichtlinie** als Geländeprofil (Erdkugel, erste Fresnelzone, Frei / Knapp / Verdeckt). Optional echte Höhen von Open-Meteo.

## Protokoll (Companion-Subset)

Handshake und Traffic folgen der [Companion Radio Protocol](https://docs.meshcore.io/companion_protocol/)-Doku:

- `CMD_DEVICE_QUERY`, `CMD_APP_START`, `CMD_SET_DEVICE_TIME`
- Kontakte / Channels laden, `PUSH_CODE_ADVERT` / `NEW_ADVERT`
- Text: `CMD_SEND_TXT_MSG`, `CMD_SEND_CHANNEL_TXT_MSG`
- Delivery: `RESP_CODE_SENT`, `PUSH_CODE_SEND_CONFIRMED`
- Bilder Channel: `CMD_SEND_CHANNEL_DATA` (`0x3E`)
- Bilder DM: `CMD_SEND_RAW_DATA` (`0x19`)
- Channel-Catch-up (MeshPix): `CMD_SEND_RAW_DATA` mit `data_type` `0xFF51` (Text / Receipt / Sync, Magic `MC`)
- Funk: `CMD_SET_RADIO_PARAMS`, `CMD_SET_RADIO_TX_POWER`, `CMD_GET_BATT_AND_STORAGE`
- Repeater-Admin: `CMD_SEND_LOGIN`, CLI als `TXT_TYPE_CLI_DATA`, `CMD_SEND_STATUS_REQ`, `CMD_SEND_TRACE_PATH`
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

Keine Offline-Stadtkarte, kein Firmware-Flash, keine MCOimg-`im3:`-Kompatibilität, kein Wi‑Fi/USB-Companion. Die Sichtlinie ist ein Profil, kein Kartenlayer. Room-Server sind MeshCores eigenes Store-and-Forward; das Channel-Nachreichen ist ein MeshPix-Overlay für Public-Flood. Der Simulator enthält **Relay1** (Passwort `password`, Wendelstein-Position). Off-grid lässt sich dort per `setSimReachable` nachstellen.
