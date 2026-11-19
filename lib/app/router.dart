import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/about/about_page.dart';
import '../features/batch/batch_page.dart';
import '../features/crop/crop_page.dart';
import '../features/export/export_page.dart';
import '../features/home/home_page.dart';
import '../features/resize/resize_page.dart';

abstract final class AppRoutes {
  static const home = '/';
  static const crop = '/crop';
  static const resize = '/resize';

  /// 导出面板：格式转换与压缩合并为同一页面（PRD 四 / 五章、十三章）。
  static const exportPanel = '/export';

  /// 批量流水线入口（v0.5 / M3）：单图是 N=1 的特例。
  static const pipeline = '/pipeline';

  /// 关于页：版本、隐私说明、开源许可、诊断日志（PRD 十三 / 十六章）。
  static const about = '/about';
}

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoutes.home,
    routes: [
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const HomePage(),
      ),
      GoRoute(
        path: AppRoutes.crop,
        builder: (context, state) => const CropPage(),
      ),
      GoRoute(
        path: AppRoutes.resize,
        builder: (context, state) => const ResizePage(),
      ),
      GoRoute(
        path: AppRoutes.exportPanel,
        builder: (context, state) => const ExportPage(),
      ),
      GoRoute(
        path: AppRoutes.pipeline,
        builder: (context, state) => const BatchPage(),
      ),
      GoRoute(
        path: AppRoutes.about,
        builder: (context, state) => const AboutPage(),
      ),
    ],
  );
});
