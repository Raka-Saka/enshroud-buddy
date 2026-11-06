package com.rakasaka.ensh_companion

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.speech.RecognizerIntent
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.WindowManager
import androidx.core.content.FileProvider
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** Voice for Ask on channel "ensh/voice": "listen" {lang} (the phone's speech recognizer, returns the text
 *  or null), "speak" {text, lang} and "stop" (text-to-speech; "spoken" is sent back when it finishes), in the
 *  app's language (a BCP 47 tag like "ja-JP"). Channel "ensh/screen": "keepOn" {on} keeps the screen awake
 *  (the live map).
 *  Channel "ensh/scan": "qr" scans a QR code with Google's code scanner (Play services draws the camera
 *  screen, so the app needs no camera permission) and returns its text, or null when cancelled.
 *  Channel "ensh/app": "version" (versionName), "open" {url} (the browser, for an update) and "share" {path,
 *  text} (a picture in the cache's share/ folder, through FileProvider, with its text: a shared build). */
class MainActivity : FlutterActivity() {
    private val listenCode = 4751
    private var pending: MethodChannel.Result? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ensh/voice")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "listen" -> listen(call.argument<String>("lang") ?: "en-US", result)
                "speak" -> speak(call.argument<String>("text") ?: "", call.argument<String>("lang") ?: "en-US", result)
                "stop" -> {
                    tts?.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ensh/screen").setMethodCallHandler { call, result ->
            if (call.method != "keepOn") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (call.argument<Boolean>("on") == true) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            result.success(null)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ensh/app").setMethodCallHandler { call, result ->
            when (call.method) {
                "version" -> result.success(packageManager.getPackageInfo(packageName, 0).versionName)
                "share" -> try {
                    val file = java.io.File(call.argument<String>("path") ?: "")
                    val uri = FileProvider.getUriForFile(this, "$packageName.share", file)
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "image/png"
                        putExtra(Intent.EXTRA_STREAM, uri)
                        putExtra(Intent.EXTRA_TEXT, call.argument<String>("text") ?: "")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(Intent.createChooser(send, null))
                    result.success(null)
                } catch (e: Exception) {
                    result.error("unavailable", e.message ?: "can't share", null)
                }
                "open" -> try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url"))))
                    result.success(null)
                } catch (e: ActivityNotFoundException) {
                    result.error("unavailable", "No browser", null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ensh/scan").setMethodCallHandler { call, result ->
            if (call.method != "qr") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
            GmsBarcodeScanning.getClient(this, options).startScan()
                .addOnSuccessListener { result.success(it.rawValue) }
                .addOnCanceledListener { result.success(null) }
                .addOnFailureListener { result.error("unavailable", it.message ?: "no scanner", null) }
        }
    }

    private fun listen(lang: String, result: MethodChannel.Result) {
        pending?.success(null)
        pending = result
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang)
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Ask about your game")
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, listenCode)
        } catch (e: ActivityNotFoundException) {
            pending = null
            result.error("unavailable", "No speech recognition on this phone", null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != listenCode) return
        val text = if (resultCode == RESULT_OK)
            data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull() else null
        pending?.success(text)
        pending = null
    }

    private fun speak(text: String, lang: String, result: MethodChannel.Result) {
        val engine = tts
        if (engine != null && ttsReady) {
            engine.language = Locale.forLanguageTag(lang)
            engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "answer")
            result.success(true)
            return
        }
        engine?.shutdown()
        tts = TextToSpeech(this) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            val t = tts
            if (!ttsReady || t == null) {
                result.error("unavailable", "No text-to-speech on this phone", null)
                return@TextToSpeech
            }
            t.language = Locale.forLanguageTag(lang)
            t.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {}
                override fun onDone(utteranceId: String?) {
                    runOnUiThread { channel?.invokeMethod("spoken", null) }
                }
                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) {
                    runOnUiThread { channel?.invokeMethod("spoken", null) }
                }
            })
            t.speak(text, TextToSpeech.QUEUE_FLUSH, null, "answer")
            result.success(true)
        }
    }

    override fun onDestroy() {
        tts?.shutdown()
        super.onDestroy()
    }
}
