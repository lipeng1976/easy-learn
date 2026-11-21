import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// 取回「拍照途中被系统回收」的照片。
///
/// 为什么需要这个东西：Android 在内存紧张时会回收退到后台的 Activity，
/// 而拍照恰好踩中这个场景 —— 相机是内存大户，学生一点「拍照」，
/// 我们自己的界面就退到后台了。照片其实拍成了、也写进了 image_picker
/// 的缓存，但控制权回来时是**冷启动**：没有任何人再去取它。
///
/// 现场的观感是「照片凭空消失」——学生只会认为白拍了一场，然后重拍一遍。
/// 它不会报错、不会留下日志，所以只能靠主动取回来解决。
/// image_picker 的官方文档对这个流程的要求是「启动时就应该跑一次」。
///
/// Web 端不存在这个问题（浏览器不会回收页面进程），但多调一次也不会出错 ——
/// 这里显式短路只是为了少一次无意义的平台调用。
class LostPhotoRecovery {
  const LostPhotoRecovery({this.retrieve});

  /// 取数入口。留成可注入是为了让「接入点有没有真的接上」能被测试覆盖：
  /// 这条路径在真机上要靠系统杀进程才触发，没法手工复现。
  final Future<LostDataResponse> Function()? retrieve;

  /// 全局实例。
  ///
  /// 用可替换的静态实例而不是构造注入，是因为调用方是界面里的 `initState`
  /// 与按钮回调 —— 把恢复服务一路透传下去会把测试的关注点泄漏进产品 API。
  /// 测试里替换它即可模拟「系统回收后重启」。
  static LostPhotoRecovery instance = const LostPhotoRecovery();

  /// 取出待恢复的照片；没有就返回空列表。
  ///
  /// `retrieveLostData()` 是**取一次就清空**的语义：别拿它当查询接口反复调用，
  /// 否则第二次会拿到空结果，把先取到的那批悄悄覆盖掉。
  ///
  /// 出错时返回空列表而不是抛出：最坏情况就是学生重拍一张，
  /// 但不该因为「取不回来」把整个提交面板变成红屏。
  Future<List<XFile>> takeLostPhotos() async {
    if (kIsWeb) return const <XFile>[];
    try {
      final response = await (retrieve ?? ImagePicker().retrieveLostData)();

      // `isEmpty` 判断的是「这个响应是不是空的」，而**不是**「里面有没有文件」——
      // 它只在用 `LostDataResponse.empty()` 构造时才为真。所以后面还得兜一层。
      if (response.isEmpty) return const <XFile>[];

      // files 与 file 两个字段都要看：多选填 files，而单张拍照在部分实现里
      // 只填 file。又因为官方注释写明「files 有值时 file 就是它的最后一项」，
      // 顺序不能反 —— 反过来会凭空多出一张重复的照片。
      final files = <XFile>[...?response.files];
      if (files.isEmpty && response.file != null) files.add(response.file!);
      return files;
    } catch (error) {
      debugPrint('取回丢失照片失败（忽略，学生可重拍）：$error');
      return const <XFile>[];
    }
  }
}
