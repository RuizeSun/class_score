import 'event.dart';

/// 冲突决议：按 (rev, rev_device) 字典序比较。
///
/// - rev 大的胜出（逻辑时钟，与设备挂钟无关，因此两台电脑差几分钟也不会错判）；
/// - rev 打平时用 rev_device 的字符串序裁决，保证所有设备**算出同一个结果**，
///   不会出现"A 认为 X 是新的、B 认为 Y 是新的"的分裂。
int compareRevision({
  required int aRev,
  required String aDevice,
  required int bRev,
  required String bDevice,
}) {
  if (aRev != bRev) return aRev.compareTo(bRev);
  return aDevice.compareTo(bDevice);
}

/// 远端事件是否应当覆盖本地已有版本。
///
/// [localRev] 为 null 表示本地没有这一行（直接接受）。
bool remoteWins({
  required SyncEvent remote,
  required int? localRev,
  required String? localDevice,
}) {
  if (localRev == null) return true;
  return compareRevision(
        aRev: remote.rev,
        aDevice: remote.revDevice,
        bRev: localRev,
        bDevice: localDevice ?? '',
      ) >
      0;
}
