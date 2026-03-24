// audio_recorder_service.dart
//
// PURPOSE:
//   Records the user's voice from the microphone (Android & iOS) and
//   converts the raw audio bytes into a base64-encoded string, ready to
//   be sent over WebSocket / HTTP to the backend.
//
// DEPENDENCIES (already in pubspec.yaml):
//   record: ^5.1.2
//   permission_handler: ^11.3.1
//
// PERMISSIONS:
//   Android → android/app/src/main/AndroidManifest.xml:
//     <uses-permission android:name="android.permission.RECORD_AUDIO"/>
//   iOS → ios/Runner/Info.plist:
//     NSMicrophoneUsageDescription → "We need mic access to record your voice."

import 'dart:async';
import 'dart:convert'; // base64Encode
import 'dart:io';     // File
import 'dart:typed_data'; // Uint8List

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

class AudioRecorderService {
  final AudioRecorder _recorder = AudioRecorder();

  /// Internal buffer — raw audio bytes collected chunk-by-chunk from the mic
  final List<int> _audioBuffer = [];
  StreamSubscription<Uint8List>? _streamSub;

  bool _isRecording = false;

  /// Whether recording is currently active
  bool get isRecording => _isRecording;

  // ─────────────────────────────────────────────────────────
  // 1. REQUEST MIC PERMISSION
  // ─────────────────────────────────────────────────────────
  /// Requests microphone permission from the OS.
  /// Returns [true] if granted, [false] if denied.
  Future<bool> requestPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  // ─────────────────────────────────────────────────────────
  // 2. START RECORDING
  //    Opens the mic, streams raw AAC-LC bytes into _audioBuffer.
  // ─────────────────────────────────────────────────────────
  /// Starts recording from the device microphone.
  /// Throws an [Exception] if microphone permission is denied.
  Future<void> startRecording() async {
    final hasPermission = await requestPermission();
    if (!hasPermission) {
      throw Exception('Microphone permission denied.');
    }

    _audioBuffer.clear();

    // Open mic as a stream of raw bytes (AAC-LC, 16 kHz mono)
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.aacLc, // AAC-LC — compatible with Whisper / most backends
        sampleRate: 16000,           // 16 kHz — optimal for speech recognition
        numChannels: 1,              // Mono
        bitRate: 64000,              // 64 kbps
      ),
    );

    // Collect every incoming chunk into the buffer
    _streamSub = stream.listen((Uint8List chunk) {
      _audioBuffer.addAll(chunk);
    });

    _isRecording = true;
  }

  // ─────────────────────────────────────────────────────────
  // 3. STOP RECORDING — returns base64 string
  // ─────────────────────────────────────────────────────────
  /// Stops recording and returns the audio as a **base64-encoded string**.
  ///
  /// Usage:
  /// ```dart
  /// final String base64Audio = await audioService.stopRecordingAsBase64();
  /// // Send to backend:
  /// //   WebSocket → {"type": "audio_chunk", "data": base64Audio}
  /// //   HTTP POST → {"audio": base64Audio}
  /// ```
  Future<String> stopRecordingAsBase64() async {
    final Uint8List bytes = await _stopAndGetBytes();
    return base64Encode(bytes);
  }

  /// Stops recording and returns the raw audio as [Uint8List].
  /// Use this if your backend prefers raw bytes instead of base64.
  Future<Uint8List> stopRecordingAsBytes() async {
    return _stopAndGetBytes();
  }

  // ─────────────────────────────────────────────────────────
  // STOP + SAVE TO TEMP FILE
  // ─────────────────────────────────────────────────────────
  /// Stops recording, saves audio to a **temp .m4a file**, and returns
  /// both the [File] and the base64-encoded string.
  ///
  /// File format: **AAC-LC inside MPEG-4 container (.m4a)** — the same
  /// encoder used by [startRecording]. The file name includes a timestamp
  /// so each recording is unique.
  ///
  /// Example return value:
  /// ```
  /// (file: File('/tmp/audio_1741500000000.m4a'), base64: 'AAAAAA...')
  /// ```
  Future<({File file, String base64})> stopRecordingToFile() async {
    final bytes = await _stopAndGetBytes();

    // Write to OS temp directory as a .m4a file
    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final path = '${dir.path}/audio_$timestamp.m4a';
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);

    return (file: file, base64: base64Encode(bytes));
  }

  // ─────────────────────────────────────────────────────────
  // INTERNAL — shared stop logic
  // ─────────────────────────────────────────────────────────
  Future<Uint8List> _stopAndGetBytes() async {
    await _recorder.stop();
    await _streamSub?.cancel();
    _streamSub = null;
    _isRecording = false;

    final Uint8List audioBytes = Uint8List.fromList(_audioBuffer);
    _audioBuffer.clear();
    return audioBytes;
  }

  // ─────────────────────────────────────────────────────────
  // 4. CLEANUP
  // ─────────────────────────────────────────────────────────
  /// Call this in your widget's [dispose] to free mic resources.
  void dispose() {
    _streamSub?.cancel();
    _recorder.dispose();
  }
}
