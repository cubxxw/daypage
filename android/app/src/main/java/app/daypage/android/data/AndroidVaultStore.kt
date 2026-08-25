package app.daypage.android.data

import android.content.Context
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

data class VaultWrite(
    val vaultPath: String,
    val markdown: String,
)

data class VaultRecord(
    val memo: MemoEntity,
    val vaultPath: String,
    val markdown: String,
)

fun interface RemoteVaultWriter {
    fun applyRemoteChanges(changes: List<MemoEntity>)
}

/**
 * Canonical raw-data writer. Room accelerates queries and owns the sync queue;
 * this Markdown file remains the durable, human-readable local source.
 */
class AndroidVaultStore private constructor(private val vaultRoot: File) : RemoteVaultWriter {
    constructor(context: Context) : this(File(context.filesDir, "vault"))

    @Synchronized
    fun append(memo: MemoEntity): VaultWrite {
        require(memo.deletedAt == null)
        val date = memo.createdAt.take(10)
        require(DATE.matches(date))
        val rawDirectory = File(vaultRoot, "raw").apply { mkdirs() }
        val target = File(rawDirectory, "$date.md")
        val markdown = memo.toCanonicalMarkdown()
        val existing = target.takeIf(File::exists)?.readText(Charsets.UTF_8).orEmpty()
        val combined = if (existing.isBlank()) markdown else existing + MEMO_SEPARATOR + markdown
        atomicWrite(target, combined)
        return VaultWrite(vaultPath = "raw/$date.md", markdown = markdown)
    }

    /**
     * Mirrors accepted remote mutations into the canonical raw Vault. The call
     * is idempotent: each memo UUID is removed before its latest block is
     * appended, and tombstones only remove the matching block.
     */
    @Synchronized
    override fun applyRemoteChanges(changes: List<MemoEntity>) {
        if (changes.isEmpty()) return
        val rawDirectory = File(vaultRoot, "raw").apply { mkdirs() }
        val blocksByFile = rawDirectory.listFiles { file -> file.isFile && file.extension == "md" }
            .orEmpty()
            .associateWithTo(linkedMapOf()) { file ->
                file.readText(Charsets.UTF_8)
                    .takeIf(String::isNotBlank)
                    ?.split(MEMO_SEPARATOR)
                    ?.toMutableList()
                    ?: mutableListOf()
            }
        val dirty = linkedSetOf<File>()

        changes.forEach { change ->
            val normalizedId = UUID.fromString(change.id).toString().lowercase()
            blocksByFile.forEach { (file, blocks) ->
                if (blocks.removeAll { block -> blockMemoId(block) == normalizedId }) dirty += file
            }
            if (change.deletedAt == null) {
                val date = change.vaultPath
                    ?.let(VAULT_PATH::matchEntire)
                    ?.groupValues
                    ?.get(1)
                    ?: change.createdAt.take(10)
                require(DATE.matches(date))
                val target = File(rawDirectory, "$date.md")
                blocksByFile.getOrPut(target, ::mutableListOf).add(change.toCanonicalMarkdown())
                dirty += target
            }
        }

        dirty.forEach { file ->
            atomicWrite(file, blocksByFile[file].orEmpty().joinToString(MEMO_SEPARATOR))
        }
    }

    fun rawFile(date: String): File = File(File(vaultRoot, "raw"), "$date.md")

    @Synchronized
    fun readAll(deviceId: String): List<VaultRecord> {
        val rawDirectory = File(vaultRoot, "raw")
        if (!rawDirectory.exists()) return emptyList()
        return rawDirectory.listFiles { file -> file.isFile && file.extension == "md" }
            .orEmpty()
            .sortedBy { it.name }
            .flatMap { file ->
                val vaultPath = "raw/${file.name}"
                file.readText(Charsets.UTF_8)
                    .split(MEMO_SEPARATOR)
                    .mapNotNull { block ->
                        parseMemo(block, deviceId)?.copy(vaultPath = vaultPath)?.let { memo ->
                            VaultRecord(
                                memo = memo,
                                vaultPath = vaultPath,
                                markdown = block,
                            )
                        }
                    }
            }
    }

    private fun atomicWrite(target: File, content: String) {
        val temporary = File.createTempFile(".${target.name}.", ".tmp", target.parentFile)
        try {
            temporary.writeText(content, Charsets.UTF_8)
            runCatching {
                Files.move(
                    temporary.toPath(),
                    target.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }.recoverCatching { error ->
                if (error !is AtomicMoveNotSupportedException) throw error
                Files.move(
                    temporary.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }.getOrThrow()
        } finally {
            temporary.delete()
        }
    }

    internal companion object {
        const val MEMO_SEPARATOR = "\n\n<!-- daypage-memo-separator -->\n\n"
        private val DATE = Regex("^\\d{4}-\\d{2}-\\d{2}$")
        private val VAULT_PATH = Regex("^raw/(\\d{4}-\\d{2}-\\d{2})\\.md$")

        fun forTesting(vaultRoot: File): AndroidVaultStore = AndroidVaultStore(vaultRoot)

        private fun parseMemo(block: String, deviceId: String): MemoEntity? {
            val lines = block.lines()
            if (lines.firstOrNull() != "---") return null
            val closing = lines.drop(1).indexOfFirst { it == "---" }
                .takeIf { it >= 0 }
                ?.plus(1)
                ?: return null
            val metadata = lines.subList(1, closing).mapNotNull { line ->
                val separator = line.indexOf(':')
                if (separator <= 0 || line.startsWith(" ")) return@mapNotNull null
                line.take(separator) to line.drop(separator + 1).trim()
            }.toMap()
            val id = metadata["id"]?.let { runCatching { UUID.fromString(it).toString() }.getOrNull() }
                ?: return null
            val created = metadata["created"]?.takeIf { it.length >= 20 } ?: return null
            val bodyStart = (closing + 1 until lines.size)
                .firstOrNull { lines[it].isNotBlank() }
                ?: lines.size
            return MemoEntity(
                id = id.lowercase(),
                type = metadata["type"] ?: "text",
                body = lines.drop(bodyStart).joinToString("\n"),
                createdAt = created,
                modifiedAt = created,
                revision = 1,
                sourceDeviceId = deviceId,
                pinnedAt = metadata["pinned_at"],
                locationJson = parseLocationJson(lines.subList(1, closing)),
                weatherJson = metadata["weather"]?.let(::yamlScalarAsJson),
                device = metadata["device"]?.let(::yamlUnquote),
                source = "android",
            )
        }

        private fun blockMemoId(block: String): String? = block.lineSequence()
            .firstOrNull { it.startsWith("id:") }
            ?.substringAfter(':')
            ?.trim()
            ?.let { runCatching { UUID.fromString(it).toString().lowercase() }.getOrNull() }

        private fun parseLocationJson(lines: List<String>): String? {
            val locationIndex = lines.indexOfFirst { it.trim() == "location:" }
            if (locationIndex < 0) return null
            val result = JSONObject()
            lines.drop(locationIndex + 1).takeWhile { it.startsWith("  ") }.forEach { line ->
                val key = line.trim().substringBefore(':')
                val value = line.substringAfter(':').trim()
                when (key) {
                    "lat", "lng" -> value.toDoubleOrNull()?.let { result.put(key, it) }
                    "name", "address" -> result.put(key, yamlUnquote(value))
                }
            }
            return result.takeIf { it.length() > 0 }?.toString()
        }

        private fun yamlScalarAsJson(value: String): String = JSONObject.quote(yamlUnquote(value))

        private fun yamlUnquote(value: String): String {
            val trimmed = value.trim()
            if (trimmed.length < 2 || trimmed.first() != '"' || trimmed.last() != '"') return trimmed
            return runCatching { JSONTokener(trimmed).nextValue() as String }.getOrDefault(trimmed)
        }
    }
}

internal fun MemoEntity.toCanonicalMarkdown(): String = buildString {
    appendLine("---")
    appendLine("id: ${UUID.fromString(id).toString().uppercase()}")
    appendLine("type: $type")
    appendLine("created: $createdAt")
    pinnedAt?.let { appendLine("pinned_at: $it") }
    locationJson?.let(::locationFrontmatter)?.takeIf(String::isNotBlank)?.let(::append)
    weatherJson?.let(::weatherScalar)?.takeIf(String::isNotBlank)?.let {
        appendLine("weather: ${yamlQuote(it)}")
    }
    (device ?: "Android").takeIf(String::isNotBlank)?.let {
        appendLine("device: ${yamlQuote(it)}")
    }
    appendLine("entity_mentions: []")
    appendLine("attachments: []")
    appendLine("---")
    appendLine()
    append(body)
}

private fun locationFrontmatter(json: String): String = runCatching {
    val location = JSONObject(json)
    buildString {
        appendLine("location:")
        listOf("name", "address").forEach { key ->
            if (location.has(key) && !location.isNull(key)) {
                appendLine("  $key: ${yamlQuote(location.getString(key))}")
            }
        }
        listOf("lat", "lng").forEach { key ->
            if (location.has(key) && !location.isNull(key)) appendLine("  $key: ${location.getDouble(key)}")
        }
    }
}.getOrDefault("")

private fun weatherScalar(json: String): String = runCatching {
    when (val value = JSONTokener(json).nextValue()) {
        is JSONObject -> value.optString("condition").takeIf(String::isNotBlank)
            ?: value.optString("weather").takeIf(String::isNotBlank)
            ?: value.toString()
        is String -> value
        else -> value.toString()
    }
}.getOrDefault(json)

private fun yamlQuote(value: String): String = buildString {
    append('"')
    value.forEach { character ->
        when (character) {
            '\\' -> append("\\\\")
            '"' -> append("\\\"")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> append(character)
        }
    }
    append('"')
}
