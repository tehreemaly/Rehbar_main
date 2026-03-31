# ai_expert.py — Rehbar AI Expert (RAG with FAISS + Gemini 1.5 Flash)
# Searches the local FAISS index for relevant chunks, then asks Gemini
# to answer the user's question in Urdu via FastAPI.

import os
from dotenv import load_dotenv
from google import genai
from google.genai import types
from fastapi import FastAPI
from pydantic import BaseModel
import uvicorn

# ────────────────── Configuration ──────────────────
load_dotenv()

BASE_DIR        = os.path.dirname(os.path.abspath(__file__))
INDEX_FOLDER    = os.path.join(BASE_DIR, "faiss_index")
INDEX_FILE      = os.path.join(INDEX_FOLDER, "index.faiss")
METADATA_FILE   = os.path.join(INDEX_FOLDER, "metadata.json")
EMBEDDING_MODEL = "all-MiniLM-L6-v2"
TOP_K           = 3  # number of chunks to retrieve

# Strict instructions to enforce constraints
SYSTEM_PROMPT = (
    "آپ کا نام رہبر ہے۔ آپ ایک مخلص اور مددگار دوست ہیں۔\n\n"
    "CRITICAL INSTRUCTIONS:\n"
    "1. ONLY answer in Urdu.\n"
    "2. ONLY use the information found in our provided documents (Context).\n"
    "3. If the answer cannot be found in the provided context, clearly state that you do not know."
)

from vector_store import search_chunks

# ────────────────── Configure Gemini ──────────────────
api_key = os.getenv("GEMINI_API_KEY")
if not api_key or api_key == "YOUR_GEMINI_API_KEY_HERE":
    print("⚠️ Warning: GEMINI_API_KEY not set. API calls will fail.")
    client = None
else:
    client = genai.Client(api_key=api_key)
    print("✅ Gemini 1.5 Flash configured using google.genai SDK.\n")


# ────────────────── Core RAG function ──────────────────
def ask_rehbar(query: str) -> str:
    """
    1. Search FAISS for the top-K most relevant chunks via vector_store.py
    2. Build a context block from those chunks.
    3. Send the system prompt + context + question to Gemini.
    4. Return the Urdu answer.
    """
    if not client:
        return "❌ Error: API Key missing. Please configure GEMINI_API_KEY in .env."

    # Step 1 & 2 — Retrieve chunks
    results = search_chunks(query, top_k=TOP_K)
    
    # Step 3 — Build context
    context_parts = []
    for rank, chunk in enumerate(results, start=1):
        source = chunk.get("source", "unknown")
        text = chunk.get("text", "")
        context_parts.append(f"[{rank}] (Source: {source})\n{text}")

    context_block = "\n\n".join(context_parts)

    # Step 4 — Build the full prompt
    full_prompt = (
        f"───── معلومات (Context) ─────\n"
        f"{context_block}\n\n"
        f"───── صارف کا سوال ─────\n"
        f"{query}"
    )

    # Step 5 — Ask Gemini overriding system instruction natively
    try:
        response = client.models.generate_content(
            model='gemini-1.5-flash',
            contents=full_prompt,
            config=types.GenerateContentConfig(
                system_instruction=SYSTEM_PROMPT,
                temperature=0.2,
            ),
        )
        return response.text
    except Exception as e:
        return f"❌ Error: {e}"

# ────────────────── FastAPI Server ──────────────────
app = FastAPI(title="Rehbar AI Expert")

class QueryRequest(BaseModel):
    query: str

class QueryResponse(BaseModel):
    response: str

@app.post("/query", response_model=QueryResponse)
def query_ai_expert(req: QueryRequest):
    answer = ask_rehbar(req.query)
    return QueryResponse(response=answer)

if __name__ == "__main__":
    print("=" * 60)
    print("  رہبر — Rehbar AI Fast API Server 🤖 listening on 8000")
    print("=" * 60)
    uvicorn.run(app, host="0.0.0.0", port=8000)
