# utils.py
import os
import pdfplumber
import docx
import unicodedata
import openai
import pinecone
import logging
import asyncio

# ---------------- Logging ----------------
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

# ---------------- Text Extraction ----------------
def read_pdf(file_path):
    try:
        text = ""
        with pdfplumber.open(file_path) as pdf:
            for page in pdf.pages:
                t = page.extract_text()
                if t:
                    text += t + "\n"
        return text
    except Exception as e:
        logging.error(f"Failed to read PDF {file_path}: {e}")
        return ""

def read_docx(file_path):
    try:
        doc = docx.Document(file_path)
        return "\n".join([p.text for p in doc.paragraphs])
    except Exception as e:
        logging.error(f"Failed to read DOCX {file_path}: {e}")
        return ""

def read_txt(file_path):
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        logging.error(f"Failed to read TXT {file_path}: {e}")
        return ""

def clean_unicode(text):
    return unicodedata.normalize("NFKC", text)

def chunk_text(text, size=500, overlap=50):
    chunks = []
    start = 0
    while start < len(text):
        end = start + size
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        start += size - overlap
    return chunks

def process_document(file_path, filename):
    if filename.endswith(".pdf"):
        text = read_pdf(file_path)
    elif filename.endswith(".docx"):
        text = read_docx(file_path)
    elif filename.endswith(".txt"):
        text = read_txt(file_path)
    else:
        logging.warning(f"Unsupported file type: {filename}")
        return []

    text = clean_unicode(text)
    chunks = chunk_text(text)
    return [{"text": c, "source": filename} for c in chunks]

def read_documents(folder):
    all_chunks = []
    for file in os.listdir(folder):
        if file.startswith("."):
            continue
        path = os.path.join(folder, file)
        chunks = process_document(path, file)
        all_chunks.extend(chunks)
        logging.info(f"Processed {file}, {len(chunks)} chunks")
    logging.info(f"Total chunks from folder '{folder}': {len(all_chunks)}")
    return all_chunks

# ---------------- Embeddings ----------------
def generate_embeddings(chunks, model="text-embedding-3-small"):
    vectors = []
    for i, chunk in enumerate(chunks):
        try:
            resp = openai.Embedding.create(model=model, input=chunk["text"])
            vector = resp["data"][0]["embedding"]
            vectors.append({
                "text": chunk["text"],
                "source": chunk["source"],
                "vector": vector
            })
            if (i + 1) % 50 == 0:
                logging.info(f"Generated embeddings for {i+1} chunks")
        except Exception as e:
            logging.error(f"Failed embedding for chunk {i} ({chunk['source']}): {e}")
    logging.info(f"Generated embeddings for {len(vectors)} chunks")
    return vectors

# ---------------- Pinecone Storage ----------------
async def store_vectors_async(vectors, index_name="village-knowledge"):
    try:
        pinecone.init(
            api_key=os.environ.get("PINECONE_API_KEY"),
            environment=os.environ.get("PINECONE_ENV")
        )
        if index_name not in pinecone.list_indexes():
            pinecone.create_index(index_name, dimension=1536)
        index = pinecone.Index(index_name)

        # Upsert in batches asynchronously
        batch_size = 50
        for i in range(0, len(vectors), batch_size):
            batch = vectors[i:i+batch_size]
            to_upsert = [
                (str(i+j), v["vector"], {"text": v["text"], "source": v["source"]})
                for j, v in enumerate(batch)
            ]
            index.upsert(vectors=to_upsert)
            logging.info(f"Upserted batch {i//batch_size + 1}/{(len(vectors)-1)//batch_size + 1}")
        logging.info(f"All {len(vectors)} vectors stored in Pinecone index '{index_name}'")
    except Exception as e:
        logging.error(f"Pinecone storage failed: {e}")

# ---------------- Helper for FastAPI ----------------
def run_pipeline(folder="documents", index_name="village-knowledge"):
    chunks = read_documents(folder)
    vectors = generate_embeddings(chunks)
    asyncio.run(store_vectors_async(vectors, index_name=index_name))
    return len(vectors)
