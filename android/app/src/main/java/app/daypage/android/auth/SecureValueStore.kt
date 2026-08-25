package app.daypage.android.auth

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.content.edit
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Small Android Keystore envelope for tokens and the short-lived PKCE attempt.
 * Ciphertext is excluded from backup; the AES key never leaves Android Keystore.
 */
interface SecureStore {
    fun put(key: String, value: String)
    fun get(key: String): String?
    fun remove(key: String)
}

class SecureValueStore(context: Context) : SecureStore {
    private val preferences = context.getSharedPreferences("daypage_secure", Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    @Synchronized
    override fun put(key: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val encoded = listOf(cipher.iv, ciphertext).joinToString(":") {
            Base64.encodeToString(it, Base64.NO_WRAP)
        }
        preferences.edit { putString(key, encoded) }
    }

    @Synchronized
    override fun get(key: String): String? {
        val encoded = preferences.getString(key, null) ?: return null
        return runCatching {
            val components = encoded.split(":", limit = 2)
            require(components.size == 2)
            val iv = Base64.decode(components[0], Base64.NO_WRAP)
            val ciphertext = Base64.decode(components[1], Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
            cipher.doFinal(ciphertext).toString(Charsets.UTF_8)
        }.getOrElse {
            preferences.edit { remove(key) }
            null
        }
    }

    @Synchronized
    override fun remove(key: String) {
        preferences.edit { remove(key) }
    }

    private fun secretKey(): SecretKey {
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
            generateKey()
        }
    }

    private companion object {
        const val KEY_ALIAS = "daypage.session.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
