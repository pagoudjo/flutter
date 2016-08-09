// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'base/logger.dart';
import 'build_info.dart';
import 'device.dart';
import 'globals.dart';
import 'observatory.dart';

// Shared code between different resident application runners.
abstract class ResidentRunner {
  ResidentRunner(this.device, {
    this.target,
    this.debuggingOptions,
    this.usesTerminalUI: true
  });

  final Device device;
  final String target;
  final DebuggingOptions debuggingOptions;
  final bool usesTerminalUI;
  final Completer<int> _finished = new Completer<int>();

  Observatory serviceProtocol;
  StreamSubscription<String> _loggingSubscription;

  /// Start the app and keep the process running during its lifetime.
  Future<int> run({
    Completer<int> observatoryPortCompleter,
    String route,
    bool shouldBuild: true
  });

  Future<bool> restart();

  Future<Null> stop() async {
    await stopEchoingDeviceLog();
    return stopApp();
  }

  Future<Null> _debugDumpApp() async {
    await serviceProtocol.flutterDebugDumpApp(serviceProtocol.firstIsolateId);
  }

  Future<Null> _debugDumpRenderTree() async {
    await serviceProtocol.flutterDebugDumpRenderTree(serviceProtocol.firstIsolateId);
  }

  void registerSignalHandlers() {
    ProcessSignal.SIGINT.watch().listen((ProcessSignal signal) async {
      _resetTerminal();
      await cleanupAfterSignal();
      exit(0);
    });
    ProcessSignal.SIGTERM.watch().listen((ProcessSignal signal) async {
      _resetTerminal();
      await cleanupAfterSignal();
      exit(0);
    });
  }

  Future<Null> startEchoingDeviceLog() async {
    if (_loggingSubscription != null) {
      return;
    }
    _loggingSubscription = device.logReader.logLines.listen((String line) {
      if (!line.contains('Observatory listening on http') &&
          !line.contains('Diagnostic server listening on http'))
        printStatus(line);
    });
  }

  Future<Null> stopEchoingDeviceLog() async {
    if (_loggingSubscription != null) {
      await _loggingSubscription.cancel();
    }
    _loggingSubscription = null;
  }

  Future<Null> connectToServiceProtocol(int port) async {
    if (!debuggingOptions.debuggingEnabled) {
      return new Future<Null>.error('Error the service protocol is not enabled.');
    }
    serviceProtocol = await Observatory.connect(port);
    printTrace('Connected to service protocol on port $port');
    serviceProtocol.populateIsolateInfo();
    serviceProtocol.onExtensionEvent.listen((Event event) {
      printTrace(event.toString());
    });
    serviceProtocol.onIsolateEvent.listen((Event event) {
      printTrace(event.toString());
    });
    // Listen for service protocol connection to close.
    serviceProtocol.done.whenComplete(() {
      appFinished();
    });
  }

  /// Returns [true] if the input has been handled by this function.
  Future<bool> _commonTerminalInputHandler(String character) async {
    final String lower = character.toLowerCase();

    printStatus(''); // the key the user tapped might be on this line

    if (lower == 'h' || lower == '?' || character == AnsiTerminal.KEY_F1) {
      // F1, help
      printHelp();
      return true;
    } else if (lower == 'w') {
      await _debugDumpApp();
      return true;
    } else if (lower == 't') {
      await _debugDumpRenderTree();
      return true;
    } else if (lower == 'q' || character == AnsiTerminal.KEY_F10) {
      // F10, exit
      await stopApp();
      return true;
    }

    return false;
  }

  Future<Null> processTerminalInput(String command) async {
    bool handled = await _commonTerminalInputHandler(command);
    if (!handled)
      await handleTerminalCommand(command);
  }

  void appFinished() {
    if (_finished.isCompleted)
      return;
    printStatus('Application finished.');
    _resetTerminal();
    _finished.complete(0);
  }

  void _resetTerminal() {
    if (usesTerminalUI)
      terminal.singleCharMode = false;
  }

  void setupTerminal() {
    if (usesTerminalUI) {
      if (!logger.quiet)
        printHelp();

      terminal.singleCharMode = true;
      terminal.onCharInput.listen((String code) {
        processTerminalInput(code);
      });
    }
  }

  Future<int> waitForAppToFinish() async {
    int exitCode = await _finished.future;
    await cleanupAtFinish();
    return exitCode;
  }

  Future<Null> stopApp() {
    if (serviceProtocol != null && !serviceProtocol.isClosed) {
      if (serviceProtocol.isolates.isNotEmpty) {
        serviceProtocol.flutterExit(serviceProtocol.firstIsolateId);
        return new Future<Null>.delayed(new Duration(milliseconds: 100));
      }
    }
    appFinished();
    return new Future<Null>.value();
  }

  /// Called when a signal has requested we exit.
  Future<Null> cleanupAfterSignal();
  /// Called right before we exit.
  Future<Null> cleanupAtFinish();
  /// Called to print help to the terminal.
  void printHelp();
  /// Called when the runner should handle a terminal command.
  Future<Null> handleTerminalCommand(String code);
}

/// Given the value of the --target option, return the path of the Dart file
/// where the app's main function should be.
String findMainDartFile([String target]) {
  if (target == null)
    target = '';
  String targetPath = path.absolute(target);
  if (FileSystemEntity.isDirectorySync(targetPath))
    return path.join(targetPath, 'lib', 'main.dart');
  else
    return targetPath;
}

String getMissingPackageHintForPlatform(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.android_arm:
    case TargetPlatform.android_x64:
      return 'Is your project missing an android/AndroidManifest.xml?\nConsider running "flutter create ." to create one.';
    case TargetPlatform.ios:
      return 'Is your project missing an ios/Runner/Info.plist?\nConsider running "flutter create ." to create one.';
    default:
      return null;
  }
}
