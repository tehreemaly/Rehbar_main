class AppConfig {
  // ── Gemini API Key (Required for STT, Chat, and Embeddings) ─────────
  static String geminiApiKey = '';

  // ── OpenAI API Key (Required for Whisper STT) ─────────
  static String openAIApiKey = '';

  // ── ElevenLabs API Key (Required for TTS) ─────────
  static String elevenLabsApiKey = 'sk_e16b51ea5f676c978b89bb3ab26c946d3939a430754afcca';

  // How long to wait for API responses
  static const Duration responseTimeout = Duration(seconds: 60);
}
