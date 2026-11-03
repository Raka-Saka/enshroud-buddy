package com.rakasaka.ensh_companion

import android.content.ActivityNotFoundException
import android.content.Intent
import android.speech.RecognizerIntent
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** Voice for Ask on channel "ensh/voice": "listen" (the phone's speech recognizer, returns the text or
 *  null), "speak" {text} and "stop" (text-to-speech; "spoken" is sent back when it finishes). English,
 *  as the game's names are. Channel "ensh/screen": "keepOn" {on} keeps the screen awake (the live map). */
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
                "listen" -> listen(result)
                "speak" -> speak(call.argument<String>("text") ?: "", result)
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
    }

    private fun listen(result: MethodChannel.Result) {
        pending?.success(null)
        pending = result
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
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

    private fun speak(text: String, result: MethodChannel.Result) {
        val engine = tts
        if (engine != null && ttsReady) {
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
            t.language = Locale.US
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
