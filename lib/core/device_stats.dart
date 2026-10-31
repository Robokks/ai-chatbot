import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Memory and storage of this device. Fields are null where the platform
/// does not report them (e.g. free storage on Windows).
class DeviceStats {
  const DeviceStats({
    this.name,
    this.totalRamMb,
    this.freeRamMb,
    this.freeDiskBytes,
    this.totalDiskBytes,
    this.lowRamDevice = false,
  });

  final String? name;
  final int? totalRamMb;
  final int? freeRamMb;
  final int? freeDiskBytes;
  final int? totalDiskBytes;
  final bool lowRamDevice;
}

Future<DeviceStats> readDeviceStats() async {
  final info = DeviceInfoPlugin();
  try {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final a = await info.androidInfo;
      return DeviceStats(
        name: '${a.manufacturer} ${a.model}',
        totalRamMb: a.physicalRamSize,
        freeRamMb: a.availableRamSize,
        freeDiskBytes: a.freeDiskSize,
        totalDiskBytes: a.totalDiskSize,
        lowRamDevice: a.isLowRamDevice,
      );
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      final w = await info.windowsInfo;
      return DeviceStats(name: w.computerName, totalRamMb: w.systemMemoryInMegabytes);
    }
  } catch (_) {
    // Fall through to "unknown".
  }
  return const DeviceStats();
}

enum ModelFit { fits, tight, tooBig, noSpace, unknown }

/// Whether a model needing [ramGb] of memory and [sizeMb] of storage suits
/// this device. Leaves headroom for Android and other apps.
ModelFit modelFit(DeviceStats d, {required double ramGb, required int sizeMb}) {
  final free = d.freeDiskBytes;
  if (free != null && sizeMb > 0 && sizeMb * 1024 * 1024 * 1.05 > free) {
    return ModelFit.noSpace;
  }
  final total = d.totalRamMb;
  if (total == null || ramGb <= 0) return ModelFit.unknown;
  final need = ramGb * 1024;
  if (need <= total * 0.5) return ModelFit.fits;
  if (need <= total * 0.75) return ModelFit.tight;
  return ModelFit.tooBig;
}
