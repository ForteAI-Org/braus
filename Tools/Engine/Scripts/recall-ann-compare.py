"""Compares an approximate nearest-neighbour index (usearch HNSW) with the exact search on the same vectors.

Evaluation only, never a dependency of Mecum: run it with the temporary evaluation environment described in
Documentation/Engine/MemoryRecall.md (usearch 2.26.4, numpy), on the float32 files `RecallScaleTests` writes with
MECUM_RECALL_EXPORT=1. The exact search is the inner product over every vector, which is what the Recall runs;
the loss measured is the index's alone, since both read the same vectors.

Usage: python3 -I recall-ann-compare.py <vectors.f32> <queries.f32> <out.json> [dimensions]
"""
import json
import sys
import time

import numpy as np
from usearch.index import Index


def load(path, dimensions):
    data = np.fromfile(path, dtype="<f4")
    assert data.size % dimensions == 0, path
    return data.reshape(-1, dimensions)


def main():
    vectors_path, queries_path, out_path = sys.argv[1:4]
    dimensions = int(sys.argv[4]) if len(sys.argv) > 4 else 384
    vectors = load(vectors_path, dimensions)
    queries = load(queries_path, dimensions)
    limits = [10, 48]
    exact_times = []
    exact = []
    for query in queries:
        started = time.perf_counter()
        scores = vectors @ query
        top = np.argsort(-scores)[: max(limits)]
        exact_times.append((time.perf_counter() - started) * 1000)
        exact.append(top)
    report = {"vectors": int(vectors.shape[0]), "queries": int(queries.shape[0]), "dimensions": dimensions,
              "exact numpy ms p50": float(np.percentile(exact_times, 50)), "exact numpy ms p95": float(np.percentile(exact_times, 95)),
              "configurations": []}
    for connectivity, expansion_add, expansion_search in [(16, 128, 64), (16, 128, 128), (32, 256, 256)]:
        index = Index(ndim=dimensions, metric="ip", dtype="f32", connectivity=connectivity, expansion_add=expansion_add,
                      expansion_search=expansion_search)
        started = time.perf_counter()
        index.add(np.arange(vectors.shape[0]), vectors)
        build = time.perf_counter() - started
        recalls = {k: [] for k in limits}
        times = []
        for query, truth in zip(queries, exact):
            started = time.perf_counter()
            found = index.search(query, max(limits))
            times.append((time.perf_counter() - started) * 1000)
            keys = list(found.keys)
            for k in limits:
                recalls[k].append(len(set(keys[:k]) & set(truth[:k].tolist())) / k)
        report["configurations"].append({
            "connectivity": connectivity, "expansion_add": expansion_add, "expansion_search": expansion_search,
            "build s": build, "memory bytes": int(index.memory_usage),
            "recall@10": float(np.mean(recalls[10])), "recall@48": float(np.mean(recalls[48])),
            "min recall@48": float(np.min(recalls[48])),
            "search ms p50": float(np.percentile(times, 50)), "search ms p95": float(np.percentile(times, 95)),
        })
    with open(out_path, "w") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
