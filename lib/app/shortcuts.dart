import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 应用级快捷键意图（PRD 九.6）。
///
/// 页面级快捷键（Ctrl+S 导出、Ctrl+0 适配、方向键微调选区）由各页面用
/// `CallbackShortcuts` / `Focus.onKeyEvent` 自行处理，因为它们依赖页面内的
/// 参数状态，放在全局会算错参数。
class OpenImageIntent extends Intent {
  const OpenImageIntent();
}

/// Esc：取消当前操作 / 返回上一页。
///
/// 不直接复用 Flutter 的 `DismissIntent`，避免与框架内同名意图冲突。
class AppEscapeIntent extends Intent {
  const AppEscapeIntent();
}

/// 应用级快捷键表：Ctrl/Cmd+O 打开图片、Esc 返回。
const Map<ShortcutActivator, Intent> appShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyO, control: true): OpenImageIntent(),
  SingleActivator(LogicalKeyboardKey.keyO, meta: true): OpenImageIntent(),
  SingleActivator(LogicalKeyboardKey.escape): AppEscapeIntent(),
};

/// 判断按键事件是否是「按下或长按重复」，用于方向键连续微调。
bool isKeyPress(KeyEvent event) =>
    event is KeyDownEvent || event is KeyRepeatEvent;

/// 当前是否按住修饰键（Windows / macOS 兼容）。
bool get isCommandPressed =>
    HardwareKeyboard.instance.isControlPressed ||
    HardwareKeyboard.instance.isMetaPressed;
