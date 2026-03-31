# ingestion.py — Document Handler
# Monitors ./datasets for new PDF/Word files, deduplicates via SHA-256,
# and splits new documents into 500-char chunks using utils.py.

import os
import sys
import json
import hashlib
import logging
import time

from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

from utils import process_document
from vector_store import save_to_index

# ────────────────── Configuration ──────────────────
WATCH_FOLDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "datasets")
HASH_STORE   = os.path.join(os.path.dirname(os.path.abspath(__file__)), "processed_files.json")
SUPPORTED_EXTENSIONS = (".pdf", ".docx")

# ────────────────── Logging ──────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("ingestion")

# ────────────────── Hash helpers ──────────────────

def _load_hashes() -> dict:
    """Load the hash→filename mapping from disk."""
    if os.path.exists(HASH_STORE):
        try:
            with open(HASH_STORE, "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            logger.warning("Could not read %s — starting with empty hash store.", HASH_STORE)
    return {}


def _save_hashes(hashes: dict) -> None:
    """Persist the hash→filename mapping to disk."""
    with open(HASH_STORE, "w", encoding="utf-8") as f:
        json.dump(hashes, f, indent=2)


def _file_sha256(file_path: str) -> str:
    """Return the hex SHA-256 digest of a file's contents."""
    h = hashlib.sha256()
    with open(file_path, "rb") as f:
        for block in iter(lambda: f.read(8192), b""):
            h.update(block)
    return h.hexdigest()

# ────────────────── Core processing ──────────────────

def handle_new_file(file_path: str) -> None:
    """
    Process a single file:
      1. Compute SHA-256 hash.
      2. Skip if already processed (duplicate).
      3. Otherwise, split into 500-char chunks via utils.process_document
         and log the results.
    """
    filename = os.path.basename(file_path)

    # Only handle supported file types
    if not filename.lower().endswith(SUPPORTED_EXTENSIONS):
        return

    logger.info("📄 New file detected: %s", filename)

    file_hash = _file_sha256(file_path)
    hashes = _load_hashes()

    if file_hash in hashes:
        logger.info(
            "⏭  Duplicate skipped: '%s' (identical content already processed as '%s').",
            filename,
            hashes[file_hash],
        )
        return

    # ── Process the document using utils.py ──
    chunks = process_document(file_path, filename)
    logger.info(
        "✅ Processed '%s' → %d chunk(s) of ~500 characters each.",
        filename,
        len(chunks),
    )

    # ── Save chunks to the FAISS vector store ──
    save_to_index(chunks)

    # Persist the hash so the file is not re-processed
    hashes[file_hash] = filename
    _save_hashes(hashes)

# ────────────────── Watchdog event handler ──────────────────

class DocumentEventHandler(FileSystemEventHandler):
    """React to newly created or moved-in files inside the watched folder."""

    def on_created(self, event):
        if event.is_directory:
            return
        # Small delay to let the OS finish writing the file
        time.sleep(0.5)
        handle_new_file(event.src_path)

    def on_moved(self, event):
        if event.is_directory:
            return
        time.sleep(0.5)
        handle_new_file(event.dest_path)

# ────────────────── Bootstrap existing files ──────────────────

def _process_existing_files() -> None:
    """Walk the datasets folder and process any files that are not yet hashed."""
    for root, _dirs, files in os.walk(WATCH_FOLDER):
        for fname in files:
            if fname.lower().endswith(SUPPORTED_EXTENSIONS):
                handle_new_file(os.path.join(root, fname))

# ────────────────── Entry point ──────────────────

def main() -> None:
    if not os.path.isdir(WATCH_FOLDER):
        os.makedirs(WATCH_FOLDER, exist_ok=True)
        logger.info("Created watch folder: %s", WATCH_FOLDER)

    # First pass: pick up any files already sitting in the folder
    logger.info("🔍 Scanning existing files in '%s' …", WATCH_FOLDER)
    _process_existing_files()

    # Start the file-system watcher
    observer = Observer()
    observer.schedule(DocumentEventHandler(), WATCH_FOLDER, recursive=True)
    observer.start()
    logger.info("👁  Watching '%s' for new PDF/Word files. Press Ctrl+C to stop.", WATCH_FOLDER)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        logger.info("🛑 Stopping watcher …")
        observer.stop()
    observer.join()
    logger.info("Done.")


if __name__ == "__main__":
    main()
