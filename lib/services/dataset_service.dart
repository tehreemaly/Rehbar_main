// lib/services/dataset_service.dart
//
// In-memory dataset service with semantic vector search.
// Loads text files from assets/datasets/, embeds chunks via
// OpenAI Embeddings API, and retrieves the most relevant
// chunks using cosine similarity — replacing ChromaDB.

import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../config/app_config.dart';

enum AppModule {
  flood('Flood', 'assets/datasets/flood.txt'),
  womensHealth('Women\'s Health', 'assets/datasets/women_health.txt'),
  education('Education', 'assets/datasets/education.txt'),
  agriculture('Agriculture', 'assets/datasets/agriculture.txt'),
  general('General', ''); // General module doesn't use a specific dataset

  final String displayName;
  final String assetPath;
  const AppModule(this.displayName, this.assetPath);
}

/// A text chunk together with its pre-computed embedding vector.
class _EmbeddedChunk {
  final String text;
  final List<double> embedding;
  _EmbeddedChunk(this.text, this.embedding);
}

class DatasetService {
  // Cache: module → list of chunks with pre-computed embeddings
  final Map<AppModule, List<_EmbeddedChunk>> _embeddingCache = {};

  // Raw text cache (to avoid re-reading assets)
  final Map<AppModule, String> _rawTextCache = {};

  /// True while background embedding work is in progress for a module.
  final Map<AppModule, bool> _loadingModules = {};

  // ── Constants ──────────────────────────────────────────────────────────────
  static const int _chunkSize = 500;
  static const int _overlap = 100;
  // OpenAI limits were 50, Gemini rate limits may vary but we can safely batch.
  // Gemini text-embedding-004 has a strong free tier.
  static const int _batchSize = 25;
  static const String _embeddingModel = 'models/text-embedding-004';

  // ─────────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────────

  /// Loads the dataset text for [module] and pre-computes embeddings.
  /// Safe to call repeatedly — subsequent calls are no-ops.
  Future<void> prefetchModule(AppModule module) async {
    if (module == AppModule.general) return;
    if (_embeddingCache.containsKey(module)) return;
    if (_loadingModules[module] == true) return; // already in progress

    _loadingModules[module] = true;

    try {
      // 1. Load raw text from asset bundle
      if (!_rawTextCache.containsKey(module)) {
        final text = await rootBundle.loadString(module.assetPath);
        _rawTextCache[module] = text;
        print('[DatasetService] Loaded ${module.displayName}: ${text.length} chars');
      }

      final text = _rawTextCache[module]!;
      if (text.isEmpty) {
        _embeddingCache[module] = [];
        return;
      }

      // 2. Split into overlapping chunks
      final chunks = _chunkText(text);
      print('[DatasetService] ${module.displayName}: ${chunks.length} chunks');

      // 3. Embed all chunks in batches
      final embeddedChunks = <_EmbeddedChunk>[];
      for (var i = 0; i < chunks.length; i += _batchSize) {
        final batch = chunks.sublist(
          i,
          (i + _batchSize).clamp(0, chunks.length),
        );
        final embeddings = await _getEmbeddings(batch);
        for (var j = 0; j < batch.length; j++) {
          embeddedChunks.add(_EmbeddedChunk(batch[j], embeddings[j]));
        }
      }

      _embeddingCache[module] = embeddedChunks;
      print('[DatasetService] ${module.displayName}: embeddings cached (${embeddedChunks.length})');
    } catch (e) {
      print('[DatasetService] Error loading ${module.assetPath}: $e');
      _embeddingCache[module] = [];
    } finally {
      _loadingModules[module] = false;
    }
  }

  /// Returns the most semantically relevant chunks for [query] from the
  /// given [module]'s dataset, ranked by cosine similarity.
  ///
  /// Falls back to basic keyword matching if the API key is missing or
  /// embedding calls fail.
  Future<String> getRelevantContext(
    AppModule module,
    String query, {
    int topK = 5,
    int chunkSize = 500,
    int overlap = 100,
  }) async {
    if (module == AppModule.general) return '';

    // Make sure module is loaded
    await prefetchModule(module);

    final chunks = _embeddingCache[module];
    if (chunks == null || chunks.isEmpty) return '';

    // ── Semantic path (preferred) ────────────────────────────────────────
    if (AppConfig.geminiApiKey.trim().isNotEmpty) {
      try {
        final queryEmbedding = await _getEmbedding(query);

        // Score every chunk by cosine similarity
        final scored = chunks.map((c) {
          final sim = _cosineSimilarity(queryEmbedding, c.embedding);
          return (chunk: c.text, score: sim);
        }).toList();

        scored.sort((a, b) => b.score.compareTo(a.score));
        final best = scored.take(topK).map((e) => e.chunk).toList();
        return best.join('\n\n...\n\n');
      } catch (e) {
        print('[DatasetService] Embedding search failed, falling back to keyword: $e');
      }
    }

    // ── Keyword fallback (no API key or embedding failed) ────────────────
    return _keywordFallback(module, query, topK: topK);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Private helpers
  // ─────────────────────────────────────────────────────────────────────────

  /// Split [text] into overlapping chunks.
  List<String> _chunkText(String text) {
    final chunks = <String>[];
    int start = 0;
    while (start < text.length) {
      final end = (start + _chunkSize).clamp(0, text.length);
      final chunk = text.substring(start, end).trim();
      if (chunk.isNotEmpty) chunks.add(chunk);
      start += _chunkSize - _overlap;
    }
    return chunks;
  }

  /// Embed a single piece of text via OpenAI Embeddings API.
  Future<List<double>> _getEmbedding(String text) async {
    final results = await _getEmbeddings([text]);
    return results.first;
  }

  /// Embed a batch of texts in a single API call using Gemini.
  Future<List<List<double>>> _getEmbeddings(List<String> texts) async {
    if (AppConfig.geminiApiKey.isEmpty) {
      throw Exception('Gemini API key is required for embeddings.');
    }

    final requests = texts.map((t) => {
      'model': _embeddingModel,
      'content': {
        'parts': [{'text': t}]
      }
    }).toList();

    final response = await http.post(
      Uri.parse('https://generativelanguage.googleapis.com/v1beta/$_embeddingModel:batchEmbedContents?key=${AppConfig.geminiApiKey.trim()}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'requests': requests}),
    );

    if (response.statusCode != 200) {
      throw Exception('Gemini Embeddings failed (${response.statusCode}): ${response.body}');
    }

    final json = jsonDecode(response.body);
    final embeddingsData = json['embeddings'] as List;

    return embeddingsData.map<List<double>>((item) {
      final values = item['values'] as List;
      return values.map<double>((v) => (v as num).toDouble()).toList();
    }).toList();
  }

  /// Cosine similarity between two vectors.
  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    double dot = 0, magA = 0, magB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      magA += a[i] * a[i];
      magB += b[i] * b[i];
    }
    final denom = sqrt(magA) * sqrt(magB);
    return denom == 0 ? 0.0 : dot / denom;
  }

  /// Basic keyword matching fallback (original algorithm).
  String _keywordFallback(AppModule module, String query, {int topK = 5}) {
    final text = _rawTextCache[module] ?? '';
    if (text.isEmpty) return '';

    final chunks = _chunkText(text);

    final queryWords = query
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 3)
        .toList();

    if (queryWords.isEmpty) {
      return chunks.take(topK).join('\n\n');
    }

    final scored = chunks.map((chunk) {
      final lower = chunk.toLowerCase();
      int score = 0;
      for (var word in queryWords) {
        int idx = lower.indexOf(word);
        while (idx != -1) {
          score++;
          idx = lower.indexOf(word, idx + word.length);
        }
      }
      return (chunk: chunk, score: score);
    }).toList();

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(topK).map((e) => e.chunk).join('\n\n...\n\n');
  }
}
