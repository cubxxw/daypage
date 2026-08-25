package app.daypage.android.data

import android.content.Context
import androidx.core.content.edit
import java.util.UUID

class DeviceIdentity(context: Context) {
    val id: String

    init {
        val preferences = context.getSharedPreferences("daypage_device", Context.MODE_PRIVATE)
        id = preferences.getString(KEY, null)
            ?.takeIf { runCatching { UUID.fromString(it) }.isSuccess }
            ?: UUID.randomUUID().toString().lowercase().also {
                preferences.edit { putString(KEY, it) }
            }
    }

    private companion object {
        const val KEY = "sync_device_id"
    }
}
