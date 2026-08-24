import 'dart:async';
import 'dart:io' show HttpClient, HttpOverrides, SecurityContext;

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_controller.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // OSM-Kachel-Policy: tile.openstreetmap.org blockt Requests ohne
  // beschreibenden User-Agent („tile usage policy", osm.wiki/blocked).
  // App-weit setzen: gilt für Kartenkacheln UND Open-Meteo-Elevation.
  HttpOverrides.global = _MeshPixHttpOverrides();

  // Globale Fehlerfänger: ungewollte Exceptions (z. B. aus
  // Fire-and-forget-Timern im Reconnect-Pfad) dürfen die App nicht
  // stürzen — Log, nicht Crash.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
    return true;
  };

  runApp(const MeshPixApp());
}

class MeshPixApp extends StatefulWidget {
  const MeshPixApp({super.key});

  @override
  State<MeshPixApp> createState() => _MeshPixAppState();
}

class _MeshPixAppState extends State<MeshPixApp> with WidgetsBindingObserver {
  late final AppController _controller = AppController()..init();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Vor dem möglichen Kill durch das OS den Verlauf sicher schreiben.
    if (state == AppLifecycleState.paused) {
      _controller.flushSave();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppController>(
      create: (_) {
        // meshcore://contact/add/… — QR-Karten und geteilte Kontakte.
        // App-Links (Android) liefern Cold-Start-Links über initialLinks;
        // laufende Links über stream.
        final appLinks = AppLinks();
        unawaited(
          appLinks
              .getInitialLink()
              .then((uri) async {
                await _handleContactLink(_controller, uri);
              })
              .catchError((Object e) => debugPrint('AppLinks init: $e')),
        );
        appLinks.uriLinkStream.listen(
          (uri) => _handleContactLink(_controller, uri),
          onError: (Object e) => debugPrint('AppLinks stream: $e'),
        );
        return _controller;
      },
      child: MaterialApp(
        title: 'MeshPix',
        debugShowCheckedModeBanner: false,
        theme: meshTheme(),
        home: const HomeScreen(),
      ),
    );
  }

  Future<void> _handleContactLink(AppController controller, Uri? uri) async {
    if (uri?.scheme != 'meshcore') return;
    await controller.handleContactUri(uri.toString());
  }
}

class _MeshPixHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.userAgent = 'MeshPix/1.0 (https://github.com/schwinguin/Meshpix)';
    return client;
  }
}
