package org.vitrivr.engine.module.features.feature.external.implementations.clip

import kotlin.math.sqrt

/**
 * Ranks candidate tags for a CLIP image embedding using cosine similarity.
 *
 * This class is intentionally independent from FES and persistence. It only
 * compares an image vector with pre-computed CLIP text vectors and returns
 * the best matching tags.
 */
object CLIPAutoTagger {

    data class TagScore(
        val tag: String,
        val similarity: Double
    )

    fun rank(
        imageVector: FloatArray,
        tagVectors: Map<String, FloatArray>,
        topK: Int = 3,
        threshold: Double = 0.0
    ): List<TagScore> {
        require(imageVector.isNotEmpty()) { "Image vector must not be empty." }
        require(tagVectors.isNotEmpty()) { "At least one tag vector is required." }
        require(topK > 0) { "topK must be positive." }
        require(threshold in -1.0..1.0) { "threshold must be between -1.0 and 1.0." }

        val normalizedImage = normalize(imageVector)

        return tagVectors.map { (tag, vector) ->
            require(tag.isNotBlank()) { "Tag names must not be blank." }
            require(vector.size == imageVector.size) {
                "Tag vector for '$tag' has dimensionality ${vector.size}, expected ${imageVector.size}."
            }

            val similarity = dot(normalizedImage, normalize(vector)).coerceIn(-1.0, 1.0)
            TagScore(tag, similarity)
        }
            .filter { it.similarity >= threshold }
            .sortedByDescending { it.similarity }
            .take(topK)
    }

    private fun normalize(vector: FloatArray): FloatArray {
        require(vector.all { it.isFinite() }) { "CLIP vectors must contain only finite values." }

        val norm = sqrt(vector.sumOf { value -> value.toDouble() * value })
        require(norm > 0.0) { "CLIP vectors must not be zero vectors." }

        return FloatArray(vector.size) { index ->
            (vector[index].toDouble() / norm).toFloat()
        }
    }

    private fun dot(first: FloatArray, second: FloatArray): Double =
        first.indices.sumOf { index ->
            first[index].toDouble() * second[index].toDouble()
        }
}
