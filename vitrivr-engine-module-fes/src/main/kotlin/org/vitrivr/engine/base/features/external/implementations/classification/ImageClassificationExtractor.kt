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
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.CAPTION_PROMPT_PARAMETER_NAME
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.CAPTION_PROMPTS_PARAMETER_DEFAULT
import org.vitrivr.engine.base.features.external.implementations.classification.ImageClassification.Companion.CAPTION_PROMPTS_PARAMETER_NAME
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
 * If static classes are configured, this behaves like the original zero-shot
 * classifier. Otherwise, it generates candidate concepts dynamically from
 * several short BLIP/BLIP2 captions and verifies/ranks them with OpenCLIP.
 *
 * @author Ralph Gasser
 * @author Vajiheh Ansari
 * @version 1.2
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

    /** Builds a captioning API client for the requested FES model. */
    private fun captioningApi(model: String) = ConditionalImageCaptioningApi(
        this.context[this.name, CAPTION_HOST_PARAMETER_NAME] ?: CAPTION_HOST_PARAMETER_DEFAULT,
        model,
        this.timeoutMs,
        this.pollingIntervalMs,
        this.retries
    )

    /** Common non-visual words that should never become tags. */
    private val stopWords = setOf(
        "a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "with", "without",
        "for", "from", "by", "is", "are", "was", "were", "be", "being", "been", "this",
        "that", "these", "those", "it", "its", "as", "there", "has", "have", "had",
        "image", "picture", "photo", "photograph", "scene", "show", "shows", "showing",
        "depict", "depicts", "depicted", "visible", "main", "object", "objects", "answer",
        "question", "what", "who", "where", "when", "why", "how", "list", "near", "next",
        "beside", "background", "foreground", "include", "includes", "including"
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
     * Generates dynamic candidates from multiple short captioning prompts.
     * The prompts are intentionally short to stay below BLIP generation limits.
     */
    private fun generateDynamicCandidates(image: ImageContent): List<String> {
        val prompts = configuredPrompts()
        val configuredModel = this.context[this.name, CAPTION_MODEL_PARAMETER_NAME] ?: CAPTION_MODEL_PARAMETER_DEFAULT
        val models = listOf(configuredModel, "blip").distinct()

        var lastFailure: Throwable? = null

        for (captionModel in models) {
            logger.info {
                "Dynamic tagging caption model attempt: $captionModel; prompts: ${prompts.joinToString(" | ")}"
            }

            try {
                val results = captioningApi(captionModel).analyseBatched(
                    prompts.map { image to InMemoryTextContent(it) }
                )

                val continuations = results.zip(prompts).mapNotNull { (result, prompt) ->
                    val raw = result.value.trim()
                    if (raw.isBlank()) {
                        null
                    } else {
                        logger.info { "Captioning response [$captionModel] for prompt '$prompt': $raw" }
                        stripPromptEcho(raw, prompt).takeIf { it.isNotBlank() }
                    }
                }

                val limit = this.context[this.name, CANDIDATE_LIMIT_PARAMETER_NAME]
                    ?.toIntOrNull()
                    ?.takeIf { it > 0 }
                    ?: CANDIDATE_LIMIT_PARAMETER_DEFAULT

                val candidates = continuations
                    .flatMap { parseCandidateTags(it) }
                    .distinct()
                    .take(limit)

                if (candidates.isNotEmpty()) {
                    if (captionModel != configuredModel) {
                        logger.warn {
                            "Caption model '$configuredModel' failed; using fallback model '$captionModel'."
                        }
                    }
                    return candidates
                }

                lastFailure = IllegalStateException(
                    "Caption model '$captionModel' returned no usable candidate tags."
                )
            } catch (t: Throwable) {
                lastFailure = t
                logger.warn {
                    "Caption model '$captionModel' failed during dynamic candidate generation: ${t.message}"
                }
            }
        }

        throw IllegalStateException(
            "All configured captioning models failed to generate dynamic candidate tags.",
            lastFailure
        )
    }

    /**
     * Reads either a pipe-separated prompt list or, for backward compatibility,
     * the old single caption_prompt parameter.
     */
    private fun configuredPrompts(): List<String> {
        val multi = this.context[this.name, CAPTION_PROMPTS_PARAMETER_NAME]
            ?.split("|")
            ?.map { it.trim() }
            ?.filter { it.isNotBlank() }
            ?.takeIf { it.isNotEmpty() }

        if (multi != null) return multi

        val single = this.context[this.name, CAPTION_PROMPT_PARAMETER_NAME]
            ?.trim()
            ?.takeIf { it.isNotBlank() }

        return single?.let { listOf(it) } ?: CAPTION_PROMPTS_PARAMETER_DEFAULT
    }

    /**
     * Removes a conditional-captioning prompt when the model echoes it.
     */
    private fun stripPromptEcho(response: String, prompt: String): String {
        val trimmedResponse = response.trim()
        val trimmedPrompt = prompt.trim()

        if (trimmedResponse.startsWith(trimmedPrompt, ignoreCase = true)) {
            return trimmedResponse.substring(trimmedPrompt.length)
                .trim()
                .trimStart(':', '-', ',', '.', ' ')
        }

        return trimmedResponse
    }

    /**
     * Converts a caption or tag-like response into candidate concepts.
     */
    private fun parseCandidateTags(response: String): List<String> {
        val normalized = response
            .lowercase(Locale.ROOT)
            .trim()

        val phraseCandidates = normalized
            .split(Regex("""[,;|\n]+"""))
            .map { cleanCandidate(it) }
            .filter { it.isNotBlank() }

        val tokenCandidates = normalized
            .replace(Regex("""[^a-z0-9\- ]+"""), " ")
            .split(Regex("""\s+"""))
            .map { it.trim() }
            .filter { it.length > 2 && it !in stopWords }

        return (phraseCandidates + tokenCandidates)
            .map { cleanCandidate(it) }
            .filter { it.isNotBlank() && it !in stopWords }
            .distinct()
    }

    /** Cleans one candidate while preserving useful short noun phrases. */
    private fun cleanCandidate(value: String): String {
        return value
            .trim()
            .replace(Regex("""^(a|an|the)\s+"""), "")
            .replace(Regex("""[^a-z0-9\- ]"""), "")
            .replace(Regex("""\s+"""), " ")
            .trim()
    }
}
