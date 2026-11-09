import 'package:flutter/material.dart';

import '../core/coord.dart';
import '../core/models.dart';
import '../core/storage.dart';
import '../core/user_message.dart';

/// 已保存路线的本地名称筛选与选择，删除前确认且不关闭当前列表。
class SavedRoutesSheet extends StatefulWidget {
  const SavedRoutesSheet({super.key, required this.storage});

  final AppStorage storage;

  @override
  State<SavedRoutesSheet> createState() => _SavedRoutesSheetState();
}

class _SavedRoutesSheetState extends State<SavedRoutesSheet> {
  final _search = TextEditingController();
  late List<RoutePlan> _routes = widget.storage.readRoutes();
  String _query = '';
  bool _deleting = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 使用最新存储快照删除，取消或写入失败时保留现有路线。
  Future<void> _delete(RoutePlan route) async {
    if (_deleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除已保存路线'),
        content: Text('确定删除「${route.name}」吗？当前编辑草稿不会被清空。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _deleting = true);
    try {
      final routes = widget.storage.readRoutes()
        ..removeWhere((item) => item.name == route.name);
      await widget.storage.writeRoutes(routes);
      if (mounted) setState(() => _routes = routes);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(userMessage(error, fallback: '路线删除失败，请重试'))),
        );
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _routes
        .where((route) => route.name.toLowerCase().contains(_query))
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('已保存的路线', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: '按路线名称搜索',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空路线搜索',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Text(
                        _routes.isEmpty ? '没有已保存的路线' : '没有找到匹配的路线',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final route = filtered[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.route_outlined),
                          title: Text(route.name),
                          subtitle: Text(
                            '${route.points.length} 个点 · ${formatDistance(route.distanceMeters)} · ${route.motion.label}',
                          ),
                          onTap: _deleting
                              ? null
                              : () => Navigator.pop(context, route),
                          trailing: IconButton(
                            tooltip: '删除「${route.name}」',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: _deleting ? null : () => _delete(route),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
