#!/usr/bin/env python3
"""Reference token ids and embeddings for the Recall's local models, from Hugging Face's own code.

Evaluation only: it runs in a temporary environment with torch, transformers and tokenizers, never on a
user's machine and never as a product dependency. It writes the fixture the Swift runtime is checked
against (LocalEmbeddingTests): the token ids the fast tokenizer gives, and the normalized embedding
each model gives, in float32, with the model card's pooling and prefixes.

usage: recall-embedding-reference.py <models-dir> <output.json>
"""

import json
import sys

import torch
import torch.nn.functional as F
from transformers import AutoModel, AutoTokenizer

TEXTS = [
    "Export the edited document as PNG",
    "Esporta il documento modificato in PNG",
    "Esportare <documento> da Anteprima con formato e destinazione variabili",
    "Set <output_name>.<output_extension> in the Name field",
    "Imposta il nome {output_name}.{extension} nel campo Nome",
    "Confirm the export",
    "Trova foto_demo.png nella cartella delle prove",
    "Ruota l'immagine a destra",
    "Open the Export dialog… then choose “JPEG”",
    "  leading and   repeated   spaces  ",
    "ÀÉÎÕÜ àéîõü çñß œæ ﬁ ﬂ ＡＢＣ１２３",
    "Tab\tand\nnewline",
    "Emoji 📷 and symbols © ™ € ½",
    "exportieren, exporter, exportar",
    "the quick brown fox jumps over the lazy dog " * 3,
    "a",
    "",
    "mixed: esporta il file as PDF, all pages / tutte le pagine",
]

MODELS = {
    "multilingual-e5-small": {"pooling": "mean", "query": "query: ", "document": "passage: "},
    "granite-embedding-107m-multilingual": {"pooling": "cls", "query": "", "document": ""},
}


def embed(model, tokenizer, texts, pooling):
    batch = tokenizer(texts, max_length=512, padding=True, truncation=True, return_tensors="pt")
    with torch.no_grad():
        hidden = model(**batch).last_hidden_state
    if pooling == "mean":
        mask = batch["attention_mask"][..., None].bool()
        pooled = hidden.masked_fill(~mask, 0.0).sum(dim=1) / batch["attention_mask"].sum(dim=1)[..., None]
    else:
        pooled = hidden[:, 0]
    return F.normalize(pooled, p=2, dim=1)


def main():
    models_dir, output = sys.argv[1], sys.argv[2]
    torch.manual_seed(0)
    fixture = {"texts": TEXTS, "models": {}}
    for name, card in MODELS.items():
        path = f"{models_dir}/{name}"
        tokenizer = AutoTokenizer.from_pretrained(path)
        model = AutoModel.from_pretrained(path, dtype=torch.float32)
        model.eval()
        ids = [tokenizer(text)["input_ids"] for text in TEXTS]
        entry = {"pooling": card["pooling"], "token_ids": ids, "query": [], "document": []}
        for role in ("query", "document"):
            prefixed = [card[role] + text for text in TEXTS]
            vectors = embed(model, tokenizer, prefixed, card["pooling"])
            entry[role] = [[round(float(x), 7) for x in row] for row in vectors]
        fixture["models"][name] = entry
    with open(output, "w", encoding="utf-8") as handle:
        json.dump(fixture, handle, ensure_ascii=False)


if __name__ == "__main__":
    main()
