import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/pages/viewer.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/profiles/edit_profile.dart';
import 'package:bett_box/views/profiles/override_profile.dart';
import 'package:bett_box/views/profiles/scripts.dart';
import 'package:bett_box/widgets/drag_reorder_grid.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';

import 'add_profile.dart';

class ProfilesView extends ConsumerStatefulWidget {
  const ProfilesView({super.key});

  @override
  ConsumerState<ProfilesView> createState() => _ProfilesViewState();
}

class _ProfilesViewState extends ConsumerState<ProfilesView> {
  Function? applyConfigDebounce;

  void _handleShowAddExtendPage() {
    showExtend(
      globalState.navigatorKey.currentState!.context,
      builder: (_, type) {
        return AdaptiveSheetScaffold(
          type: type,
          body: AddProfileView(
            context: globalState.navigatorKey.currentState!.context,
          ),
          title: appLocalizations.add,
        );
      },
    );
  }

  Future<void> _updateProfiles() async {
    final profiles = globalState.config.profiles;
    final messages = <String>[];
    final updateProfiles = profiles.map<Future>((profile) async {
      if (profile.type == ProfileType.file) return;
      try {
        await globalState.appController.updateProfile(profile);
      } on Object catch (e) {
        messages.add('${profile.label ?? profile.id}: ${e.formatError}');
      }
    });
    await Future.wait(updateProfiles);
    if (messages.isNotEmpty) {
      globalState.showNotifier(messages.join('\n'));
    }
  }

  List<Widget> _buildActions() {
    return [
      IconButton(
        onPressed: () {
          _updateProfiles();
        },
        icon: const Icon(Icons.sync),
        tooltip: appLocalizations.syncAll,
      ),
      IconButton(
        onPressed: () {
          showExtend(
            context,
            builder: (_, type) {
              return const ScriptsView();
            },
          );
        },
        tooltip: appLocalizations.script,
        icon: Consumer(
          builder: (_, ref, _) {
            final isScriptMode = ref.watch(
              scriptStateProvider.select((state) => state.realId != null),
            );
            return Icon(
              Icons.terminal_outlined,
              color: isScriptMode ? context.colorScheme.primary : null,
            );
          },
        ),
      ),
    ];
  }

  Widget _buildFAB() {
    final isMobileView = ref.watch(isMobileViewProvider);
    return Padding(
      padding: EdgeInsets.only(
        bottom: isMobileView
            ? getFloatingBottomBarFABReserveHeight(context)
            : 0,
      ),
      child: FloatingActionButton.extended(
        heroTag: null,
        onPressed: _handleShowAddExtendPage,
        icon: const Icon(Icons.add),
        label: Text(appLocalizations.addProfile),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appSettingProvider.select((state) => state.locale));
    return CommonScaffold(
      title: appLocalizations.profiles,
      floatingActionButton: _buildFAB(),
      actions: _buildActions(),
      body: ActiveConsumer(
        builder: (_, ref) {
          final profilesSelectorState = ref.watch(
            profilesSelectorStateProvider,
          );
          final isMobileView = ref.watch(isMobileViewProvider);
          if (profilesSelectorState.profiles.isEmpty) {
            return NullStatus(label: appLocalizations.nullProfileDesc);
          }
          final columns = system.isAndroid
              ? 1
              : profilesSelectorState.profiles.length <
                    profilesSelectorState.columns
              ? profilesSelectorState.profiles.length
              : profilesSelectorState.columns;
          return ScrollConfiguration(
            behavior: NoMouseDragScrollBehavior(),
            child: ScrollEdgeRise(
              builder: (context, rise) => Align(
                alignment: Alignment.topCenter,
                child: SingleChildScrollView(
                  key: profilesStoreKey,
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 16 + rise,
                    bottom:
                        (profilesSelectorState.profiles.isNotEmpty &&
                                profilesSelectorState.profiles.length % columns ==
                                    0
                            ? 88
                            : 16) +
                        (isMobileView
                            ? getFloatingBottomBarReserveHeight(context)
                            : 0),
                  ),
                  child: DragReorderGrid<Profile>(
                    crossAxisCount: columns,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    items: profilesSelectorState.profiles,
                    keyOf: (profile) => profile.id,
                    itemBuilder: (_, profile) =>
                        ProfileItem(
                          key: Key(profile.id),
                          profile: profile,
                          groupValue: profilesSelectorState.currentProfileId,
                          onChanged: (profileId) {
                            ref.read(currentProfileIdProvider.notifier).value =
                                profileId;
                          },
                        ),
                    onReorder: (profiles) {
                      globalState.appController.setProfiles(profiles);
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class ProfileItem extends StatefulWidget {
  final Profile profile;
  final String? groupValue;
  final void Function(String? value) onChanged;

  const ProfileItem({
    super.key,
    required this.profile,
    required this.groupValue,
    required this.onChanged,
  });

  @override
  State<ProfileItem> createState() => _ProfileItemState();
}

class _ProfileItemState extends State<ProfileItem> {
  bool _hovered = false;
  PopupOpen? _menuOpen;

  Profile get profile => widget.profile;

  String? get groupValue => widget.groupValue;

  void Function(String? value) get onChanged => widget.onChanged;

  Future<void> _handleDeleteProfile(BuildContext context) async {
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(
        text: appLocalizations.deleteTip(appLocalizations.profile),
      ),
    );
    if (res != true) {
      return;
    }
    await globalState.appController.deleteProfile(profile.id);
  }

  Future<void> _handlePreviewRuntimeConfig(BuildContext context) async {
    await globalState.appController.safeRun(
      () async {
        final patchConfig = globalState.config.patchClashConfig;
        final content = await globalState.getRuntimeConfigContent(
          patchConfig: patchConfig,
          profile: profile,
        );
        if (!context.mounted) {
          return;
        }

        final previewPage = ViewerPage(
          title:
              '${appLocalizations.runtimeConfig} - ${profile.label ?? profile.id}',
          content: content,
          highlightMode: editorYamlMode,
        );
        BaseNavigator.push<String>(context, previewPage, maintainState: false);
      },
      needLoading: true,
      title: appLocalizations.tip,
    );
  }

  Future updateProfile() async {
    if (profile.type == ProfileType.file) return;
    try {
      await globalState.appController.updateProfile(profile);
    } on Object catch (e) {
      globalState.showNotifier(
        '${profile.label ?? profile.id}: ${e.formatError}',
      );
    }
  }

  void _handleShowEditExtendPage(BuildContext context) {
    final editKey = GlobalKey<EditProfileViewState>();
    showExtend(
      context,
      builder: (_, type) {
        return AdaptiveSheetScaffold(
          type: type,
          actions: [
            IconButton(
              icon: const Icon(Icons.security),
              tooltip: appLocalizations.ageKeyGenerateTitle,
              onPressed: () {
                editKey.currentState?.showAgeKeyGenerator();
              },
            ),
          ],
          body: EditProfileView(
            key: editKey,
            profile: profile,
            context: context,
          ),
          title: appLocalizations.edit,
        );
      },
    );
  }

  Widget _buildTitleRow(BuildContext context) {
    final subtitleText = profile.type == ProfileType.file
        ? appLocalizations.localFile
        : profile.subscriptionInfo?.expireDesc;

    return Row(
      children: [
        Flexible(
          child: EmojiText(
            profile.label ?? profile.id,
            style: context.textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (subtitleText != null && subtitleText.isNotEmpty) ...[
          const SizedBox(width: 6),
          Text('·', style: context.textTheme.labelMedium?.toLight),
          const SizedBox(width: 6),
          Text(
            subtitleText,
            style: context.textTheme.labelMedium?.toLight,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  Widget _buildContentInfo(BuildContext context) {
    final subscriptionInfo = profile.subscriptionInfo;
    final updateTimeText = profile.lastUpdateDate?.lastUpdateTimeDesc ?? '';
    final hasUsageBar =
        subscriptionInfo != null &&
        ((subscriptionInfo.upload + subscriptionInfo.download > 0) ||
            subscriptionInfo.total > 0);

    String bottomText;
    if (hasUsageBar) {
      bottomText = '${_getTrafficText(subscriptionInfo)} · $updateTimeText';
    } else if (profile.type == ProfileType.url) {
      final trafficText = subscriptionInfo != null
          ? _getTrafficText(subscriptionInfo)
          : 'Unlimited';
      bottomText = '$trafficText · $updateTimeText';
    } else {
      bottomText = '${appLocalizations.lastEdit} · $updateTimeText';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 6),
        SizedBox(
          height: 14,
          child: hasUsageBar
              ? Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2.5),
                    child: Container(
                      height: 5,
                      alignment: Alignment.centerLeft,
                      color: context.colorScheme.primary.withValues(
                        alpha: 0.15,
                      ),
                      child: FractionallySizedBox(
                        widthFactor:
                            (subscriptionInfo.total > 0
                                    ? (subscriptionInfo.upload +
                                              subscriptionInfo.download) /
                                          subscriptionInfo.total
                                    : 0.0)
                                .clamp(0.0, 1.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: context.colorScheme.primary,
                            borderRadius: BorderRadius.circular(2.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : Center(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      appLocalizations.noUsageData,
                      style: context.textTheme.labelSmall?.toLight.copyWith(
                        height: 1.0,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 6),
        Text(
          bottomText,
          style: context.textTheme.labelMedium?.toLight,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  String _getTrafficText(SubscriptionInfo subscriptionInfo) {
    final use = subscriptionInfo.upload + subscriptionInfo.download;
    final total = subscriptionInfo.total;

    // Show Unlimited when no traffic info
    if (use == 0 && total == 0) {
      return 'Unlimited';
    }

    // Total is 0 but has usage
    if (total == 0) {
      final useShow = TrafficValue(value: use).show;
      return '$useShow / Unlimited';
    }

    final useShow = TrafficValue(value: use).show;
    final totalShow = TrafficValue(value: total).show;
    return '$useShow / $totalShow';
  }

  // _handleCopyLink(BuildContext context) async {
  //   await Clipboard.setData(
  //     ClipboardData(
  //       text: profile.url,
  //     ),
  //   );
  //   if (context.mounted) {
  //     context.showNotifier(appLocalizations.copySuccess);
  //   }
  // }

  Future<void> _handleExportFile(BuildContext context) async {
    final res = await globalState.appController.safeRun<bool>(
      () async {
        final file = await profile.getFile();
        final rawName = (profile.label ?? profile.id).trim();
        final fileName = (rawName.endsWith('.yaml') || rawName.endsWith('.yml'))
            ? rawName
            : '$rawName.yaml';
        final value = await picker.saveFile(
          fileName,
          await file.readAsBytes(),
          allowedExtensions: ['yaml', 'yml'],
        );
        if (value == null) return false;
        return true;
      },
      needLoading: true,
      title: appLocalizations.tip,
    );
    if (res == true && context.mounted) {
      context.showNotifier(appLocalizations.exportSuccess);
    }
  }

  void _handlePushGenProfilePage(BuildContext context, String id) {
    final overrideProfileView = OverrideProfileView(profileId: id);
    BaseNavigator.push(context, overrideProfileView);
  }

  List<PopupMenuItemData> _buildMenuItems(BuildContext context) {
    return [
      PopupMenuItemData(
        icon: Icons.edit_outlined,
        label: appLocalizations.edit,
        onPressed: () {
          _handleShowEditExtendPage(context);
        },
      ),
      if (profile.type == ProfileType.url) ...[
        PopupMenuItemData(
          icon: Icons.sync_alt_sharp,
          label: appLocalizations.sync,
          onPressed: () {
            updateProfile();
          },
        ),
      ],
      PopupMenuItemData(
        icon: Icons.extension_outlined,
        label: appLocalizations.override,
        onPressed: () {
          _handlePushGenProfilePage(context, profile.id);
        },
      ),
      PopupMenuItemData(
        icon: Icons.file_copy_outlined,
        label: appLocalizations.exportFile,
        onPressed: () {
          _handleExportFile(context);
        },
      ),
      PopupMenuItemData(
        icon: Icons.delete_outlined,
        label: appLocalizations.delete,
        onPressed: () {
          _handleDeleteProfile(context);
        },
      ),
    ];
  }

  void _showTVMenu(BuildContext context) {
    final items = _buildMenuItems(context);
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in items)
              ListTile(
                leading: item.icon != null ? Icon(item.icon) : null,
                title: Text(item.label),
                onTap: () {
                  Navigator.of(context).pop();
                  item.onPressed!();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _openMenuAtTrailingButton() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    // 锚点取卡片内 36px 按钮（top/right 各 6）的右下角，菜单落在按钮正下方对齐
    _menuOpen?.call(offset: Offset(box.size.width - 6, 6 + 36 + 4));
  }

  Widget _buildTrailing(BuildContext context) {
    return SizedBox(
      height: 36,
      width: 36,
      child: FadeThroughBox(
        child: profile.isUpdating
            ? Padding(
                padding: const EdgeInsets.all(6),
                child: SyncedLoading(
                  size: 24,
                  child: SpinKitFadingCircle(
                    color: context.colorScheme.primary,
                    size: 24,
                  ),
                ),
              )
            : IconButton(
                padding: EdgeInsets.zero,
                onPressed: _openMenuAtTrailingButton,
                icon: const Icon(Icons.more_vert, size: 20),
              ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, {required bool showTrailing}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(right: showTrailing ? 36 : 0),
            child: _buildTitleRow(context),
          ),
          _buildContentInfo(context),
        ],
      ),
    );
  }

  Widget _buildTVLayout(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: () => onChanged(profile.id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [_buildTitleRow(context), _buildContentInfo(context)],
              ),
            ),
          ),
        ),
        IconButton(
          onPressed: () => _showTVMenu(context),
          icon: const Icon(Icons.more_vert),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTV = globalState.isAndroidTV;
    final card = CommonCard(
      isSelected: profile.id == groupValue,
      onPressed: isTV ? null : () => onChanged(profile.id),
      onLongPress: isTV ? null : () => _handlePreviewRuntimeConfig(context),
      child: isTV
          ? _buildTVLayout(context)
          : _buildContent(
              context,
              showTrailing: _hovered || profile.isUpdating,
            ),
    );
    if (isTV) return card;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: CommonPopupBox(
        popup: CommonPopupMenu(
          items: _buildMenuItems(context),
          minItemVerticalPadding: 10,
        ),
        targetBuilder: (open) {
          _menuOpen = open;
          return Stack(
            children: [
              card,
              if (_hovered || profile.isUpdating)
                Positioned(
                  top: 6,
                  right: 6,
                  child: _buildTrailing(context),
                ),
            ],
          );
        },
      ),
    );
  }
}

