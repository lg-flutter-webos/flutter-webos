// Copyright (c) 2026 LG Electronics, Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/build_info.dart';

// webOS has no dedicated [TargetPlatform] enum value, so it borrows upstream
// values. There are three *distinct* concerns, each needing a different value
// for the same target arch — keep them separate instead of overloading one
// mapping:
//
//  * [genSnapshotTargetPlatformForArch] — the platform handed to the AOT
//    snapshotter / gen_snapshot. It must be an `android_*` value so that
//    [WebosArtifacts] can intercept the cross-compiled gen_snapshot (it keys on
//    a name starting with `android`) and so the upstream AOT snapshotter
//    applies the 32-bit ARM codegen flags (gated on `android_arm`). On an arm64
//    host it falls back to `linux_*` because the cross artifacts don't support
//    self-building on arm64 hosts yet.
//
//  * [assetTargetPlatform] — the platform used for asset bundling. webOS is a
//    Linux platform, so this is always `linux_*`. Asset bundling does not bake
//    a runtime OS, so the `android_*` concern above does not apply here.
//
//  * [kernelTargetPlatform] — the platform baked into the kernel as the runtime
//    OS. webOS reports as Linux at runtime, so we use [TargetPlatform.tester]
//    (its `targetOS` is null, i.e. no `--target-os` is baked, identical to the
//    debug path). Using an `android_*` value here would bake
//    `operatingSystem == 'android'` into release/profile snapshots and break
//    `defaultTargetPlatform` for plugins that branch on it (e.g. firebase).

/// The [TargetPlatform] used for AOT codegen (gen_snapshot). Host-aware.
///
/// See: [getTargetPlatformForName] in `build_info.dart`.
TargetPlatform genSnapshotTargetPlatformForArch(String arch) {
  // Use gen_snapshot for Arm64 Linux when the host is arm64 because the
  // artifacts for arm64 host don't support self-building now.
  final arm64Host = getCurrentHostPlatform().platformName == 'arm64';
  switch (arch) {
    case 'arm':
      return arm64Host ? TargetPlatform.linux_arm64 : TargetPlatform.android_arm;
    case 'arm64':
      return arm64Host ? TargetPlatform.linux_arm64 : TargetPlatform.android_arm64;
    case 'x86':
    case 'x64':
      return arm64Host ? TargetPlatform.linux_x64 : TargetPlatform.android_x64;
    default:
      throw ArgumentError('Unexpected target arch: $arch');
  }
}

/// The [TargetPlatform] used for asset bundling. webOS is always Linux here.
TargetPlatform assetTargetPlatform(String arch) =>
    arch == 'arm64' ? TargetPlatform.linux_arm64 : TargetPlatform.linux_x64;

/// The [TargetPlatform] baked into the kernel as the runtime OS.
///
/// `tester` maps to a null `targetOS`, so no `--target-os` is baked and the VM
/// reports the real OS (Linux) at runtime — matching the debug build path.
const TargetPlatform kernelTargetPlatform = TargetPlatform.tester;
