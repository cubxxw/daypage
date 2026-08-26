package app.daypage.android.sync

import app.daypage.android.data.SyncOutboxEntity
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest

class SyncContractFixtureTest {
    @Test
    fun pushFixtureRoundTripsThroughAndroidWireModel() {
        val fixture = JSONObject(resource("sync-push-v1.json"))
        val operation = fixture.getJSONArray("p_operations").getJSONObject(0)
        val entity = SyncOutboxEntity(
            operationId = operation.getString("operation_id"),
            memoId = operation.getString("memo_id"),
            kind = operation.getString("kind"),
            revision = operation.getLong("revision"),
            modifiedAt = operation.getString("modified_at"),
            contentHash = operation.getString("content_hash"),
            deviceId = operation.getString("device_id"),
            payloadJson = operation.getJSONObject("payload").toString(),
            sizeBytes = operation.getInt("size_bytes"),
        )

        val encoded = entity.asWireJson()
        assertEquals("upsert", encoded.getString("kind"))
        assertEquals("ios", encoded.getJSONObject("payload").getString("source"))
        assertEquals(operation.getString("operation_id"), encoded.getString("operation_id"))
    }

    @Test
    fun exactReceiptFixtureIsAccepted() {
        val fixture = JSONObject(resource("sync-push-result-v1.json"))
        val result = parsePushResult(fixture)

        assertEquals(1, result.accepted.size)
        assertEquals("applied", result.accepted.single().status)
        assertEquals(1, result.rejectedOperationIds.size)
    }

    @Test
    fun pullFixturePreservesMonotonicCursor() {
        val fixture = JSONObject(resource("sync-pull-page-v1.json"))
        val page = parseRemotePage(fixture)

        assertTrue(page.isValid(after = 40))
        assertEquals(page.changes.last().changeSequence, page.nextCursor)
        assertEquals("macos", page.changes.first().source)
        assertEquals("MacBook Pro", page.changes.first().device)
        assertEquals("raw/2026-08-25.md", page.changes.first().vaultPath)
        assertEquals("{\"condition\":\"晴\"}", page.changes.first().weatherJson)
    }

    @Test
    fun malformedCursorCannotAdvanceLocalState() {
        val fixture = JSONObject(resource("sync-pull-page-v1.json"))
        fixture.put("next_cursor", 999)

        assertFalse(parseRemotePage(fixture).isValid(after = 40))
    }

    @Test
    fun v2FixturesDecodeAndBindTheCanonicalAttachmentManifest() {
        val push = JSONObject(resource("sync-push-v2.json"))
        val operation = push.getJSONArray("p_operations").getJSONObject(0)
        val attachments = operation.getJSONObject("payload").getJSONArray("attachments")
        assertEquals(2, operation.getInt("protocol_version"))
        assertEquals(
            operation.getString("attachment_manifest_hash"),
            manifestHash(attachments),
        )

        val pull = JSONObject(resource("sync-pull-page-v2.json"))
        val change = pull.getJSONArray("changes").getJSONObject(0)
        assertEquals(change.getString("attachment_manifest_hash"), manifestHash(change.getJSONArray("attachments")))
        assertEquals("photo.jpg", change.getJSONArray("attachments").getJSONObject(0).getString("original_filename"))

        val receipt = JSONObject(resource("sync-push-result-v2.json"))
        assertEquals(
            operation.getString("attachment_manifest_hash"),
            receipt.getJSONArray("accepted").getJSONObject(0).getString("attachment_manifest_hash"),
        )
        assertTrue(JSONObject(resource("attachment-upload-prepared-v2.json")).has("reservation_id"))
    }

    private fun manifestHash(attachments: org.json.JSONArray): String {
        fun lengthPrefix(value: String): String = "${value.toByteArray(Charsets.UTF_8).size}:$value"
        val records = (0 until attachments.length())
            .map { attachments.getJSONObject(it) }
            .sortedBy { it.getInt("position") }
            .joinToString("") { attachment ->
                val fields = listOf(
                    attachment.getInt("position").toString(),
                    attachment.getString("kind"),
                    attachment.getString("content_sha256"),
                    attachment.getLong("size_bytes").toString(),
                    attachment.getString("mime_type"),
                    attachment.getString("object_key"),
                    attachment.getString("original_filename"),
                    attachment.opt("duration_ms").takeUnless { it == null || it == JSONObject.NULL }?.toString() ?: "",
                    attachment.opt("transcript").takeUnless { it == null || it == JSONObject.NULL }?.toString() ?: "",
                    attachment.opt("transcription_status").takeUnless { it == null || it == JSONObject.NULL }?.toString() ?: "",
                )
                lengthPrefix(fields.joinToString("") { lengthPrefix(it) })
            }
        val canonical = lengthPrefix("2") + records
        return MessageDigest.getInstance("SHA-256")
            .digest(canonical.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    private fun resource(name: String): String = requireNotNull(
        javaClass.classLoader?.getResourceAsStream(name),
    ).bufferedReader().use { it.readText() }
}
