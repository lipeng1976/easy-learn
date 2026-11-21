import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/point_model.dart';
import '../../repositories/point_repository.dart';
import '../../services/database_service.dart';
import '../../widgets/point_widgets.dart';

/// 积分明细。
///
/// 这个页面**刻意不碰全局账本**（`PointController`）：家长可能一边翻着
/// A 的明细、一边又从别处切到 B，用同一份全局缓存会让 A 的页面突然显示
/// B 的数字。明细是只读的，自己拉自己的数据最省事，也不会互相干扰。
class PointLedgerPage extends StatefulWidget {
  const PointLedgerPage({
    super.key,
    required this.studentId,
    this.title = '积分明细',
    this.subjectName = '',
    this.repository,
  });

  final String studentId;
  final String title;

  /// 展示用的人名（「林小宇的积分」），空则不显示。
  final String subjectName;

  /// 明细的数据源。默认走本地库 —— **换云端实现时只改这一处默认值**。
  ///
  /// 之所以由页面自己持一个引用（而不是去 `Get.find<PointController>()`）：
  /// 见上面的类注释，这个页面刻意与全局账本解耦。它是全项目**最后一个**
  /// 直接碰 `DatabaseService` 的页面，收口后 UI 层对具体实现零依赖。
  final PointRepository? repository;

  @override
  State<PointLedgerPage> createState() => _PointLedgerPageState();
}

class _PointLedgerPageState extends State<PointLedgerPage> {
  List<PointLedgerEntry> entries = const [];
  PointAccount account = PointAccount.empty;
  bool isLoading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => isLoading = true);
    try {
      final repo = widget.repository ?? DatabaseService.instance;
      final rows = await repo.queryPointLedger(
        widget.studentId,
      );
      if (!mounted) return;
      setState(() {
        entries = rows;
        account = PointAccount.fromLedger(rows);
        error = null;
        isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = '$e';
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PointBalanceCard(
              account: account,
              title: widget.subjectName.isEmpty
                  ? '积分余额'
                  : '${widget.subjectName}的积分',
              subtitle: '余额由每一条记录累加得来，撤销会留下痕迹',
            ),
            const SizedBox(height: 16),
            const Text(
              '积分记录',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            if (isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null)
              PointEmptyHint(text: '读取失败：$error')
            else if (entries.isEmpty)
              const PointEmptyHint(
                text: '还没有积分记录。\n交作业、运动、打卡、复习都能赚积分。',
              )
            else
              ...entries.map((entry) => PointLedgerTile(entry: entry)),
            if (entries.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                '撤销不会删掉记录，而是补一笔相反的账 —— 所以「已撤销」的那条还会留在这里。',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
