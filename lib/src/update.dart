import "dart:async";
import "dart:io";

import "package:desktop_updater/desktop_updater.dart";
import "package:desktop_updater/src/download.dart";
import "package:path/path.dart" as path;

/// Gets bundle identifier from Info.plist (macOS)
Future<String?> _getBundleIdFromInfoPlist() async {
  if (!Platform.isMacOS) return null;

  try {
    final executablePath = Platform.resolvedExecutable;
    final bundleMatch = RegExp(
      r"^(.+\.app)/Contents/",
    ).firstMatch(executablePath);

    if (bundleMatch == null) return null;

    final bundlePath = bundleMatch.group(1);
    if (bundlePath == null) return null;

    final infoPlistPath = path.join(bundlePath, "Contents", "Info.plist");
    final infoPlistFile = File(infoPlistPath);

    if (!await infoPlistFile.exists()) return null;

    final content = await infoPlistFile.readAsString();
    final bundleIdMatch = RegExp(
      r"<key>CFBundleIdentifier</key>\s*<string>([^<]+)</string>",
      caseSensitive: false,
    ).firstMatch(content);

    return bundleIdMatch?.group(1);
  } catch (_) {
    return null;
  }
}

/// Modified updateAppFunction to return a stream of UpdateProgress.
/// The stream emits total kilobytes, received kilobytes, and the currently downloading file's name.
Future<Stream<UpdateProgress>> updateAppFunction({
  required String remoteUpdateFolder,
  required List<FileHashModel?> changes,
}) async {
  final executablePath = Platform.resolvedExecutable;

  final directoryPath = executablePath.substring(
    0,
    executablePath.lastIndexOf(Platform.pathSeparator),
  );

  var dir = Directory(directoryPath);

  if (Platform.isMacOS) {
    dir = dir.parent;
  }

  final responseStream = StreamController<UpdateProgress>();

  try {
    if (await dir.exists()) {
      var downloadPath = dir.path;

      if (Platform.isMacOS) {
        final home = Platform.environment["HOME"];
        final bundleId = await _getBundleIdFromInfoPlist();

        if (home != null && bundleId != null) {
          downloadPath = path.join(
            home,
            "Library",
            "Application Support",
            bundleId,
            "updates",
          );
        }
      }

      final updateFolder = Directory(path.join(downloadPath, "update"));
      if (await updateFolder.exists()) {
        await updateFolder.delete(recursive: true);
      }
      await updateFolder.create(recursive: true);

      if (changes.isEmpty) {
        print("No updates required.");
        await responseStream.close();
        return responseStream.stream;
      }

      var receivedBytes = 0.0;
      final totalFiles = changes.length;
      var completedFiles = 0;

      // Calculate total length in KB
      final totalLengthKB = changes.fold<double>(
        0,
        (previousValue, element) =>
            previousValue + ((element?.length ?? 0) / 1024.0),
      );

      final changesFutureList = <Future<dynamic>>[];

      for (final file in changes) {
        if (file != null) {
          changesFutureList.add(
            downloadFile(
              remoteUpdateFolder,
              file.filePath,
              downloadPath,
              (received, total) {
                receivedBytes += received;
                responseStream.add(
                  UpdateProgress(
                    totalBytes: totalLengthKB,
                    receivedBytes: receivedBytes,
                    currentFile: file.filePath,
                    totalFiles: totalFiles,
                    completedFiles: completedFiles,
                  ),
                );
              },
            ).then((_) {
              completedFiles += 1;

              responseStream.add(
                UpdateProgress(
                  totalBytes: totalLengthKB,
                  receivedBytes: receivedBytes,
                  currentFile: file.filePath,
                  totalFiles: totalFiles,
                  completedFiles: completedFiles,
                ),
              );
              print("Completed: ${file.filePath}");
            }).catchError((error) {
              responseStream.addError(error);
              return null;
            }),
          );
        }
      }

      unawaited(
        Future.wait(changesFutureList).then((_) async {
          await responseStream.close();
        }),
      );

      return responseStream.stream;
    }
  } catch (e) {
    responseStream.addError(e);
    await responseStream.close();
  }

  return responseStream.stream;
}
