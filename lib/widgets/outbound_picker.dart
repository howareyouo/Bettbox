import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/proxies/card.dart'
    show ProxyDelayText, proxyIconProvider;
import 'package:bett_box/widgets/builder.dart';
import 'package:bett_box/widgets/dialog.dart';
import 'package:bett_box/widgets/icon.dart';
import 'package:bett_box/widgets/text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

const _hiddenProxyTypes = {'Reject', 'RejectDrop', 'Pass', 'Compatible'};

@visibleForTesting
Widget buildSpeedTestOutboundPickerForTesting({
  required String selected,
  required List<Group> groups,
  bool batch = false,
}) => _OutboundPicker(selected: selected, groups: groups, batch: batch);

class _OutboundPicker extends StatefulWidget {
  final String selected;
  final List<Group> groups;
  final bool batch;

  const _OutboundPicker({
    required this.selected,
    required this.groups,
    this.batch = false,
  });

  @override
  State<_OutboundPicker> createState() => _OutboundPickerState();
}

class _OutboundPickerState extends State<_OutboundPicker> {
  late final Set<String> _expandedGroups = {
    ...widget.groups
        .where(
          (group) =>
              group.name == widget.selected ||
              group.all.any((proxy) => proxy.name == widget.selected),
        )
        .map((group) => group.name),
  };

  void _select(String value) => Navigator.of(
    context,
  ).pop(widget.batch ? (scope: OutboundBatchScope.node, name: value) : value);

  void _pickGroup(String name) =>
      Navigator.of(context).pop((scope: OutboundBatchScope.group, name: name));

  void _toggleGroup(String name) {
    setState(() {
      if (_expandedGroups.contains(name)) {
        _expandedGroups.remove(name);
      } else {
        _expandedGroups.add(name);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final batch = widget.batch;
    return CommonDialog(
      title: batch
          ? appLocalizations.mediaBatchScope
          : appLocalizations.speedTestOutbound,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      overrideScroll: true,
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: [
          if (batch)
            QuickOutboundCard(
              title: appLocalizations.mediaBatchAll,
              subtitle: appLocalizations.mediaBatchAllDesc,
              icon: Icons.done_all_rounded,
              isSelected: false,
              onTap: () => Navigator.of(
                context,
              ).pop((scope: OutboundBatchScope.all, name: '')),
            )
          else
            Row(
              children: [
                Expanded(
                  child: QuickOutboundCard(
                    title: appLocalizations.speedTestFollowRules,
                    subtitle: appLocalizations.speedTestRoute,
                    icon: Icons.alt_route_rounded,
                    isSelected: widget.selected.isEmpty,
                    onTap: () => _select(''),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: QuickOutboundCard(
                    title: appLocalizations.direct,
                    subtitle: 'DIRECT',
                    icon: Icons.arrow_outward_rounded,
                    isSelected: widget.selected == 'DIRECT',
                    onTap: () => _select('DIRECT'),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 12),
          for (final group in widget.groups) ...[
            _OutboundGroupCard(
              group: group,
              isExpanded: _expandedGroups.contains(group.name),
              isSelected: !batch && widget.selected == group.name,
              onToggle: () => _toggleGroup(group.name),
              onPick: batch ? () => _pickGroup(group.name) : null,
            ),
            if (_expandedGroups.contains(group.name)) ...[
              const SizedBox(height: 8),
              _OutboundProxyGrid(
                group: group,
                proxies: group.all
                    .where(
                      (p) =>
                          !_hiddenProxyTypes.contains(p.type) &&
                          !(batch &&
                              outboundBatchExcludedTypes.contains(p.type)),
                    )
                    .toList(),
                testUrl: group.testUrl,
                selected: widget.selected,
                highlightActive: !batch,
                onSelect: _select,
              ),
            ],
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class QuickOutboundCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const QuickOutboundCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final textTheme = context.textTheme;

    return FocusStateBuilder(
      builder: (context, hasFocus) {
        final focused = hasFocus && globalState.isAndroidTV;
        return Stack(
          children: [
            Container(
              height: 64,
              decoration: ShapeDecoration(
                color: isSelected
                    ? colorScheme.secondaryContainer
                    : colorScheme.surface,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.zero,
                  side: BorderSide(
                    color: isSelected || focused
                        ? colorScheme.primary
                        : colorScheme.outlineVariant.withValues(alpha: 0.55),
                    width: focused ? 2.5 : (isSelected ? 1.5 : 1),
                  ),
                ),
              ),
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? colorScheme.primary.withValues(alpha: 0.15)
                              : colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          icon,
                          size: 19,
                          color: isSelected
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: EdgeInsets.only(
                                right: isSelected ? 12 : 0,
                              ),
                              child: EmojiText(
                                title,
                                style: textTheme.bodyMedium?.copyWith(
                                  fontWeight: isSelected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: isSelected
                                      ? colorScheme.primary
                                      : colorScheme.onSurface,
                                  fontSize: 13.5,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(height: 2),
                            EmojiText(
                              subtitle,
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.outline,
                                fontSize: 10.5,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (isSelected)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 11,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _OutboundGroupCard extends ConsumerWidget {
  final Group group;
  final bool isExpanded;
  final bool isSelected;
  final VoidCallback onToggle;
  final VoidCallback? onPick;

  const _OutboundGroupCard({
    required this.group,
    required this.isExpanded,
    required this.isSelected,
    required this.onToggle,
    this.onPick,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = context.colorScheme;
    final textTheme = context.textTheme;
    final icon = ref.watch(proxyIconProvider(group.name));

    final activeProxyName =
        ref.watch(getSelectedProxyNameProvider(group.name)) ?? group.now ?? '';

    return FocusStateBuilder(
      builder: (context, hasFocus) {
        final focused = hasFocus && globalState.isAndroidTV;
        return Stack(
          children: [
            Container(
              height: 56,
              decoration: ShapeDecoration(
                color: isSelected
                    ? colorScheme.secondaryContainer.withValues(alpha: 0.7)
                    : colorScheme.surface,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.zero,
                  side: BorderSide(
                    color: isSelected || focused
                        ? colorScheme.primary
                        : colorScheme.outlineVariant.withValues(alpha: 0.55),
                    width: focused ? 2.5 : (isSelected ? 1.5 : 1),
                  ),
                ),
              ),
              child: InkWell(
                onTap: onToggle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: icon.isNotEmpty
                            ? CommonTargetIcon(src: icon, size: 18)
                            : Icon(
                                Icons.hub_outlined,
                                size: 17,
                                color: colorScheme.primary,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            EmojiText(
                              group.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurface,
                                fontSize: 14,
                              ),
                            ),
                            if (activeProxyName.isNotEmpty) ...[
                              const SizedBox(height: 1),
                              EmojiText(
                                activeProxyName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.labelSmall?.copyWith(
                                  color: colorScheme.outline,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (onPick case final onPick?)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 4),
                          child: FilledButton.tonal(
                            onPressed: onPick,
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              minimumSize: const Size(0, 30),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              textStyle: textTheme.labelMedium,
                            ),
                            child: Text(appLocalizations.mediaBatchGroup),
                          ),
                        ),
                      AnimatedRotation(
                        turns: isExpanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 20,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (isSelected)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 11,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _OutboundProxyGrid extends ConsumerWidget {
  final Group group;
  final List<Proxy> proxies;
  final String? testUrl;
  final String selected;
  final bool highlightActive;
  final ValueChanged<String> onSelect;

  const _OutboundProxyGrid({
    required this.group,
    required this.proxies,
    this.testUrl,
    required this.selected,
    this.highlightActive = true,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeProxyName =
        ref.watch(getSelectedProxyNameProvider(group.name)) ?? group.now ?? '';
    final hasManualSelection = proxies.any((p) => p.name == selected);

    const columns = 2;
    final rowCount = (proxies.length / columns).ceil();

    return Column(
      children: [
        for (var i = 0; i < rowCount; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          Row(
            children: [
              for (var c = 0; c < columns; c++) ...[
                if (c > 0) const SizedBox(width: 8),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final idx = i * columns + c;
                      if (idx >= proxies.length) return const SizedBox();
                      final proxy = proxies[idx];
                      final isSelected = hasManualSelection
                          ? selected == proxy.name
                          : highlightActive &&
                                (activeProxyName == proxy.name ||
                                    selected == proxy.name);
                      return _OutboundProxyCard(
                        proxy: proxy,
                        testUrl: testUrl,
                        isSelected: isSelected,
                        onTap: () => onSelect(proxy.name),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

class _OutboundProxyCard extends StatelessWidget {
  final Proxy proxy;
  final String? testUrl;
  final bool isSelected;
  final VoidCallback onTap;

  const _OutboundProxyCard({
    required this.proxy,
    this.testUrl,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final textTheme = context.textTheme;

    return FocusStateBuilder(
      builder: (context, hasFocus) {
        final focused = hasFocus && globalState.isAndroidTV;
        return Stack(
          children: [
            Container(
              height: 56,
              decoration: ShapeDecoration(
                color: isSelected
                    ? colorScheme.secondaryContainer
                    : colorScheme.surface,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.zero,
                  side: BorderSide(
                    color: isSelected || focused
                        ? colorScheme.primary
                        : colorScheme.outlineVariant.withValues(alpha: 0.5),
                    width: focused ? 2.5 : (isSelected ? 1.5 : 1),
                  ),
                ),
              ),
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: EdgeInsets.only(right: isSelected ? 12 : 0),
                        child: EmojiText(
                          proxy.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium?.copyWith(
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: isSelected
                                ? colorScheme.primary
                                : colorScheme.onSurface,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: EmojiText(
                              proxy.type,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.outline,
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                          ProxyDelayText(
                            proxy: proxy,
                            testUrl: testUrl,
                            enableTest: false,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (isSelected)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 11,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

Future<String?> showOutboundPicker({
  required String selected,
  required List<Group> groups,
}) => globalState.showCommonDialog<String>(
  child: _OutboundPicker(selected: selected, groups: groups),
);

enum OutboundBatchScope { all, group, node }

typedef OutboundBatchTarget = ({OutboundBatchScope scope, String name});

const outboundBatchExcludedTypes = {
  'Direct',
  'Reject',
  'RejectDrop',
  'Pass',
  'Compatible',
  'Dns',
};

Future<OutboundBatchTarget?> showBatchOutboundPicker({
  required List<Group> groups,
}) async {
  final value = await globalState.showCommonDialog<Object>(
    child: _OutboundPicker(selected: '', groups: groups, batch: true),
  );
  return value is OutboundBatchTarget ? value : null;
}

List<String> collectBatchNodes(List<Group> groups, OutboundBatchTarget target) {
  final byName = {for (final group in groups) group.name: group};
  final names = <String>{};
  void visit(Group group, Set<String> seen) {
    if (!seen.add(group.name)) return;
    for (final proxy in group.all) {
      if (byName[proxy.name] case final child?) {
        visit(child, seen);
      } else if (!outboundBatchExcludedTypes.contains(proxy.type)) {
        names.add(proxy.name);
      }
    }
  }

  switch (target.scope) {
    case OutboundBatchScope.all:
      for (final group in groups) {
        for (final proxy in group.all) {
          if (!byName.containsKey(proxy.name) &&
              !outboundBatchExcludedTypes.contains(proxy.type)) {
            names.add(proxy.name);
          }
        }
      }
    case OutboundBatchScope.group:
      if (byName[target.name] case final group?) visit(group, {});
    case OutboundBatchScope.node:
      names.add(target.name);
  }
  return names.toList();
}
