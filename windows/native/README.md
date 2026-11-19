# Windows 端随包原生编解码器

这些能力在纯 Dart 里没有对应实现，只能借原生库 / 原生程序（PRD 十二 ADR-010）：

| 能力 | 为什么需要原生实现 | 用到的库 |
|---|---|---|
| WebP 编码 | `image` 包只有 webp **解码**器，没有编码器 | libwebp（+ libsharpyuv） |
| HEIC / HEIF 解码 | Windows 系统没有 HEVC 解码组件，WIC 解不了 | libheif（内置 libde265 做 HEVC 解码） |
| AVIF 编解码 | `image` 包无 AV1 编解码器 | libavif 官方 CLI（avifenc/avifdec，静态链接 aom/dav1d/libyuv） |

Android 端不依赖这些：HEIC 用系统 `BitmapFactory`，WebP 用系统 `Bitmap.compress`，
AVIF 用系统 `ImageDecoder`（12+，仅解码——系统无 AVIF 编码器，导出能力位关闭）。

## 目录内容

```
bin/x64/
  webp.dll         libwebp 1.4.0（BSD-3-Clause）
  libsharpyuv.dll  libwebp 的 RGB→YUV 转换依赖（BSD-3-Clause）
  heif.dll         libheif 1.18.2（LGPL-3.0），内含 libde265 1.0.15（LGPL-3.0）
  avifenc.exe      libavif 1.4.2 编码器（BSD-2-Clause），静态链接 libaom 3.14.1（BSD-2）
  avifdec.exe      libavif 1.4.2 解码器（BSD-2-Clause），静态链接 dav1d 1.5.3（BSD-2）、libyuv（BSD-3）
licenses/
  libwebp-COPYING     BSD-3-Clause 全文
  libheif-COPYING     LGPL-3.0 全文
  libde265-COPYING    LGPL-3.0 全文
  libavif-RBSD.txt    libavif 完整许可合集（含内嵌 dav1d / libyuv 等第三方声明）
  aom-BSD.txt         libaom BSD-2-Clause 全文
  dav1d-BSD.txt       dav1d BSD-2-Clause 全文
  libyuv-BSD.txt      libyuv BSD-3-Clause 全文
```

前三个 DLL 合计约 1.4MB，两个 AVIF CLI 各约 12MB。CMake 会在构建时把它们复制到
exe 同目录（`windows/CMakeLists.txt` 里的 `install(FILES ...)`）——**必须与 exe 同目录**：
DLL 是 FFI 的 `DynamicLibrary.open` 按名加载，AVIF CLI 是 Dart 侧按
`Platform.resolvedExecutable` 同目录拼路径。许可全文复制到同级的 `licenses/` 目录。

## AVIF 为什么是 CLI 而不是 DLL

libavif 官方 release 只提供静态链接的命令行程序（avifenc/avifdec），没有 DLL。
从源码自建 libavif.dll 需要 nasm/perl 工具链，还要单独分发 libaom / dav1d 依赖链——
与"别人没有编译环境也能用"的目标冲突。CLI 方案把编解码器连同依赖全部静态链进 exe，
随包即用、零环境依赖：

- 编码：RGBA → PNG 字节 → `avifenc --stdin --input-format png -o out.avif -q -s 10`；
- 解码：AVIF 字节写临时文件 → `avifdec --size-limit N in.avif out.png` → 读回 PNG；
- 二者都通过 `Process` 调用，在后台 Isolate 内可用（符合重活不阻塞 UI 的约束）。

Dart 侧入口在 `lib/services/image/avif_cli.dart` 与 `avif_codec.dart`，
真实编解码回归在 `test/services/image/avif_codec_test.dart`（Windows 上执行真实 CLI）。

## 加载方式

Dart 侧全部走 FFI（`lib/services/image/webp_native_ffi.dart`、
`lib/services/image/heif_native_ffi.dart`），不走平台通道：

- 桌面 embedder 不支持后台 isolate 发平台消息，而 WebP 编码必须在编码子
  Isolate 里完成（PRD 八.9），所以 Windows 只能用 FFI。
- libheif 与 libwebp 都是标准 C API，FFI 绑定是薄薄一层。

`libwebp.dll` 依赖 `libsharpyuv.dll`：Windows 解析 DLL 依赖时搜的是「exe 所在
目录」而不是「webp.dll 所在目录」，所以代码里先按短名预加载 `libsharpyuv.dll`，
让 webp.dll 解析依赖时能命中已加载的同名模块。

## 重新构建

正常开发不需要重新构建——产物已入库。只有升级版本或改编译选项时才跑：

```powershell
powershell -ExecutionPolicy Bypass -File tool/build_native.ps1
```

脚本会下载固定版本的源码、用 Visual Studio 2022 自带的 CMake + Ninja 构建，
并把 DLL 复制回 `bin/x64`。版本号锁定在脚本开头的 `$versions`，改动时必须同步
更新 PRD ADR-010 与本文件。

AVIF 的 CLI 不走这个脚本——直接取 libavif 官方 release 的 `windows-artifacts.zip`
（当前锁定 **v1.4.2**，内含 avifenc/avifdec），解出后放进 `bin/x64` 即可。升级版本时
需同步更新本文件、`lib/app/native_licenses.dart` 的版本号与 PRD 四.8 / 十章。

## 许可与专利

- libwebp / libsharpyuv：BSD-3-Clause，可自由分发。
- libheif / libde265：LGPL-3.0，以动态库形式随包分发，符合 LGPL 的分发要求。
- 许可全文放在 `licenses/`，随包复制到发布目录，并在关于页「原生库许可」可查
  （清单定义在 `lib/app/native_licenses.dart`，测试 `test/app/native_licenses_test.dart` 守护）。
- **HEVC 专利**：libde265 只做 HEVC **解码**，不做编码；解码专利由用户设备
  自带的解码实现承担。商业分发前请自行确认 HEVC 专利池（Access Advance）的
  适用结论——本项目当前为个人工具，未做商业授权评估。
