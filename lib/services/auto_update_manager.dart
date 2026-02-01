import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:hlaprint/models/app_version_model.dart';
import 'package:hlaprint/services/versioning_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AutoUpdateManager extends ChangeNotifier {
  static final AutoUpdateManager _instance = AutoUpdateManager._internal();
  factory AutoUpdateManager() => _instance;
  AutoUpdateManager._internal();

  final VersioningService _service = VersioningService();
  bool _isDownloading = false;
  double _progress = 0.0;
  String _statusText = "";
  File? _readyInstaller;
  CancelToken? _cancelToken;
  bool get isDownloading => _isDownloading;
  bool get isReadyToInstall => _readyInstaller != null;
  double get progress => _progress;
  String get statusText => _statusText;

  Future<void> checkAndRunAutoUpdate() async {
    if (_isDownloading || _readyInstaller != null) {
      debugPrint(
          "[AutoUpdate] ⚠️ Skipped. Download already in progress or ready.");
      return;
    }

    try {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      String currentVersion = packageInfo.version;
      debugPrint("[AutoUpdate] Current App Version: $currentVersion");

      AppVersion result = await _service.checkVersion(currentVersion);
      debugPrint("[AutoUpdate] API Response - Has Update: ${result.hasUpdate}, URL: ${result.downloadUrl}");

      if (result.hasUpdate && result.downloadUrl != null && result.downloadUrl!.isNotEmpty) {
        debugPrint("[AutoUpdate] ✅ Update found! Starting silent download...");
        _startSilentDownload(result.downloadUrl!);
      } else {
        debugPrint("[AutoUpdate] No update necessary.");
      }
    } catch (e) {
      debugPrint("AutoUpdate Check Failed: $e");
    }
  }

  Future<void> _startSilentDownload(String url) async {
    _isDownloading = true;
    _progress = 0.0;
    _statusText = "Downloading updates in the background...";
    _cancelToken = CancelToken();
    notifyListeners();

    try {
      debugPrint("[AutoUpdate] Downloading from: $url");
      File file = await _service.downloadInstaller(
        url,
            (received, total) {
          if (total != -1) {
            _progress = received / total;
            if (_progress >= 1.0 || (_progress * 100).toInt() % 5 == 0) {
              notifyListeners();
            }
          }
        },
        cancelToken: _cancelToken,
      );

      _readyInstaller = file;
      _statusText = "The update is ready to be installed.";
      debugPrint("[AutoUpdate] ✅ Download Complete. File at: ${file.path}");
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        debugPrint("Download cancelled by user");
      } else {
        debugPrint("Download failed: $e");
      }
      _readyInstaller = null;
    } finally {
      _isDownloading = false;
      _cancelToken = null;
      notifyListeners();
    }
  }

  void cancelDownload() {
    if (_cancelToken != null && !_cancelToken!.isCancelled) {
      _cancelToken!.cancel();
    }
    _isDownloading = false;
    _readyInstaller = null;
    notifyListeners();
  }

  Future<void> executeInstallation() async {
    if (_readyInstaller != null) {
      _statusText = "Preparing for installation...";
      notifyListeners();

      await _service.runSilentInstaller(_readyInstaller!);
    }
  }
}