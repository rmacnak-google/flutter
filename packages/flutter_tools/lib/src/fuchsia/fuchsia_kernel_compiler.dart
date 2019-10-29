// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:meta/meta.dart';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/process.dart';
import '../base/process_manager.dart';
import '../build_info.dart';
import '../convert.dart';
import '../globals.dart';
import '../project.dart';

/// This is a simple wrapper around the custom kernel compiler from the Fuchsia
/// SDK.
class FuchsiaKernelCompiler {
  /// Compiles the [fuchsiaProject] with entrypoint [target] to a collection of
  /// .dilp files (consisting of the app split along package: boundaries, but
  /// the Flutter tool should make no use of that fact), and a manifest that
  /// refers to them.
  Future<void> build({
    @required FuchsiaProject fuchsiaProject,
    @required String target, // E.g., lib/main.dart
    BuildInfo buildInfo = BuildInfo.debug,
  }) async {
    final String engineDartPath = artifacts.getArtifactPath(Artifact.engineDartBinary);
    if (!processManager.canRun(engineDartPath)) {
      throwToolExit('Unable to find Dart binary at $engineDartPath');
    }
    final String frontendServer = artifacts.getArtifactPath(
      Artifact.frontendServerSnapshotForEngineDartSdk
    );
    if (!fs.isFileSync(frontendServer)) {
      throwToolExit('Frontend server not found at "$frontendServer"');
    }

    // TODO(zra): Use filesystem root and scheme information from buildInfo.
    const String multiRootScheme = 'main-root';
    final String packagesFile = fuchsiaProject.project.packagesFile.path;
    final String outDir = getFuchsiaBuildDirectory();
    final String appName = fuchsiaProject.project.manifest.appName;
    final String fsRoot = fuchsiaProject.project.directory.path;
    final String relativePackagesFile = fs.path.relative(packagesFile, from: fsRoot);
    final String manifestPath = fs.path.join(outDir, '$appName.dilpmanifest');
    final String sdkRoot = artifacts.getArtifactPath(
        Artifact.fuchsiaPatchedSdk,
        mode: buildInfo.mode
    );
    final String platformDill = artifacts.getArtifactPath(
      Artifact.fuchsiaPlatformDill,
      platform: TargetPlatform.fuchsia_x64,  // This file is not arch-specific.
      mode: buildInfo.mode,
    );
    if (!fs.isFileSync(platformDill)) {
      throwToolExit('Fuchisa platform file not found at "$platformDill"');
    }
    List<String> flags = <String>[
      '--target', 'flutter_runner',
      '--sdk-root', sdkRoot,
      '--platform', platformDill,
      '--filesystem-scheme', 'main-root',
      '--filesystem-root', fsRoot,
      '--packages', '$multiRootScheme:///$relativePackagesFile',
      '--output-dill', fs.path.join(outDir, '$appName.dil'),
      '--no-link-platform',
      '--split-output-by-packages',
      '--far-manifest', manifestPath,
      '--component-name', appName,
    ];

    if (buildInfo.isDebug) {
      flags += <String>[
        '--embed-source-text',
        '--gen-bytecode',
        '--drop-ast',
      ];
    } else if (buildInfo.isProfile) {
      flags += <String>[
        '--no-embed-source-text',
        '-Ddart.vm.profile=true',
        '--gen-bytecode',
        '--drop-ast',
      ];
    } else if (buildInfo.isRelease) {
      flags += <String>[
        '--no-embed-source-text',
        '-Ddart.vm.release=true',
        '--gen-bytecode',
        '--drop-ast',
      ];
    } else {
      throwToolExit('Expected build type to be debug, profile, or release');
    }

    flags += <String>[
      '$multiRootScheme:///$target',
    ];

    final List<String> command = <String>[
      engineDartPath,
      frontendServer,
      ...flags,
    ];
    final Process process = await processUtils.start(command);
    final Status status = logger.startProgress(
      'Building Fuchsia application...',
      timeout: null,
    );
    int result;
    try {
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(printError);
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(printTrace);
      result = await process.exitCode;
    } finally {
      status.cancel();
    }
    if (result != 0) {
      throwToolExit('Build process failed');
    }
  }
}
