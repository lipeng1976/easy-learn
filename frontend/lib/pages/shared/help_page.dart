import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../constants/app_colors.dart';
import '../../controllers/auth_controller.dart';

/// 使用帮助（角色视角手册）。
///
/// 纯静态内容页：不查库、不联网 —— 帮助页自己挂了就会变成第二个「卡住
/// 等数据」的地方，那就讽刺了。内容改这里就行。
///
/// 默认按当前登录角色展示：学生看「学生手册」（从结对讲起，按一天的使用
/// 顺序串下来），家长看「家长视角」。顶部可切到另一份。
///
/// 学生手册的重点章节是错题本：它的状态流转（待复习 → 复习中 → 待批改 →
/// 已掌握）是全 App 唯一一个「不解释就一定有人卡住」的机制 —— 卷子导出后
/// 错题会从「待复习」消失，学生第一反应是「我的题哪去了」。
class HelpPage extends StatefulWidget {
  const HelpPage({super.key});

  @override
  State<HelpPage> createState() => _HelpPageState();
}

class _HelpPageState extends State<HelpPage> {
  late bool _studentView;

  @override
  void initState() {
    super.initState();
    final role =
        Get.find<AuthController>().currentUser.value?.role ?? 'student';
    _studentView = role != 'parent';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('使用帮助'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                _RoleTab(
                  label: '学生手册',
                  selected: _studentView,
                  onTap: () => setState(() => _studentView = true),
                ),
                const SizedBox(width: 10),
                _RoleTab(
                  label: '家长视角',
                  selected: !_studentView,
                  onTap: () => setState(() => _studentView = false),
                ),
              ],
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: _studentView ? _studentSections() : _parentSections(),
      ),
    );
  }

  // ===== 学生手册 =====

  List<Widget> _studentSections() => const [
        _Section(
          title: '第一步：和家长结伴',
          children: [
            _Paragraph(
              '学生和家长是互相邀请结对的，谁先发起都行。',
            ),
            _Bullet(
              label: '怎么结',
              text: '点首页右上角的「绑定管理」（两个小人的图标），输入对方的手机号，'
                  '发送结伴邀请。对方在自己的绑定管理页里看到这条邀请，点「通过」就行。',
            ),
            _Bullet(
              label: '结伴后',
              text: '家长能看到你的作业、错题和复习进度，也能给你布置锻炼和学习计划、'
                  '兑现心愿。你也能看到家长写给你的每日点评。',
            ),
          ],
        ),
        SizedBox(height: 14),
        _Section(
          title: '每天放学：把作业录进来',
          children: [
            _Paragraph(
              '作业页点「拍照识别」：可以一张一张拍（最多 9 张），也可以从相册一次'
                  '多选整份作业。App 会识别出每一行作业，按科目归类，再预填成一个'
                  '「待核对」的表单。',
            ),
            _Paragraph('保存前做两件事：'),
            _Bullet(
              label: '核对标题',
              text: '识别的字可能认错，改对标题即可。标题改对了，「预计耗时」和'
                  '「要不要批改」会跟着自动变对。',
            ),
            _Bullet(
              label: '看是否要批改',
              text: '只有「有标准答案」的作业才需要 AI 批改。详见下一节。',
            ),
            _Paragraph(
              '识别不出来也别慌：App 会给出口，要么重拍、要么直接手工录一条，'
                  '后面的批改和错题复习都照常走。',
            ),
          ],
        ),
        SizedBox(height: 14),
        _Section(
          title: '哪些作业要 AI 批改，哪些只记完成',
          children: [
            _Paragraph(
              '判断标准只有一条：**这道题的答案有没有被你拍进照片里**。',
            ),
            _Bullet(
              label: '要批改',
              text: '口算、书面题、订正 —— 题目和答案在同一张纸上，模型能照着题面判。'
                  '交上来会给出分数和错题，错的自动进错题本。',
            ),
            _Bullet(
              label: '只记完成',
              text: '默写/听写、抄写/字帖、朗读、背诵、预习 —— 纸上只有你写的东西，'
                  '题干（词表、范字、要背的课文）根本不在照片里，模型没有可判的东西。'
                  '这类交上来的照片是「我做过了」的凭证，不判对错。',
            ),
            _Paragraph(
              '「要不要批改」系统会按标题先帮你选好，你随时可以在录入时或提交前改。'
                  '改了才作数，系统不会在你没动过的地方瞎覆盖。',
            ),
          ],
        ),
        SizedBox(height: 14),
        _Section(
          title: '写作业时：开专注计时',
          children: [
            _Paragraph(
              '在作业项上点开专注计时，就能给这一项作业记实际用时。',
            ),
            _Bullet(
              label: '只记专注时间',
              text: '暂停不计时，走神、上厕所的时间不算。连续用满 40 分钟会提醒你休息。',
            ),
            _Bullet(
              label: '一次只记一项',
              text: '同时只能有一份作业在计时。要开始另一项，先把上一项暂停并保存 —— '
                  '两科时间叠在一起，那个「实际用时」就没有意义了。',
            ),
          ],
        ),
        SizedBox(height: 14),
        _Section(
          title: '计划和锻炼：家长布置，你来打卡',
          children: [
            _Paragraph(
              '家长布置的学习计划或锻炼计划，会先出现在你的「计划」或「运动」页里'
                  '标着「待确认」。',
            ),
            _Bullet(
              label: '先确认',
              text: '看清楚就点确认（接受），不想做或做不到就拒绝、可以填一句理由，'
                  '家长看到后会调整。',
            ),
            _Bullet(
              label: '再打卡',
              text: '计划生效后，按计划里写的周期（每天/每周/每月）执行，做完在对应'
                  '那天点打卡。计划页顶部会提示今天还有几项没打卡。',
            ),
          ],
        ),
        SizedBox(height: 14),
        _Section(
          title: '复习：错题本的完整闭环',
          children: [
            _Paragraph(
              '错题有三个来源：作业拍照批改（批完自动进本）、扫题录入、手工录入。'
                  '不管哪条路进来，题都先停在「待复习」。',
            ),
            _StateFlow(),
            _Paragraph('每个状态里你该做什么：'),
            _Bullet(
              label: '待复习',
              text: '题在池子里。点卡片能看讲解、出变式题；也可以把同类的题组进'
                  '一份重做卷（支持导出 PDF 打印）。',
            ),
            _Bullet(
              label: '复习中',
              text: '题已经进卷、资料已导出，所以它会从「待复习」里消失——这不是丢了。'
                  '去「复习资料」把卷子做完，做完回传。',
            ),
            _Bullet(
              label: '待批改',
              text: '卷子已回传，等判定。填了答案的题由 AI 判，没填的按你的自评记。',
            ),
            _Bullet(
              label: '已掌握',
              text: '毕业了，不再进池。档案留着，随时能回看。',
            ),
          ],
        ),
        SizedBox(height: 14),
        _Section(
          title: '错题什么时候能毕业',
          children: [
            _Paragraph(
              '一次做对不算毕业。做对后题目回到「待复习」，等下一轮组卷再考一次；'
                  '连续两轮都通过才算真正掌握、移出错题本。反复错的题就是用这个机制'
                  '逼着多过几遍。',
            ),
            _Paragraph(
              '注意：AI 批改偶尔会误判（把做对的报成错的、把「漏答一问」说成「算错」）。'
                  '发现错因和实际对不上，在错题详情里改掉就行，以你改的为准。',
            ),
          ],
        ),
        SizedBox(height: 14),
        _Section(
          title: '心愿与积分',
          children: [
            _Paragraph(
              '交作业、运动打卡、学习计划打卡、错题毕业……都能赚积分。攒够了就许个愿。',
            ),
            _Bullet(
              label: '许愿',
              text: '在「心愿」页新增心愿，写明想要什么、要多少积分。',
            ),
            _Bullet(
              label: '申请兑现',
              text: '积分够了就点「申请兑现」。这一步只登记意向、不扣分 —— '
                  '真正的扣分发生在家长确认兑现的那一刻。家长没确认前可以撤回。',
            ),
          ],
        ),
        SizedBox(height: 24),
      ];

  // ===== 家长视角 =====

  List<Widget> _parentSections() => const [
        _Section(
          title: '和孩子结伴',
          children: [
            _Paragraph(
              '家长和孩子是互相邀请结对的，谁先发起都行。',
            ),
            _Bullet(
              label: '怎么结',
              text: '点右上角「更多 → 伴学绑定」，输入孩子的手机号发结伴邀请。'
                  '孩子在绑定管理页点「通过」即可。',
            ),
            _Bullet(
              label: '结伴后',
              text: '你能看到孩子的作业、错题和复习进度，布置学习和锻炼计划、'
                  '兑现心愿、写每日点评。',
            ),
          ],
        ),
        SizedBox(height: 14),
        _Section(
          title: '你能为孩子做什么',
          children: [
            _Bullet(
              label: '布置计划',
              text: '布置学习计划或锻炼计划。布置后孩子那边会显示「待确认」，'
                  '孩子接受才生效，拒绝会带理由回给你。',
            ),
            _Bullet(
              label: '看作业',
              text: '孩子提交的作业、AI 批改结果、错题都能看。',
            ),
            _Bullet(
              label: '兑现心愿',
              text: '孩子申请兑现后由你确认，确认的那一刻才扣积分。',
            ),
            _Bullet(
              label: '每日点评',
              text: '顶栏的笔图标，给孩子写一句当天的话。',
            ),
          ],
        ),
        SizedBox(height: 14),
        _Section(
          title: '看懂错题本：孩子的复习闭环',
          children: [
            _Paragraph(
              '孩子的错题在四个状态里流转。看懂这个，你就知道「他复习到哪一步了」。',
            ),
            _StateFlow(),
            _Bullet(
              label: '待复习',
              text: '错题在池子里，还没进卷。这是「还没开始复习」的信号。',
            ),
            _Bullet(
              label: '复习中',
              text: '已组卷并导出，孩子正在（或该去做）这份重做卷。题从待复习里'
                  '消失是正常的。',
            ),
            _Bullet(
              label: '待批改',
              text: '卷子回传了，正在判定。',
            ),
            _Bullet(
              label: '已掌握',
              text: '连续两轮做对，毕业了。',
            ),
            _Paragraph(
              '注意：AI 批改可能误判。孩子（或你）在错题详情里能改错因，以改的为准。',
            ),
          ],
        ),
        SizedBox(height: 14),
        _Section(
          title: '常见疑问',
          children: [
            _Faq(
              q: '孩子导出卷子后，「待复习」里的题怎么不见了？',
              a: '它们进了「复习中」。卷子导出后错题就从待复习池移出，避免被重复组卷。'
                  '孩子做完卷子回传，它们会继续往前走。',
            ),
            _Faq(
              q: '手工录入的错题为什么没有「批改」？',
              a: '批改只发生在作业那条链路（拍照交作业后 AI 批改）。手工录入的错题'
                  '没有「当时的批改」，只有复习结果——做完重做卷回传后就能看到判定。',
            ),
            _Faq(
              q: '同一道题能录两次吗？',
              a: '不能。同样的题干 5 分钟内再次保存会提示「刚加过」，不会插入重复。'
                  '隔了很久再录是允许的——那说明真的又错了一次。',
            ),
          ],
        ),
        SizedBox(height: 24),
      ];
}

class _RoleTab extends StatelessWidget {
  const _RoleTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? AppColors.primary : AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // 用 `Material` 而不是 `Container + BoxDecoration`：卡里的 FAQ 是
    // `ExpansionTile`（内部 `ListTile`），它要把背景和墨水涟漪画到
    // 最近的 Material 上 —— Container 的 DecoratedBox 会把这一切盖住，
    // 测试框架直接抛断言（ListTile background may be invisible）。
    return Material(
      color: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Paragraph extends StatelessWidget {
  const _Paragraph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, height: 1.7),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 3),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, height: 1.7),
            ),
          ),
        ],
      ),
    );
  }
}

class _Faq extends StatelessWidget {
  const _Faq({required this.q, required this.a});

  final String q;
  final String a;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: AppColors.border),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text(
          q,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              a,
              style: const TextStyle(
                fontSize: 13,
                height: 1.7,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态流转图：四个状态块 + 箭头，纯 widget 画，不引外部资源。
class _StateFlow extends StatelessWidget {
  const _StateFlow();

  @override
  Widget build(BuildContext context) {
    const states = [
      ('待复习', '在池里，可组卷', AppColors.primary),
      ('复习中', '已进卷，等做完', AppColors.warning),
      ('待批改', '已回传，等判定', AppColors.primary),
      ('已掌握', '毕业，只留档', AppColors.success),
    ];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              for (var i = 0; i < states.length; i++) ...[
                if (i > 0)
                  const Icon(
                    Icons.arrow_forward_ios,
                    size: 12,
                    color: AppColors.textMuted,
                  ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        states[i].$1,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: states[i].$3,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        states[i].$2,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            '做对但没到两轮 → 回到「待复习」，下一轮再考',
            style: TextStyle(fontSize: 10.5, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}
