package app.daypage.android.data

import android.app.Application
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class DayPageDatabaseTest {
    private lateinit var database: DayPageDatabase

    @Before
    fun setUp() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            DayPageDatabase::class.java,
        ).allowMainThreadQueries().build()
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun captureCommitsMemoAndOutboxTogether() = runTest {
        val memo = MemoEntity(
            id = "20000000-0000-4000-8000-000000000001",
            type = "text",
            body = "Android local first",
            createdAt = "2026-08-25T00:00:00Z",
            modifiedAt = "2026-08-25T00:00:00Z",
            revision = 1,
            sourceDeviceId = "30000000-0000-4000-8000-000000000001",
        )
        val operation = SyncOutboxEntity(
            operationId = "10000000-0000-4000-8000-000000000001",
            memoId = memo.id,
            kind = "upsert",
            revision = 1,
            modifiedAt = memo.modifiedAt,
            contentHash = "a".repeat(64),
            deviceId = memo.sourceDeviceId,
            payloadJson = "{}",
            sizeBytes = memo.body.length,
        )

        database.dayPageDao().capture(memo, operation)

        assertNotNull(database.dayPageDao().memo(memo.id))
        assertEquals(1, database.dayPageDao().observePendingCount().first())
    }

    @Test
    fun concurrentRemoteChangePreservesLocalMemoAsConflictCopy() = runTest {
        val local = MemoEntity(
            id = "20000000-0000-4000-8000-000000000001",
            type = "text",
            body = "local edit",
            createdAt = "2026-08-25T00:00:00Z",
            modifiedAt = "2026-08-25T00:02:00Z",
            revision = 2,
            sourceDeviceId = "30000000-0000-4000-8000-000000000001",
        )
        val pending = SyncOutboxEntity(
            operationId = "10000000-0000-4000-8000-000000000001",
            memoId = local.id,
            kind = "upsert",
            revision = 2,
            modifiedAt = local.modifiedAt,
            contentHash = "a".repeat(64),
            deviceId = local.sourceDeviceId,
            payloadJson = "{\"type\":\"text\",\"body\":\"local edit\"}",
            sizeBytes = local.body.length,
        )
        database.dayPageDao().capture(local, pending)
        val remote = local.copy(
            body = "remote edit",
            modifiedAt = "2026-08-25T00:03:00Z",
            revision = 3,
            sourceDeviceId = "30000000-0000-4000-8000-000000000002",
        )

        val vaultChanges = database.dayPageDao().applyRemoteChanges(listOf(remote))
        database.dayPageDao().setCursor(
            SyncCursorEntity("40000000-0000-4000-8000-000000000001", 41),
        )

        assertEquals("remote edit", database.dayPageDao().memo(local.id)?.body)
        assertTrue(database.dayPageDao().observeMemos().first().any { it.body == "local edit" })
        val conflictOperation = database.dayPageDao().pendingOperations(limit = 10).single()
        assertTrue(conflictOperation.memoId != local.id)
        assertEquals(setOf("local edit", "remote edit"), vaultChanges.map { it.body }.toSet())
        assertEquals(41L, database.dayPageDao().cursor("40000000-0000-4000-8000-000000000001"))
    }
}
