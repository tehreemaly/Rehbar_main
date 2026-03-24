// server.js
//
// Single-file WebSocket server — all logic consolidated here.
//
// Protocol (Flutter → Backend):
//   { type: "audio_chunk", data: "<base64 encoded audio bytes>" }
//   { type: "end" }   ← signals all audio has been sent
//
// Protocol (Backend → Flutter):
//   { type: "status",      message: "processing" }
//   { type: "text_chunk",  data: "<word or phrase>" }
//   { type: "text_done" }
//   { type: "audio_start" }
//   { type: "audio",       url: "<audio url>" }
//   { type: "audio_done" }
//   { type: "error",       message: "<description>" }

const WebSocket = require('ws');
const axios = require('axios');

const PORT = 3000;
const wss = new WebSocket.Server({ port: PORT });

// ─────────────────────────────────────────────────────────────────────────────
// FORMATTER — helpers to build standardised JSON messages
// ─────────────────────────────────────────────────────────────────────────────
const fmt = {
  status:     (message) => JSON.stringify({ type: 'status',      message }),
  textChunk:  (data)    => JSON.stringify({ type: 'text_chunk',  data }),
  textDone:   ()        => JSON.stringify({ type: 'text_done' }),
  audioStart: ()        => JSON.stringify({ type: 'audio_start' }),
  audio:      (url)     => JSON.stringify({ type: 'audio',       url }),
  audioDone:  ()        => JSON.stringify({ type: 'audio_done' }),
  error:      (message) => JSON.stringify({ type: 'error',       message }),
};

// ─────────────────────────────────────────────────────────────────────────────
// STT STUB — decodes the base64 audio and returns a placeholder transcript.
// Replace this with a real Whisper / Google STT call when ready.
// ─────────────────────────────────────────────────────────────────────────────
async function transcribeAudio(audioBuffer) {
  // audioBuffer is a Buffer of raw audio bytes (AAC-LC, 16 kHz mono)
  console.log(`[STT] Received ${audioBuffer.length} bytes of audio`);

  // TODO: Replace with real STT, e.g.:
  //   const FormData = require('form-data');
  //   const form = new FormData();
  //   form.append('file', audioBuffer, { filename: 'audio.m4a', contentType: 'audio/m4a' });
  //   form.append('model', 'whisper-1');
  //   const res = await axios.post('https://api.openai.com/v1/audio/transcriptions', form, {
  //     headers: { ...form.getHeaders(), Authorization: `Bearer ${process.env.OPENAI_API_KEY}` }
  //   });
  //   return res.data.text;

  return 'Hello this is a test transcript from the backend stub.';
}

// ─────────────────────────────────────────────────────────────────────────────
// AI PIPELINE — sends the transcript to the RAG backend and gets a response.
// Expects a Python FastAPI backend running at localhost:8000 with POST /query.
// Falls back to a stub response if the pipeline is unreachable.
// ─────────────────────────────────────────────────────────────────────────────
async function getAIResponse(query) {
  try {
    const res = await axios.post('http://localhost:8000/query', { query });
    return res.data.response;
  } catch (err) {
    console.warn('[Pipeline] Could not reach AI pipeline, using stub response.');
    return `You said: "${query}". (AI pipeline not connected yet.)`;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TTS STUB — generates TTS audio and returns its URL.
// Replace with a real ElevenLabs / OpenAI TTS call when ready.
// ─────────────────────────────────────────────────────────────────────────────
async function generateAudio(text) {
  console.log(`[TTS] Generating audio for: "${text.slice(0, 60)}..."`);
  // TODO: Replace with real TTS call
  return 'https://dummy-audio-url.com/audio.mp3';
}

// ─────────────────────────────────────────────────────────────────────────────
// STREAM TEXT — sends a response string word-by-word over the WebSocket.
// ─────────────────────────────────────────────────────────────────────────────
async function streamText(socket, text) {
  const words = text.split(' ');
  for (const word of words) {
    if (socket.readyState !== WebSocket.OPEN) break;
    await new Promise(res => setTimeout(res, 80)); // small delay per word
    socket.send(fmt.textChunk(word + ' '));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CONNECTION HANDLER
// ─────────────────────────────────────────────────────────────────────────────
wss.on('connection', (socket) => {
  console.log('[WS] Client connected');

  // Buffer to collect incoming audio chunks
  const audioChunks = [];

  socket.on('message', async (message) => {
    let data;
    try {
      data = JSON.parse(message.toString());
    } catch {
      socket.send(fmt.error('Invalid JSON message.'));
      return;
    }

    // ── audio_chunk: accumulate base64 audio data ────────────────────────
    if (data.type === 'audio_chunk') {
      if (typeof data.data !== 'string') {
        socket.send(fmt.error('audio_chunk must have a base64 "data" field.'));
        return;
      }
      const chunkBuffer = Buffer.from(data.data, 'base64');
      audioChunks.push(chunkBuffer);
      console.log(`[WS] audio_chunk received — ${chunkBuffer.length} bytes`);
      return;
    }

    // ── end: all audio received — run the full pipeline ──────────────────
    if (data.type === 'end') {
      console.log('[WS] End signal received — starting pipeline');

      try {
        // 1. Combine all chunks into one Buffer
        const fullAudioBuffer = Buffer.concat(audioChunks);
        audioChunks.length = 0; // free memory

        // 2. STT — transcribe the audio
        socket.send(fmt.status('transcribing'));
        const transcript = await transcribeAudio(fullAudioBuffer);
        console.log(`[STT] Transcript: "${transcript}"`);

        // 3. AI pipeline — get response
        socket.send(fmt.status('processing'));
        const aiText = await getAIResponse(transcript);

        // 4. Stream response text word-by-word
        await streamText(socket, aiText);
        socket.send(fmt.textDone());

        // 5. TTS — generate audio
        const audioUrl = await generateAudio(aiText);

        // 6. Send audio
        socket.send(fmt.audioStart());
        socket.send(fmt.audio(audioUrl));
        socket.send(fmt.audioDone());

        console.log('[WS] Pipeline complete');

      } catch (err) {
        console.error('[WS] Pipeline error:', err);
        if (socket.readyState === WebSocket.OPEN) {
          socket.send(fmt.error('Server error: ' + err.message));
        }
      }

      return;
    }

    // ── Legacy support: user_message (text-only, no audio) ───────────────
    if (data.type === 'user_message') {
      try {
        socket.send(fmt.status('processing'));
        const aiText = await getAIResponse(data.message);
        await streamText(socket, aiText);
        socket.send(fmt.textDone());
        const audioUrl = await generateAudio(aiText);
        socket.send(fmt.audioStart());
        socket.send(fmt.audio(audioUrl));
        socket.send(fmt.audioDone());
      } catch (err) {
        socket.send(fmt.error('Server error: ' + err.message));
      }
      return;
    }

    // ── Unknown message type ─────────────────────────────────────────────
    socket.send(fmt.error(`Unknown message type: "${data.type}"`));
  });

  socket.on('close', () => {
    console.log('[WS] Client disconnected');
    audioChunks.length = 0;
  });

  socket.on('error', (err) => {
    console.error('[WS] Socket error:', err.message);
  });
});

console.log(`WebSocket server running on ws://localhost:${PORT}`);