package app.daypage.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AndroidVaultStoreTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun appendUsesCanonicalRawPathAndMemoSeparator() {
        val root = temporaryFolder.newFolder("vault")
        val store = AndroidVaultStore.forTesting(root)
        val first = memo(
            id = "20000000-0000-4000-8000-000000000001",
            body = "第一条 Android Noter",
        )
        val second = memo(
            id = "20000000-0000-4000-8000-000000000002",
            body = "second note",
        )

        val firstWrite = store.append(first)
        store.append(second)

        assertEquals("raw/2026-08-25.md", firstWrite.vaultPath)
        val raw = store.rawFile("2026-08-25").readText()
        assertEquals(1, raw.windowed(AndroidVaultStore.MEMO_SEPARATOR.length)
            .count { it == AndroidVaultStore.MEMO_SEPARATOR })
        assertTrue(raw.contains("id: 20000000-0000-4000-8000-000000000001"))
        assertTrue(raw.contains("type: text"))
        assertTrue(raw.contains("created: 2026-08-25T00:00:00Z"))
        assertTrue(raw.contains("entity_mentions: []"))
        assertTrue(raw.contains("attachments: []"))
        assertTrue(raw.endsWith("second note"))
        val records = store.readAll("30000000-0000-4000-8000-000000000001")
        assertEquals(2, records.size)
        assertEquals("第一条 Android Noter", records.first().memo.body)
        assertEquals("second note", records.last().memo.body)
    }

    @Test
    fun remoteChangesReplaceCanonicalBlocksAndApplyTombstonesIdempotently() {
        val root = temporaryFolder.newFolder("remote-vault")
        val store = AndroidVaultStore.forTesting(root)
        val original = memo(
            id = "20000000-0000-4000-8000-000000000001",
            body = "local version",
        )
        store.append(original)
        val remote = original.copy(
            body = "来自另一台 Mac",
            revision = 4,
            sourceDeviceId = "30000000-0000-4000-8000-000000000002",
            weatherJson = "{\"condition\":\"晴\"}",
            device = "MacBook Pro",
            source = "macos",
            vaultPath = "raw/2026-08-24.md",
        )

        store.applyRemoteChanges(listOf(remote))
        store.applyRemoteChanges(listOf(remote))

        assertTrue(store.rawFile("2026-08-25").readText().isEmpty())
        val raw = store.rawFile("2026-08-24").readText()
        assertEquals(1, raw.lineSequence().count { it.startsWith("id:") })
        assertTrue(raw.contains("weather: \"晴\""))
        assertTrue(raw.contains("device: \"MacBook Pro\""))
        assertTrue(raw.endsWith("来自另一台 Mac"))

        store.applyRemoteChanges(listOf(remote.copy(deletedAt = "2026-08-25T00:03:00Z")))

        assertTrue(store.rawFile("2026-08-24").readText().isEmpty())
    }

    private fun memo(id: String, body: String) = MemoEntity(
        id = id,
        type = "text",
        body = body,
        createdAt = "2026-08-25T00:00:00Z",
        modifiedAt = "2026-08-25T00:00:00Z",
        revision = 1,
        sourceDeviceId = "30000000-0000-4000-8000-000000000001",
    )
}
