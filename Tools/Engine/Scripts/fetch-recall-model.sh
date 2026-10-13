#!/bin/bash
#
# Installs one local embedding model of the Recall at the exact revision its manifest pins
# (Sources/Engine/LocalEmbedding/EmbeddingModelManifest.swift), and refuses it unless every file the runtime
# reads has the pinned sha256. This is the explicit setup step: Braus never downloads at run time, and a
# missing or refused model leaves the lexical index answering, saying so.
#
# Downloading is a setup action someone decides to take: it reaches huggingface.co and writes a few hundred
# megabytes. --verify-only reads a folder already installed and touches no network.
#
# Usage: fetch-recall-model.sh <e5-small|granite-107m> [models-folder]
#        fetch-recall-model.sh --verify-only <e5-small|granite-107m> [models-folder]
#        The folder defaults to ~/Library/Application Support/Braus/Models, where the app and braus look
#        when BRAUS_RECALL_MODELS does not name another.

set -euo pipefail

verify_only=0
if [[ "${1:-}" == "--verify-only" ]]; then
    verify_only=1
    shift
fi
name=${1:?"usage: fetch-recall-model.sh [--verify-only] <e5-small|granite-107m> [models-folder]"}
folder=${2:-"$HOME/Library/Application Support/Braus/Models"}

case "$name" in
    e5-small)
        repo=intfloat/multilingual-e5-small
        revision=614241f622f53c4eeff9890bdc4f31cfecc418b3
        license=MIT
        weights=1a55775f53449dac10a2bcbc312469fac40b96d53198c407081a831f81c98477
        tokenizer=0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39
        configuration=69137736cab8b8903a07fe8afaafdda25aac55415a12a55d1bffa9f581abf959
        directory="multilingual-e5-small@$revision"
        ;;
    granite-107m)
        repo=ibm-granite/granite-embedding-107m-multilingual
        revision=d6cffd338414d6a1c1f5decfad5fec62eebc90d5
        license=Apache-2.0
        weights=ae6f20cc5dc433041118c900b652d87532e1335dade78c37765f0b94d1161283
        tokenizer=7fc9e475f2ac473f070052d92b0c46ec2b91d9cd672935feb6fd837a65d33f78
        configuration=aa3b6a5d1d6efeacdb844fb8ba773556463af2195003ad5e70a6f014d11be9cf
        directory="granite-embedding-107m-multilingual@$revision"
        ;;
    *)
        echo "unknown model $name: e5-small or granite-107m" >&2
        exit 2
        ;;
esac

target="$folder/$directory"
files=(config.json tokenizer.json tokenizer_config.json special_tokens_map.json model.safetensors)

if [[ $verify_only == 0 ]]; then
    echo "downloading $repo at $revision ($license) into $target"
    mkdir -p "$target"
    for file in "${files[@]}"; do
        curl --silent --show-error --location --fail --max-time 3600 \
            "https://huggingface.co/$repo/resolve/$revision/$file" --output "$target/$file.part"
        mv "$target/$file.part" "$target/$file"
    done
fi

check() {
    local file=$1 expected=$2
    if [[ ! -f "$target/$file" ]]; then
        echo "refused: $target/$file is missing" >&2
        return 1
    fi
    local actual
    actual=$(shasum -a 256 "$target/$file" | cut -d' ' -f1)
    if [[ "$actual" != "$expected" ]]; then
        echo "refused: $file has sha256 $actual, the manifest pins $expected" >&2
        return 1
    fi
    echo "  $file $actual"
}

echo "$repo@$revision in $target"
status=0
check model.safetensors "$weights" || status=1
check tokenizer.json "$tokenizer" || status=1
check config.json "$configuration" || status=1
if [[ $status != 0 ]]; then
    echo "the model is refused: Braus will not load it, and its lexical index answers" >&2
    exit 1
fi
echo "verified: every pinned file has its sha256"
