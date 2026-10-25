import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/widgets.dart';

import 'widgets.dart';

extension DashboardWidgetExt on DashboardWidget {
  GridItem get gridItem => switch (this) {
    DashboardWidget.networkSpeed => const GridItem(
      crossAxisCellCount: 8,
      child: NetworkSpeed(),
    ),
    DashboardWidget.networkSpeedSmall => const GridItem(
      crossAxisCellCount: 4,
      child: NetworkSpeedSmall(),
    ),
    DashboardWidget.outboundModeV2 => const GridItem(
      crossAxisCellCount: 8,
      child: OutboundModeV2(),
    ),
    DashboardWidget.outboundMode => const GridItem(
      crossAxisCellCount: 4,
      child: OutboundMode(),
    ),
    DashboardWidget.trafficUsage => const GridItem(
      crossAxisCellCount: 4,
      child: TrafficUsage(),
    ),
    DashboardWidget.networkDetection => const GridItem(
      crossAxisCellCount: 4,
      child: NetworkDetection(),
    ),
    DashboardWidget.tunButton => const GridItem(
      crossAxisCellCount: 4,
      child: TUNButton(),
    ),
    DashboardWidget.vpnButton => const GridItem(
      crossAxisCellCount: 4,
      child: VpnButton(),
    ),
    DashboardWidget.systemProxyButton => const GridItem(
      crossAxisCellCount: 4,
      child: SystemProxyButton(),
    ),
    DashboardWidget.intranetIp => const GridItem(
      crossAxisCellCount: 4,
      child: IntranetIP(),
    ),
    DashboardWidget.memoryInfo => const GridItem(
      crossAxisCellCount: 4,
      child: MemoryInfo(),
    ),
    DashboardWidget.connectionsCount => const GridItem(
      crossAxisCellCount: 4,
      child: ConnectionsCount(),
    ),
    DashboardWidget.ipv6Switch => const GridItem(
      crossAxisCellCount: 4,
      child: Ipv6Switch(),
    ),
    DashboardWidget.wakelockSwitch => const GridItem(
      crossAxisCellCount: 4,
      child: WakelockSwitch(),
    ),
    DashboardWidget.dnsOverride => const GridItem(
      crossAxisCellCount: 4,
      child: DnsOverride(),
    ),
    DashboardWidget.snifferOverride => const GridItem(
      crossAxisCellCount: 4,
      child: SnifferOverride(),
    ),
    DashboardWidget.ntpOverride => const GridItem(
      crossAxisCellCount: 4,
      child: NtpOverride(),
    ),
    DashboardWidget.providersInfo => const GridItem(
      crossAxisCellCount: 4,
      child: ProvidersInfo(),
    ),
    DashboardWidget.fcmStatus => const GridItem(
      crossAxisCellCount: 4,
      child: FcmStatus(),
    ),
    DashboardWidget.onlinePanel => const GridItem(
      crossAxisCellCount: 4,
      child: OnlinePanel(),
    ),
    DashboardWidget.mediaUnlock => const GridItem(
      crossAxisCellCount: 8,
      child: MediaUnlock(),
    ),
    DashboardWidget.mediaUnlockSmall => const GridItem(
      crossAxisCellCount: 4,
      child: MediaUnlockSmall(),
    ),
    DashboardWidget.startButton => const GridItem(
      crossAxisCellCount: 4,
      isDeletable: false,
      child: StartButton(),
    ),
  };

  Widget get child => gridItem.child;
}
