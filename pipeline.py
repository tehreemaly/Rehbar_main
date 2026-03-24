import pdfplumber
import docx
import os
import unicodedata


def read_pdf(file):
    text = ""
    with pdfplumber.open(file) as pdf:
        for page in pdf.pages:
            t = page.extract_text()
            if t:
                text += t + "\n"
    return text


def read_docx(file):
    document = docx.Document(file)
    return "\n".join([p.text for p in document.paragraphs])


def read_txt(file):
    with open(file, "r", encoding="utf-8") as f:
        return f.read()


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


def process_document(path, filename):

    if filename.endswith(".pdf"):
        text = read_pdf(path)

    elif filename.endswith(".docx"):
        text = read_docx(path)

    elif filename.endswith(".txt"):
        text = read_txt(path)

    else:
        return []

    text = clean_unicode(text)

    chunks = chunk_text(text)

    # attach metadata (source file)
    chunk_objects = []

    for chunk in chunks:
        chunk_objects.append({
            "text": chunk,
            "source": filename
        })

    return chunk_objects


def read_documents(folder):

    all_chunks = []

    for file in os.listdir(folder):

        if file.startswith("."):
            continue

        path = os.path.join(folder, file)

        doc_chunks = process_document(path, file)

        all_chunks.extend(doc_chunks)

    return all_chunks


def main():

    chunks = read_documents("documents")

    print("Total chunks:", len(chunks))

    if chunks:
        print("\nSample Chunk:\n")
        print(chunks[0]["text"][:200])
        print("\nSource File:", chunks[0]["source"])
    else:
        print("No text found.")


if __name__ == "__main__":
    main()
