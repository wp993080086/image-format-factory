import 'package:flutter/material.dart';

/// 功能占位页通用骨架：标题 + 需求要点清单（搭建期展示 PRD 锚点，后续逐功能替换实现）。
class FeaturePageScaffold extends StatelessWidget {
  const FeaturePageScaffold({
    super.key,
    required this.title,
    required this.requirementPoints,
  });

  final String title;
  final List<String> requirementPoints;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: requirementPoints.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index == 0) {
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      Icons.construction,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    const Expanded(child: Text('功能开发中，以下为对应需求要点：')),
                  ],
                ),
              ),
            );
          }
          final point = requirementPoints[index - 1];
          return ListTile(
            leading: const Icon(Icons.check_circle_outline),
            title: Text(point),
            dense: true,
          );
        },
      ),
    );
  }
}
