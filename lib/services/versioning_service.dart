import 'dart:io';
import 'package:dio/dio.dart';
import 'package:Hlaprint/constants.dart';
import 'package:Hlaprint/models/app_version_model.dart';
import 'package:Hlaprint/services/auth_service.dart';
import 'package:path_provider/path_provider.dart';

class VersioningService {
  final AuthService _authService = AuthService();
  final Dio _dio = Dio();

  Future<AppVersion> checkVersion(String currentVersion) async {
    final token = await _authService.getToken();
    final bool isTokenEmpty = token == null || token.isEmpty;
    final url = isTokenEmpty
        ? '$baseUrl/api/check-version'
        : '$baseUrl/api/new-check-version';

    final headers = {
      "Content-Type": "application/json",
      "Accept": "application/json",
    };

    if (!isTokenEmpty) {
      headers["Authorization"] = "Bearer $token";
    }
    try {
      final response = await _dio.get(
        url,
        queryParameters: {
          "current_version": currentVersion,
          "platform": "windows_7"
        },
        options: Options(headers: headers),
      );

      if (response.statusCode == 200) {
        return AppVersion.fromJson(response.data);
      } else {
        return _createFallbackResult();
      }
    } on DioException {
      return _createFallbackResult();
    }
  }

  AppVersion _createFallbackResult() {

    return AppVersion(
      hasUpdate: false,
      forceUpdate: false,
      message: "The version already updated",
      latestVersion: null,
      downloadUrl: null,
    );
  }
  
  Future<File> downloadInstaller(
      String url,
      Function(int, int) onReceiveProgress,
      {CancelToken? cancelToken}
      ) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final String savePath = '${tempDir.path}\\installer_update_${DateTime.now().millisecondsSinceEpoch}.exe';

      await _dio.download(
        url,
        savePath,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
      );

      return File(savePath);
    } catch (e) {
      throw Exception("Download failed: $e");
    }
  }

  Future<void> runSilentInstaller(File installerFile) async {
    if (await installerFile.exists()) {
      await Process.start(
        installerFile.path,
        ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'],
        mode: ProcessStartMode.detached,
      );
      exit(0);
    }
  }
}