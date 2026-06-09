import 'package:flutter/material.dart';
import 'ui/sender_screen.dart';
import 'ui/theme.dart';

void main() {
  runApp(const EverdjApp());
}

class EverdjApp extends StatelessWidget {
  const EverdjApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EVERDJ',
      debugShowCheckedModeBanner: false,
      theme: buildEverdjTheme(),
      home: const SenderScreen(),
    );
  }
}
