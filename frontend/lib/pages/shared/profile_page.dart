import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../constants/grades.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/parent_controller.dart';
import '../../controllers/point_controller.dart';
import '../../controllers/profile_controller.dart';
import '../../models/user_model.dart';
import '../../models/user_profile_model.dart';
import '../../repositories/ima_repository.dart';
import '../../services/database_service.dart';
import '../../services/data_api_client.dart';
import '../../widgets/point_widgets.dart';
import '../../widgets/update_widgets.dart';
import '../student/widgets/tts_settings_sheet.dart';
import 'point_ledger_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final nameController = TextEditingController();
  final bioController = TextEditingController();
  String gender = '未填写';
  String grade = '未填写';
  String term = '未填写';
  final selectedHobbies = <String>{};
  final hobbies = const ['阅读', '运动', '音乐', '绘画', '编程', '旅行'];
  final profileController = Get.put(ProfileController());

  @override
  void initState() {
    super.initState();
    final user = Get.find<AuthController>().currentUser.value;
    if (user != null) {
      // 积分卡要有数字可显示，先把账本拉一遍。
      // 学生端在 `StudentController.loadData` 里已经拉过，这里只是兜底 ——
      // 直接进个人信息页（例如从通知跳过来）时也不会看到空余额。
      PointController.to.loadFor(user.id);
      profileController.load(user.id).then((_) {
        final profile = profileController.profile.value;
        if (!mounted || profile == null) return;
        setState(() {
          nameController.text = profile.name;
          bioController.text = profile.bio;
          gender = profile.gender.isEmpty ? '未填写' : profile.gender;
          // 老档案里若存过「七年级」这类别名，先归一；下拉的 initialValue
          // 必须是 items 里的值，否则 DropdownButtonFormField 会抛断言。
          grade = profileInitialGrade(profile.grade);
          term = kTermOptions.contains(profile.term.trim())
              ? profile.term.trim()
              : kGradeUnset;
          selectedHobbies
            ..clear()
            ..addAll(profile.hobbies);
        });
      });
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    bioController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = Get.find<AuthController>().currentUser.value;
    final isStudent = user?.role == 'student';

    return Scaffold(
      appBar: AppBar(title: const Text('个人信息设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 积分只对学生本人展示：家长的积分入口在家长端「积分」页，
          // 那里能切孩子、能设分值，个人信息页放一份反而会让人以为
          // 这里是改分值的地方。
          if (isStudent && user != null) ...[
            Obx(() {
              final points = PointController.to;
              return PointBalanceCard(
                account: points.account.value,
                title: '我的积分',
                subtitle: '交作业、运动、打卡、复习都能赚积分',
                onOpenLedger: () => Get.to(
                  () => PointLedgerPage(
                    studentId: user.id,
                    subjectName: nameController.text.trim(),
                  ),
                ),
              );
            }),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: '名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: gender,
            decoration: const InputDecoration(
              labelText: '性别',
              border: OutlineInputBorder(),
            ),
            items: const ['未填写', '男', '女', '其他']
                .map((item) => DropdownMenuItem(value: item, child: Text(item)))
                .toList(),
            onChanged: (value) => setState(() => gender = value ?? '未填写'),
          ),
          const SizedBox(height: 14),
          if (isStudent)
            DropdownButtonFormField<String>(
              initialValue: grade,
              decoration: const InputDecoration(
                labelText: '年级',
                border: OutlineInputBorder(),
              ),
              // 年级只有 [kGradeOptions] 一份真值：教材/词表导入弹窗、
              // 错题归档顺序都读它。抄一份就会重新长出「初一 vs 七年级」。
              items: <String>[kGradeUnset, ...kGradeOptions]
                  .map(
                    (item) =>
                        DropdownMenuItem(value: item, child: Text(item)),
                  )
                  .toList(),
              onChanged: (value) => setState(() => grade = value ?? '未填写'),
            ),
          if (isStudent) const SizedBox(height: 14),
          if (isStudent)
            DropdownButtonFormField<String>(
              initialValue: term,
              decoration: const InputDecoration(
                labelText: '学期',
                helperText: '错题会按「年级 + 学期」归档，升级后历史错题仍留在原学期',
                border: OutlineInputBorder(),
              ),
              items: const {'未填写': '未填写', '上': '上学期', '下': '下学期'}.entries
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => term = value ?? '未填写'),
            ),
          if (isStudent) const SizedBox(height: 14),
          const Text(
            '兴趣爱好（可多选）',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: hobbies
                .map(
                  (item) => FilterChip(
                    label: Text(item),
                    selected: selectedHobbies.contains(item),
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          selectedHobbies.add(item);
                        } else {
                          selectedHobbies.remove(item);
                        }
                      });
                    },
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: bioController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '个人简介',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: user == null ? null : () => _save(user.id),
              child: const Text('保存个人信息'),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '家长端不要求填写年级，学生端年级用于后续学习内容匹配。',
            style: TextStyle(color: AppColors.textMuted),
          ),
          if (user != null) ...[
            const SizedBox(height: 24),
            // 朗读设置放这里，不放讲解页：声音是「一个人的偏好」，
            // 设一次就该一直用，不该每听一道题都要重新挑一遍。
            const TtsSettingsTile(),
            const SizedBox(height: 12),
            _AccountSecurityCard(
              phone: user.phone,
              hasPhone: user.hasPhone,
              hasPassword: user.hasPassword,
              smsEnabled: Get.find<AuthController>().smsEnabled,
            ),
            const SizedBox(height: 16),
            if (DatabaseService.isCloud) ...[
              // 概念打卡的入口已经搬到计划标签页（`CheckinEntryCard`）：
              // 它属于「今天要做什么」，不属于账号设置。这里只剩 ima 同步，
              // 那个确实和「身份 / 账号」绑在一起。
              const _ImaSyncCard(),
              const SizedBox(height: 16),
            ],
            // 更新卡片自己判断「服务端有没有更新包」：没有就渲染成空，
            // 不显示一个点了没反应的按钮。
            const UpdateCard(),
            const SizedBox(height: 16),
            _SignOutCard(name: user.name, phone: user.phone, role: user.role),
          ],
        ],
      ),
    );
  }

  Future<void> _save(String userId) async {
    if (nameController.text.trim().isEmpty) {
      Get.snackbar('提示', '名称不能为空');
      return;
    }
    await profileController.saveProfile(
      UserProfileModel(
        userId: userId,
        name: nameController.text.trim(),
        gender: gender == '未填写' ? '' : gender,
        grade: grade == '未填写' ? '' : grade,
        term: term == '未填写' ? '' : term,
        hobbies: selectedHobbies.toList(),
        bio: bioController.text.trim(),
      ),
    );
    Get.snackbar('保存成功', '个人信息已写入数据库');
  }
}

/// 「账号与安全」：登录方式的**现状**与**预留入口**。
///
/// 放在个人信息页而不是塞进设置菜单，是因为这里已经有身份上下文
/// （`currentUser`），而三件事都需要它才能说清楚：
/// 手机号打码后展示、有没有设过密码、改密码该走哪条路。
///
/// 注意文案的分支来自**账号数据**（[UserModel.hasPassword]），
/// 不是来自环境：微信建号没有密码，对它说「重置密码」是错的 ——
/// 用户会先怀疑自己忘了什么，再发现原来从来没设过。
class _AccountSecurityCard extends StatelessWidget {
  const _AccountSecurityCard({
    required this.phone,
    required this.hasPhone,
    required this.hasPassword,
    required this.smsEnabled,
  });

  final String phone;
  final bool hasPhone;
  final bool hasPassword;
  final bool smsEnabled;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '账号与安全',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 12),
            _AccountRow(
              label: '登录手机号',
              value: hasPhone ? UserModel.maskPhone(phone) : '未绑定手机号',
            ),
            const SizedBox(height: 8),
            _AccountRow(
              label: '登录密码',
              value: hasPassword ? '已设置' : '未设置（微信登录创建）',
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                // 入口一直可点，页面会说明为什么现在用不了。
                // 灰掉它、或者干脆不显示，就没人记得这里少了一个功能。
                onPressed: hasPhone
                    ? () => Get.toNamed('/forgot-password', arguments: phone)
                    : null,
                child: Text(hasPassword ? '修改密码' : '设置密码'),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hasPhone
                  ? (smsEnabled
                        ? '修改密码需要通过手机号短信验证码验证。'
                        : '修改密码需要通过手机号短信验证码验证；'
                              '短信服务尚未接入，暂时无法使用。')
                  : '未绑定手机号，暂时无法通过短信修改密码。',
              style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: const TextStyle(color: AppColors.textMuted),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// 「退出登录」。
///
/// 刻意**不和「保存个人信息」并排**：一个是把资料写回去，另一个会丢掉本机
/// 登录态 —— 两者误点的代价不对等（保存点错了没损失，退出点错了要重新登录，
/// 云端模式下还要重输密码）。所以它单独一张卡、单独一次确认。
///
/// 卡片上写清楚**要退出哪个账号**：同一台设备上家长和学生轮流登录是常态，
/// 只说「退出登录」的话，用户没法确认自己要走的不是孩子那个号 ——
/// 而这个动作会连带清掉本机的登录凭证。
class _SignOutCard extends StatefulWidget {
  const _SignOutCard({
    required this.name,
    required this.phone,
    required this.role,
  });

  final String name;
  final String phone;
  final String role;

  @override
  State<_SignOutCard> createState() => _SignOutCardState();
}

class _SignOutCardState extends State<_SignOutCard> {
  /// 请求在飞的时候禁用按钮。连点两次会多发一次登出请求，第二次必然
  /// 401 然后被吞掉 —— 结果是对的，但按钮会闪两下，看起来像没点中。
  bool _busy = false;

  String get _roleLabel => widget.role == 'parent' ? '家长' : '学生';

  String get _identity {
    final phone = widget.phone.isEmpty
        ? '（未绑定手机号）'
        : '（${UserModel.maskPhone(widget.phone)}）';
    return '${widget.name} · $_roleLabel$phone';
  }

  Future<void> _confirm() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录？'),
        content: Text(
          '将退出当前账号：$_identity\n\n'
          '本机保存的登录凭证会被清除，下次进入需要重新登录。'
          '已同步到服务端的作业与照片不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            // 对话框里这一颗才是「真退」，所以用危险色；卡片上那颗只是入口。
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    // 跳转由 [AuthController.logout] 负责（它会先吊销服务端会话、再清本地
    // 凭证、最后才 `offAllNamed`）。这里 await 它，只是为了把按钮按住 ——
    // 用户在这几百毫秒里连点，就是上面那个「闪两下」的来源。
    await Get.find<AuthController>().logout();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '退出当前账号',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              '当前登录：$_identity',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _confirm,
                icon: const Icon(Icons.logout, size: 18),
                label: Text(_busy ? '正在退出…' : '退出登录'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '换账号（比如家长改成孩子的号）走这里。'
              '退出只清本机的登录凭证，服务端的数据不会被删。',
              style: TextStyle(fontSize: 13, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「ima 知识库同步」入口卡（仅云端模式可见）。
///
/// 自包含：自己拉一次状态并展示徽标，点「管理」跳到 `ima_settings_page`。
/// 放在个人信息页是因为它和用户身份、账号管理同屏，家长一眼能看到「开没开」。
///
/// 只给一个入口、不在这里展开连接表单，理由与「账号与安全」一致：
/// 连接要粘贴密钥、展示每个孩子的 KB，那是另一个完整的交互，
/// 塞进这张已经很长的页只会让它更难读。真要做连接，去专门的设置页。
class _ImaSyncCard extends StatefulWidget {
  const _ImaSyncCard();

  @override
  State<_ImaSyncCard> createState() => _ImaSyncCardState();
}

class _ImaSyncCardState extends State<_ImaSyncCard> {
  ImaStatus? _status;
  bool _loading = true;

  /// 状态读取失败（本地模式 / 断网 / 服务端异常）。
  /// 与「未开启」分开：前者是**不知道**，后者是**知道且没开**。
  bool _failed = false;

  Worker? _studentWorker;

  @override
  void initState() {
    super.initState();
    // ⭐ ima 配置按学生归属：个人页的徽标也必须跟着「当前伴学学生」切，
    // 否则父亲给老大配好后，切到没配的老二仍显示「已开启」。
    if (Get.isRegistered<ParentController>()) {
      _studentWorker = ever<String>(
        Get.find<ParentController>().selectedStudentId,
        (_) => unawaited(_load()),
      );
    }
    _load();
  }

  @override
  void dispose() {
    _studentWorker?.dispose();
    super.dispose();
  }

  String? _currentStudentId() {
    if (!Get.isRegistered<ParentController>()) return null;
    final id = Get.find<ParentController>().selectedStudentId.value;
    return id.isEmpty ? null : id;
  }

  Future<void> _load() async {
    // 重读时先把上一次的失败标记清掉，否则「连上了」仍会显示「状态未知」。
    if (mounted && _failed) setState(() => _failed = false);
    try {
      final s = await DatabaseService.ima.getStatus(studentId: _currentStudentId());
      if (mounted) setState(() => _status = s);
    } on DataApiException {
      // 状态读不到不阻塞个人信息页其余部分 —— 但**必须显式说出来**：
      // 若只是保持 null，`_loading` 已为 false，徽标会永远停在「加载中…」，
      // 「加载完了却还在转」是最容易被读成「卡住了」的假象。
      if (mounted) setState(() => _failed = true);
    } catch (_) {
      // 本地模式 / 网络异常同理：吞掉异常，但留下失败标记。
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  (String, Color) get _badge {
    // 文案只从 [_label] 来，颜色另算 —— 同一个语义不许两处各写一遍。
    final s = _status;
    final color = switch (s) {
      null => AppColors.textMuted,
      _ when s.isActive => AppColors.success,
      _ when s.isExpired => AppColors.warning,
      _ => AppColors.textMuted,
    };
    return (imaStatusLabel(_status, failed: _failed), color);
  }

  @override
  Widget build(BuildContext context) {
    // 服务端没开通 ima：这张入口卡整体不出现。
    // 「功能可以没有，但不能出错」—— 不显示一个点进去只会报错的按钮。
    if (_status?.isFeatureEnabled == false) return const SizedBox.shrink();
    final (label, color) = _badge;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'ima 知识库同步',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
                const Spacer(),
                if (!_loading)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(color: color, fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '把当前伴学学生的错题档案同步到他自己的 ima 知识库，方便检索与二次学习。'
              '这是可选功能，不开启也能正常使用。',
              style: TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                // 从设置页回来必须重读状态 —— 否则刚连上 ima、返回这里
                // 徽标还写着「未开启」，用户会以为没连成功。
                onPressed: () async {
                  await Get.toNamed('/ima-settings');
                  if (mounted) await _load();
                },
                child: const Text('管理 ima 同步'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
