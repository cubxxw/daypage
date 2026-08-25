package app.daypage.android.sync

import android.app.Application
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import app.daypage.android.data.DayPageDatabase
import app.daypage.android.data.RemoteVaultWriter
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RemotePageCommitterTest {
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
    fun cursorAdvancesOnlyAfterCanonicalVaultWrite() = runTest {
        val dao = database.dayPageDao()
        val page = remotePage()
        val failure = RemotePageCommitter(dao, RemoteVaultWriter { error("disk full") })

        val result = runCatching { failure.commit(ACCOUNT_ID, page) }

        assertTrue(result.isFailure)
        assertNull(dao.cursor(ACCOUNT_ID))
        assertEquals("remote Noter", dao.memo(MEMO_ID)?.body)

        val mirrored = mutableListOf<String>()
        RemotePageCommitter(dao, RemoteVaultWriter { changes ->
            mirrored += changes.map { it.body }
        }).commit(ACCOUNT_ID, page)

        assertEquals(listOf("remote Noter"), mirrored)
        assertEquals(41L, dao.cursor(ACCOUNT_ID))
    }

    private fun remotePage() = RemotePage(
        changes = listOf(
            RemoteChange(
                id = MEMO_ID,
                type = "text",
                body = "remote Noter",
                createdAt = "2026-08-25T00:00:00Z",
                pinnedAt = null,
                locationJson = null,
                weatherJson = null,
                device = "iPhone",
                source = "ios",
                vaultPath = "raw/2026-08-25.md",
                sourceModifiedAt = "2026-08-25T00:02:00Z",
                syncRevision = 4,
                lastSyncDeviceId = "30000000-0000-4000-8000-000000000002",
                deletedAt = null,
                changeSequence = 41,
            ),
        ),
        nextCursor = 41,
        hasMore = false,
    )

    private companion object {
        const val ACCOUNT_ID = "40000000-0000-4000-8000-000000000001"
        const val MEMO_ID = "20000000-0000-4000-8000-000000000001"
    }
}
