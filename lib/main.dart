import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_controller.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

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

class MeshPixApp extends StatelessWidget {
  const MeshPixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) {
        final controller = AppController()..init();
        // meshcore://contact/add/… — QR-Karten und geteilte Kontakte.
        // App-Links (Android) liefern Cold-Start-Links über initialLinks;
        // laufende Links über stream.
        final appLinks = AppLinks();
        unawaited(
          appLinks
              .getInitialLink()
              .then((uri) async {
                await _handleContactLink(controller, uri);
              })
              .catchError((Object e) => debugPrint('AppLinks init: $e')),
        );
        appLinks.uriLinkStream.listen(
          (uri) => _handleContactLink(controller, uri),
          onError: (Object e) => debugPrint('AppLinks stream: $e'),
        );
        return controller;
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
