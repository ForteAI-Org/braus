// LocalEmbeddingKernels.h
// Braus
//
// The one matrix product the local embedding runtime needs, over Accelerate's current CBLAS interface. Swift
// cannot import that interface without a compiler define, so this C target owns the define and nothing else.

#ifndef LOCAL_EMBEDDING_KERNELS_H
#define LOCAL_EMBEDDING_KERNELS_H

#include <stdbool.h>

/// C = alpha * op(A) * op(B) + beta * C for row-major float32 matrices, where op transposes when asked. A is M x K
/// after op, B is K x N after op, C is M x N; lda, ldb and ldc are the row strides as stored.
void braus_sgemm(bool transposeA, bool transposeB, int m, int n, int k, float alpha, const float *a, int lda,
                 const float *b, int ldb, float beta, float *c, int ldc);

#endif
