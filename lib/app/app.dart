import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/editor/editor_controller.dart';
import 'router.dart';
import 'shortcuts.dart';
import 'theme.dart';

/// 像素工坊应用根组件。
class PixelForgeApp extends ConsumerWidget {
  const PixelForgeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: '像素工坊',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('zh', 'CN')],
      locale: const Locale('zh', 'CN'),
      routerConfig: router,
      // 全局快捷键挂在 Navigator 之上，覆盖所有页面（PRD 九.6）
      builder: (context, child) => Shortcuts(
        shortcuts: appShortcuts,
        child: Actions(
          actions: <Type, Action<Intent>>{
            OpenImageIntent: CallbackAction<OpenImageIntent>(
              onInvoke: (_) {
                ref.read(editorControllerProvider.notifier).pickAndLoad();
                return null;
              },
            ),
            AppEscapeIntent: CallbackAction<AppEscapeIntent>(
              onInvoke: (_) {
                // 能退就退；首页无可退时保持原地，不触发系统退出
                if (router.canPop()) router.pop();
                return null;
              },
            ),
          },
          child: Focus(
            // 全局快捷键需要一个落在 Shortcuts 子树内的焦点节点，
            // 否则首页等无输入控件的地方按键无人接收
            autofocus: true,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
