import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:Hlaprint/constants.dart';
import 'package:Hlaprint/services/versioning_service.dart';
import 'package:Hlaprint/services/auto_update_manager.dart';
import 'package:Hlaprint/screens/home_page.dart';
import 'package:Hlaprint/screens/login_screen.dart';
import 'package:Hlaprint/services/MyHttpOverrides.dart';
import 'package:Hlaprint/services/auth_service.dart';
import 'package:Hlaprint/constants.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  HttpOverrides.global = MyHttpOverrides();

  await SentryFlutter.init(
        (options) {
      options.dsn = isStaging ? ''
              : 'https://7022892b4c4313f2acf1b4bd43a0c7a7@o4508279105060864.ingest.de.sentry.io/4510219873812560';
      options.sendDefaultPii = true;
      options.enableAppHangTracking = false;
    },
    appRunner: () async {
      final prefs = await SharedPreferences.getInstance();
      String initialRoute = '/login';

      try {
        final savedUserId = prefs.getString(userIdKey);
        final savedName = prefs.getString(nameKey);
        final savedEmail = prefs.getString(emailKey);
        final authService = AuthService();
        final token = await authService.getToken();

        if (token != null) {
          initialRoute = '/home';
        }
        if (savedUserId != null || savedName != null || savedEmail != null) {
          Sentry.configureScope((scope) {
            scope.setUser(SentryUser(
              id: savedUserId,
              username: savedName,
              email: savedEmail,
            ));
          });
        }
      } catch (e, stackTrace) {
        debugPrint("ERROR INITIALIZATION: $e");
        await Sentry.captureException(e, stackTrace: stackTrace);
      }

      runApp(
        MyApp(initialRoute: initialRoute),
      );
    },
  );
}

class MyApp extends StatelessWidget {
  final String initialRoute;

  const MyApp({super.key, required this.initialRoute});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Hlaprint',
      theme: ThemeData(primarySwatch: Colors.blue),
      initialRoute: initialRoute,
      builder: (context, child) {
        return UpdateManager(child: child!);
      },
      routes: {
        '/login': (context) => LoginScreen(),
        '/home': (context) => HomePage(),
      },
    );
  }
}

class UpdateManager extends StatefulWidget {
  final Widget child;
  const UpdateManager({super.key, required this.child});

  @override
  State<UpdateManager> createState() => _UpdateManagerState();
}

class _UpdateManagerState extends State<UpdateManager> {
  final VersioningService _versioningService = VersioningService();
  final AutoUpdateManager _updateManager = AutoUpdateManager();
  Timer? _autoUpdateTimer;

  @override
  void initState() {
    super.initState();
    // 1. TAMBAHAN: Dengarkan perubahan dari AutoUpdateManager
    _updateManager.addListener(_handleAutoUpdateStateChange);

    if (Platform.isWindows) {
      _startAutoUpdateCheck();
    }
  }

  @override
  void dispose() {
    // 2. TAMBAHAN: Hapus listener untuk mencegah memory leak
    _updateManager.removeListener(_handleAutoUpdateStateChange);
    _autoUpdateTimer?.cancel();
    super.dispose();
  }

  // Fungsi callback ketika ada notifikasi dari AutoUpdateManager
  void _handleAutoUpdateStateChange() {
    if (mounted) {
      setState(() {
        // Memicu rebuild agar UI overlay muncul/berubah
      });
    }
  }

  void _startAutoUpdateCheck() {
    debugPrint("[AutoUpdate] Timer Setup Initiated.");
    _autoUpdateTimer?.cancel();
    _checkWindowsUpdate();

    _autoUpdateTimer = Timer.periodic(const Duration(hours: 1), (timer) {
      debugPrint("[AutoUpdate] ⏰ Periodic timer tick.");
      _checkWindowsUpdate();
    });
  }

  Future<void> _checkWindowsUpdate() async {
    if (!Platform.isWindows) return;

    final prefs = await SharedPreferences.getInstance();
    bool autoUpdateEnabled = prefs.getBool('update_automatically') ?? true;

    if (autoUpdateEnabled) {
      debugPrint("[AutoUpdate] Manager: Starting check logic...");
      // Logic ini jalan di background, UI-nya ditangani oleh listener _handleAutoUpdateStateChange
      _updateManager.checkAndRunAutoUpdate();
      return;
    }

    // --- Logic untuk Manual Update (jika auto update dimatikan user) ---
    debugPrint("[AutoUpdate] 🛑 Skipped. User disabled auto update in settings.");
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final result = await _versioningService.checkVersion(currentVersion);

      if (result.hasUpdate) {
        final String latestVersion = result.latestVersion ?? 'Unknown';
        final String downloadUrl = result.downloadUrl ?? '';
        final String message = result.message ?? 'New version available';

        _processUpdateUI(latestVersion, downloadUrl, message, result.forceUpdate);
      }
    } catch (e) {
      debugPrint("Auto-update check failed: $e");
    }
  }

  // --- UI Logic untuk Manual Update (Existing Code) ---
  Future<void> _processUpdateUI(String latestVersion, String url, String msg, bool forceUpdate) async {
    final prefs = await SharedPreferences.getInstance();

    if (!forceUpdate) {
      final String ignoredVersion = prefs.getString('update_ignored_version') ?? '';
      int laterCount = prefs.getInt('update_later_count') ?? 0;

      if (latestVersion != ignoredVersion) {
        laterCount = 0;
        await prefs.setInt('update_later_count', 0);
        await prefs.setString('update_ignored_version', latestVersion);
      }

      if (laterCount >= 3) {
        return;
      }
    }

    if (!mounted) return;

    ScaffoldMessenger.of(context).clearMaterialBanners();
    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        content: Text('$msg (v$latestVersion)'),
        leading: const Icon(Icons.system_update, color: Colors.blue),
        backgroundColor: Colors.yellow[50],
        forceActionsBelow: false,
        actions: [
          if (!forceUpdate)
            TextButton(
              onPressed: () => _handleUpdateLater(latestVersion),
              child: const Text('Later'),
            ),
          ElevatedButton(
            onPressed: () => _handleUpdateInstall(url),
            child: const Text('Install'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleUpdateLater(String version) async {
    ScaffoldMessenger.of(context).clearMaterialBanners();
    final prefs = await SharedPreferences.getInstance();
    int currentCount = prefs.getInt('update_later_count') ?? 0;
    await prefs.setInt('update_later_count', currentCount + 1);
    await prefs.setString('update_ignored_version', version);
    _startAutoUpdateCheck();
  }

  Future<void> _handleUpdateInstall(String url) async {
    final navContext = navigatorKey.currentContext;
    if (navContext == null) {
      debugPrint("Error: Navigator context is null");
      return;
    }

    ScaffoldMessenger.of(navContext).clearMaterialBanners();
    ValueNotifier<double> progressNotifier = ValueNotifier(0.0);

    showDialog(
      context: navContext,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return WillPopScope(
          onWillPop: () async {
            return false;
          },
          child: AlertDialog(
            title: const Text('Downloading Update'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Downloading update package, please wait...'),
                const SizedBox(height: 20),
                ValueListenableBuilder<double>(
                  valueListenable: progressNotifier,
                  builder: (context, value, child) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LinearProgressIndicator(value: value),
                        const SizedBox(height: 8),
                        Text(
                          '${(value * 100).toStringAsFixed(0)}%',
                          textAlign: TextAlign.end,
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );

    try {
      File installer = await _versioningService.downloadInstaller(url, (received, total) {
        if (total != -1) {
          progressNotifier.value = received / total;
        }
      });

      if (await installer.exists()) {
        await Process.start(installer.path, [], mode: ProcessStartMode.detached);
        exit(0);
      }
    } catch (e) {
      if (navigatorKey.currentState?.canPop() ?? false) {
        navigatorKey.currentState?.pop();
      }

      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text("Update failed: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 3. TAMBAHAN: Gunakan Stack untuk menumpuk UI Auto Update di atas aplikasi
    return Stack(
      children: [
        // Aplikasi Utama
        widget.child,

        // Overlay jika AutoUpdateManager sedang mendownload
        if (_updateManager.isDownloading)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Material(
              color: Colors.blue[50],
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.downloading, color: Colors.blue),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _updateManager.statusText,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          LinearProgressIndicator(value: _updateManager.progress),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      "${(_updateManager.progress * 100).toStringAsFixed(0)}%",
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // Overlay jika AutoUpdateManager siap install
        if (_updateManager.isReadyToInstall)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Material(
              color: Colors.green[50],
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline, color: Colors.green),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        _updateManager.statusText,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () {
                        _updateManager.executeInstallation();
                      },
                      icon: const Icon(Icons.system_update_alt),
                      label: const Text("Install Now"),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                    )
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}