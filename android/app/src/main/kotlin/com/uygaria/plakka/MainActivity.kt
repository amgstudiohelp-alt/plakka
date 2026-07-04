package com.uygaria.plakka

import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.uygaria.plakka/web_session"
    private val preferencesName = "plakka_web_session"
    private val cookiesKey = "cookies"
    private val lastUrlKey = "last_url"
    private val notificationConsentKey = "notification_consent"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val url = call.arguments as? String ?: "https://uygaria.com/plakka.php"

                when (call.method) {
                    "restoreCookies" -> {
                        result.success(restoreCookies(url))
                    }
                    "saveCookies" -> {
                        result.success(saveCookies(url))
                    }
                    "getNotificationConsent" -> {
                        result.success(getNotificationConsent())
                    }
                    "setNotificationConsent" -> {
                        val allowed = call.arguments as? Boolean ?: false
                        saveNotificationConsent(allowed)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun restoreCookies(url: String): Boolean {
        val cookieManager = CookieManager.getInstance()
        cookieManager.setAcceptCookie(true)

        val preferences = getSharedPreferences(preferencesName, MODE_PRIVATE)
        val cookies = preferences.getString(cookiesKey, null)
        val lastUrl = preferences.getString(lastUrlKey, null)

        if (!cookies.isNullOrBlank()) {
            val targetUrls = linkedSetOf(url)
            if (!lastUrl.isNullOrBlank()) {
                targetUrls.add(lastUrl)
            }

            targetUrls.forEach { targetUrl ->
                cookies.split(";")
                    .map { it.trim() }
                    .filter { it.isNotEmpty() && it.contains("=") }
                    .forEach { cookie ->
                        cookieManager.setCookie(targetUrl, "$cookie; Path=/")
                    }
            }
        }

        cookieManager.flush()
        return !cookies.isNullOrBlank()
    }

    private fun saveCookies(url: String): Boolean {
        val cookieManager = CookieManager.getInstance()
        cookieManager.setAcceptCookie(true)

        val cookies = cookieManager.getCookie(url)
        val preferences = getSharedPreferences(preferencesName, MODE_PRIVATE)
        val editor = preferences.edit()

        if (isLogoutUrl(url)) {
            editor.remove(cookiesKey)
            editor.remove(lastUrlKey)
        } else if (!cookies.isNullOrBlank()) {
            editor.putString(cookiesKey, cookies)
            editor.putString(lastUrlKey, url)
        }

        editor.apply()
        cookieManager.flush()
        return !preferences.getString(cookiesKey, null).isNullOrBlank()
    }

    private fun isLogoutUrl(url: String): Boolean {
        val normalized = url.lowercase()
        return listOf(
            "logout",
            "log_out",
            "signout",
            "sign_out",
            "cikis",
            "oturumkapat",
            "oturumu_kapat"
        ).any { normalized.contains(it) }
    }

    private fun getNotificationConsent(): Boolean? {
        val preferences = getSharedPreferences(preferencesName, MODE_PRIVATE)
        if (!preferences.contains(notificationConsentKey)) {
            return null
        }

        return preferences.getBoolean(notificationConsentKey, false)
    }

    private fun saveNotificationConsent(allowed: Boolean) {
        getSharedPreferences(preferencesName, MODE_PRIVATE)
            .edit()
            .putBoolean(notificationConsentKey, allowed)
            .apply()
    }
}
