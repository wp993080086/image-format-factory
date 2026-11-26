# 图片格式工厂 (ImageFormatFactory)

纯本地离线图片编辑工具。原图不上传服务器，所有解码、编辑、压缩、转换全部本地运行。

需求文档：`docs/产品需求清单-本地图片编辑工具.md`

## 端与优先级

Windows（首发基线）→ Android → HarmonyOS Next（M4）→ 微信小程序（独立代码库，V3+）

以 PRD 第十五章里程碑为准：当前 M3 只做 Windows + Android 双端；鸿蒙顺延 M4。
注意 PRD 头部「鸿蒙优先于 Android / MVP 三端同步」是 v0.1 遗留声明，以 v0.5 修订记录与第十五章为准。

## 版本策略

- 开发基线：官方 Flutter 3.44.9（本机已装）
- 代码 API 面控制在 **3.41 兼容范围**内
- 鸿蒙构建使用 Flutter-OH 适配版 SDK（CPF-Flutter / OpenHarmony SIG 维护），
  届时在 3.44.9+ohos（canary，同 3.44 基线）与 3.41.10-ohos（稳定线）之间验证取舍；
  接入前需验证 `Platform.operatingSystem` 在 OH 上的取值（见 `lib/core/platform/app_platform_impl_native.dart`）
- 架构铁律：图像编解码、重采样、压缩全部走纯 Dart 库（`image` 包），
  平台插件只保留文件选择/保存等薄层（PRD 七.2）；
  已知例外：SVG 光栅化、HEIF 解码、WebP 编码、AVIF 编解码

## 目录结构

```
lib/
├── app/                  # 应用入口：MaterialApp、路由、主题、快捷键
├── core/
│   ├── batch/            # 批量队列模型与执行器
│   ├── di/               # Riverpod providers
│   ├── error/            # 错误码与导出错误映射
│   ├── image/            # 纯 Dart 图像处理（编解码/裁剪/缩放/调色/水印/标注/格式探测）
│   ├── log/              # AppLogger 与日志留存
│   └── platform/         # 端检测 + 各端能力矩阵（PRD 七章）
├── features/             # 功能模块：home / crop / resize / export / annotate / batch / editor / about
├── services/
│   ├── batch/            # 批量处理流水线（编排 core 各步骤）
│   ├── file/             # 导入导出服务（file_selector 薄层 + 平台条件导入）
│   └── image/            # 原生编解码适配（AVIF / HEIF / WebP，各有 native/ffi 分层）
└── main.dart
```

详细规则见 `.agents/rules/04-目录结构.md`。

## 开发

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

注意：本机代理环境会导致 `flutter test` 无法连接 flutter_tester，
运行测试前临时清空代理变量：`http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= flutter test`

Android arm64 Release 包：

```bash
http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= \
  flutter build apk --release --split-per-abi --target-platform android-arm64
```

产物为 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`，复制到 `dist/android/` 并更新 `SHA256SUMS.txt`。
必须带 `--split-per-abi`：不带时产出的 `app-release.apk` 会混入旧 ABI 残留的 JNI 库，不能当纯 arm64 包使用。

## 标注与打码（当前交互）

- 工具栏：文字 / 直线 / 箭头 / 矩形 / 圆形 / 椭圆 / 涂抹打码 / 头像块 / 昵称条。点一次激活，再点一次取消高亮回到选择态；进入页面默认无工具激活，此时点空白平移视图。
- 命中优先：点已有标注的手柄或本体即进入调整，与当前工具无关；点空白才新建。圆形/椭圆用上下左右四个贴边手柄等比缩放，其他形状与文字用四角手柄。
- 涂抹打码只有马赛克一种模式（块中心取色，非雪花噪点），笔刷半径可调；矩形马赛克与涂抹共用同一取色语义。头像块/昵称条为单击落下的预设马赛克块，尺寸按屏幕逻辑像素反算。
- 标注坐标钳制在图片内，绘制裁剪到图片矩形；文字落点即框中心，首次字号按屏幕像素反算。
- 顶部栏：撤销 / 重做 / 删除选中标注 / 清空标注。整图模糊是独立功能，与涂抹打码无关。
- 导出的 TIFF 在 Android 系统相册里通常无法预览（系统解码器不支持），文件本身有效、可在 APP 内重新导入；需在手机直接查看请导出 PNG/JPEG。
