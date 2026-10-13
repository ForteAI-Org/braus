//
//  EmbeddingModelManifest.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Memory

/// EmbeddingModelManifest pins one local embedding model: its Hub id and exact revision, the license, the
/// files the runtime reads with their sha256, and what its model card prescribes (the formats of a query and
/// of a document, the pooling, the context). A model directory is accepted only when every pinned file has
/// its digest: another revision, a damaged download or a different tokenizer is refused at load, so a vector
/// never silently comes from artifacts other than the ones its space names. The files are installed by an
/// explicit setup step (`Tools/Engine/Scripts/fetch-recall-model.sh`); Mecum never downloads at run time.
public struct EmbeddingModelManifest: Sendable, Equatable {

    public let modelID: String
    public let revision: String
    public let license: String
    /// The directory's name under the models folder: the model's name and its revision.
    public let directoryName: String
    public let weightsFile: String
    public let weightsDigest: String
    public let weightsBytes: Int
    public let tokenizerDigest: String
    public let configurationDigest: String
    public let pooling: Pooling
    /// The dimensions of a vector, as the model's configuration states its hidden size.
    public let dimensions: Int
    public let queryPrefix: String
    public let documentPrefix: String
    public let maximumTokens: Int

    public enum Pooling: String, Sendable, Equatable {
        case mean, cls
    }

    /// intfloat/multilingual-e5-small (MIT): 12 layers, 384 dimensions, mean pooling, "query: " and "passage: "
    /// prefixes as its model card requires for retrieval.
    public static let multilingualE5Small = EmbeddingModelManifest(
        modelID            : "intfloat/multilingual-e5-small",
        revision           : "614241f622f53c4eeff9890bdc4f31cfecc418b3",
        license            : "MIT",
        directoryName      : "multilingual-e5-small@614241f622f53c4eeff9890bdc4f31cfecc418b3",
        weightsFile        : "model.safetensors",
        weightsDigest      : "1a55775f53449dac10a2bcbc312469fac40b96d53198c407081a831f81c98477",
        weightsBytes       : 470_641_600,
        tokenizerDigest    : "0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39",
        configurationDigest: "69137736cab8b8903a07fe8afaafdda25aac55415a12a55d1bffa9f581abf959",
        pooling            : .mean,
        dimensions         : 384,
        queryPrefix        : "query: ",
        documentPrefix     : "passage: ",
        maximumTokens      : 512
    )

    /// ibm-granite/granite-embedding-107m-multilingual (Apache-2.0): 6 layers, 384 dimensions, bfloat16 weights,
    /// CLS pooling, no prefixes. It replaces EmbeddingGemma, whose official artifacts are gated.
    public static let graniteEmbedding107MMultilingual = EmbeddingModelManifest(
        modelID            : "ibm-granite/granite-embedding-107m-multilingual",
        revision           : "d6cffd338414d6a1c1f5decfad5fec62eebc90d5",
        license            : "Apache-2.0",
        directoryName      : "granite-embedding-107m-multilingual@d6cffd338414d6a1c1f5decfad5fec62eebc90d5",
        weightsFile        : "model.safetensors",
        weightsDigest      : "ae6f20cc5dc433041118c900b652d87532e1335dade78c37765f0b94d1161283",
        weightsBytes       : 214_000_232,
        tokenizerDigest    : "7fc9e475f2ac473f070052d92b0c46ec2b91d9cd672935feb6fd837a65d33f78",
        configurationDigest: "aa3b6a5d1d6efeacdb844fb8ba773556463af2195003ad5e70a6f014d11be9cf",
        pooling            : .cls,
        dimensions         : 384,
        queryPrefix        : "",
        documentPrefix     : "",
        maximumTokens      : 512
    )

    /// The space this model's vectors belong to, known from the manifest alone: a generation can name it before
    /// the model's files are installed, and its vectors are computed once they are.
    public var space: EmbeddingSpace {
        EmbeddingSpace(modelID: modelID, modelRevision: revision, weightsDigest: weightsDigest, tokenizerDigest: tokenizerDigest,
                       dimensions: dimensions, pooling: pooling.rawValue, queryPrefix: queryPrefix, documentPrefix: documentPrefix,
                       maximumTokens: maximumTokens)
    }

    /// Every model this build knows, by a short name for configuration and diagnosis.
    public static let known: [String: EmbeddingModelManifest] = [
        "e5-small"   : multilingualE5Small,
        "granite-107m": graniteEmbedding107MMultilingual,
    ]
}
