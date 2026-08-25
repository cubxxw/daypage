package app.daypage.android.sync

import app.daypage.android.data.SyncOutboxEntity
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

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

    private fun resource(name: String): String = requireNotNull(
        javaClass.classLoader?.getResourceAsStream(name),
    ).bufferedReader().use { it.readText() }
}
