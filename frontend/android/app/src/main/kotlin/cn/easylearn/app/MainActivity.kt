package cn.easylearn.app

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 系统离线朗读。
 *
 * 只用 Android 自带的 TextToSpeech：不引入插件、可离线、跟着系统中文语音包走。
 * 三类失败都必须**回报给 Dart**，不能悄悄吞掉：
 *  · 设备没有引擎（TextToSpeech 初始化失败）
 *  · 有引擎但没有中文包（setLanguage 返回 MISSING_DATA / NOT_SUPPORTED）
 *  · 朗读引擎报错或被系统拒绝
 */
class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "cn.easylearn.app/tts"

        /// 屏幕常亮。计时页开着的时候，屏幕自己熄灭会把学生计时到一半
        /// 的手机锁上 —— 而熄屏本身又会触发「离开应用自动暂停」，
        /// 看起来就是「计时莫名其妙停了」。
        const val SCREEN_CHANNEL = "cn.easylearn.app/screen"
        const val STATE_INITIALIZING = 0
        const val STATE_READY = 1
        const val STATE_UNAVAILABLE = -1

        /// 引擎起来了，但「中文语音数据」或「更好听的音色」没配上。
        ///
        /// 这个状态**必须能朗读**。以前 `setLanguage` 一失败就把它和
        /// 「引擎根本起不来」一起判成不可用来，于是整台机器上再没声音 ——
        /// 可实际上不少引擎（尤其是鸿蒙/卓易通那类兼容层）对 `setLanguage`
        /// 的返回值实现得不标准，报着「没有中文」，`speak` 却念得出来。
        /// 那正好就是我们想要的结果：**用系统默认的**。
        /// ⚠️ 探测是探测、朗读是朗读：探测的结论只能变成一句提示，
        ///    不能变成一道闸门。
        const val STATE_DEGRADED = 2
        /// 元信息（引擎列表 / 音色列表 / 应用设置）走**单独的通道**，并且挂在
        /// **后台 task queue** 上：枚举音色要给那个引擎临时建一个实例并等它就绪
        /// （最多 6 秒），在主线程这么干必然 ANR。speak/stop 留在主线程的那条。
        const val CATALOG_CHANNEL = "cn.easylearn.app/tts-catalog"
        const val PREFS = "easylearn_tts"
        const val PREF_ENGINE = "engine"
        const val PREF_VOICE = "voice"
        const val PREF_RATE = "rate"
        const val DEFAULT_RATE = 0.95f
        const val PROBE_TIMEOUT_MS = 6000L
        const val INIT_TIMEOUT_MS = 6000L

        /// 引擎受理朗读后，等多久还没有任何进度回调就判「没出声」。
        ///
        /// 取 8 秒：离线引擎首句一般 1 秒内就开始，慢的也就两三秒。再短会误伤
        /// 那些先把整段合成完再开播的引擎；再长则学生已经在怀疑自己点没点到。
        const val SPEAK_SILENCE_MS = 8000L
        const val TAG = "EasyLearnTts"

        /// 朗读语言。用短码而不是完整 locale：Dart 只关心「念中文还是念英文」，
        /// 具体落到 zh_CN 还是 en_US 由原生按设备的语音包去挑。
        const val LANG_ZH = "zh"
        const val LANG_EN = "en"

        /// 「引擎起不来」这句话在三个地方要吐（朗读请求、初始化回调、startSpeaking），
        /// 措辞必须一致：它同时承担「告诉用户这不是音色问题」的职责。
        const val MSG_ENGINE_UNAVAILABLE =
            "这台设备没有可用的朗读引擎。" +
                "若你用的是鸿蒙系统（应用通过卓易通安装），那里没有安卓的语音合成服务 —— " +
                "这是系统能力缺失，装语音包也不会生效。"
    }

    private var channel: MethodChannel? = null
    private var catalogChannel: MethodChannel? = null
    private var tts: TextToSpeech? = null
    private var engineState = STATE_INITIALIZING

    /// 用户挑好的设置（SharedPreferences）。
    private val prefs: SharedPreferences
        get() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /// 实际生效的那个音色名 —— 只有 setVoice 成功之后才写，
    /// 所以「界面上显示的」和「真的在用的」不会是两回事。
    @Volatile
    private var activeVoiceName: String? = null

    private var pendingResult: MethodChannel.Result? = null
    private var pendingSentences: List<String>? = null
    private var pendingPauseMs = 0
    private var pendingUtteranceId: String? = null

    /// 当前这条朗读请求要用的语言。中途引擎重建时靠它恢复 —— 重建会把
    /// 引擎的语言与音色全部清回默认，不记住就会拿中文音色去念英文。
    private var pendingLanguage = LANG_ZH

    /// 引擎**此刻**被切到的朗读语言。null = 还没配过（新建实例后的初始态）。
    ///
    /// 为什么需要它：`setLanguage` + `setVoice` 不便宜，而朗读是**一句一次**
    /// 调用通道的。每句都重新切一遍语言，句子之间的停顿会被拉长成卡顿。
    /// 只在语言真的变了才切。
    private var currentSpeakLanguage: String? = null

    /// 英文语音数据认不认。**独立于** `languageReady`：后者是中文的诊断结论，
    /// 朗读设置面板看的是它，不能被一次英文朗读改掉。
    @Volatile
    private var englishReady = false

    private var utteranceSeq = 0

    /// 最近一次引擎初始化回调给的状态码（`TextToSpeech.SUCCESS` 或错误码）。
    ///
    /// 为什么要留它：`TextToSpeech` 初始化失败时**不抛异常、也不说话**，
    /// 只是回调一个非 SUCCESS 的数。没有这个字段，「起不来」在界面上
    /// 就会和「没有中文包」混成同一句提示 —— 鸿蒙的卓易通正是前者。
    @Volatile
    private var lastInitStatus: Int? = null

    /// 语言到底认不认。失败时用它把「引擎在但没中文」与「引擎根本起不来」分开。
    @Volatile
    private var languageReady = false

    /// 当前这个引擎实例还有没有「失败后重建一次」的额度。
    ///
    /// 每新建一个引擎实例给一次（见 [ensureEngine] / [rebuildEngine]），用完清零。
    /// 要它，是因为「不可用」必须是可恢复的 —— 一次初始化失败就让朗读
    /// 在这台机器上永久失效，代价太大；不要它，失败就会套娃（重建→失败→再重建…）。
    @Volatile
    private var retryArmed = true

    private val mainHandler = Handler(Looper.getMainLooper())
    private var initTimeout: Runnable? = null

    /// 「受理了但一声不出」看门狗。见 [armSilenceWatchdog]。
    private var silenceWatchdog: Runnable? = null
    private var silenceWatchdogId: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> handleSpeak(
                    readSentences(call),
                    call.argument<String>("utteranceId"),
                    call.argument<Int>("pauseMs") ?: 0,
                    call.argument<String>("language") ?: LANG_ZH,
                    result,
                )
                "stop" -> {
                    stopSpeaking()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        ensureEngine()

        // 单独一条通道 + **后台 task queue**：枚举音色要临时建一个引擎实例并等它
        // 就绪（≤6s），这个等待绝不能发生在主线程。
        catalogChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CATALOG_CHANNEL,
            StandardMethodCodec.INSTANCE,
            flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue(),
        )
        catalogChannel?.setMethodCallHandler { call, result ->
            runCatching {
                when (call.method) {
                    "engines" -> result.success(listEngines())
                    "voices" -> result.success(listVoices(call.argument<String>("engine")))
                    "status" -> result.success(readStatus())
                    "diagnose" -> result.success(diagnose())
                    "apply" -> applySettings(call, result)
                    else -> result.notImplemented()
                }
            }.onFailure { e ->
                Log.w(TAG, "朗读设置 ${call.method} 失败：${e.message}")
                if (e is CatalogFailure) {
                    // 把「为什么」的原始事实一起带回去：界面上要能看见引擎几个、
                    // 初始化返回什么码。只有一句话的提示，在鸿蒙容器里会把
                    // 「引擎起不来」误读成「没装中文语音包」。
                    result.error(e.code, e.userMessage, e.detail)
                } else {
                    result.error("catalog_failed", e.message ?: "读取朗读引擎信息失败", null)
                }
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SCREEN_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setKeepScreenOn" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    // 加的是 Activity 窗口标志，不是 WakeLock：不需要权限，
                    // 也不会在页面退出后继续占着（进程一销毁随窗口消失）。
                    if (on) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /// 用户挑好的引擎包名；空 = 用系统默认那个。
    private val preferredEnginePkg: String?
        get() = prefs.getString(PREF_ENGINE, null)?.takeIf { it.isNotBlank() }

    private fun ensureEngine() {
        if (tts != null) return
        engineState = STATE_INITIALIZING
        activeVoiceName = null
        retryArmed = true
        val pkg = preferredEnginePkg
        tts = if (pkg == null) {
            TextToSpeech(applicationContext) { onEngineInit(it, allowFallback = true) }
        } else {
            TextToSpeech(applicationContext, { onEngineInit(it, allowFallback = true) }, pkg)
        }
    }

    /// [allowFallback]：用户挑的引擎**可能已经不在了**（卸载 / 被禁用 / ROM 升级改名）。
    /// 这种情况下系统会让它初始化失败，如果就此认输，朗读会彻底没声音 ——
    /// 比难听糟得多。所以第一次失败时清掉偏好、回落到系统默认再试一次（只一次）。
    private fun onEngineInit(status: Int, allowFallback: Boolean) {
        lastInitStatus = status
        if (status == TextToSpeech.SUCCESS) {
            // ⚠️ 语言/音色配得上配不上，**都不影响能不能念**。
            // 以前 `configureLanguage` 返回 false 就整台判不可用，等于拿一次探测
            // 的返回值永久关掉了朗读 —— 可探测说「没有中文」的机器，
            // `speak` 往往照念不误（鸿蒙/卓易通那类兼容层对 setLanguage 的
            // 返回值实现得不标准）。那正是我们要的结果：**用系统默认的**。
            engineState = if (configureLanguage()) STATE_READY else STATE_DEGRADED
            if (engineState == STATE_DEGRADED) {
                Log.w(TAG, "中文语音数据没配上，按系统默认继续（degraded）")
            }
            dispatchPending()
            return
        }

        // 失败有可能是「用户当初挑的那个引擎现在不在了」。就此认输的话朗读彻底没声，
        // 所以先清掉偏好、用系统默认重来一次（只一次，避免套娃）。
        val pkg = preferredEnginePkg
        if (pkg != null && allowFallback) {
            Log.w(TAG, "引擎 $pkg 初始化失败，回落到系统默认")
            prefs.edit().remove(PREF_ENGINE).remove(PREF_VOICE).apply()
            val dying = tts
            tts = null
            engineState = STATE_INITIALIZING
            activeVoiceName = null
            runCatching { dying?.shutdown() }
            ensureEngine()
            return
        }

        engineState = STATE_UNAVAILABLE
        failPending("engine_unavailable", MSG_ENGINE_UNAVAILABLE)
    }

    /// 引擎刚就绪（或降级就绪）时补发排队中的那条朗读请求。
    private fun dispatchPending() {
        val sentences = pendingSentences ?: return
        val result = pendingResult ?: return
        startSpeaking(sentences, result)
    }

    /**
     * 配语言、语速、音色，装上进度回调。
     *
     * ⚠️ 返回值**不代表能不能朗读**，只代表「中文数据是不是按我们希望的配上了」。
     * 这里原来在语言失败时直接 `return false`，调用方就把它判成不可用 ——
     * 于是语速、音色、进度回调全都没装上，降级实际上退化成了「什么都不做」。
     * 这三样跟语言无关，必须照装：**降级要降的是听感，不是功能**。
     */
    private fun configureLanguage(): Boolean {
        val engine = tts ?: return false
        // 新建的引擎默认按中文配：讲解朗读、朗读设置面板都以中文为准。
        currentSpeakLanguage = LANG_ZH
        languageReady = switchLanguage(engine, LANG_ZH)
        applyRateAndPitch(engine)
        // 必须在 setLanguage 之后：切语言会把引擎的音色重置回默认。
        selectPreferredVoice(engine)
        installProgressListener(engine)
        return languageReady
    }

    /// 语速与音高。切语言之后要重设一遍 —— 有些引擎会在 `setLanguage` 时
    /// 把这两项一起复位，学生刚调好的语速就白调了。
    private fun applyRateAndPitch(engine: TextToSpeech) {
        val rate = prefs.getFloat(PREF_RATE, DEFAULT_RATE).coerceIn(0.5f, 2.0f)
        engine.setSpeechRate(rate)
        engine.setPitch(1.0f)
    }

    /// 把引擎切到指定语言的语音数据上，返回「这套数据认不认」。
    ///
    /// 返回值只用于**选择音色与写诊断**，不作为能不能朗读的闸门 ——
    /// 大量兼容层（鸿蒙/卓易通）对 `setLanguage` 的返回值实现得不标准，
    /// 报着「没有中文」却照念不误。念得出来就是好结果。
    private fun switchLanguage(engine: TextToSpeech, language: String): Boolean {
        if (language == LANG_EN) {
            val us = engine.setLanguage(Locale.US)
            if (!isLanguageMissing(us)) return true
            return !isLanguageMissing(engine.setLanguage(Locale.ENGLISH))
        }
        val preferred = engine.setLanguage(Locale.SIMPLIFIED_CHINESE)
        if (!isLanguageMissing(preferred)) return true
        return !isLanguageMissing(engine.setLanguage(Locale.CHINA))
    }

    /**
     * 让引擎按这条朗读请求要求的语言出声。
     *
     * 只在语言**真的变了**的时候动引擎：朗读是一句一次调用通道的，
     * 每句都 setLanguage + setVoice 会把句子之间的停顿拖成卡顿。
     *
     * 英文念不了（没装英文语音包）时**不拦**：沿用引擎当前的默认声音继续念。
     * 中文腔的英文对孩子当然不够好，但「一点声音都没有」更糟 ——
     * 和中文那边的降级是同一个取舍。
     */
    private fun applyLanguageFor(language: String) {
        if (language == currentSpeakLanguage) return
        val engine = tts ?: return
        val ok = switchLanguage(engine, language)
        if (language == LANG_EN) englishReady = ok else languageReady = ok
        applyRateAndPitch(engine)
        if (language == LANG_EN) {
            selectEnglishVoice(engine)
        } else {
            selectPreferredVoice(engine)
        }
        currentSpeakLanguage = language
        if (!ok) {
            Log.w(TAG, "没有 $language 语音数据，沿用系统默认声音继续念")
        }
    }

    private fun installProgressListener(engine: TextToSpeech) {
        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                // 回调来自 TTS 引擎线程，MethodChannel 的结果必须回主线程提交。
                mainHandler.post {
                    // 出声了就撤掉「受理后一直没声音」的看门狗。
                    cancelSilenceWatchdog()
                    // ⚠️ 这里**不再** success：结果在 startSpeaking 里「引擎受理」时就结掉了。
                    //    一个 MethodChannel.Result 只能回一次，重复回会抛
                    //    「Reply already submitted」。而且以前是「最后一句开始念」才回，
                    //    多句长文（一篇英文课文几十句）要等念到结尾 —— Dart 那边 10 秒
                    //    早已超时，报「朗读引擎没有响应」，可声音明明在放。
                    Log.i(TAG, "开始朗读：$utteranceId")
                }
            }

            override fun onDone(utteranceId: String?) {
                mainHandler.post {
                    cancelSilenceWatchdog()
                    channel?.invokeMethod("onDone", utteranceId)
                }
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                mainHandler.post { reportError(reportMessage("朗读引擎报错，请检查系统的")) }
            }

            override fun onError(utteranceId: String?, errorCode: Int) {
                mainHandler.post { reportError(reportMessage("朗读引擎报错（代码 $errorCode），请检查系统的")) }
            }
        })
    }

    /// 报错文案跟着当前朗读的语言走 —— 念英文时说「中文语音包」会把人引到错的方向。
    private fun reportMessage(prefix: String): String {
        val name = if (pendingLanguage == LANG_EN) "英文" else "中文"
        return "$prefix${name}语音包"
    }

    /**
     * 挑一个最好听的中文音色。
     *
     * **不改这里的后果**：只用 `setLanguage` 的话，引擎会落在它自己的默认音色上，
     * 通常是 `QUALITY_NORMAL` 的离线包 —— 那就是「声音很生硬」的直接来源。
     * 同一台手机上 NORMAL 和 VERY_HIGH 的差别是听得出来的。
     *
     * 三条筛选，顺序不能变：
     * 1. 讲普通话（locale 必须以 zh 开头）；
     * 2. **不要需要联网的音色** —— 那些是云端合成，断网就哑，而且会偷走流量；
     * 3. 在剩下的里面按 quality 从高到低排（VERY_HIGH > HIGH > NORMAL > LOW），
     *    同一档里再优先大陆（zh_CN）而不是台湾读法。
     *
     * 挑不到就什么都不做（保留引擎默认），不在这里抛：宁可难听，也不要没声音。
     */
    private fun selectPreferredVoice(engine: TextToSpeech) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
        val voices = try {
            engine.voices
        } catch (e: Exception) {
            // 少数厂商 ROM 在这一步抛异常而不是返回 null。
            Log.w(TAG, "取不到音色列表：${e.message}")
            null
        }
        if (voices.isNullOrEmpty()) {
            Log.i(TAG, "引擎没有报告任何音色，沿用默认")
            return
        }

        // 用户在设置里点名要哪个音色，就要哪个 —— 已经付过「试听」的代价了。
        // ⚠️ 音色名只在**同一个引擎**内有效：换引擎之后这个名字多半不存在，
        //    这时必须丢掉它走自动挑选，不能拿着一个空名去 setVoice（那会失败或静默无效）。
        val wanted = prefs.getString(PREF_VOICE, null)?.takeIf { it.isNotBlank() }
        if (wanted != null) {
            val named = voices.firstOrNull { it.name == wanted }
            if (named != null) {
                val code = runCatching { engine.setVoice(named) }
                    .getOrDefault(TextToSpeech.ERROR)
                if (code == TextToSpeech.SUCCESS) {
                    activeVoiceName = named.name
                    Log.i(TAG, "音色（用户指定）：${named.name}")
                    return
                }
                Log.w(TAG, "用户指定的音色 $wanted 用不了（code=$code），改为自动挑选")
            } else {
                Log.w(TAG, "这个引擎里没有叫 $wanted 的音色，改为自动挑选")
            }
            prefs.edit().remove(PREF_VOICE).apply()
        }

        val candidates = voices.filter(::isOfflineChineseVoice)
        if (candidates.isEmpty()) {
            Log.i(TAG, "没有可用的离线中文音色，沿用默认（共 ${voices.size} 个音色）")
            return
        }

        val best = candidates
            .sortedWith(
                compareByDescending<Voice> { qualityRank(it.quality) }
                    // 同档音色里优先大陆普通话：zh_TW 的默认音色念数字和
                    // 专业术语都用台湾读法，学生听着别扭。
                    .thenByDescending { if (it.locale?.country == "CN") 1 else 0 },
            )
            .first()
        val code = runCatching { engine.setVoice(best) }.getOrDefault(TextToSpeech.ERROR)
        if (code == TextToSpeech.SUCCESS) activeVoiceName = best.name
        Log.i(
            TAG,
            "音色：${best.name} · quality=${best.quality} · " +
                "候选 ${candidates.size}/${voices.size} · setVoice=$code",
        )
    }

    /**
     * 挑一个发音地道一点的英文音色。
     *
     * 和中文那套共用三条筛选（离线 → quality 降序 → 优先母语地区），但**不读
     * 用户偏好** [PREF_VOICE]：设置面板里列的一直是中文音色，那个名字在
     * 英文音色里多半不存在，拿着它去 setVoice 只会失败或静默无效。
     *
     * 挑不到就什么都不做（沿用引擎默认），不在这里抛：宁可带口音，
     * 也不要没声音。
     */
    private fun selectEnglishVoice(engine: TextToSpeech) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
        val voices = try {
            engine.voices
        } catch (e: Exception) {
            Log.w(TAG, "取不到音色列表：${e.message}")
            return
        }
        if (voices.isNullOrEmpty()) return

        val candidates = voices.filter { voice ->
            if (voice.isNetworkConnectionRequired) return@filter false
            val locale = voice.locale ?: return@filter false
            locale.language == Locale.ENGLISH.language && voice.name.isNotEmpty()
        }
        if (candidates.isEmpty()) {
            Log.i(TAG, "没有可用的离线英文音色，沿用默认（共 ${voices.size} 个音色）")
            return
        }

        val best = candidates
            .sortedWith(
                compareByDescending<Voice> { qualityRank(it.quality) }
                    // 同档里优先美音：教材配套音频、考试听力都是美音居多。
                    .thenByDescending { if (it.locale?.country == "US") 1 else 0 },
            )
            .first()
        val code = runCatching { engine.setVoice(best) }.getOrDefault(TextToSpeech.ERROR)
        if (code == TextToSpeech.SUCCESS) activeVoiceName = best.name
        Log.i(
            TAG,
            "英文音色：${best.name} · quality=${best.quality} · " +
                "候选 ${candidates.size}/${voices.size} · setVoice=$code",
        )
    }

    private fun isChineseVoice(voice: Voice): Boolean {
        val locale = voice.locale ?: return false
        return locale.language == Locale.CHINESE.language && voice.name.isNotEmpty()
    }

    private fun isOfflineChineseVoice(voice: Voice): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            // 联网音色必须排除：断网时它会直接失败，比难听更糟。
            if (voice.isNetworkConnectionRequired) return false
        }
        val locale = voice.locale ?: return false
        if (locale.language != Locale.CHINESE.language) return false
        return voice.name.isNotEmpty()
    }

    private fun qualityRank(quality: Int?): Int = when (quality) {
        Voice.QUALITY_VERY_HIGH -> 4
        Voice.QUALITY_HIGH -> 3
        Voice.QUALITY_NORMAL -> 2
        Voice.QUALITY_LOW -> 1
        else -> 0
    }

    private fun isLanguageMissing(result: Int): Boolean =
        result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED

    // ---------- 朗读设置：给「朗读设置」面板查询与写入 ----------

    /**
     * 查询类失败：**必须把原始事实带回去**。
     *
     * [userMessage] 是给人看的一句话，[detail] 是给诊断行看的数字。
     * 两者分开，是因为「引擎起不来」「没有中文包」「音色为空」对用户
     * 意味着完全不同的下一步 —— 共用一句笼统文案时，人会照着错的
     * 方向去折腾（比如在鸿蒙容器里反复装语音包，那里根本没有 TTS 服务）。
     */
    private class CatalogFailure(
        val code: String,
        val userMessage: String,
        val detail: Map<String, Any?> = emptyMap(),
    ) : Exception(userMessage)

    /// 这台机器的事实。鸿蒙 / 卓易通没有 Android 的 TTS 服务，
    /// 界面上要能把「制造商 + 引擎数 + 初始化码」摊开给人看。
    private fun deviceFacts(): Map<String, Any?> = mapOf(
        "manufacturer" to Build.MANUFACTURER,
        "model" to Build.MODEL,
        "sdk" to Build.VERSION.SDK_INT,
        "release" to Build.VERSION.RELEASE,
    )

    /// 引擎包名 → 显示名。拿不到就退回包名，绝不返回空串。
    private fun engineLabel(pkg: String?): String {
        if (pkg.isNullOrBlank()) return "系统默认引擎"
        val label = runCatching {
            tts?.engines?.firstOrNull { it.name == pkg }?.label
        }.getOrNull()
        return label?.takeIf { it.isNotBlank() } ?: pkg
    }

    /// 面板上的「诊断」信息：只陈述事实，不做推断。
    private fun diagnose(): Map<String, Any?> {
        val engineCount = runCatching { tts?.engines?.size }.getOrNull() ?: 0
        val defaultPkg = runCatching { tts?.defaultEngine }.getOrNull() ?: ""
        return deviceFacts() + mapOf(
            "engineCount" to engineCount,
            "defaultEngine" to defaultPkg,
            "preferredEngine" to (preferredEnginePkg ?: ""),
            "state" to engineState,
            "initStatus" to (lastInitStatus ?: -1),
            "languageReady" to languageReady,
            "activeVoice" to (activeVoiceName ?: ""),
        )
    }

    /// 本机装了哪些朗读引擎。
    private fun listEngines(): List<Map<String, Any?>> {
        val engine = tts ?: throw CatalogFailure(
            "engine_not_ready",
            "朗读引擎还没准备好（退出这一页再进来试试）",
            deviceFacts() + mapOf("state" to engineState, "initStatus" to (lastInitStatus ?: -1)),
        )
        // 注意：getDefaultEngine() 是**实例方法**，不是静态的。
        val defaultPkg = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            runCatching { engine.defaultEngine }.getOrNull()
        } else {
            null
        }
        return (engine.engines ?: emptyList()).map { info ->
            mapOf(
                "name" to info.name,
                "label" to info.label,
                "isDefault" to (info.name == defaultPkg),
            )
        }
    }

    /// 某个引擎里有哪些中文音色。
    ///
    /// `voices` 是**实例方法**，拿不到别的引擎的音色 —— 所以这里为那个引擎
    /// **临时建一个实例**，取完立刻 `shutdown`。慢（几百毫秒～几秒）但只此一路，
    /// 这也是这些查询必须跑在后台 task queue 上的原因（见 CATALOG_CHANNEL）。
    private fun listVoices(enginePkg: String?): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            throw CatalogFailure(
                "too_old",
                "这台设备的系统版本太低，没法列出音色",
                deviceFacts(),
            )
        }
        val pkg = enginePkg?.takeIf { it.isNotBlank() }
        val label = engineLabel(pkg)
        val latch = CountDownLatch(1)
        // 不用 @Volatile（Kotlin 不允许修饰局部变量）：这里的可见性由 CountDownLatch
        // 保证 —— countDown 之前的写入，在 await 返回之后一定看得到。
        var initStatus: Int? = null
        var languageOk = false
        var probe: TextToSpeech? = null
        try {
            probe = TextToSpeech(
                applicationContext,
                TextToSpeech.OnInitListener { status ->
                    initStatus = status
                    val created = probe
                    if (status == TextToSpeech.SUCCESS && created != null) {
                        val primary = created.setLanguage(Locale.SIMPLIFIED_CHINESE)
                        languageOk = if (isLanguageMissing(primary)) {
                            !isLanguageMissing(created.setLanguage(Locale.CHINA))
                        } else {
                            true
                        }
                    }
                    latch.countDown()
                },
                pkg,
            )
            if (!latch.await(PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                throw CatalogFailure(
                    "probe_timeout",
                    "引擎「$label」超过 ${PROBE_TIMEOUT_MS / 1000} 秒没有就绪，建议换一个",
                    deviceFacts() + mapOf("engine" to (pkg ?: ""), "initStatus" to -1),
                )
            }
            // 「起不来」和「没有中文」是两件事。`TextToSpeech` 初始化失败时
            // 不抛异常、只回调一个非 SUCCESS 的码 —— 不把这一步单独判出来，
            // 鸿蒙容器里的「根本没有 TTS 服务」就会被说成「缺中文语音包」。
            if (initStatus != TextToSpeech.SUCCESS) {
                throw CatalogFailure(
                    "engine_init_failed",
                    "引擎「$label」没有启动起来（系统返回 ${initStatus ?: -1}）。" +
                        "鸿蒙上通过卓易通运行安卓应用时没有语音合成服务，装语音包也解决不了。",
                    deviceFacts() + mapOf(
                        "engine" to (pkg ?: ""),
                        "initStatus" to (initStatus ?: -1),
                    ),
                )
            }
            if (!languageOk) {
                throw CatalogFailure(
                    "language_not_supported",
                    "引擎「$label」能启动，但它报告自己没有中文语音包",
                    deviceFacts() + mapOf(
                        "engine" to (pkg ?: ""),
                        "initStatus" to (initStatus ?: -1),
                    ),
                )
            }
            val voices = runCatching { probe?.voices }.getOrNull() ?: emptySet()
            val mapped = voices.filter(::isChineseVoice).map { voice ->
                mapOf(
                    "name" to voice.name,
                    "quality" to (voice.quality ?: -1),
                    "network" to voice.isNetworkConnectionRequired,
                    "locale" to (voice.locale?.toString() ?: ""),
                )
            }
            if (mapped.isEmpty()) {
                throw CatalogFailure(
                    "no_chinese_voice",
                    "引擎「$label」没有可选的中文音色 —— 去系统设置里给它装一个中文语音包再回来",
                    deviceFacts() + mapOf(
                        "engine" to (pkg ?: ""),
                        "initStatus" to (initStatus ?: -1),
                        "voiceCount" to 0,
                    ),
                )
            }
            return mapped.sortedWith(
                compareByDescending<Map<String, Any?>> { qualityRank(it["quality"] as? Int) }
                    .thenByDescending { it["locale"] == "zh_CN" }
                    .thenBy { it["network"] == true },
            )
        } finally {
            // 探完就关：一台手机上同时开着好几个 TTS 实例是被系统允许的资源浪费。
            runCatching { probe?.shutdown() }
        }
    }

    private fun readStatus(): Map<String, Any?> = mapOf(
        // ⚠️ 降级也算子 ready：它**能念**，只是声音是系统默认那个。
        //    把 ready 定义成「一切都按我们希望的配好了」，界面就会在
        //    明明能出声的机器上显示「朗读不可用」。
        "ready" to (engineState == STATE_READY || engineState == STATE_DEGRADED),
        "degraded" to (engineState == STATE_DEGRADED),
        "engine" to (preferredEnginePkg ?: ""),
        "voice" to (activeVoiceName ?: ""),
        "rate" to prefs.getFloat(PREF_RATE, DEFAULT_RATE),
    )

    /// 存下用户的选择并**立刻重建引擎**生效。
    ///
    /// 三个参数区分三种状态：`null` = 这一项不改；`''` = 恢复默认；有值 = 用它。
    /// 这个区分是必要的 —— 否则「换引擎」和「不换引擎」会共用同一个语义，
    /// 而换引擎必须**连音色偏好一起清**（音色名只在同一引擎内有效）。
    private fun applySettings(call: MethodCall, result: MethodChannel.Result) {
        val editor = prefs.edit()
        if (call.hasArgument("engine")) {
            val pkg = (call.argument<String>("engine") ?: "").trim()
            if (pkg.isEmpty()) editor.remove(PREF_ENGINE) else editor.putString(PREF_ENGINE, pkg)
            editor.remove(PREF_VOICE)
        }
        if (call.hasArgument("voice")) {
            val voice = (call.argument<String>("voice") ?: "").trim()
            if (voice.isEmpty()) {
                editor.remove(PREF_VOICE)
            } else {
                editor.putString(PREF_VOICE, voice)
            }
        }
        if (call.hasArgument("rate")) {
            val rate = (call.argument<Double>("rate") ?: DEFAULT_RATE.toDouble()).toFloat()
            editor.putFloat(PREF_RATE, rate.coerceIn(0.5f, 2.0f))
        }
        editor.apply()

        // TextToSpeech 必须在主线程建和销毁，所以回到主线程再重建。
        mainHandler.post {
            rebuildEngine()
            result.success(readStatus())
        }
    }

    private fun rebuildEngine() {
        // 旧引擎的「没出声」看门狗必须撤掉：它盯的那条朗读已经跟着引擎一起没了，
        // 留着只会在新引擎明明念得出来的时候弹一条假失败。
        cancelSilenceWatchdog()
        val dying = tts
        tts = null
        engineState = STATE_INITIALIZING
        activeVoiceName = null
        // 新引擎的语言、音色都是默认态，别再以为还停在上一门语言上 ——
        // 否则下一次朗读会跳过切换，拿中文音色去念英文。
        currentSpeakLanguage = null
        retryArmed = true
        runCatching { dying?.stop() }
        runCatching { dying?.shutdown() }
        ensureEngine()
    }

    /**
     * 通道里的 `List<*>` 在 Dart 侧保证是 `List<String>`，但跨边界的类型不能被信任：
     * 丢掉非字符串的条目（丢比念错好），空列表视为没有内容。
     */
    private fun readSentences(call: MethodCall): List<String> {
        val raw = call.argument<List<*>>("sentences") ?: return emptyList()
        return raw.filterIsInstance<String>().filter { it.isNotBlank() }
    }

    private fun handleSpeak(
        sentences: List<String>,
        utteranceId: String?,
        pauseMs: Int,
        language: String,
        result: MethodChannel.Result,
    ) {
        if (sentences.isEmpty()) {
            result.error("empty_text", "没有可朗读的内容", null)
            return
        }

        // 同一时刻只允许一条朗读请求：上一条的 result 必须被结掉，
        // 否则 Dart 侧会一直等一个永远不来的响应。
        pendingResult?.error("superseded", "已被新的朗读请求替换", null)
        pendingResult = null

        pendingSentences = sentences
        pendingPauseMs = pauseMs.coerceIn(0, 2000)
        pendingUtteranceId = utteranceId?.takeIf { it.isNotBlank() } ?: "utt-${++utteranceSeq}"
        // 认不出的语言按中文处理：老客户端不带这个参数时行为必须和以前一模一样。
        pendingLanguage = if (language == LANG_EN) LANG_EN else LANG_ZH

        when (engineState) {
            STATE_READY, STATE_DEGRADED -> startSpeaking(sentences, result)
            STATE_UNAVAILABLE -> {
                // ⚠️ 不可用**不能是终态**。引擎初始化失败常常只是那一刻系统 TTS
                // 服务还没起来（冷启动、刚更新完语音包、刚切过默认引擎），
                // 而 engineState 一旦落进 UNAVAILABLE 就再没有回到初始化中的路径 ——
                // 结果是：这一次没起来，这台机器上就永远念不出来，
                // 除非杀掉进程重启。这里重建一次（只一次，靠 retryArmed 防套娃）。
                if (retryArmed) {
                    Log.w(TAG, "引擎不可用，重建后重试一次")
                    rebuildEngine()
                    // ⚠️ 必须在 rebuild 之后清：rebuildEngine 会把额度重置回 true，
                    //    先清再建等于没清，失败就会一路重建下去。
                    retryArmed = false
                    pendingResult = result
                    pendingSentences = sentences
                    armInitTimeout()
                } else {
                    failPending("engine_unavailable", MSG_ENGINE_UNAVAILABLE)
                }
            }
            else -> {
                armInitTimeout()
                ensureEngine()
            }
        }
    }

    /// 给「等引擎就绪」这件事挂一个上限。
    ///
    /// `onEngineInit` 不被系统调用是完全可能的（服务没起来时它一声不响），
    /// 没有这个超时，Dart 侧那次 `speak` 会一直挂着，界面上的「正在朗读」
    /// 也跟着一直转 —— 那比报错糟：学生不知道是慢还是坏了。
    private fun armInitTimeout() {
        initTimeout?.let { mainHandler.removeCallbacks(it) }
        initTimeout = Runnable {
            if (engineState == STATE_INITIALIZING) {
                failPending("engine_timeout", "朗读引擎启动超时，请稍后重试")
            }
        }.also { mainHandler.postDelayed(it, INIT_TIMEOUT_MS) }
    }

    /**
     * 把整段排进引擎队列，**句与句之间插一段静默**。
     *
     * 这是「听着生硬」的另一半原因：一次性 `speak(整篇)` 时，中文 TTS 不会在句号后
     * 真的停下来换气，听感就是一路念到底。这里一句一次 `QUEUE_ADD`，中间用
     * `playSilentUtterance` 补一段空白（API 21+，所有支持的机型都有）。
     *
     * 只有最后一句用 Dart 给的 utteranceId —— 整个队列的完成以它为准，
     * 中间句子的回调会被 Dart 侧的 id 配对判掉（对不上就忽略）。
     */
    private fun startSpeaking(sentences: List<String>, result: MethodChannel.Result) {
        val engine = tts
        if (engine == null) {
            failPending("engine_unavailable", MSG_ENGINE_UNAVAILABLE)
            return
        }
        initTimeout?.let { mainHandler.removeCallbacks(it) }
        initTimeout = null
        pendingResult = result
        pendingSentences = null
        val id = pendingUtteranceId ?: "utt-${++utteranceSeq}"
        val pauseMs = pendingPauseMs
        val canPause = Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && pauseMs > 0

        var failedWith = TextToSpeech.SUCCESS
        try {
            // 念英文课文前先切到英文语音数据。放在这里而不是 handleSpeak：
            // 引擎可能是刚重建出来的（那边刚按中文配过），必须在校验完引擎之后切。
            applyLanguageFor(pendingLanguage)

            for ((index, sentence) in sentences.withIndex()) {
                val isLast = index == sentences.size - 1
                val code = engine.speak(
                    sentence,
                    if (index == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD,
                    null,
                    if (isLast) id else "$id-p$index",
                )
                if (code != TextToSpeech.SUCCESS) {
                    failedWith = code
                    break
                }
                if (canPause && !isLast) {
                    engine.playSilentUtterance(pauseMs.toLong(), TextToSpeech.QUEUE_ADD, "$id-s$index")
                }
            }
        } catch (e: Exception) {
            // 引擎服务被系统杀掉、被别的进程抢占、兼容层实现不全 —— 都可能在
            // setLanguage/speak 上直接抛。**不接住的话 result 永远不回**，
            // Dart 侧只会看到一个「没有响应」的超时，真实原因（异常）丢得干干净净。
            Log.e(TAG, "朗读调用抛异常：${e.message}", e)
            failPending(
                "speak_failed",
                "朗读引擎出错了（${e.message ?: e.javaClass.simpleName}）",
            )
            return
        }

        if (failedWith != TextToSpeech.SUCCESS) {
            // 降级态下 `speak` 还失败，才是真的「一个声音都出不来」——
            // 这时才值得让人去装语音包。引擎本来是好的却失败，那是另一回事，
            // 混成一句「引擎拒绝了这段文字」会让人无从下手。
            // ⚠️ 装哪个语音包要跟着**这门语言**说：念英文时说「装中文语音包」
            //    会把人引到完全错的方向去。
            val degraded = if (pendingLanguage == LANG_EN) !englishReady else {
                engineState == STATE_DEGRADED || !languageReady
            }
            failPending(
                "speak_failed",
                if (degraded) {
                    val name = if (pendingLanguage == LANG_EN) "英文" else "中文"
                    "这台设备没有可用的${name}语音数据，系统默认的声音也念不出来。" +
                        "去系统设置里装一个${name}语音包再试。"
                } else {
                    "朗读引擎拒绝了这段文字（系统返回 $failedWith）"
                },
            )
            return
        }

        // ⚠️ **受理即结，不再等 onStart。**
        //
        // `speak()` 返回 SUCCESS 的语义就是「引擎收下了这段文本」，这就是 Dart 需要
        // 知道的事。等 onStart 会有两个后果：
        // ① 中间句的 utteranceId 是 `$id-pN`，只有**最后一句**才等于 `id`，
        //    于是要等整篇念到最后一句才开始 —— 一篇英文课文几十句，Dart 的 10 秒
        //    超时早炸了，用户看到「朗读引擎没有响应」，而声音其实一直在放；
        // ② 少数兼容层（鸿蒙的卓易通正是）根本不回调 `onStart`，只有 onDone，
        //    那么任何朗读都会报「没有响应」。
        // 真正的「出没出声」交给下面的看门狗判，那是另一件事。
        val accepted = pendingResult
        pendingResult = null
        accepted?.success(null)
        armSilenceWatchdog(id)
    }

    /// 引擎受理了，但一直没有任何进度回调 —— 这才是「真的没声音」。
    ///
    /// 为什么必须单独判：`speak` 返回 SUCCESS 只表示排队成功。设备没有可用的
    /// 语音合成服务时（鸿蒙上通过卓易通安装的应用就在这一类），引擎照样收下、
    /// 照样返回 SUCCESS，然后**一声不吭**。没有这条判据，界面会一直显示
    /// 「正在朗读」，学生以为在等前奏。
    private fun armSilenceWatchdog(utteranceId: String) {
        cancelSilenceWatchdog()
        silenceWatchdogId = utteranceId
        silenceWatchdog = Runnable {
            if (silenceWatchdogId != utteranceId) return@Runnable
            silenceWatchdogId = null
            Log.w(TAG, "受理后 ${SPEAK_SILENCE_MS}ms 无任何进度回调：$utteranceId")
            // 把「有没有英文语音数据」一并说出来：同样是「没声音」，
            // 「没装英文包」和「这台机器根本没有语音合成服务」的下一步完全不同。
            val langNote = if (pendingLanguage == LANG_EN && !englishReady) {
                "这台设备也没有可用的英文语音数据。"
            } else {
                ""
            }
            reportError(
                "朗读引擎收下了这段文字，但一直没有出声。$langNote" +
                    "如果这台机器是鸿蒙系统、应用通过卓易通安装，那里没有安卓的语音合成服务 —— " +
                    "这是系统能力缺失，装语音包也不会生效。",
            )
        }.also { mainHandler.postDelayed(it, SPEAK_SILENCE_MS) }
    }

    private fun cancelSilenceWatchdog() {
        silenceWatchdog?.let { mainHandler.removeCallbacks(it) }
        silenceWatchdog = null
        silenceWatchdogId = null
    }

    private fun reportError(message: String) {
        cancelSilenceWatchdog()
        // 主动 stop 之后不该再冒出一条「朗读失败」。
        if (pendingUtteranceId == null) return
        val result = pendingResult
        pendingResult = null
        result?.error("speak_failed", message, null)
        channel?.invokeMethod("onError", message)
    }

    private fun failPending(code: String, message: String) {
        cancelSilenceWatchdog()
        pendingSentences = null
        pendingUtteranceId = null
        initTimeout?.let { mainHandler.removeCallbacks(it) }
        initTimeout = null
        val result = pendingResult
        pendingResult = null
        result?.error(code, message, null)
    }

    private fun stopSpeaking() {
        cancelSilenceWatchdog()
        pendingSentences = null
        pendingUtteranceId = null
        initTimeout?.let { mainHandler.removeCallbacks(it) }
        initTimeout = null
        val result = pendingResult
        pendingResult = null
        result?.error("stopped", "朗读已停止", null)
        tts?.stop()
    }

    override fun onDestroy() {
        initTimeout?.let { mainHandler.removeCallbacks(it) }
        initTimeout = null
        cancelSilenceWatchdog()
        pendingResult = null
        tts?.stop()
        tts?.shutdown()
        tts = null
        channel = null
        catalogChannel?.setMethodCallHandler(null)
        catalogChannel = null
        super.onDestroy()
    }
}
