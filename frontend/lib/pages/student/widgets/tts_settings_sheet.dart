import 'package:flutter/material.dart';

import '../../../constants/app_colors.dart';
import '../../../services/tts_service.dart';

/// 打开「朗读设置」面板。
///
/// 入口在**个人资料**里，一次设好就一直生效（原生侧存在 SharedPreferences，
/// 下次启动接着用）。早期版本还有个入口挂在讲解页的朗读条上，那会让人
/// 以为「每次朗读都要挑一次声音」—— 已经撤掉了。
Future<void> showTtsSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _TtsSettingsSheet(),
  );
}

/// 个人资料页里的「朗读设置」入口。
///
/// 单独做成一个 widget 而不是在资料页内联几行：判据要能把它单独拉起来，
/// 不必为了点它去搭登录态、积分、档案三个控制器。
class TtsSettingsTile extends StatelessWidget {
  const TtsSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(
          Icons.record_voice_over_outlined,
          color: AppColors.primary,
        ),
        title: const Text(
          '朗读设置',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
        subtitle: const Text(
          '讲题的声音和语速，设一次就记住',
          style: TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
        onTap: () => showTtsSettingsSheet(context),
      ),
    );
  }
}

/// 一个引擎对应的一组数据。音色列表跟着引擎走，所以要绑在一起。
class _VoiceOption {
  const _VoiceOption({
    required this.name,
    required this.locale,
    required this.quality,
    required this.network,
  });

  final String name;
  final String locale;
  final int quality;
  final bool network;

  /// 面板上给人看的名字。
  ///
  /// 引擎给的 `name` 常常是 `zh-cn-x-ccc-local` 这种，直接铺出来没法选；
  /// 这里退化成「普通话·高质量」+ 短后缀，既能区分又不吓人。
  String get label {
    final isTaiwan = locale.contains('TW') || locale.contains('Hant');
    final region = isTaiwan ? '台湾' : '普通话';
    return '$region · ${_qualityLabel(quality)}';
  }

  /// 同一档音色往往有好几个（不同说话人），光靠 label 分不开，用它补位。
  ///
  /// 取**最后两段**而不是最后一段：`zh-cn-x-ccc-local` 和 `zh-cn-x-xxx-local`
  /// 的最后一段都叫 `local` —— 那样列表里会出现两行一模一样的选项，
  /// 看着有得选，其实分不出选的是哪个。
  String get suffix {
    final parts = name.split('-');
    return parts.length >= 2 ? parts.sublist(parts.length - 2).join('-') : name;
  }

  static String _qualityLabel(int quality) => switch (quality) {
    400 => '极高质量',
    300 => '高质量',
    200 => '标准',
    100 => '低质量',
    _ => '未知质量',
  };
}

class _TtsSettingsSheet extends StatefulWidget {
  const _TtsSettingsSheet();

  @override
  State<_TtsSettingsSheet> createState() => _TtsSettingsSheetState();
}

class _TtsSettingsSheetState extends State<_TtsSettingsSheet> {
  bool _loading = true;

  /// 整个面板不可用（平台不支持 / 连当前状态都读不到）。
  String? _error;

  /// 引擎列表读不到。**不致命**：面板照常打开，只是没有引擎可选。
  String? _enginesError;

  /// 当前引擎的音色读不到。**不致命**：引擎列表仍然可点，能换一个再试。
  ///
  /// 这两处必须分开。原来一个 `_error` 管全部，于是一个引擎起不来
  /// 就会把整个面板变成错误页 —— 用户连「换一个引擎」都点不到，
  /// 而换引擎恰恰是这里唯一可能有效的动作。
  String? _voicesError;

  List<({String name, String label, bool isDefault})> _engines = const [];
  List<_VoiceOption> _voices = const [];

  /// 原生侧**实际生效**的引擎包名与音色名（空 = 系统默认 / 尚未定）。
  String _activeEngine = '';
  String _activeVoice = '';
  double _rate = 0.95;

  /// 引擎能念，但中文语音数据/音色没配上 —— 正在用系统默认的声音。
  ///
  /// 这不是故障，是**降级**。它必须被显示出来（否则用户不明白为什么
  /// 换了引擎声音没变），但不能显示成错误 —— 题照样念得出来。
  bool _degraded = false;

  /// 机器的朗读环境事实，只在出问题时拉一次。
  ({
    String manufacturer,
    String model,
    int sdk,
    int engineCount,
    int state,
    int initStatus,
    bool languageReady,
  })?
  _diagnosis;

  /// 正在保存的那一项，用来禁用重复点击；同时保证「保存失败」有地方显示。
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({String? engineOverride}) async {
    if (!TtsService.isSupported) {
      setState(() {
        _loading = false;
        _error = '朗读设置只能在手机上调整，网页版和电脑版没有这个面板';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _enginesError = null;
      _voicesError = null;
    });
    try {
      final status = await TtsService.status();
      final engine = engineOverride ?? status.engine;

      var engines = <({String name, String label, bool isDefault})>[];
      String? enginesError;
      try {
        engines = await TtsService.listEngines();
      } on TtsException catch (e) {
        enginesError = e.message;
      }

      var voices = <_VoiceOption>[];
      String? voicesError;
      try {
        final rows = await TtsService.listVoices(
          engine.isEmpty ? null : engine,
        );
        voices = rows
            .map(
              (v) => _VoiceOption(
                name: v.name,
                locale: v.locale,
                quality: v.quality,
                network: v.network,
              ),
            )
            .toList();
      } on TtsException catch (e) {
        voicesError = e.message;
      }

      // 只有「一件事都列不出来」时才值得多跑一趟诊断；正常路径不加这次往返。
      final needDiagnosis = enginesError != null || voicesError != null;
      final diagnosis = needDiagnosis ? await _safeDiagnose() : null;

      if (!mounted) return;
      setState(() {
        _engines = engines;
        _voices = voices;
        _enginesError = enginesError;
        _voicesError = voicesError;
        _diagnosis = diagnosis;
        _activeEngine = status.engine;
        _activeVoice = status.voice;
        _rate = status.rate;
        _degraded = status.degraded;
        _loading = false;
      });
    } on TtsException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// 诊断本身失败不该再抛一次 —— 它只是解释，不是功能。
  Future<
    ({
      String manufacturer,
      String model,
      int sdk,
      int engineCount,
      int state,
      int initStatus,
      bool languageReady,
    })?
  >
  _safeDiagnose() async {
    try {
      return await TtsService.diagnose();
    } on TtsException {
      return null;
    }
  }

  Future<void> _apply({String? engine, String? voice, double? rate}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final status = await TtsService.apply(
        engine: engine,
        voice: voice,
        rate: rate,
      );
      if (!mounted) return;
      setState(() {
        _activeEngine = status.engine;
        _activeVoice = status.voice;
        _rate = status.rate;
        _degraded = status.degraded;
        _saving = false;
      });
      // 换引擎之后音色列表整份作废，必须重新拉。
      if (engine != null) {
        await _load(engineOverride: status.engine);
      }
    } on TtsException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _preview() async {
    try {
      await TtsService.speak('这句话就是用刚才选的声音念的，你听听顺不顺耳。');
    } on TtsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      // 不用固定高度：矮屏上固定高度会把最下面几个音色挤出可视区，
      // 而且那种失败是**静默的**（不报错，只是点不到）。
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.78,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _handle(),
            _header(),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: CircularProgressIndicator(),
              )
            else if (_error != null)
              _errorView(_error!)
            else
              Flexible(child: _content()),
          ],
        ),
      ),
    );
  }

  Widget _handle() => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 2),
    child: Container(
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: AppColors.textMuted.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
    child: Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '朗读设置',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 2),
              Text(
                '声音是手机系统的语音引擎念的，这里换一个试试',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        TextButton.icon(
          onPressed: _saving ? null : _preview,
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: const Text('试听'),
        ),
      ],
    ),
  );

  Widget _errorView(String message) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
    child: Column(
      children: [
        const Icon(
          Icons.record_voice_over_outlined,
          size: 32,
          color: AppColors.textMuted,
        ),
        const SizedBox(height: 10),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
        ),
        const SizedBox(height: 14),
        OutlinedButton(onPressed: () => _load(), child: const Text('重试')),
      ],
    ),
  );

  Widget _content() => ListView(
    padding: const EdgeInsets.only(bottom: 16),
    children: [
      if (_degraded) _degradedBanner(),
      _sectionTitle('语音引擎'),
      if (_engines.isEmpty)
        _hint(_enginesError ?? '这台设备没有向系统注册任何朗读引擎')
      else
        for (final engine in _engines) _engineTile(engine),
      const Divider(height: 24),
      _sectionTitle('音色（只有中文的会列出来）'),
      // 音色读不到时**只坏这一节**：上面的引擎列表仍然可以点，换一个再试。
      if (_voicesError != null)
        _voicesErrorView(_voicesError!)
      else if (_voices.isEmpty)
        _hint('这个引擎没有报告中文音色，换上面的引擎试试')
      else
        for (final voice in _voices) _voiceTile(voice),
      if (_diagnosis != null) ...[const Divider(height: 24), _diagnosisBlock()],
      const Divider(height: 24),
      _rateSection(),
    ],
  );

  /// 「用系统默认的」要说出来，但不能说成坏了。
  ///
  /// ⚠️ 这段是这条链路上**最容易误导人**的一句。说成「没有中文朗读能力」，
  /// 用户会去装语音包、换引擎折腾一圈 —— 可题明明念得出来。
  /// 说成「一切正常」又不成立：换了引擎声音没变化，人会觉得设置没生效。
  /// 所以是：**能念 + 用的是系统默认 + 想换去哪里换**。
  Widget _degradedBanner() => Container(
    margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: BoxDecoration(
      color: AppColors.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 16, color: AppColors.primary),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            '这台设备没有报告可用的中文语音数据，'
            '正在用系统默认的声音朗读（题照样能念出来）。'
            '想换声音，去系统设置 → 语言和输入法 → 文字转语音里装一个中文语音包。',
            style: TextStyle(fontSize: 12, height: 1.5),
          ),
        ),
      ],
    ),
  );

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
    ),
  );

  Widget _voicesErrorView(String message) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _saving
              ? null
              : () => _load(engineOverride: _activeEngine),
          child: const Text('重新读取'),
        ),
      ],
    ),
  );

  /// 出问题时把**原始事实**摊开：厂商、引擎数、初始化返回码。
  ///
  /// 这一块不是为了好看。鸿蒙上通过卓易通运行安卓应用时根本没有 TTS 服务，
  /// 但界面上原来只说「没有中文朗读能力」—— 用户会去装语音包、换引擎，
  /// 折腾一圈都不会有效果。「引擎 0 个 / 初始化返回 -1」是唯一能让人
  /// 立刻判断「这条路在这台机器上不存在」的证据。
  Widget _diagnosisBlock() {
    final d = _diagnosis!;
    final initFailed = d.initStatus != _ttsInitSuccess && d.initStatus != -1;
    final looksLikeContainer = d.engineCount == 0 || initFailed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '诊断',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '设备：${d.manufacturer} ${d.model} · Android ${d.sdk}',
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
          Text(
            '引擎：${d.engineCount} 个 · 中文${d.languageReady ? '可用' : '不可用'} · '
            '状态 ${_stateLabel(d.state)}'
            '${d.initStatus == _ttsInitSuccess || d.initStatus == -1 ? '' : '（初始化返回 ${d.initStatus}）'}',
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
          if (looksLikeContainer) ...[
            const SizedBox(height: 8),
            const Text(
              '引擎一个都没起来，通常是系统层面没有语音合成服务。'
              '鸿蒙（应用通过卓易通安装）就是这种情况：'
              '那边没有实现安卓的 TTS，装中文语音包也不会生效 —— '
              '这类设备上朗读出不了声，只能用眼睛看讲解。',
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ] else if (d.initStatus == _ttsInitSuccess && !d.languageReady) ...[
            // 引擎好着，只是没报告中文数据 —— 这是**降级**，不是故障。
            // 和上面那条结论必须分开：一个让人别折腾，一个让人知道还有救。
            const SizedBox(height: 8),
            const Text(
              '引擎能启动，只是没报告中文语音数据；'
              '这种情况下会用系统默认的声音继续朗读。',
              style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  static const int _ttsInitSuccess = 0;

  String _stateLabel(int state) => switch (state) {
    1 => '就绪',
    2 => '降级（用系统默认）',
    0 => '初始化中',
    -1 => '不可用',
    _ => '未知($state)',
  };

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppColors.textMuted,
      ),
    ),
  );

  Widget _engineTile(({String name, String label, bool isDefault}) engine) {
    // 「系统默认」也要是一个能选回来的选项，否则选错引擎就回不去了。
    final selected =
        _activeEngine == engine.name ||
        (_activeEngine.isEmpty && engine.isDefault);
    return ListTile(
      dense: true,
      leading: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 18,
        color: selected ? AppColors.primary : AppColors.textMuted,
      ),
      title: Text(engine.label, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        engine.isDefault ? '系统默认' : engine.name,
        style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted),
      ),
      onTap: _saving ? null : () => _apply(engine: engine.name),
    );
  }

  Widget _voiceTile(_VoiceOption voice) {
    final selected = _activeVoice == voice.name;
    return ListTile(
      // 用 key 定位而不是靠显示文字：显示文字是「给人看的」，会随排版调整，
      // 拿它当测试锚点会让判据跟着 UI 文案一起漂。
      key: ValueKey<String>('tts-voice-${voice.name}'),
      dense: true,
      leading: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 18,
        color: selected ? AppColors.primary : AppColors.textMuted,
      ),
      title: Text(
        '${voice.label}（${voice.suffix}）',
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: voice.network
          ? const Text(
              '需要联网才能念 —— 断网时会退回别的音色',
              style: TextStyle(fontSize: 10.5, color: AppColors.textMuted),
            )
          : null,
      onTap: _saving ? null : () => _apply(voice: voice.name),
    );
  }

  Widget _rateSection() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '语速',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
                ),
              ),
            ),
            Text(
              '${(_rate * 100).round()}%',
              style: const TextStyle(fontSize: 12, color: AppColors.primary),
            ),
          ],
        ),
        Slider(
          value: _rate.clamp(0.5, 1.5),
          min: 0.5,
          max: 1.5,
          divisions: 20,
          label: '${(_rate * 100).round()}%',
          // 拖动时只改本地数字：每动一格就重建一次引擎会卡，
          // 而且重建的那一瞬间正在念的声音会被切断。
          onChanged: (v) => setState(() => _rate = v),
          onChangeEnd: (v) => _apply(rate: v),
        ),
        const Text(
          '讲推导时 90%~100% 比较好跟；只想快速过一遍可以调到 120%。',
          style: TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
      ],
    ),
  );
}
