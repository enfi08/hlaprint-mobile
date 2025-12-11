import 'dart:io';
import 'package:dio/dio.dart';
import 'package:hlaprint/constants.dart';
import 'package:hlaprint/models/app_version_model.dart';
import 'package:path_provider/path_provider.dart';

class VersioningService {
  final Dio _dio = Dio();

  Future<AppVersion> checkVersion(String currentVersion) async {
    final url = '$baseUrl/api/check-version-win';

    final headers = {
      "Accept": "application/json",
    };

    try {
      final response = await _dio.get(
        url,
        queryParameters: {
          "current_version": currentVersion
        },
        options: Options(headers: headers),
      );

      if (response.statusCode == 200) {
        return AppVersion.fromJson(response.data);
      } else {
        throw Exception("Failed to check version: ${response.statusCode}");
      }
    } on DioException catch (e) {
      throw Exception("Connection error: ${e.message}");
    }
  }

  Future<File> downloadInstaller(String url, Function(int, int) onReceiveProgress) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final String savePath = '${tempDir.path}\\installer_update.exe';

      await _dio.download(
        url,
        savePath,
        onReceiveProgress: onReceiveProgress,
      );

      return File(savePath);
    } catch (e) {
      throw Exception("Download failed: $e");
    }
  }
}