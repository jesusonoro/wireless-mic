import 'package:flutter/material.dart';
import 'ui/sender_screen.dart';

void main() {
  runApp(const EvermicApp());
}

class EvermicApp extends StatelessWidget {
  const EvermicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'evermic',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const SenderScreen(),
    );
  }
}
