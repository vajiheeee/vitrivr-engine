package org.vitrivr.engine.base.features.external.implementations.classification

import org.vitrivr.engine.base.features.external.api.ConditionalImageCaptioningApi
import org.vitrivr.engine.base.features.external.api.ZeroShotClassificationApi
import org.vitrivr.engine.base.features.external.common.ExternalFesAnalyser
import org.vitrivr.engine.base.features.external.common.FesExtractor
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.CANDIDATE_LIMIT_PARAMETER_DEFAULT
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.CANDIDATE_LIMIT_PARAMETER_NAME
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.CAPTION_HOST_PARAMETER_DEFAULT
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.CAPTION_HOST_PARAMETER_NAME
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.CAPTION_MODEL_PARAMETER_DEFAULT
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.CAPTION_MODEL_PARAMETER_NAME
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.CAPTION_PROMPT_PARAMETER_DEFAULT
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.CAPTION_PROMPT_PARAMETER_NAME
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.CLASSES_PARAMETER_NAME
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.THRESHOLD_PARAMETER_NAME
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.TOPK_PARAMETER_NAME
import org.vitrivr.engine.core.context.Context
import org.vitrivr.engine.core.model.content.element.ImageContent
import org.vitrivr.engine.core.model.content.impl.memory.InMemoryTextContent
import org.vitrivr.engine.core.model.descriptor.struct.LabelDescriptor
import org.vitrivr.engine.core.model.metamodel.Schema
import org.vitrivr.engine.core.model.retrievable.Retrievable
import org.vitrivr.engine.core.model.types.Value
import org.vitrivr.engine.core.operators.Operator
import java.util.*

/**
 * Image classification extractor.
 *
 * If the operator provides a static "classes" parameter, this behaves like the
 * original zero-shot classifier. If "classes" is absent, candidate tags are
 * generated dynamically with conditional image captioning and then verified
 * and ranked with OpenCLIP.
 *
 * @author Ralph Gasser
 * @author Vajiheh Ansari
 * @version 1.1
 */
class ImageClassificationExtractor : FesExtractor<ImageContent, LabelDescriptor> {

    constructor(
        input: Operator<out Retrievable>,
        field: Schema.Field<ImageContent, LabelDescriptor>,
        analyser: ExternalFesAnalyser<ImageContent, LabelDescriptor>,
        context: Context
    ) : super(input, field, analyser, context)

    constructor(
        input: Operator<out Retrievable>,
        name: String,
        analyser: ExternalFesAnalyser<ImageContent, LabelDescriptor>,
        context: Context
    ) : super(input, name, analyser, context)

    /** OpenCLIP zero-shot API used to rank candidate tags. */
    private val api by lazy {
        ZeroShotClassificationApi(
            this.host,
            this.model,
            this.timeoutMs,
            this.pollingIntervalMs,
            this.retries
        )
    }

    /** Captioning API used only when no static classes are configured. */
    private val captioningApi by lazy {
        ConditionalImageCaptioningApi(
            this.context[this.name, CAPTION_HOST_PARAMETER_NAME] ?: CAPTION_HOST_PARAMETER_DEFAULT,
            this.context[this.name, CAPTION_MODEL_PARAMETER_NAME] ?: CAPTION_MODEL_PARAMETER_DEFAULT,
            this.timeoutMs,
            this.pollingIntervalMs,
            this.retries
        )
    }

    /** Common words that should not become visual candidate tags. */
    private val stopWords = setOf(
        "a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "with", "without",
        "for", "from", "by", "is", "are", "was", "were", "be", "being", "been", "this",
        "that", "these", "those", "it", "its", "as", "there", "has", "have", "had",
        "image", "picture", "photo", "photograph", "scene", "show", "shows", "showing",
        "depict", "depicts", "depicted", "visible", "main", "object", "objects", "answer",
        "question", "what", "who", "where", "when", "why", "how", "list", "near", "next",
        "beside", "background", "foreground"
    )

    override fun extract(batch: List<Retrievable>): List<List<LabelDescriptor>> {
        val staticClasses = this.context[this.name, CLASSES_PARAMETER_NAME]
            ?.split(",")
            ?.map { it.trim() }
            ?.filter { it.isNotBlank() }
            ?.takeIf { it.isNotEmpty() }

        val topK = this.context[this.name, TOPK_PARAMETER_NAME]?.toIntOrNull() ?: 1
        val threshold = this.context[this.name, THRESHOLD_PARAMETER_NAME]?.toFloatOrNull() ?: 0.0f

        return batch.map { retrievable ->
            retrievable.content.filterIsInstance<ImageContent>().flatMap { image ->
                val classes = staticClasses ?: generateDynamicCandidates(image)

                if (staticClasses == null) {
                    logger.info {
                        "Dynamic candidate tags for retrievable ${retrievable.id}: ${classes.joinToString(", ")}"
                    }
                }

                val probabilities = this.api.analyse(image to classes)
                    ?: throw IllegalStateException("OpenCLIP returned no classification result.")

                probabilities.zip(classes)
                    .map { (confidence, label) ->
                        LabelDescriptor(
                            UUID.randomUUID(),
                            retrievable.id,
                            mapOf(
                                "label" to Value.String(label),
                                "confidence" to Value.Float(confidence.value.toFloat())
                            ),
                            this.field
                        )
                    }
                    .filter { it.confidence.value >= threshold }
                    .sortedByDescending { it.confidence.value }
                    .take(topK)
            }
        }
    }

    /**
     * Generates candidate labels for one image through conditional image captioning.
     */
    private fun generateDynamicCandidates(image: ImageContent): List<String> {
        val prompt = this.context[this.name, CAPTION_PROMPT_PARAMETER_NAME]
            ?: CAPTION_PROMPT_PARAMETER_DEFAULT

        val response = this.captioningApi.analyse(
            image to InMemoryTextContent(prompt)
        )?.value?.trim().orEmpty()

        if (response.isBlank()) {
            throw IllegalStateException("Captioning returned no candidate tags.")
        }

        logger.info { "Captioning candidate response: $response" }

        val generatedOnly = stripPromptEcho(response, prompt)
        logger.info { "Captioning response after prompt removal: $generatedOnly" }

        val limit = this.context[this.name, CANDIDATE_LIMIT_PARAMETER_NAME]
            ?.toIntOrNull()
            ?.takeIf { it > 0 }
            ?: CANDIDATE_LIMIT_PARAMETER_DEFAULT

        val candidates = parseCandidateTags(generatedOnly).take(limit)

        if (candidates.isEmpty()) {
            throw IllegalStateException("Could not derive candidate tags from captioning response: $response")
        }

        return candidates
    }

    /**
     * Removes a conditional-captioning prompt when the model echoes it in the
     * decoded output. BLIP commonly returns the prompt together with the
     * generated continuation.
     */
    private fun stripPromptEcho(response: String, prompt: String): String {
        val trimmedResponse = response.trim()
        val trimmedPrompt = prompt.trim()

        if (trimmedResponse.startsWith(trimmedPrompt, ignoreCase = true)) {
            return trimmedResponse.substring(trimmedPrompt.length)
                .trim()
                .trimStart(':', '-', ',', '.', ' ')
        }

        val answerMarker = Regex("""(?i)\banswer\s*:\s*""").find(trimmedResponse)
        if (answerMarker != null) {
            return trimmedResponse.substring(answerMarker.range.last + 1).trim()
        }

        return trimmedResponse
    }

    /**
     * Parses either a comma-separated tag response or a normal caption.
     *
     * The prompt normally produces comma-separated concepts. Token extraction
     * is kept as a fallback because captioning models do not always follow the
     * requested output format exactly.
     */
    private fun parseCandidateTags(response: String): List<String> {
        val normalized = response
            .lowercase(Locale.ROOT)
            .replace(Regex("""^(answer|tags?)\s*:\s*"""), "")
            .trim()

        val commaSeparated = normalized
            .split(Regex("""[,;|\n]+"""))
            .map { cleanCandidate(it) }
            .filter { it.isNotBlank() }

        val tokenFallback = normalized
            .replace(Regex("""[^a-z0-9\- ]+"""), " ")
            .split(Regex("""\s+"""))
            .map { it.trim() }
            .filter { it.length > 2 && it !in stopWords }

        val combined = if (commaSeparated.size > 1) {
            commaSeparated + tokenFallback
        } else {
            tokenFallback
        }

        return combined
            .map { cleanCandidate(it) }
            .filter { it.isNotBlank() && it !in stopWords }
            .distinct()
    }

    /** Cleans one candidate label while preserving short noun phrases. */
    private fun cleanCandidate(value: String): String {
        return value
            .trim()
            .replace(Regex("""^(a|an|the)\s+"""), "")
            .replace(Regex("""[^a-z0-9\- ]"""), "")
            .replace(Regex("""\s+"""), " ")
            .trim()
    }
}
