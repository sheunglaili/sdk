// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert' show jsonDecode, JsonEncoder;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:meta/meta.dart';
import 'package:nnbd_migration/nnbd_migration.dart';
import 'package:nnbd_migration/src/front_end/charcodes.dart';
import 'package:nnbd_migration/src/front_end/dartfix_listener.dart';
import 'package:nnbd_migration/src/front_end/instrumentation_listener.dart';
import 'package:nnbd_migration/src/front_end/migration_state.dart';
import 'package:nnbd_migration/src/front_end/migration_summary.dart';
import 'package:nnbd_migration/src/preview/http_preview_server.dart';
import 'package:nnbd_migration/src/utilities/json.dart' as json;
import 'package:pub_semver/pub_semver.dart';
import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

/// [NonNullableFix] visits each named type in a resolved compilation unit
/// and determines whether the associated variable or parameter can be null
/// then adds or removes a '?' trailing the named type as appropriate.
class NonNullableFix {
  // TODO(srawlins): Refactor to use
  //  `Feature.non_nullable.releaseVersion` when this becomes non-null (perhaps
  //  after "Beta").
  static final Version _intendedMinimumSdkVersion = Version.parse('2.12.0-0');

  // In the package_config.json file, the patch number is omitted.
  static final String _intendedLanguageVersion =
      '${_intendedMinimumSdkVersion.major}.${_intendedMinimumSdkVersion.minor}';

  static final String _intendedSdkVersionConstraint =
      '>=$_intendedMinimumSdkVersion <2.12.0';

  static final List<HttpPreviewServer> _allServers = [];

  /// The internet address the server should bind to.  Should be suitable for
  /// passing to HttpServer.bind, i.e. either a [String] or an
  /// [InternetAddress].
  final Object bindAddress;

  final int preferredPort;

  final DartFixListener listener;

  /// The root of the included paths.
  ///
  /// The included paths may contain absolute and relative paths, non-canonical
  /// paths, and directory and file paths. The "root" is the deepest directory
  /// which all included paths share.
  final String includedRoot;

  /// If non-null, the path to which a machine-readable summary of migration
  /// results should be written.
  final String summaryPath;

  final ResourceProvider resourceProvider;

  final LineInfo Function(String) _getLineInfo;

  /// The HTTP server that serves the preview tool.
  HttpPreviewServer _server;

  String authToken;

  InstrumentationListener instrumentationListener;

  NullabilityMigrationAdapter adapter;

  NullabilityMigration migration;

  /// If this flag has a value of `false`, then something happened to prevent
  /// at least one package from being marked as non-nullable.
  /// If this occurs, then don't update any code.
  bool _packageIsNNBD = true;

  Future<MigrationState> Function() rerunFunction;

  /// A list of the URLs corresponding to the included roots.
  List<String> previewUrls;

  NonNullableFix(
      this.listener, this.resourceProvider, this._getLineInfo, this.bindAddress,
      {List<String> included = const [], this.preferredPort, this.summaryPath})
      : includedRoot =
            _getIncludedRoot(included, listener.server.resourceProvider) {
    reset();
  }

  bool get isPreviewServerRunning => _server != null;

  InstrumentationListener createInstrumentationListener(
          {MigrationSummary migrationSummary}) =>
      InstrumentationListener(migrationSummary: migrationSummary);

  Future<void> finalizeUnit(ResolvedUnitResult result) async {
    if (!_packageIsNNBD) {
      return;
    }
    migration.finalizeInput(result);
  }

  Future<MigrationState> finish() async {
    migration.finish();
    final state = MigrationState(
        migration, includedRoot, listener, instrumentationListener);
    await state.refresh();
    return state;
  }

  Future<void> prepareUnit(ResolvedUnitResult result) async {
    if (!_packageIsNNBD) {
      return;
    }
    migration.prepareInput(result);
  }

  /// Processes the non-source files of the package rooted at [pkgFolder].
  ///
  /// This means updating the pubspec.yaml file, the package_config.json
  /// file, and the analysis_options.yaml file, each only if necessary.
  void processPackage(Folder pkgFolder) {
    if (!_packageIsNNBD) {
      return;
    }

    var pubspecFile = pkgFolder.getChildAssumingFile('pubspec.yaml');
    if (!pubspecFile.exists) {
      // If the pubspec file cannot be found, we do not attempt to change the
      // Package Config file, nor the analysis options file.
      return;
    }

    _YamlFile pubspec;
    try {
      pubspec = _YamlFile._parseFrom(pubspecFile);
    } on FileSystemException catch (e) {
      _processPubspecException('read', pubspecFile.path, e);
      return;
    } on FormatException catch (e) {
      _processPubspecException('parse', pubspecFile.path, e);
      return;
    }

    var updated = _processPubspec(pubspec);
    if (updated) {
      _processConfigFile(pkgFolder, pubspec);
    }
  }

  Future<void> processUnit(ResolvedUnitResult result) async {
    if (!_packageIsNNBD) {
      return;
    }
    migration.processInput(result);
  }

  Future<MigrationState> rerun() async {
    reset();
    var state = await rerunFunction();
    await state.refresh();
    return state;
  }

  void reset() {
    instrumentationListener = createInstrumentationListener(
        migrationSummary: summaryPath == null
            ? null
            : MigrationSummary(summaryPath, resourceProvider, includedRoot));
    adapter = NullabilityMigrationAdapter(listener);
    migration = NullabilityMigration(adapter, _getLineInfo,
        permissive: true, instrumentation: instrumentationListener);
  }

  void shutdownServer() {
    _server?.close();
    _server = null;
  }

  Future<void> startPreviewServer(
      MigrationState state, void Function() applyHook) async {
    // This method may be called multiple times, for example during a re-run.
    // But the preview server should only be started once.
    if (_server == null) {
      _server = HttpPreviewServer(
          state, rerun, applyHook, bindAddress, preferredPort);
      _server.serveHttp();
      _allServers.add(_server);
      var serverHostname = await _server.boundHostname;
      var serverPort = await _server.boundPort;
      authToken = await _server.authToken;

      previewUrls = [
        // TODO(jcollins-g): Change protocol to only return a single string.
        Uri(
            scheme: 'http',
            host: serverHostname,
            port: serverPort,
            path: state.pathMapper.map(includedRoot),
            queryParameters: {'authToken': authToken}).toString()
      ];
    }
  }

  /// Updates the Package Config file to specify a minimum Dart SDK version
  /// which supports null safety.
  void _processConfigFile(Folder pkgFolder, _YamlFile pubspec) {
    if (!_packageIsNNBD) {
      return;
    }

    var packageName = pubspec._getName();
    if (packageName == null) {
      return;
    }

    var packageConfigFile = pkgFolder
        .getChildAssumingFolder('.dart_tool')
        .getChildAssumingFile('package_config.json');

    if (!packageConfigFile.exists) {
      _processPackageConfigException(
          'Warning: Could not find the package configuration file.',
          packageConfigFile.path);
      return;
    }
    try {
      var configText = packageConfigFile.readAsStringSync();
      var configMap = json.expectType<Map>(jsonDecode(configText), 'root');
      json.expectKey(configMap, 'configVersion');
      var configVersion =
          json.expectType<int>(configMap['configVersion'], 'configVersion');
      if (configVersion != 2) {
        _processPackageConfigException(
            'Warning: Unexpected package configuration file version '
            '$configVersion (expected version 2). Cannot update this file.',
            packageConfigFile.path);
        return;
      }
      json.expectKey(configMap, 'packages');
      var packagesList =
          json.expectType<List>(configMap['packages'], 'packages');
      for (var package in packagesList) {
        var packageMap = json.expectType<Map>(package, 'package');
        json.expectKey(packageMap, 'name');
        var name = json.expectType<String>(packageMap['name'], 'name');
        if (name != packageName) {
          continue;
        }
        json.expectKey(packageMap, 'languageVersion');
        packageMap['languageVersion'] = _intendedLanguageVersion;
        // Pub appears to always use a two-space indent. This will minimize the
        // diff between the previous text and the new text.
        var newText = JsonEncoder.withIndent('  ').convert(configMap) + '\n';

        // TODO(srawlins): This is inelegant. We add an "edit" which replaces
        // the entire content of the package config file with new content, while
        // it is likely that only 1 character has changed. I do not know of a
        // JSON parser that yields SourceSpans, so that I may know the proper
        // index. One idea, another hack, would be to write a magic string in
        // place of the version number, encode to JSON, and find the index of
        // the magic string.
        var line = 0;
        var offset = 0;
        var edit = SourceEdit(offset, configText.length, newText);
        listener.addSourceFileEdit(
            'enable Null Safety language feature',
            Location(packageConfigFile.path, offset, newText.length, line, 0),
            SourceFileEdit(packageConfigFile.path, 0, edits: [edit]));
      }
    } on FormatException catch (e) {
      _processPackageConfigException(
          'Warning: Encountered an error parsing the package configuration '
          'file: $e\n\nCannot update this file.',
          packageConfigFile.path);
    }
  }

  void _processPackageConfigException(String prefix, String packageConfigPath,
      [Object error = '']) {
    // TODO(#42138): This should use [listener.addRecommendation] when that
    // function is implemented.
    print('''$prefix
  $packageConfigPath
  $error

  Be sure to run `pub get` before examining the results of the migration.
''');
  }

  /// Updates the pubspec.yaml file to specify a minimum Dart SDK version which
  /// supports null safety.
  bool _processPubspec(_YamlFile pubspec) {
    var pubspecMap = pubspec.content;
    YamlNode environmentOptions;
    if (pubspecMap is YamlMap) {
      environmentOptions = pubspecMap.nodes['environment'];
    }
    if (environmentOptions == null) {
      var start = SourceLocation(0, line: 0, column: 0);
      var content = '''
environment:
  sdk: '$_intendedSdkVersionConstraint'

''';
      pubspec._insertAfterParent(
          SourceSpan(start, start, ''), content, listener);
    } else if (environmentOptions is YamlMap) {
      var sdk = environmentOptions.nodes['sdk'];
      if (sdk == null) {
        var content = """

  sdk: '$_intendedSdkVersionConstraint'""";
        pubspec._insertAfterParent(environmentOptions.span, content, listener);
      } else if (sdk is YamlScalar) {
        VersionConstraint currentConstraint;
        if (sdk.value is String) {
          currentConstraint = VersionConstraint.parse(sdk.value as String);
          if (currentConstraint is VersionRange &&
              currentConstraint.min >= _intendedMinimumSdkVersion) {
            // The current SDK version constraint already enables Null Safety.
            // Do not edit pubspec.yaml, nor package_config.json.
            return false;
          } else {
            // TODO(srawlins): This overwrites the current maximum version. In
            // the uncommon situation that the maximum is not '<3.0.0', it
            // should not.
            pubspec._replaceSpan(
                sdk.span, "'$_intendedSdkVersionConstraint'", listener);
          }
        } else {
          // Something is odd with the SDK constraint we've found in
          // pubspec.yaml; Best to leave it alone.
          return false;
        }
      }
    }

    return true;
  }

  void _processPubspecException(String action, String pubspecPath, error) {
    listener.addRecommendation('''Failed to $action pubspec file
  $pubspecPath
  $error

  Manually update this file to enable the Null Safety language feature by
  adding:

    environment:
      sdk: '$_intendedSdkVersionConstraint';
''');
    _packageIsNNBD = false;
  }

  /// Allows unit tests to shut down any rogue servers that have been started,
  /// so that unit testing can complete.
  @visibleForTesting
  static void shutdownAllServers() {
    for (var server in _allServers) {
      try {
        server.close();
      } catch (_) {}
    }
    _allServers.clear();
  }

  /// Get the "root" of all [included] paths. See [includedRoot] for its
  /// definition.
  static String _getIncludedRoot(
      List<String> included, ResourceProvider provider) {
    var context = provider.pathContext;
    // This step looks like it may be expensive (`getResource`, splitting up
    // all of the paths, comparing parts, joining one path back together). In
    // practice, this should be cheap because typically only one path is given
    // to dartfix.
    var rootParts = included
        .map((p) => context.normalize(context.absolute(p)))
        .map((p) => provider.getResource(p) is File ? context.dirname(p) : p)
        .map((p) => context.split(p))
        .reduce((value, parts) {
      var shorterPath = value.length < parts.length ? value : parts;
      var length = shorterPath.length;
      for (var i = 0; i < length; i++) {
        if (value[i] != parts[i]) {
          // [value] and [parts] are the same, only up to part [i].
          return value.sublist(0, i);
        }
      }
      // [value] and [parts] are the same up to the full length of the shorter
      // of the two, so just return that.
      return shorterPath;
    });
    return context.joinAll(rootParts);
  }
}

class NullabilityMigrationAdapter implements NullabilityMigrationListener {
  final DartFixListener listener;

  NullabilityMigrationAdapter(this.listener);

  @override
  void addEdit(Source source, SourceEdit edit) {
    listener.addEditWithoutSuggestion(source, edit);
  }

  @override
  void addSuggestion(String descriptions, Location location) {
    listener.addSuggestion(descriptions, location);
  }

  @override
  void reportException(
      Source source, AstNode node, Object exception, StackTrace stackTrace) {
    listener.reportException('''
$exception

$stackTrace''');
  }
}

class _YamlFile {
  final String path;
  final String textContent;

  final YamlNode content;

  _YamlFile._(this.path, this.textContent, this.content);

  String _getName() {
    YamlNode packageNameNode;

    if (content is YamlMap) {
      packageNameNode = (content as YamlMap).nodes['name'];
    } else {
      return null;
    }

    if (packageNameNode is YamlScalar && packageNameNode.value is String) {
      return packageNameNode.value as String;
    } else {
      return null;
    }
  }

  /// Inserts [content] into this file, immediately after [parentSpan].
  void _insertAfterParent(
      SourceSpan parentSpan, String content, DartFixListener listener) {
    var line = parentSpan.end.line;
    var offset = parentSpan.end.offset;
    // Walk [offset] and [line] back to the first non-whitespace character
    // before [offset].
    while (offset > 0) {
      var ch = textContent.codeUnitAt(offset - 1);
      if (ch == $space || ch == $cr) {
        --offset;
      } else if (ch == $lf) {
        --offset;
        --line;
      } else {
        break;
      }
    }
    var edit = SourceEdit(offset, 0, content);
    listener.addSourceFileEdit(
        'enable Null Safety language feature',
        Location(path, offset, content.length, line, 0),
        SourceFileEdit(path, 0, edits: [edit]));
  }

  void _replaceSpan(SourceSpan span, String content, DartFixListener listener) {
    var line = span.start.line;
    var offset = span.start.offset;
    var edit = SourceEdit(offset, span.length, content);
    listener.addSourceFileEdit(
        'enable Null Safety language feature',
        Location(path, offset, content.length, line, 0),
        SourceFileEdit(path, 0, edits: [edit]));
  }

  static _YamlFile _parseFrom(File file) {
    var textContent = file.readAsStringSync();
    var content = loadYaml(textContent);
    if (content is YamlNode) {
      return _YamlFile._(file.path, textContent, content);
    } else {
      throw FormatException('pubspec.yaml is not a YAML map.');
    }
  }
}
