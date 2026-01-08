import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

Future<void> performWindowsDataMigration() async {
  if (!Platform.isWindows) return;

  try {
    final Directory newDir = await getApplicationSupportDirectory();
    final String newFilePath = '${newDir.path}\\shared_preferences.json';
    final File newFile = File(newFilePath);

    if (await newFile.exists()) {
      return;
    }

    final String? appData = Platform.environment['APPDATA'];
    if (appData == null) return;

    final String oldFilePath = '$appData\\com.example\\hlaprint\\shared_preferences.json';
    final File oldFile = File(oldFilePath);

    if (!await oldFile.exists()) return;

    debugPrint("MIGRATION: Data lama ditemukan di com.example. Menyalin ke lokasi baru...");

    if (!await newFile.parent.exists()) {
      await newFile.parent.create(recursive: true);
    }

    await oldFile.copy(newFilePath);
    debugPrint("MIGRATION: SUKSES. Data berhasil dipindahkan ke $newFilePath");

  } catch (e) {
    debugPrint("MIGRATION ERROR: $e");
  }
}