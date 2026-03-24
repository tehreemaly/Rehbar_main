// lib/models/transcription_result.dart
//
// Data class representing messages received from the backend over WebSocket.
//
// Supported message types from server.js:
//   { "type": "status",      "message": "transcribing" | "processing" }
//   { "type": "text_chunk",  "data": "<word>" }
//   { "type": "text_done" }
//   { "type": "audio_start" }
//   { "type": "audio",       "url": "<url>" }
//   { "type": "audio_done" }
//   { "type": "error",       "message": "<description>" }

class TranscriptionResult {
  /// Type of the message received (status, text_chunk, text_done, audio, etc.)
  final String messageType;

  /// Full accumulated text (only populated on a 'done' synthetic result).
  final String transcript;

  /// A single text chunk word/phrase (populated for type == 'text_chunk').
  final String? textChunk;

  /// Audio URL from TTS service (populated for type == 'audio').
  final String? audioUrl;

  /// Backend status text (populated for type == 'status').
  final String? statusMessage;

  /// Non-null when the backend returned an error.
  final String? errorMessage;

  /// True when transcript is populated and no error occurred.
  bool get isSuccess => errorMessage == null && transcript.isNotEmpty;

  const TranscriptionResult({
    this.messageType = '',
    this.transcript = '',
    this.textChunk,
    this.audioUrl,
    this.statusMessage,
    this.errorMessage,
  });

  /// Parses a single JSON message received over WebSocket from server.js.
  factory TranscriptionResult.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String? ?? '';

    switch (type) {
      case 'text_chunk':
        return TranscriptionResult(
          messageType: 'text_chunk',
          textChunk: json['data'] as String? ?? '',
        );

      case 'text_done':
        return const TranscriptionResult(messageType: 'text_done');

      case 'audio_start':
        return const TranscriptionResult(messageType: 'audio_start');

      case 'audio':
        return TranscriptionResult(
          messageType: 'audio',
          audioUrl: json['url'] as String?,
        );

      case 'audio_done':
        return const TranscriptionResult(messageType: 'audio_done');

      case 'status':
        return TranscriptionResult(
          messageType: 'status',
          statusMessage: json['message'] as String?,
        );

      case 'error':
        return TranscriptionResult(
          messageType: 'error',
          errorMessage: json['message'] as String? ?? 'Unknown backend error',
        );

      // Legacy support
      case 'result':
        return TranscriptionResult(
          messageType: 'result',
          transcript: json['transcript'] as String? ?? '',
        );

      default:
        return TranscriptionResult(messageType: type);
    }
  }

  @override
  String toString() => 'TranscriptionResult('
      'type: "$messageType", '
      'transcript: "$transcript", '
      'chunk: "$textChunk", '
      'status: "$statusMessage", '
      'error: "$errorMessage")';
}
