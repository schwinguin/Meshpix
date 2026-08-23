import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_controller.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MeshPixApp());
}

class MeshPixApp extends StatelessWidget {
  const MeshPixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppController()..init(),
      child: MaterialApp(
        title: 'MeshPix',
        debugShowCheckedModeBanner: false,
        theme: meshTheme(),
        home: const HomeScreen(),
      ),
    );
  }
}
