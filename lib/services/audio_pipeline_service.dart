// lib/services/audio_pipeline_service.dart
//
// Native Mobile Audio Pipeline via Direct OpenAI APIs
//   1. Record mic audio
//   2. STT via OpenAI Whisper
//   3. Get AI Response via OpenAI Chat Completions (Streamed natively)
//   4. TTS via OpenAI Speech

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';

import '../audio_recorder_service.dart';
import '../config/app_config.dart';
import '../models/transcription_result.dart';
import 'dataset_service.dart';

enum PipelineState { idle, recording, saving, sending, processing, done, error }

class AudioPipelineService {
  final AudioRecorderService _recorder = AudioRecorderService();
  final DatasetService _datasetService = DatasetService();
  PipelineState _state = PipelineState.idle;
  
  final List<Content> _chatHistory = [];

  void clearChatHistory() {
    _chatHistory.clear();
  }

  PipelineState get state => _state;
  bool get isRecording => _recorder.isRecording;

  Future<void> startRecording() async {
    _state = PipelineState.recording;
    await _recorder.startRecording();
  }

  Future<TranscriptionResult> stopAndProcess({
    required void Function(PipelineState state) onStateChange,
    required void Function(String chunk) onTextChunk,
    AppModule module = AppModule.general,
  }) async {
    try {
      if (AppConfig.geminiApiKey.trim().isEmpty) {
        throw Exception("Gemini API Key is missing. Please enter it in the top input box.");
      }
      if (AppConfig.openAIApiKey.trim().isEmpty) {
        throw Exception("OpenAI API Key is missing. Please enter it in the second input box.");
      }

      // ── Step 1: Save Audio ──────────────────────────────────────────────────
      _setState(PipelineState.saving, onStateChange);
      final audioBytes = await _recorder.stopRecordingAsBytes();
      // We don't necessarily need to save to a temp file, we can send bytes directly!

      // ── Step 2: STT (OpenAI Whisper API) ──────────────────────────────────────
      _setState(PipelineState.sending, onStateChange);
      final transcript = await _transcribeAudioWithWhisper(audioBytes);

      // ── Step 2.5: Dataset Context Retrieval ─────────────────────────────────
      String moduleContext = '';
      if (module != AppModule.general) {
        try {
          moduleContext = await _datasetService.getRelevantContext(module, transcript);
        } catch (e) {
          print('[Pipeline] Dataset query failed: $e');
        }
      }

      // ── Step 3: Chat Completions (Live Streamed) ────────────────────────────
      _setState(PipelineState.processing, onStateChange);
      final aiText = await _streamChatCompletionGemini(transcript, onTextChunk, ragContext: moduleContext);

      if (aiText.trim().isEmpty) {
        return TranscriptionResult(transcript: transcript, errorMessage: "AI returned an empty response.");
      }

      // ── Step 4: TTS (ElevenLabs API) ────────────────────────────────────────
      await _generateSpeechElevenLabs(aiText);

      _setState(PipelineState.done, onStateChange);
      return TranscriptionResult(transcript: aiText, audioUrl: "Played on Device Speakers");
    } catch (e) {
      _setState(PipelineState.error, onStateChange);
      return TranscriptionResult(errorMessage: e.toString());
    }
  }

  // ─────────────────────────────────────────────────────────
  // Gemini & Native API Calls
  // ─────────────────────────────────────────────────────────

  Future<String> _transcribeAudioWithWhisper(List<int> bytes) async {
    if (AppConfig.openAIApiKey.trim().isEmpty) {
      throw Exception("OpenAI API Key is missing.");
    }

    final url = Uri.parse('https://api.openai.com/v1/audio/transcriptions');
    final request = http.MultipartRequest('POST', url)
      ..headers['Authorization'] = 'Bearer ${AppConfig.openAIApiKey.trim()}'
      ..fields['model'] = 'whisper-1'
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: 'audio.m4a',
      ));

    final response = await request.send();
    final responseData = await response.stream.bytesToString();

    if (response.statusCode != 200) {
      throw Exception('Whisper STT failed: $responseData');
    }

    final json = jsonDecode(responseData);
    return json['text'] as String? ?? '';
  }

  Future<String> _streamChatCompletionGemini(String userText, void Function(String chunk)? onTextChunk, {String ragContext = ''}) async {
    String systemPrompt = 'You are a highly capable AI assistant interacting over a speech interface. Keep responses very concise, accurate, and conversational.';
    if (ragContext.isNotEmpty) {
      systemPrompt += '\n\nUse the following context from uploaded documents to answer the user\'s question. If the context doesn\'t help, answer from your own knowledge.\n\n--- DOCUMENT CONTEXT ---\n$ragContext\n--- END CONTEXT ---';
    }

    final model = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: AppConfig.geminiApiKey.trim(),
      systemInstruction: Content.system(systemPrompt),
    );

    _chatHistory.add(Content.text(userText));

    final responseStream = model.generateContentStream(_chatHistory);
    
    StringBuffer fullText = StringBuffer();
    
    await for (final chunk in responseStream) {
      if (chunk.text != null) {
        fullText.write(chunk.text!);
        onTextChunk?.call(chunk.text!);
      }
    }
    
    _chatHistory.add(Content.model([TextPart(fullText.toString())]));
    
    return fullText.toString();
  }

  Future<void> _generateSpeechElevenLabs(String text) async {
    if (AppConfig.elevenLabsApiKey.trim().isEmpty) {
      throw Exception("ElevenLabs API Key is missing.");
    }
    
    // Using Adam voice by default
    const voiceId = 'pNInz6obpgDQGcFmaJgB';
    final url = Uri.parse('https://api.elevenlabs.io/v1/text-to-speech/$voiceId');
    
    final response = await http.post(
      url,
      headers: {
        'Accept': 'audio/mpeg',
        'Content-Type': 'application/json',
        'xi-api-key': AppConfig.elevenLabsApiKey.trim(),
      },
      body: jsonEncode({
        'text': text,
        'model_id': 'eleven_multilingual_v2',
        'voice_settings': {
          'stability': 0.5,
          'similarity_boost': 0.75,
        }
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('ElevenLabs TTS failed: ${response.body}');
    }

    final bytes = response.bodyBytes;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/elevenlabs_response.mp3');
    await file.writeAsBytes(bytes);

    final player = AudioPlayer();
    await player.play(DeviceFileSource(file.path));
    
    // Wait for the audio to finish playing
    await player.onPlayerComplete.first;
    await player.dispose();
  }

  // ─────────────────────────────────────────────────────────


  void _setState(PipelineState s, void Function(PipelineState)? cb) {
    _state = s;
    cb?.call(s);
  }

  void dispose() {
    _recorder.dispose();
  }
}
