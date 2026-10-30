package org.vitrivr.engine.module.features.feature.external.implementations.clip

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class CLIPAutoTaggerTest {

    @Test
    fun ranksMostSimilarTagsFirst() {
        val image = floatArrayOf(1.0f, 0.0f, 0.0f)

        val tags = linkedMapOf(
            "piano" to floatArrayOf(0.9f, 0.1f, 0.0f),
            "music" to floatArrayOf(0.8f, 0.2f, 0.0f),
            "car" to floatArrayOf(0.0f, 1.0f, 0.0f)
        )

        val result = CLIPAutoTagger.rank(
            imageVector = image,
            tagVectors = tags,
            topK = 2
        )

        assertEquals(2, result.size)
        assertEquals("piano", result[0].tag)
        assertEquals("music", result[1].tag)
        assertTrue(result[0].similarity > result[1].similarity)
    }

    @Test
    fun appliesThreshold() {
        val image = floatArrayOf(1.0f, 0.0f)

        val tags = mapOf(
            "close" to floatArrayOf(1.0f, 0.0f),
            "far" to floatArrayOf(0.0f, 1.0f)
        )

        val result = CLIPAutoTagger.rank(
            imageVector = image,
            tagVectors = tags,
            topK = 5,
            threshold = 0.5
        )

        assertEquals(1, result.size)
        assertEquals("close", result.first().tag)
    }
}
