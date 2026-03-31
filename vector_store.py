# vector_store.py — FAISS local vector store
# Embeds text chunks using sentence-transformers and persists a FAISS index
# to the `faiss_index/` folder on disk.

import os
import json
import logging
import numpy as np
import faiss
from sentence_transformers import SentenceTransformer

# ────────────────── Configuration ──────────────────
BASE_DIR       = os.path.dirname(os.path.abspath(__file__))
INDEX_FOLDER   = os.path.join(BASE_DIR, "faiss_index")
INDEX_FILE     = os.path.join(INDEX_FOLDER, "index.faiss")
METADATA_FILE  = os.path.join(INDEX_FOLDER, "metadata.json")
EMBEDDING_MODEL = "all-MiniLM-L6-v2"        # 384-dim, fast & lightweight

logger = logging.getLogger("vector_store")

# Lazy-loaded globals
_model: SentenceTransformer | None = None


def _get_model() -> SentenceTransformer:
    """Lazy-load the embedding model so import stays cheap."""
    global _model
    if _model is None:
        logger.info("Loading embedding model '%s' …", EMBEDDING_MODEL)
        _model = SentenceTransformer(EMBEDDING_MODEL)
    return _model


def _load_existing():
    """Return (faiss_index, metadata_list) from disk, or fresh ones."""
    if os.path.exists(INDEX_FILE) and os.path.exists(METADATA_FILE):
        index = faiss.read_index(INDEX_FILE)
        with open(METADATA_FILE, "r", encoding="utf-8") as f:
            metadata = json.load(f)
        logger.info("Loaded existing FAISS index with %d vectors.", index.ntotal)
        return index, metadata
    return None, []


def save_to_index(chunks: list[dict]) -> None:
    """
    Embed *chunks* and append them to the FAISS index on disk.

    Each chunk is a dict with at least:
        { "text": str, "source": str }

    The function:
      1. Generates embeddings with sentence-transformers.
      2. Loads any existing FAISS index (or creates a new one).
      3. Adds the new vectors.
      4. Writes the index + metadata to `faiss_index/`.
    """
    if not chunks:
        logger.warning("save_to_index called with an empty chunk list — skipping.")
        return

    model = _get_model()
    texts = [c["text"] for c in chunks]

    logger.info("Generating embeddings for %d chunk(s) …", len(texts))
    embeddings = model.encode(texts, show_progress_bar=False)
    embeddings = np.array(embeddings, dtype="float32")

    # Load or create
    index, metadata = _load_existing()
    dim = embeddings.shape[1]

    if index is None:
        index = faiss.IndexFlatL2(dim)
        metadata = []

    index.add(embeddings)

    for chunk in chunks:
        metadata.append({
            "text": chunk["text"],
            "source": chunk.get("source", "unknown"),
        })

    # Persist
    print("--- SAVING INDEX TO DISK ---")
    os.makedirs(INDEX_FOLDER, exist_ok=True)
    faiss.write_index(index, INDEX_FILE)
    with open(METADATA_FILE, "w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2, ensure_ascii=False)

    logger.info(
        "✅ FAISS index saved to '%s'  —  total vectors: %d",
        INDEX_FOLDER,
        index.ntotal,
    )


def search_chunks(query: str, top_k: int = 3) -> list[dict]:
    """
    Search the FAISS index for the top_k chunks most similar to the query.
    Returns a list of dicts containing 'text', 'source', and 'score'.
    """
    model = _get_model()
    index, metadata = _load_existing()

    if index is None or index.ntotal == 0:
        logger.warning("Search called but FAISS index is empty or missing.")
        return []

    logger.info("Generating embedding for search query …")
    query_vector = model.encode([query], show_progress_bar=False)
    query_vector = np.array(query_vector, dtype="float32")

    distances, indices = index.search(query_vector, top_k)

    results = []
    for score, idx in zip(distances[0], indices[0]):
        if idx != -1 and idx < len(metadata):
            chunk = metadata[idx]
            results.append({
                "text": chunk.get("text", ""),
                "source": chunk.get("source", "unknown"),
                "score": float(score)
            })

    return results
