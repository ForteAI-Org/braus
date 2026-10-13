// LocalEmbeddingKernels.c
// Braus
//
// ACCELERATE_NEW_LAPACK is defined by the target (Package.swift), so the Accelerate module is built with it.

#include <Accelerate/Accelerate.h>
#include "LocalEmbeddingKernels.h"

void braus_sgemm(bool transposeA, bool transposeB, int m, int n, int k, float alpha, const float *a, int lda,
                 const float *b, int ldb, float beta, float *c, int ldc) {
    cblas_sgemm(CblasRowMajor, transposeA ? CblasTrans : CblasNoTrans, transposeB ? CblasTrans : CblasNoTrans,
                m, n, k, alpha, a, lda, b, ldb, beta, c, ldc);
}
