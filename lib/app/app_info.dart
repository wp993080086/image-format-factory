/// 应用元信息（关于页、诊断日志头部共用）。
///
/// 未引入 `package_info_plus`：为了一个只显示一次的版本号新增一个平台插件，
/// 与「鸿蒙适配面最小化」的架构铁律相悖。代价是**版本号必须与 pubspec.yaml
/// 手动保持一致**，此项在 S8 一致性检查中核对。
library;

const String appName = '图片格式工厂';

const String appVersion = '0.1.0';

const String appBuildNumber = '1';

/// 展示用版本号，如 `0.1.0+1`。
const String appVersionLabel = '$appVersion+$appBuildNumber';

/// 隐私说明正文（PRD 十六章：上架合规要求）。
///
/// 逐条对应实现事实，不写「我们承诺」式空话：
/// 代码里没有任何网络 API 调用，也没有申请网络权限。
const List<String> privacyPoints = <String>[
  '所有图片处理都在本机完成，不上传任何图片或文件。',
  '不收集设备信息、使用统计、崩溃上报等任何数据。',
  '不申请网络权限，应用在完全离线状态下可用全部功能。',
  '诊断日志只写在本机应用目录，仅在你主动导出时才会离开设备。',
  '导出的图片保存在你选择的位置，应用不保留副本。',
];
