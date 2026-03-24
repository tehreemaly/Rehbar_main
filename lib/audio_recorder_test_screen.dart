// audio_recorder_test_screen.dart
import 'package:flutter/material.dart';
import 'services/audio_pipeline_service.dart';
import 'services/dataset_service.dart';
import 'config/app_config.dart';

class AudioRecorderTestScreen extends StatefulWidget {
  const AudioRecorderTestScreen({super.key});

  @override
  State<AudioRecorderTestScreen> createState() => _AudioRecorderTestScreenState();
}

class _AudioRecorderTestScreenState extends State<AudioRecorderTestScreen> {
  final AudioPipelineService _pipeline = AudioPipelineService();
  final TextEditingController _apiKeyController = TextEditingController(text: AppConfig.geminiApiKey);
  final TextEditingController _openaiKeyController = TextEditingController(text: AppConfig.openAIApiKey);

  AppModule? _selectedModule;
  bool _isRecording = false;
  String _status = '';
  String _liveText = '';
  String _audioUrl = '';
  String _errorMsg = '';

  // ── Start ──────────────────────────────────────────────────────────────
  Future<void> _startRecording() async {
    try {
      await _pipeline.startRecording();
      setState(() {
        _isRecording = true;
        _status = '🎙️ Recording… Press STOP & SEND when done.';
        _liveText = '';
        _audioUrl = '';
        _errorMsg = '';
      });
    } catch (e) {
      if (mounted) setState(() => _errorMsg = '❌ Could not start: $e');
    }
  }

  // ── Stop & Process ────────────────────────────────────────────────────
  Future<void> _stopAndSend() async {
    setState(() {
      _isRecording = false;
      _status = '⏳ Sending audio…';
    });

    final result = await _pipeline.stopAndProcess(
      module: _selectedModule ?? AppModule.general,
      onStateChange: (state) {
        final msg = switch (state) {
          PipelineState.saving     => '💾 Saving audio…',
          PipelineState.sending    => '📡 Transcribing speech…',
          PipelineState.processing => '🔄 Waiting for AI response…',
          PipelineState.done       => '✅ Done!',
          PipelineState.error      => '❌ Pipeline error',
          _                        => _status,
        };
        if (mounted) setState(() => _status = msg);
      },
      onTextChunk: (chunk) {
        if (mounted) setState(() => _liveText += chunk);
      },
    );

    if (mounted) {
      if (result.isSuccess) {
        setState(() {
          _status = '✅ Response received!';
          _audioUrl = result.audioUrl ?? '';
          _errorMsg = '';
        });
      } else if (result.errorMessage != null) {
        setState(() {
          _status = '⚠️ Error occurred';
          _errorMsg = result.errorMessage!;
        });
      }
    }
  }

  @override
  void dispose() {
    _pipeline.dispose();
    super.dispose();
  }

  // ── UI ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_selectedModule != null) {
      return _buildVoiceScreen();
    }
    return _buildModuleSelectionScreen();
  }

  Widget _buildModuleSelectionScreen() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MyRehbar — Select Module'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Gemini API Key (AIzaSy...)',
                prefixIcon: const Icon(Icons.vpn_key),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                filled: true,
                fillColor: Colors.white,
              ),
              onChanged: (val) => AppConfig.geminiApiKey = val.trim(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _openaiKeyController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'OpenAI API Key (sk-...) (For Whisper STT)',
                prefixIcon: const Icon(Icons.vpn_key),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                filled: true,
                fillColor: Colors.white,
              ),
              onChanged: (val) => AppConfig.openAIApiKey = val.trim(),
            ),
            const SizedBox(height: 32),
            const Text(
              'Select a Knowledge Base Module:',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(child: _moduleButton(AppModule.flood, Icons.water, Colors.blue)),
                const SizedBox(width: 16),
                Expanded(child: _moduleButton(AppModule.womensHealth, Icons.pregnant_woman, Colors.pink)),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _moduleButton(AppModule.education, Icons.school, Colors.orange)),
                const SizedBox(width: 16),
                Expanded(child: _moduleButton(AppModule.agriculture, Icons.agriculture, Colors.green)),
              ],
            ),
            const SizedBox(height: 16),
            _moduleButton(AppModule.general, Icons.chat, Colors.grey.shade700, fullWidth: true),
          ],
        ),
      ),
    );
  }

  Widget _moduleButton(AppModule module, IconData icon, Color color, {bool fullWidth = false}) {
    return InkWell(
      onTap: () {
        _pipeline.clearChatHistory();
        setState(() {
          _selectedModule = module;
          _status = 'Press START to record related to ${module.displayName}.';
          _liveText = '';
          _audioUrl = '';
          _errorMsg = '';
        });
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: fullWidth ? 80 : 120,
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          border: Border.all(color: color, width: 2),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: fullWidth ? 32 : 48, color: color),
            const SizedBox(height: 8),
            Text(module.displayName, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceScreen() {
    return Scaffold(
      appBar: AppBar(
        title: Text('${_selectedModule!.displayName} Assistant'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            _pipeline.clearChatHistory();
            setState(() => _selectedModule = null);
          },
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _status,
                style: const TextStyle(fontSize: 15),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _isRecording ? null : _startRecording,
              icon: const Icon(Icons.mic),
              label: const Text('START Recording'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _isRecording ? _stopAndSend : null,
              icon: const Icon(Icons.send),
              label: const Text('STOP & SEND'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 24),
            if (_liveText.isNotEmpty) ...[
              const Text(
                '🤖 AI Response (streaming):',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  border: Border.all(color: Colors.green.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(_liveText, style: const TextStyle(fontSize: 15)),
              ),
            ],
            if (_audioUrl.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  border: Border.all(color: Colors.blue.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('🔊 Audio saved: $_audioUrl', style: TextStyle(fontSize: 13, color: Colors.blue.shade800)),
              ),
            ],
            if (_errorMsg.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  border: Border.all(color: Colors.red.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('⚠️ $_errorMsg', style: TextStyle(color: Colors.red.shade800, fontSize: 13)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
