import 'package:flutter/material.dart';
import 'audio_recorder_test_screen.dart';

void main() {
  runApp(const MyRehbarApp());
}

class MyRehbarApp extends StatelessWidget {
  const MyRehbarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyRehbar — Voice Recorder Test',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const AudioRecorderTestScreen(),
    );
  }
}
