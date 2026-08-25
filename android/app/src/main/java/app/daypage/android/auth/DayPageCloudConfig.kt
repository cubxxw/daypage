package app.daypage.android.auth

data class DayPageCloudConfig(
    val supabaseUrl: String,
    val anonKey: String,
    val redirectUri: String,
) {
    val isConfigured: Boolean
        get() = supabaseUrl.startsWith("https://") && anonKey.isNotBlank()
}
