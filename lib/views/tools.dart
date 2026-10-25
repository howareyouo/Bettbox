import 'dart:async';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/about.dart';
import 'package:bett_box/views/access.dart';
import 'package:bett_box/views/application_setting.dart';
import 'package:bett_box/views/config/config.dart';
import 'package:bett_box/views/config/dns.dart';
import 'package:bett_box/views/config/experimental.dart';
import 'package:bett_box/views/config/general.dart';
import 'package:bett_box/views/config/network.dart';
import 'package:bett_box/views/config/ntp.dart';
import 'package:bett_box/views/config/sniffer.dart';
import 'package:bett_box/views/config/tunnel.dart';
import 'package:bett_box/views/connection/connections.dart';
import 'package:bett_box/views/hotkey.dart';
import 'package:bett_box/views/other_setting.dart';
import 'package:bett_box/views/profiles/scripts.dart';
import 'package:bett_box/views/resources.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' show dirname, join;

import 'backup_and_recovery.dart';
import 'developer.dart';
import 'theme.dart';

void _openLoopbackManager() {
  windows?.runas(
    '"${join(dirname(Platform.resolvedExecutable), "WindowsLoopbackManager.exe")}"',
    '',
    showWindow: true,
  );
}

Future<void> _confirmDisclaimer() async {
  final accepted = await globalState.appController.showDisclaimer();
  if (!accepted) {
    globalState.appController.handleExit();
  }
}

class _SearchItem {
  final String title;
  final String? subtitle;
  final String category;
  final Widget? leading;
  final void Function(BuildContext context, WidgetRef ref) onTap;

  const _SearchItem({
    required this.title,
    this.subtitle,
    required this.category,
    this.leading,
    required this.onTap,
  });
}

class ToolsShortcut {
  final Widget icon;
  final String title;
  final String? subtitle;
  final WidgetBuilder? builder;
  final VoidCallback? onTap;
  final bool wrap;

  const ToolsShortcut({
    required this.icon,
    required this.title,
    this.subtitle,
    this.builder,
    this.onTap,
    this.wrap = true,
  });

  void open(BuildContext context) {
    final builder = this.builder;
    if (builder == null) {
      onTap?.call();
      return;
    }
    showExtend(
      context,
      props: const ExtendProps(forceFull: true),
      builder: (_, type) {
        final child = builder(context);
        return wrap
            ? AdaptiveSheetScaffold(type: type, title: title, body: child)
            : child;
      },
    );
  }
}

const _flyoutPages = <SidebarFlyoutEntry, (IconData, Widget, bool)>{
  SidebarFlyoutEntry.resources: (Icons.storage, ResourcesView(), false),
  SidebarFlyoutEntry.script: (Icons.terminal_outlined, ScriptsView(), false),
  SidebarFlyoutEntry.theme: (Icons.style, ThemeView(), true),
  SidebarFlyoutEntry.backupAndRecovery: (
    Icons.cloud_sync,
    BackupAndRecovery(),
    true,
  ),
  SidebarFlyoutEntry.hotkeyManagement: (Icons.keyboard, HotKeyView(), true),
  SidebarFlyoutEntry.basicConfig: (
    Icons.developer_board_rounded,
    ConfigView(),
    true,
  ),
  SidebarFlyoutEntry.otherSettings: (
    Icons.settings_suggest_outlined,
    OtherSettingView(),
    true,
  ),
  SidebarFlyoutEntry.application: (
    Icons.settings,
    ApplicationSettingView(),
    true,
  ),
  SidebarFlyoutEntry.about: (Icons.info, AboutView(), true),
};

String? _flyoutSubtitle(SidebarFlyoutEntry entry) => switch (entry) {
  SidebarFlyoutEntry.resources => appLocalizations.resourcesDesc,
  SidebarFlyoutEntry.script => appLocalizations.scriptDesc,
  SidebarFlyoutEntry.theme => appLocalizations.themeDesc,
  SidebarFlyoutEntry.backupAndRecovery =>
    appLocalizations.backupAndRecoveryDesc,
  SidebarFlyoutEntry.hotkeyManagement => appLocalizations.hotkeyManagementDesc,
  SidebarFlyoutEntry.basicConfig => appLocalizations.basicConfigDesc,
  SidebarFlyoutEntry.otherSettings => appLocalizations.otherSettingsDesc,
  SidebarFlyoutEntry.application => appLocalizations.applicationDesc,
  _ => null,
};

ToolsShortcut? _flyoutPageShortcut(SidebarFlyoutEntry entry) {
  final page = _flyoutPages[entry];
  if (page == null) {
    return null;
  }
  final (icon, child, wrap) = page;
  return ToolsShortcut(
    icon: Icon(icon),
    title: entry.localizedName,
    subtitle: _flyoutSubtitle(entry),
    builder: (_) => child,
    wrap: wrap,
  );
}

List<ToolsShortcut> getToolsShortcuts(
  List<NavigationItem> moreItems,
  List<SidebarFlyoutEntry> entries,
) {
  ToolsShortcut? buildNavigationShortcut(PageLabel label) {
    final item = moreItems.where((item) => item.label == label).firstOrNull;
    if (item == null) {
      return null;
    }
    return ToolsShortcut(
      icon: item.icon,
      title: Intl.message(item.label.name),
      subtitle: switch (item.description) {
        final description? => Intl.message(description),
        null => null,
      },
      builder: item.builder,
      wrap: false,
    );
  }

  return [
    for (final entry in SidebarFlyoutEntry.supportedValues)
      if (entries.contains(entry))
        ?switch (entry) {
          SidebarFlyoutEntry.toolbox => buildNavigationShortcut(
            PageLabel.toolbox,
          ),
          SidebarFlyoutEntry.loopback => ToolsShortcut(
            icon: const Icon(Icons.lock),
            title: appLocalizations.loopback,
            subtitle: appLocalizations.loopbackDesc,
            onTap: _openLoopbackManager,
          ),
          _ => _flyoutPageShortcut(entry),
        },
  ];
}

class _GeneralListView extends StatelessWidget {
  const _GeneralListView();

  @override
  Widget build(BuildContext context) {
    return generateListView(generalItems);
  }
}

class ToolsView extends ConsumerStatefulWidget {
  const ToolsView({super.key});

  @override
  ConsumerState<ToolsView> createState() => _ToolViewState();
}

class _ToolViewState extends ConsumerState<ToolsView> {
  Widget _buildNavigationPage(NavigationItem navigationItem) {
    if (navigationItem.label == PageLabel.connections) {
      return const ConnectionsView(respectCurrentPage: false);
    }
    return navigationItem.builder(context);
  }

  Widget _buildNavigationMenuItem(NavigationItem navigationItem) {
    return ListItem.next(
      leading: navigationItem.icon,
      title: Text(Intl.message(navigationItem.label.name)),
      subtitle: navigationItem.description != null
          ? Text(Intl.message(navigationItem.description!))
          : null,
      delegate: NextDelegate(
        title: Intl.message(navigationItem.label.name),
        builder: (_) => _buildNavigationPage(navigationItem),
        wrap: false,
      ),
    );
  }

  Widget _buildModernSection(
    BuildContext context, {
    required String title,
    required List<Widget> items,
    bool isFirst = false,
  }) {
    return SectionContainer(title: title, items: items, isFirst: isFirst);
  }

  String _query = '';
  List<_SearchItem>? _cachedSearchItems;
  String _cachedMoreItemsKey = '';
  Timer? _searchTimer;

  @override
  void dispose() {
    _searchTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _searchTimer?.cancel();
    if (query.isEmpty) {
      if (_query.isNotEmpty || _cachedSearchItems != null) {
        setState(() {
          _query = '';
          _cachedSearchItems = null;
          _cachedMoreItemsKey = '';
        });
      }
      return;
    }
    _searchTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() {
        _query = query.toLowerCase();
      });
    });
  }

  String _moreItemsKey(List<NavigationItem> items) {
    return items
        .map((item) => '${item.label.name}\x00${item.description ?? ''}')
        .join('\x01');
  }

  List<_SearchItem> _getSearchItems(List<NavigationItem> moreItems) {
    if (_query.isEmpty) {
      return const [];
    }
    final key = _moreItemsKey(moreItems);
    if (_cachedSearchItems != null && _cachedMoreItemsKey == key) {
      return _cachedSearchItems!;
    }
    _cachedMoreItemsKey = key;
    _cachedSearchItems = _buildSearchItems(moreItems);
    return _cachedSearchItems!;
  }

  void _pushPage(BuildContext context, String title, Widget page) {
    showExtend(
      context,
      builder: (_, type) =>
          AdaptiveSheetScaffold(type: type, title: title, body: page),
    );
  }

  _SearchItem _searchNav(
    String category,
    String title,
    String? subtitle,
    IconData? icon,
    Widget page, {
    String? pageTitle,
  }) {
    return _SearchItem(
      title: title,
      subtitle: subtitle,
      category: category,
      leading: icon == null ? null : Icon(icon),
      onTap: (context, _) => _pushPage(context, pageTitle ?? title, page),
    );
  }

  List<_SearchItem> _group(
    String category,
    String pageTitle,
    Widget page,
    List<(String, String?)> rows,
  ) {
    return [
      for (final (title, subtitle) in rows)
        _SearchItem(
          title: title,
          subtitle: subtitle,
          category: category,
          onTap: (context, _) => _pushPage(context, pageTitle, page),
        ),
    ];
  }

  List<_SearchItem> _buildSearchItems(List<NavigationItem> moreItems) {
    final settings = appLocalizations.settings;
    final config = '$settings/${appLocalizations.basicConfig}';
    final other = appLocalizations.other;
    return [
      for (final item in moreItems)
        _SearchItem(
          title: Intl.message(item.label.name),
          subtitle: item.description != null
              ? Intl.message(item.description!)
              : null,
          category: appLocalizations.more,
          leading: item.icon,
          onTap: (context, _) => _pushPage(
            context,
            Intl.message(item.label.name),
            _buildNavigationPage(item),
          ),
        ),
      _searchNav(
        settings,
        appLocalizations.language,
        appLocalizations.language,
        Icons.language_outlined,
        const _LocaleItem(),
      ),
      _searchNav(
        settings,
        appLocalizations.theme,
        appLocalizations.themeDesc,
        Icons.style,
        const ThemeView(),
      ),
      _searchNav(
        settings,
        appLocalizations.backupAndRecovery,
        appLocalizations.backupAndRecoveryDesc,
        Icons.cloud_sync,
        const BackupAndRecovery(),
      ),
      if (system.isDesktop)
        _searchNav(
          settings,
          appLocalizations.hotkeyManagement,
          appLocalizations.hotkeyManagementDesc,
          Icons.keyboard,
          const HotKeyView(),
        ),
      if (system.isWindows)
        _SearchItem(
          title: appLocalizations.loopback,
          subtitle: appLocalizations.loopbackDesc,
          category: settings,
          leading: const Icon(Icons.lock),
          onTap: (_, _) => _openLoopbackManager(),
        ),
      if (system.isAndroid)
        _searchNav(
          settings,
          appLocalizations.accessControl,
          appLocalizations.accessControlDesc,
          Icons.view_list,
          const AccessView(),
          pageTitle: appLocalizations.appAccessControl,
        ),
      _searchNav(
        settings,
        appLocalizations.basicConfig,
        appLocalizations.basicConfigDesc,
        Icons.developer_board_rounded,
        const ConfigView(),
      ),
      _searchNav(
        settings,
        appLocalizations.otherSettings,
        appLocalizations.otherSettingsDesc,
        Icons.settings_suggest_outlined,
        const OtherSettingView(),
      ),
      _searchNav(
        settings,
        appLocalizations.application,
        appLocalizations.applicationDesc,
        Icons.settings,
        const ApplicationSettingView(),
      ),
      _SearchItem(
        title: appLocalizations.disclaimer,
        category: other,
        leading: const Icon(Icons.gavel),
        onTap: (_, _) => _confirmDisclaimer(),
      ),
      _searchNav(
        other,
        appLocalizations.about,
        null,
        Icons.info,
        const AboutView(),
      ),
      _searchNav(
        other,
        appLocalizations.developerMode,
        null,
        Icons.developer_board,
        const DeveloperView(),
      ),
      ..._group(
        '$settings/${appLocalizations.theme}',
        appLocalizations.theme,
        const ThemeView(),
        [
          (appLocalizations.themeMode, null),
          (appLocalizations.themeColor, null),
          (appLocalizations.pureBlackMode, null),
          (appLocalizations.harmonyFont, appLocalizations.harmonyFontDesc),
          if (system.isAndroid)
            (appLocalizations.darkIcon, appLocalizations.darkIconDesc),
          if (system.isWindows)
            (
              appLocalizations.trayIconInvert,
              appLocalizations.trayIconInvertDesc,
            ),
          (appLocalizations.textScale, null),
        ],
      ),
      ..._group(
        '$settings/${appLocalizations.backupAndRecovery}',
        appLocalizations.backupAndRecovery,
        const BackupAndRecovery(),
        [
          (appLocalizations.remote, null),
          (appLocalizations.local, null),
          (appLocalizations.recoveryStrategy, null),
        ],
      ),
      ..._group(
        '$settings/${appLocalizations.application}',
        appLocalizations.application,
        const ApplicationSettingView(),
        [
          (appLocalizations.autoLaunch, appLocalizations.autoLaunchDesc),
          if (system.isDesktop)
            (appLocalizations.silentLaunch, appLocalizations.silentLaunchDesc),
          (appLocalizations.autoRun, appLocalizations.autoRunDesc),
          if (system.isAndroid)
            (appLocalizations.exclude, appLocalizations.excludeDesc),
          if (system.isDesktop && (system.isWindows || system.isLinux))
            (
              appLocalizations.alwaysShowTitleBar,
              appLocalizations.alwaysShowTitleBarDesc,
            ),
          if (system.isMacOS)
            (appLocalizations.keepDockIcon, appLocalizations.keepDockIconDesc),
          (
            appLocalizations.showStartSwitch,
            appLocalizations.showStartSwitchDesc,
          ),
          if (system.isDesktop)
            (
              appLocalizations.sidebarFlyout,
              appLocalizations.sidebarFlyoutDesc,
            ),
          if (system.isAndroid)
            (
              appLocalizations.navBarHapticFeedback,
              appLocalizations.navBarHapticFeedbackDesc,
            ),
          (
            appLocalizations.onlyStatisticsProxy,
            appLocalizations.onlyStatisticsProxyDesc,
          ),
          (
            appLocalizations.autoCheckUpdate,
            appLocalizations.autoCheckUpdateDesc,
          ),
        ],
      ),
      ..._group(
        '$settings/${appLocalizations.otherSettings}',
        appLocalizations.otherSettings,
        const OtherSettingView(),
        [
          (
            appLocalizations.autoCloseConnections,
            appLocalizations.autoCloseConnectionsDesc,
          ),
          if (system.isAndroid)
            (
              appLocalizations.flushDnsOnNetworkChange,
              appLocalizations.flushDnsOnNetworkChangeDesc,
            ),
          (appLocalizations.smartAutoStop, appLocalizations.smartAutoStopDesc),
          (appLocalizations.networkMatch, appLocalizations.networkMatchHint),
          if (system.isAndroid)
            (appLocalizations.dozeSuspend, appLocalizations.dozeSuspendDesc),
          if (system.isAndroid)
            (
              appLocalizations.quickResponse,
              appLocalizations.quickResponseDesc,
            ),
          if (system.isAndroid)
            (appLocalizations.storeFix, appLocalizations.storeFixDesc),
          (
            appLocalizations.loopbackProtection,
            appLocalizations.loopbackProtectionDesc,
          ),
          (appLocalizations.disableQuic, appLocalizations.disableQuicDesc),
          (appLocalizations.excludeChina, appLocalizations.excludeChinaDesc),
          if (system.isAndroid)
            (
              appLocalizations.notificationHighPriority,
              appLocalizations.notificationHighPriorityDesc,
            ),
          if (system.isAndroid)
            (
              appLocalizations.networkSpeedNotification,
              appLocalizations.networkSpeedNotificationDesc,
            ),
          if (!system.isAndroid)
            (
              appLocalizations.trayEnhancement,
              appLocalizations.trayEnhancementDesc,
            ),
          if (system.isMacOS)
            (
              appLocalizations.enableTraySpeed,
              appLocalizations.enableTraySpeedDesc,
            ),
          if (system.isWindows)
            (appLocalizations.highPriority, appLocalizations.highPriorityDesc),
          if (system.isWindows)
            (appLocalizations.networkFix, appLocalizations.networkFixDesc),
          if (system.isAndroid)
            (
              appLocalizations.batteryOptimization,
              appLocalizations.batteryOptimizationDesc,
            ),
        ],
      ),
      ..._group(
        '$config/${appLocalizations.general}',
        appLocalizations.general,
        const _GeneralListView(),
        [
          (appLocalizations.logLevel, null),
          ('UA', null),
          (appLocalizations.keepAliveIntervalDesc, appLocalizations.interval),
          (appLocalizations.testUrl, null),
          (appLocalizations.port, null),
          ('IPv6', appLocalizations.ipv6Desc),
          (appLocalizations.allowLan, appLocalizations.allowLanDesc),
          (appLocalizations.unifiedDelay, appLocalizations.unifiedDelayDesc),
          (
            appLocalizations.findProcessMode,
            appLocalizations.findProcessModeDesc,
          ),
          (appLocalizations.tcpConcurrent, appLocalizations.tcpConcurrentDesc),
          (
            appLocalizations.externalController,
            appLocalizations.externalControllerDesc,
          ),
          (appLocalizations.controlSecret, appLocalizations.controlSecretDesc),
        ],
      ),
      ..._group(
        '$config/${appLocalizations.network}',
        appLocalizations.network,
        const NetworkListView(),
        [
          ('VPN', appLocalizations.vpnEnableDesc),
          (appLocalizations.allowBypass, appLocalizations.allowBypassDesc),
          if (system.isDesktop)
            (appLocalizations.systemProxy, appLocalizations.systemProxyDesc),
          if (system.isDesktop)
            (appLocalizations.bypassDomain, appLocalizations.bypassDomainDesc),
          if (system.isDesktop)
            (appLocalizations.tun, appLocalizations.tunDesc),
          if (system.isMacOS) (appLocalizations.autoSetSystemDns, null),
          if (!system.isAndroid)
            (appLocalizations.strictRoute, appLocalizations.strictRouteDesc),
          (
            appLocalizations.icmpForwarding,
            appLocalizations.icmpForwardingDesc,
          ),
          (appLocalizations.dnsHijack, appLocalizations.dnsHijackDesc),
          (
            appLocalizations.endpointIndependentNat,
            appLocalizations.endpointIndependentNatDesc,
          ),
          (appLocalizations.stackMode, null),
          ('MTU', null),
          (
            appLocalizations.bypassPrivateRoute,
            appLocalizations.bypassPrivateRouteDesc,
          ),
        ],
      ),
      ..._group('$config/DNS', 'DNS', const DnsListView(), [
        (appLocalizations.overrideDns, appLocalizations.overrideDnsDesc),
        (appLocalizations.status, appLocalizations.statusDesc),
        (appLocalizations.listen, null),
        (appLocalizations.cacheAlgorithm, null),
        (appLocalizations.useHosts, null),
        (appLocalizations.useSystemHosts, null),
        ('IPv6', null),
        (appLocalizations.respectRules, appLocalizations.respectRulesDesc),
        ('PreferH3', appLocalizations.preferH3Desc),
        (appLocalizations.dnsMode, null),
        (appLocalizations.fakeipRange, null),
        (appLocalizations.fakeipRangeV6, null),
        (appLocalizations.fakeIpFilterMode, null),
        (appLocalizations.fakeipFilter, null),
        (appLocalizations.fakeipTtl, null),
        (
          appLocalizations.defaultNameserver,
          appLocalizations.defaultNameserverDesc,
        ),
        (
          appLocalizations.nameserverPolicy,
          appLocalizations.nameserverPolicyDesc,
        ),
        (appLocalizations.nameserver, appLocalizations.nameserverDesc),
        (appLocalizations.fallback, appLocalizations.fallbackDesc),
        (
          appLocalizations.proxyNameserver,
          appLocalizations.proxyNameserverDesc,
        ),
        (
          appLocalizations.directNameserver,
          appLocalizations.directNameserverDesc,
        ),
        (appLocalizations.directNameserverFollowPolicy, null),
        ('Geoip', null),
        (appLocalizations.geoipCode, null),
        (
          appLocalizations.fallbackConcurrent,
          appLocalizations.fallbackConcurrentDesc,
        ),
        (appLocalizations.ipcidr, null),
        (appLocalizations.domain, null),
      ]),
      ..._group('$config/NTP', 'NTP', const NtpListView(), [
        (appLocalizations.overrideNtp, appLocalizations.overrideNtpDesc),
        (appLocalizations.ntpStatus, appLocalizations.ntpStatusDesc),
        (appLocalizations.writeToSystem, appLocalizations.writeToSystemDesc),
        (appLocalizations.ntpServer, null),
        (appLocalizations.ntpPort, null),
        (appLocalizations.ntpInterval, null),
      ]),
      ..._group(
        '$config/Hosts',
        appLocalizations.basicConfig,
        const ConfigView(),
        [('Hosts', appLocalizations.hostsDesc)],
      ),
      ..._group(
        '$config/${appLocalizations.sniffer}',
        appLocalizations.sniffer,
        const SnifferListView(),
        [
          (
            appLocalizations.overrideSniffer,
            appLocalizations.overrideSnifferDesc,
          ),
          (appLocalizations.snifferStatus, appLocalizations.snifferStatusDesc),
          (appLocalizations.forceDnsMapping, null),
          (appLocalizations.parsePureIp, null),
          (appLocalizations.overrideDestination, null),
          (appLocalizations.httpPortSniffer, null),
          (appLocalizations.tlsPortSniffer, null),
          (appLocalizations.quicPortSniffer, null),
          (appLocalizations.forceDomain, null),
          (appLocalizations.skipDomain, null),
          (appLocalizations.skipSrcAddress, null),
          (appLocalizations.skipDstAddress, null),
        ],
      ),
      ..._group(
        '$config/${appLocalizations.tunnel}',
        appLocalizations.tunnel,
        const TunnelListView(),
        [(appLocalizations.tunnel, appLocalizations.tunnelDesc)],
      ),
      ..._group(
        '$config/${appLocalizations.experimental}',
        appLocalizations.experimental,
        const ExperimentalListView(),
        [
          (
            appLocalizations.overrideExperimental,
            appLocalizations.overrideExperimentalDesc,
          ),
          (appLocalizations.quicGoDisableGso, null),
          (appLocalizations.quicGoDisableEcn, null),
          (appLocalizations.dialerIp4pConvert, null),
        ],
      ),
    ];
  }

  List<Widget> _buildSearchResults(List<_SearchItem> items) {
    final query = _query.toLowerCase();
    final filtered = items.where((item) {
      return item.title.toLowerCase().contains(query) ||
          (item.subtitle?.toLowerCase().contains(query) ?? false) ||
          item.category.toLowerCase().contains(query);
    }).toList();

    if (filtered.isEmpty) {
      return [Center(child: NullStatus(label: appLocalizations.noData))];
    }

    final groups = <String, List<_SearchItem>>{};
    for (final item in filtered) {
      groups.putIfAbsent(item.category, () => []).add(item);
    }

    final sections = <Widget>[];
    for (final entry in groups.entries) {
      sections.add(
        _buildModernSection(
          context,
          title: entry.key,
          items: entry.value
              .map(
                (item) => ListItem(
                  leading: item.leading,
                  title: Text(item.title),
                  subtitle: item.subtitle != null ? Text(item.subtitle!) : null,
                  onTap: () => item.onTap(context, ref),
                ),
              )
              .toList(),
        ),
      );
    }
    return sections;
  }

  @override
  Widget build(BuildContext context) {
    final vm2 = ref.watch(
      appSettingProvider.select(
        (state) => VM2(a: state.locale, b: state.developerMode),
      ),
    );
    final isMobileView = ref.watch(isMobileViewProvider);
    final moreItems = ref.watch(
      moreToolsSelectorStateProvider.select((state) => state.navigationItems),
    );
    final logsItem = isMobileView && !globalState.isAndroidTV
        ? moreItems.where((item) => item.label == PageLabel.logs).firstOrNull
        : null;
    final searchItems = _getSearchItems(moreItems);
    final searchResults = _query.isEmpty
        ? const <Widget>[]
        : _buildSearchResults(searchItems);

    final items = [
      Consumer(
        builder: (_, ref, _) {
          final state = ref.watch(moreToolsSelectorStateProvider);
          final navigationItems = state.navigationItems
              .where((item) => logsItem == null || item.label != logsItem.label)
              .toList();
          if (navigationItems.isEmpty) {
            return Container();
          }
          return _buildModernSection(
            context,
            title: appLocalizations.more,
            isFirst: true,
            items: navigationItems
                .map((item) => _buildNavigationMenuItem(item))
                .toList(),
          );
        },
      ),
      _buildModernSection(
        context,
        title: appLocalizations.settings,
        items: [
          _LocaleItem(),
          _navItem(
            Icons.style,
            appLocalizations.theme,
            appLocalizations.themeDesc,
            const ThemeView(),
          ),
          _navItem(
            Icons.cloud_sync,
            appLocalizations.backupAndRecovery,
            appLocalizations.backupAndRecoveryDesc,
            const BackupAndRecovery(),
          ),
          if (system.isDesktop)
            _navItem(
              Icons.keyboard,
              appLocalizations.hotkeyManagement,
              appLocalizations.hotkeyManagementDesc,
              const HotKeyView(),
            ),
          if (system.isWindows)
            _actionItem(
              Icons.lock,
              appLocalizations.loopback,
              appLocalizations.loopbackDesc,
              _openLoopbackManager,
            ),
          if (system.isAndroid)
            _navItem(
              Icons.view_list,
              appLocalizations.accessControl,
              appLocalizations.accessControlDesc,
              const AccessView(),
              pageTitle: appLocalizations.appAccessControl,
            ),
          _navItem(
            Icons.developer_board_rounded,
            appLocalizations.basicConfig,
            appLocalizations.basicConfigDesc,
            const ConfigView(),
          ),
          _navItem(
            Icons.settings_suggest_outlined,
            appLocalizations.otherSettings,
            appLocalizations.otherSettingsDesc,
            const OtherSettingView(),
          ),
          _navItem(
            Icons.settings,
            appLocalizations.application,
            appLocalizations.applicationDesc,
            const ApplicationSettingView(),
          ),
        ],
      ),
      _buildModernSection(
        context,
        title: appLocalizations.other,
        items: [
          _actionItem(
            Icons.gavel,
            appLocalizations.disclaimer,
            null,
            _confirmDisclaimer,
          ),
          if (vm2.b)
            _navItem(
              Icons.developer_board,
              appLocalizations.developerMode,
              null,
              const DeveloperView(),
            ),
          _navItem(Icons.info, appLocalizations.about, null, const AboutView()),
        ],
      ),
    ];

    return CommonScaffold(
      title: isMobileView ? appLocalizations.tools : appLocalizations.settings,
      searchState: AppBarSearchState(onSearch: _onSearchChanged),
      actions: [
        if (logsItem != null)
          IconButton(
            onPressed: () => showExtend(
              context,
              props: const ExtendProps(forceFull: true),
              builder: (_, _) => _buildNavigationPage(logsItem),
            ),
            icon: logsItem.icon,
            tooltip: Intl.message(logsItem.label.name),
          ),
      ],
      body: ScrollEdgeRise(
        builder: (context, rise) => ListView.builder(
          key: _query.isEmpty ? toolsStoreKey : null,
          itemCount: _query.isEmpty ? items.length : searchResults.length,
          itemBuilder: (_, index) {
            return _query.isEmpty ? items[index] : searchResults[index];
          },
          padding: EdgeInsets.only(
            bottom:
                (globalState.isAndroidTV ? 80.0 : 20.0) +
                (isMobileView ? getFloatingBottomBarReserveHeight(context) : 0),
            top: 8 + rise,
          ),
        ),
      ),
    );
  }

  Widget _navItem(
    IconData icon,
    String title,
    String? subtitle,
    Widget page, {
    String? pageTitle,
  }) {
    return ListItem.next(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      delegate: NextDelegate(title: pageTitle ?? title, builder: (_) => page),
    );
  }

  Widget _actionItem(
    IconData icon,
    String title,
    String? subtitle,
    VoidCallback onTap,
  ) {
    return ListItem(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: onTap,
    );
  }
}

class _LocaleItem extends ConsumerWidget {
  const _LocaleItem();

  static final List<Locale> _localeOptions = _getOrderedLocales();
  static const Map<String, String> _nativeLocaleNames = {
    'zh_CN': '简体中文',
    'zh_TC': '繁體中文',
    'en': 'English',
    'ru': 'Русский',
    'fa': 'فارسی',
    'ja': '日本語',
    'ko': '한국어',
  };

  static List<Locale> _getOrderedLocales() {
    final priority = ['zh_CN', 'zh_TC', 'en', 'ru', 'fa', 'ja', 'ko'];
    final locales = List<Locale>.from(
      AppLocalizations.delegate.supportedLocales,
    );
    locales.sort((a, b) {
      final aKey = a.toString();
      final bKey = b.toString();
      final aIndex = priority.indexOf(aKey);
      final bIndex = priority.indexOf(bKey);
      if (aIndex != -1 && bIndex != -1) return aIndex.compareTo(bIndex);
      if (aIndex != -1) return -1;
      if (bIndex != -1) return 1;
      return aKey.compareTo(bKey);
    });
    return locales;
  }

  String _getLocaleString(Locale locale) {
    return _nativeLocaleNames[locale.toString()] ?? locale.toString();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(
      appSettingProvider.select((state) => state.locale),
    );
    final currentLocale =
        utils.getLocaleForString(locale) ?? utils.getSystemLocale();
    return ListItem<Locale>.options(
      leading: const Icon(Icons.language_outlined),
      title: Text(appLocalizations.language),
      subtitle: Text(_getLocaleString(currentLocale)),
      delegate: OptionsDelegate(
        title: appLocalizations.language,
        options: _localeOptions,
        onChanged: (Locale? locale) {
          if (locale == null) return;
          ref
              .read(appSettingProvider.notifier)
              .updateState(
                (state) => state.copyWith(locale: locale.toString()),
              );
        },
        textBuilder: (locale) => _getLocaleString(locale),
        value: currentLocale,
      ),
    );
  }
}
