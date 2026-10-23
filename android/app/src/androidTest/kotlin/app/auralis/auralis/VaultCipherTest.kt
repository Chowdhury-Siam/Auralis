package app.auralis.auralis

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class VaultCipherTest {
    @Test fun nativeKeystoreRoundTripAndTamperDetection() {
        val vault = VaultCipher()
        val plain = "Synthetic API data: 夜の音楽".toByteArray(Charsets.UTF_8)
        val first = vault.encrypt(plain)
        val second = vault.encrypt(plain)
        assertFalse(first.contentEquals(second))
        assertFalse(first.contentEquals(plain))
        assertArrayEquals(plain, VaultCipher().decrypt(first))
        first[first.lastIndex] = (first.last().toInt() xor 1).toByte()
        try { vault.decrypt(first); fail("Modified ciphertext must fail authentication") }
        catch (_: javax.crypto.AEADBadTagException) { }
    }
}
