import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:Hlaprint/colors.dart';
import 'package:Hlaprint/models/print_job_model.dart';
import 'package:Hlaprint/screens/settings_page.dart';
import 'package:Hlaprint/services/auth_service.dart';
import 'package:Hlaprint/services/cash_approve_service.dart';
import 'package:Hlaprint/services/print_count_service.dart';
import 'package:Hlaprint/services/print_job_service.dart';
import 'package:Hlaprint/services/order_list_service.dart';
import 'package:Hlaprint/services/user_service.dart';
import 'package:Hlaprint/services/versioning_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sentry/sentry.dart';
import 'package:flutter/services.dart';
import 'package:Hlaprint/constants.dart';
import 'package:shimmer/shimmer.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';

import '../models/user_detail_model.dart';


class HomePage extends StatefulWidget {
  final Map<String, String>? currentCredentials;

  const HomePage({super.key, this.currentCredentials});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const platform = MethodChannel('com.hlaprint.app/printing');
  final List<TextEditingController> _pinControllers =
  List.generate(4, (_) => TextEditingController());
  final PrintJobService _printJobService = PrintJobService();
  final PrintCountService _printCountService = PrintCountService();
  final OrderListService _orderListService = OrderListService();
  final CashApproveService _cashApproveService = CashApproveService();
  final VersioningService _versioningService = VersioningService();
  final UserService _userService = UserService();
  bool _hasCheckedLoginSave = false;
  bool _isLoading = false;
  String _pin = '';
  String _name = '';
  String _email = '';
  String _printerStatus = '';
  bool _isSkipCashier = false;
  String? _userRole;
  List<PrintJob> _bookshopOrders = [];
  Timer? _autoRefreshTimer;
  Timer? _autoUpdateTimer;

  final _scrollController = ScrollController();
  ScaffoldMessengerState? _scaffoldMessenger;
  int _currentPage = 1;
  final int _limit = 8;
  bool _isLoadMoreLoading = false;
  bool _hasNextPage = true;
  bool _isGsProcessing = false;
  double _gsProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _loadCachedUserData();
    _loadUserRoleAndData();
    _startAutoRefresh();
    _startAutoUpdateCheck();
    _scrollController.addListener(_onScroll);

    for (var controller in _pinControllers) {
      controller.addListener(_updatePin);
    }

    platform.setMethodCallHandler((call) async {
      if (call.method == "onPrinterStatus") {
        setState(() {
          _printerStatus = call.arguments; // "Online" / "Offline"
        });
      }
    });

  }

  void _startAutoUpdateCheck() {
    _autoUpdateTimer?.cancel();
    _checkWindowsUpdate();

    _autoUpdateTimer = Timer.periodic(const Duration(hours: 1), (timer) {
      _checkWindowsUpdate();
    });
  }

  Future<void> _checkWindowsUpdate() async {
    if (!Platform.isWindows) return;

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

    _autoUpdateTimer?.cancel();
    _autoUpdateTimer = null;

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

    debugPrint("Update v$version skipped. Count: ${currentCount + 1}");
    _startAutoUpdateCheck();
  }

  Future<void> _handleUpdateInstall(String url) async {
    ScaffoldMessenger.of(context).clearMaterialBanners();

    ValueNotifier<double> progressNotifier = ValueNotifier(0.0);

    showDialog(
      context: context,
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
        debugPrint("Running installer: ${installer.path}");

        await Process.start(
          installer.path,
          [],
          mode: ProcessStartMode.detached,
        );

        exit(0);
      }
    } catch (e) {
      if (mounted && Navigator.canPop(context)) {
        Navigator.of(context).pop();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Update failed: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _loadUserRoleAndData() async {
    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString(userRoleKey);
    final isSkipCashier = prefs.getBool(skipCashierKey) ?? false;
    if (mounted) {
      setState(() {
        _userRole = role;
        _isSkipCashier = isSkipCashier;
      });
    }

    if (role != null && ['shopowner', 'shopmanager', 'cashier', 'coffeshop'].contains(role)) {
      _loadOrders(isRefresh: true);
    } else {
      _fetchAndSaveUserRole();
    }
    if (!_hasCheckedLoginSave && widget.currentCredentials != null) {
      _checkAndOfferSaveLogin();
    }
  }

  Future<void> _checkAndOfferSaveLogin() async {
    _hasCheckedLoginSave = true;
    final email = widget.currentCredentials?['email'];
    final password = widget.currentCredentials?['password'];

    if (email == null || email.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final String? savedString = prefs.getString('saved_logins');
    List<dynamic> savedAccounts = [];

    if (savedString != null) {
      savedAccounts = jsonDecode(savedString);
    }

    final bool isAlreadySaved = savedAccounts.any((acc) => acc['email'] == email);

    if (!isAlreadySaved && mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text("Save Login Info?"),
          content: const Text("Would you like to save your account info for faster login next time?"),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text("Not now", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                savedAccounts.add({
                  'email': email,
                  'password': password,
                });
                await prefs.setString('saved_logins', jsonEncode(savedAccounts));

                if (context.mounted) {
                  Navigator.of(context).pop(); // Tutup dialog
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Login info saved!")),
                  );
                }
              },
              child: const Text("Save"),
            ),
          ],
        ),
      );
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels == _scrollController.position.maxScrollExtent && !_isLoadMoreLoading && _hasNextPage) {
      _loadOrders(isRefresh: false);
    }
  }

  void _startAutoRefresh() {
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_userRole != null && ['shopowner', 'shopmanager', 'cashier', 'coffeshop'].contains(_userRole)) {
        _loadOrders(isRefresh: true, isSilent: true);
      }
    });
  }

  void _stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  Future<void> _loadOrders({bool isRefresh = true, bool isSilent = false}) async {
    if (_isLoading || _isLoadMoreLoading) return;

    if (isRefresh) {
      _currentPage = 1;
      _bookshopOrders.clear();
      _hasNextPage = true;
      if (!isSilent) {
        if (mounted) {
          setState(() {
            _isLoading = true;
          });
        }
      }
      _fetchAndSaveUserRole();
    } else {
      if (mounted) {
        setState(() {
          _isLoadMoreLoading = true;
        });
      }
    }

    try {
      final orders = await _orderListService.getOrderList(page: _currentPage, limit: _limit);
      if (mounted) {
        setState(() {
          _bookshopOrders.addAll(orders);
          _currentPage++;
          _hasNextPage = orders.length == _limit;
        });
      }
    } catch (e, s) {
      await Sentry.captureException(
        e,
        stackTrace: s,
      );
      debugPrint("Failed to load bookshop orders: $e");
      if (mounted && !isSilent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load orders: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          if (isRefresh) {
            _isLoading = false;
            _isLoadMoreLoading = false;
          } else {
            _isLoadMoreLoading = false;
          }
        });
      }
    }
  }

  Future<void> _loadCachedUserData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _name = prefs.getString(nameKey) ?? '';
      _email = prefs.getString(emailKey) ?? '';
    });
  }

  Future<void> _fetchAndSaveUserRole() async {
    try {
      final User user = await _userService.getUser();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(userRoleKey, user.role);
      await prefs.setString(nameKey, user.name);
      await prefs.setString(emailKey, user.email);
      await prefs.setBool(skipCashierKey, user.isSkipCashier);

      Sentry.configureScope((scope) {
        scope.setUser(SentryUser(
          id: user.id.toString(),
          username: user.name,
          email: user.email,
        ));
      });

      if (mounted) {
        setState(() {
          _userRole = user.role;
          _isSkipCashier = user.isSkipCashier;
          _name = user.name;
          _email = user.email;
        });
      }
    } catch (e, s) {
      await Sentry.captureException(
        e,
        stackTrace: s,
      );
    }
  }

  Future<void> _showCashApproveDialog(int jobId, String jobCode) async {
    bool canPay = true;
    if (_userRole == 'shopmanager' && !_isSkipCashier) {
      canPay = false;
    }
    String title = canPay ? 'Payment Confirmation' : 'Warning';
    String description = canPay ? 'Are you sure you want to approve this payment?' : 'please go to the cashier for this process';
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(description),
              ],
            ),
          ),
          actions: <Widget>[
            if (canPay)
              TextButton(
                child: const Text('Cancel'),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            TextButton(
              child: const Text('Ok'),
              onPressed: () async {
                Navigator.of(context).pop();

                if (canPay) {
                  await _processCashApprove(jobId, jobCode);
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<String> _getPrinterIP() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(ipPrinterKey) ?? "";
  }

  Future<void> _processCashApprove(int jobId, String jobCode) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Process payment approval...')),
      );

      await _cashApproveService.cashApprove(jobCode);

      final indexToUpdate = _bookshopOrders.indexWhere((job) => job.id == jobId);
      if (indexToUpdate != -1) {
        final updatedJob = _bookshopOrders[indexToUpdate].copyWith(status: 'Sent To Print');
        if (mounted) {
          setState(() {
            _bookshopOrders[indexToUpdate] = updatedJob;
          });
        }
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Payment successfully approved!')),
      );

    } catch (e, s) {
      await Sentry.captureException(
        e,
        stackTrace: s,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to approve payment: ${e.toString()}')),
      );
    }
  }

  @override
  void dispose() {
    _stopAutoRefresh();
    _autoUpdateTimer?.cancel();
    _scaffoldMessenger?.clearMaterialBanners();
    _scrollController.dispose();
    for (var controller in _pinControllers) {
      controller.removeListener(_updatePin);
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scaffoldMessenger = ScaffoldMessenger.maybeOf(context);
  }

  void _handleKeypadTap(String value) {
    setState(() {
      if (value == '<') {
        if (_pin.isNotEmpty) {
          _pin = _pin.substring(0, _pin.length - 1);
        }
      } else if (value == 'C') {
        _pin = '';
      } else if (_pin.length < 4) {
        _pin += value;
      }
    });
  }

  Widget _buildPinDisplay() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        return Container(
          width: 60,
          height: 60,
          margin: const EdgeInsets.symmetric(horizontal: 7),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey),
            borderRadius: BorderRadius.circular(8),
            color: Colors.white,
          ),
          alignment: Alignment.center,
          child: Text(
            index < _pin.length ? _pin[index] : '',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        );
      }),
    );
  }

  Widget _buildKeypadButton(String text,
      {bool isLarge = false}) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: ElevatedButton(
        onPressed: () => _handleKeypadTap(text),
        style: ElevatedButton.styleFrom(
          backgroundColor: hexToColor(buttonBlue),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          minimumSize:
          isLarge ? const Size(double.infinity, 60) : const Size(90, 60),
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        child:
        text == '<' ? const Icon(Icons.arrow_back, size: 24, color: Colors.white) : Text(text),
      ),
    );
  }

  Widget _buildKeypad() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildKeypadButton('1'),
            _buildKeypadButton('2'),
            _buildKeypadButton('3'),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildKeypadButton('4'),
            _buildKeypadButton('5'),
            _buildKeypadButton('6'),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildKeypadButton('7'),
            _buildKeypadButton('8'),
            _buildKeypadButton('9'),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildKeypadButton('<'),
            _buildKeypadButton('0'),
            _buildKeypadButton('C'), // 'C' for clear
          ],
        ),
      ],
    );
  }

  void _updatePin() {
    final newPin = _pinControllers.map((c) => c.text).join();
    setState(() {
      _pin = newPin;
    });
  }

  Future<void> _updatePrintJobStatus(int printJobId, String newStatus, {required String currentStatus}) async {
    // Defines the hierarchical order of statuses.
    const statusOrder = ['Received', 'Processing', 'Sent To Printer', 'Completed'];

    final newStatusIndex = statusOrder.indexOf(newStatus);
    final currentStatusIndex = statusOrder.indexOf(currentStatus);

    // Check for unknown statuses.
    if (newStatusIndex == -1 || currentStatusIndex == -1) {
      debugPrint("Warning: Attempting to update with an unknown status. Current: '$currentStatus', New: '$newStatus'. Allowing update.");
    } else if (newStatusIndex <= currentStatusIndex) {
      // This is the core logic: prevent updating to a status that is earlier in the hierarchy or the same.
      debugPrint(
          "Blocked status regression for job $printJobId: Cannot move from '$currentStatus' to '$newStatus'.");
      return; // Stop the function to prevent the invalid update.
    }

    try {
      await _printJobService.updatePrintJobStatus(printJobId, newStatus);
      debugPrint("Status for job $printJobId successfully updated to: '$newStatus'");
    } catch (e, s) {
      await Sentry.captureException(
        e,
        stackTrace: s,
      );
      debugPrint("Failed to update print job status for $printJobId: $e");
    }
  }

  Future<void> _updatePrintCount(int printJobId) async {
    try {
      await _printCountService.updatePrintCount(printJobId);
      debugPrint("Status for print count $printJobId successfully updated");
    } catch (e, s) {
      await Sentry.captureException(
        e,
        stackTrace: s,
      );
      debugPrint("Failed to update print count for $printJobId: $e");
    }
  }

  Future<bool> _runGhostscriptCommand(String inputPath, String outputPath, int timeoutSeconds, {required int startPage, required int endPage}) async {
    final String execDir = p.dirname(Platform.resolvedExecutable);
    final String gstPath = p.join(execDir, 'gswin64c.exe');

    final args = [
      '-dBATCH',
      '-dNOPAUSE',
      '-dSAFER',
      '-sDEVICE=pdfimage24',
      '-r300',
      '-dTextAlphaBits=4',
      '-dGraphicsAlphaBits=4',
      '-dDownsampleColorImages=false',
      '-dDownsampleGrayImages=false',
      '-dDownsampleMonoImages=false',
      '-dFirstPage=$startPage',
      '-dLastPage=$endPage',
      '-sOutputFile=$outputPath',
      inputPath
    ];

    try {
      final process = await Process.start(gstPath, args);

      if (timeoutSeconds > 0) {
        final exitCodeFuture = process.exitCode;
        final timeoutFuture = Future.delayed(Duration(seconds: timeoutSeconds), () => null);
        final result = await Future.any([exitCodeFuture, timeoutFuture]);

        if (result == null) {
          process.kill();
          return false;
        } else {
          return (result as int) == 0;
        }
      } else {
        final exitCode = await process.exitCode;
        return exitCode == 0;
      }

    } catch (e) {
      debugPrint("Exception running GS: $e");
      return false;
    }
  }

  Future<void> _processAndPrintStreamed(
      File originalFile,
      String printerName,
      PrintJob job
      ) async {
    setState(() {
      _isGsProcessing = true;
      _gsProgress = 0.0;
    });

    final jobId = job.id;
    final startPage = job.pagesStart;
    final endPage = job.pageEnd;
    const int batchSize = 10;
    int totalPages = endPage - startPage + 1;
    int numberOfBatches = (totalPages / batchSize).ceil();

    try {
      debugPrint("Starting Pagination Print: $totalPages pages in $numberOfBatches batches.");

      for (int i = 0; i < numberOfBatches; i++) {
        int currentBatchStart = startPage + (i * batchSize);
        int currentBatchEnd = currentBatchStart + batchSize - 1;
        if (currentBatchEnd > endPage) {
          currentBatchEnd = endPage;
        }
        double progress = (i + 1) / numberOfBatches;
        setState(() => _gsProgress = progress);

        debugPrint("Processing Batch ${i + 1}/$numberOfBatches (Page $currentBatchStart - $currentBatchEnd)...");

        final dir = await getTemporaryDirectory();
        final batchOutputPath = '${dir.path}${Platform.pathSeparator}batch_${i + 1}_${DateTime.now().millisecondsSinceEpoch}.pdf';

        if (File(batchOutputPath).existsSync()) File(batchOutputPath).deleteSync();

        bool success = await _runGhostscriptCommand(
            originalFile.path,
            batchOutputPath,
            20,
            startPage: currentBatchStart,
            endPage: currentBatchEnd
        );

        if (success && File(batchOutputPath).existsSync()) {
          debugPrint("Batch ${i + 1} Success. Sending to printer...");

          await _printFile(printerName,File(batchOutputPath), job);
          await Future.delayed(const Duration(seconds: 1));
          try { File(batchOutputPath).delete(); } catch (_) {}
        } else {
          debugPrint("Batch ${i + 1} Failed/Timeout. Fallback to Sumatra per page...");
          await _printWithSumatra(originalFile.path, printerName, currentBatchStart, currentBatchEnd);
          await Future.delayed(const Duration(milliseconds: 200));
        }
        if (i == 0) {
          Future.delayed(Duration(seconds: totalPages), () async {
            try {
              debugPrint("Timer $totalPages s finished. Updating job $jobId to 'Completed'...");
              await _updatePrintJobStatus(jobId, 'Completed', currentStatus: 'Sent To Printer');
            } catch (e) {
              debugPrint("Background Status Update Error: $e");
            }
          });
        }

        if (i == numberOfBatches - 1) {
            debugPrint("Last batch sent. Updating status to 'Sent To Printer'...");
            await _updatePrintJobStatus(
                jobId, 'Sent To Printer', currentStatus: 'Processing');
        }
      }

      setState(() => _gsProgress = 1.0);
      debugPrint("All batches processed successfully.");
    } catch (e) {
      debugPrint("Pagination Print Error: $e");
      rethrow;
    } finally {
      if (mounted) setState(() => _isGsProcessing = false);
    }
  }

  Future<bool> _printWithSumatra(String filePath, String printerName, int startPage, int endPage) async {
    debugPrint("Attempting fallback print with SumatraPDF...");

    String pageRange = (startPage == endPage) ? "$startPage" : "$startPage-$endPage";

    final List<String> args = [
      '-print-to', printerName,
      '-print-settings', pageRange,
      '-silent',
      filePath
    ];

    try {
      final String execDir = p.dirname(Platform.resolvedExecutable);
      final exePath = p.join(execDir, 'SumatraPDF.exe');
      final result = await Process.run(
        exePath,
        args,
        workingDirectory: execDir,
      );

      if (result.exitCode == 0) {
        debugPrint("SumatraPDF printed successfully.");
        return true;
      } else {
        debugPrint("SumatraPDF failed with exit code: $exitCode");
        return false;
      }
    } catch (e) {
      debugPrint("Exception running SumatraPDF: $e");
      return false;
    }
  }


  Future<void> _submitPrintJob() async {
    final prefs = await SharedPreferences.getInstance();
    final bwPrinterName = prefs.getString(printerNameKey) ?? "";
    final colorPrinterName = prefs.getString(printerColorNameKey);

    if (bwPrinterName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_userRole != 'darkstore'
              ? 'Please to setting, and set the b/w printer'
              : 'Please to setting, and set the default print.'),
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      PrintJobResponse response = await _printJobService.getPrintJobByCode(_pin, false);

      if (_userRole != 'darkstore') {
        final bool needsColorPrinter = response.printFiles.any((job) => job.color == true);
        if (needsColorPrinter && (colorPrinterName == null || colorPrinterName.isEmpty)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please to setting, and set the color printer'),
            ),
          );
          setState(() => _isLoading = false); // Hentikan loading
          return; // Hentikan eksekusi
        }
      }

      if (response.printFiles.isNotEmpty) {
        if (response.isUseInvoice) {
          String invoicePrinter = bwPrinterName;
          if (_userRole != null && _userRole != 'darkstore' && response.printFiles.first.color == true) {
            invoicePrinter = colorPrinterName!;
          }
          await _printInvoiceFromHtml(invoicePrinter, response);
        }

        // Menggunakan loop untuk memproses setiap pekerjaan cetak satu per satu
        for (int i = 0; i < response.printFiles.length; i++) {
          final job = response.printFiles[i];
          File? downloadedFile;

          String selectedPrinter;
          if (_userRole != 'darkstore' && job.color == true) {
            selectedPrinter = colorPrinterName!;
          } else {
            selectedPrinter = bwPrinterName;
          }

          try {
            await _updatePrintJobStatus(job.id, 'Processing', currentStatus: job.status);

            await _updatePrintCount(job.id);

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Downloading file ${i + 1} of ${response.printFiles.length}...')),
            );

            final String filenameToDownload = Uri
                .parse(job.filename)
                .pathSegments
                .last;
            downloadedFile = await _printJobService.downloadFile(
              job.filename,
              filenameToDownload,
            );

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Download complete. Printing file ${i + 1} of ${response.printFiles.length}...')),
            );

            if (Platform.isWindows) {
              await _processAndPrintStreamed(downloadedFile, selectedPrinter, job);
            } else {
              await _printFile(selectedPrinter, downloadedFile, job);
            }
          } catch (e) {
            debugPrint("Error processing job ${i + 1}: $e");
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to process job ${i + 1}: ${e.toString()}')),
            );
            continue;
          } finally {
            // Hapus file sementara setelah setiap pekerjaan selesai atau gagal
            if (downloadedFile != null && await downloadedFile.exists()) {
              _safeDeleteFile(downloadedFile);
              // await downloadedFile.delete();
              // debugPrint("Temporary file deleted for job ${i + 1}.");
            }
          }
        }

        if (response.isUseSeparator) {
          await _printSeparatorFromAsset(bwPrinterName);
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No print jobs found.')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
      if (e.toString().contains("Unauthorized")) {
        AuthService().deleteToken();
        Navigator.of(context).pushReplacementNamed('/login');
      }
    } finally {
      setState(() {
        _isLoading = false;
        _pin = '';
      });
    }
  }

  // Future<String> _checkPrinterStatus(String printerName) async {
  //   try {
  //     final String status = await platform.invokeMethod('getPrinterStatus', {
  //       'printerName': printerName,
  //     });
  //     return status;
  //   } on PlatformException catch (e) {
  //     print('Gagal mendapatkan status printer: ${e.message}');
  //     return 'Error: ${e.message}';
  //   }
  // }

  Future<void> _printInvoiceFromHtml(String printerName, PrintJobResponse jobResponse) async {
    if (jobResponse.userRole != "online") {
      String colorStatus = '';
      bool? color = jobResponse.printFiles.first.color;
      if (jobResponse.printFiles.length == 1) {
        if (color == true) {
          colorStatus = 'color';
        } else if (color == false) {
          colorStatus = 'bw';
        }
      }

      String invoiceUrl;
      if (jobResponse.userRole == 'darkstore') {
        String path = "PrintInvoicesNanaNew";
        invoiceUrl = '$baseUrl/$path/${jobResponse
            .transactionId}/${jobResponse.companyId}/$colorStatus';
      } else {
        invoiceUrl =
        '$baseUrl/PrintInvoices/${jobResponse.transactionId}/$colorStatus';
      }

      await _printInvoiceForWindows(printerName, invoiceUrl, color);
    }
  }

  void _showSuccessDialog(String message) {
    debugPrint('*** Attempting to show success dialog ***');

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Settings Saved'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(message),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                debugPrint('Dialog closed.');
              },
            ),
          ],
        );
      },
    ).then((_) {
      debugPrint('showDialog Future resolved (Dialog should have closed)');
    });
    debugPrint('*** showDialog call complete ***');
  }

  void _goToSettings() async {
    debugPrint('--- _goToSettings STARTED ---');
    final currentContext = context;
    final result = await Navigator.push(
      currentContext,
      MaterialPageRoute(builder: (currentContext) => const SettingsPage()),
    );

    if (!mounted) {
      return;
    }

    if (result != null && result is String) {
      _showSuccessDialog(result);
    }
  }

  Widget _buildUserInfoHeader() {
    final bool showDivider = _name.isNotEmpty || _email.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _email,
                style: TextStyle(fontSize: 14, color: Colors.grey[700]),
              ),
            ],
          ),
        ),
        if (showDivider)
          const Divider(height: 1, thickness: 1),
      ],
    );
  }


  Future<void> _printInvoiceForWindows(String printerName, String invoiceUrl, bool? color) async {
    try {
      final htmlContent = await _printJobService.fetchInvoiceHtml(
          invoiceUrl);

      final tempDir = await Directory.systemTemp.createTemp();
      final inputHtml = File(p.join(tempDir.path, 'input.html'));
      await inputHtml.writeAsString(htmlContent);

      final outputPdf = File(p.join(tempDir.path, 'output.pdf'));

      final String execDir = p.dirname(Platform.resolvedExecutable);
      final exePath = p.join(execDir, 'wkhtmltopdf.exe');

      final result = await Process.run(
        exePath,
        [inputHtml.path, outputPdf.path],
        workingDirectory: execDir,
      );
      if (result.exitCode == 0) {
        await _printInvoiceFile(printerName, outputPdf, color);
      }
    } catch (e, s) {
      await Sentry.captureException(
        e,
        stackTrace: s,
      );
      debugPrint("Failed to print invoice: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to print invoice: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<Uint8List> generateInvoicePdf(String path, int transId, int companyId, String color) async {
    debugPrint('generateInvoicePdf: $path | transId: $transId | companyId: $companyId | color: $color');
    final response = await http.post(
      Uri.parse("$baseUrl/api/$path"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "trans_id": transId,
        "company_id": companyId,
        "color": color
      }),
    );

    if (response.statusCode == 200) {
      return response.bodyBytes;
    } else {
      throw Exception("PDF generation failed");
    }
  }

  Future<Uint8List> fetchInvoicePdf(String url) async {
    int maxRetries = 3;
    int attempt = 0;

    while (attempt < maxRetries) {
      attempt++;
      try {
        debugPrint("📄 Request PDF Invoice (Percobaan $attempt/$maxRetries)...");
        final response = await http.post(
          Uri.parse("$baseUrl/api/generate-pdf"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"url": url}),
        );
        if (response.statusCode == 200) {
          if (response.bodyBytes.isEmpty) {
            throw Exception("Server merespon 200 OK tapi data PDF kosong (0 bytes).");
          }
          return response.bodyBytes;
        } else {
          throw Exception("Gagal download PDF. Status Code: ${response.statusCode}");
        }

      } catch (e) {
        debugPrint("⚠️ Gagal pada percobaan ke-$attempt: $e");

        if (attempt >= maxRetries) {
          throw Exception("Gagal print invoice setelah $maxRetries kali percobaan. Cek koneksi server.");
        }

        await Future.delayed(const Duration(seconds: 2));
      }
    }
    throw Exception("Unexpected Error fetching PDF");
  }

  Future<File> rasterizePdf(String url, String filename, int pageStart, int pageEnd) async {
    final response = await http.post(
      Uri.parse("$baseUrl/api/rasterize-pdf"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "pdf_url": url,
        "page_start": pageStart,
        "page_end": pageEnd
      }),
    );

    if (response.statusCode == 200) {
      final dir = await getTemporaryDirectory();
      final savePath = '${dir.path}/$filename';
      final file = File(savePath);
      await file.writeAsBytes(response.bodyBytes);

      return file;
    } else {
      throw Exception("PDF generation failed");
    }
  }


  Future<void> _printInvoiceFile(String printerName, File file, bool? color) async {
    try {
      final result = await platform.invokeMethod(
        'printPDF',
        {
          'filePath': file.path,
          'printerName': printerName,
          'printJobId': -1, // Dummy ID for invoice
          'color': false,
          'doubleSided': false,
          'copies': 1,
          'pagesStart': 1,
          'pageEnd': 2,
          'pageOrientation': 'auto',
        },
      );

      if (result == 'success') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invoice printed successfully.'),
            backgroundColor: Colors.green,
          ),
        );
      } else if (result == 'Sent To Printer') {
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to print invoice: $result'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } on PlatformException catch (e, s) {
      debugPrint("Failed to print invoice: '${e.message}'.");
      await Sentry.captureException(
        e,
        stackTrace: s,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Print Error: ${e.message}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _printSeparatorFromAsset(String printerName) async {
    File? tempFile;
    try {
      final byteData = await rootBundle.load('assets/pdf/separator.pdf');
      final tempDir = await Directory.systemTemp.createTemp();
      tempFile = File(p.join(tempDir.path, 'separator.pdf'));
      await tempFile.writeAsBytes(byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ));
        await platform.invokeMethod(
          'printPDF',
          {
            'filePath': tempFile.path,
            'printerName': printerName,
            'printJobId': -2, // Using a dummy ID for a separator print
            'color': true,
            'doubleSided': true,
            'copies': 1,
            'pagesStart': 1, // A value of 0 often signifies printing all pages
            'pageEnd': 2,
            'pageOrientation': 'auto',
          },
        );

    } catch (e, s) {
      await Sentry.captureException(
        e,
        stackTrace: s,
      );
      debugPrint("An unexpected error occurred: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('An unexpected error occurred: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      // 4. Clean up by deleting the temporary file.
      if (tempFile != null && await tempFile.exists()) {
        await tempFile.delete();
        debugPrint("Temporary separator file deleted.");
      }
    }
  }

  Future<void> _printFile(String printerName, File file, PrintJob job) async {
      try {
        String rawPath = file.path; // Path asli dari temp
        String fixedPath = p.normalize(rawPath).replaceAll('/', '\\'); // Paksa format Windows

        debugPrint("Fixing Path: $rawPath -> $fixedPath");
        final String result = await platform.invokeMethod(
          'printPDF',
          {
            'printJobId': job.id,
            'filePath': fixedPath,
            'printerName': printerName,
            'color': job.color,
            'doubleSided': job.doubleSided,
            'pagesStart': job.pagesStart,
            'pageEnd': job.pageEnd,
            'copies': job.copies,
            'pageOrientation': job.pageOrientation,
          },
        );
        if (result == 'success') {
          debugPrint('Cetak berhasil!');
        } else if (result == 'Sent To Printer') {
          debugPrint('Pekerjaan cetak sudah dikirim ke printer.');
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed print: $result'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } on PlatformException catch (e, s) {
        debugPrint("Failed to print: '${e.message}'.");
        await Sentry.captureException(
          e,
          stackTrace: s,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Print Error: ${e.message}'),
            backgroundColor: Colors.red,
          ),
        );
      }
  }

  Future<void> _safeDeleteFile(File file) async {
    const int maxRetries = 10; // Coba sampai 10x

    for (int i = 0; i < maxRetries; i++) {
      try {
        if (await file.exists()) {
          await file.delete();
          debugPrint("File berhasil dihapus: ${file.path}");
        }
        return; // Keluar jika sukses atau file sudah tidak ada
      } catch (e) {
        debugPrint("Gagal hapus file (percobaan ${i + 1}/$maxRetries): Sedang dikunci OS...");
        // Tunggu 1 detik sebelum coba lagi
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    debugPrint("Menyerah menghapus file. File akan dibersihkan oleh OS nanti.");
  }

  Future<void> _logout() async {
    await AuthService().deleteToken();
    Navigator.of(context).pushReplacementNamed('/login');
  }

  Widget _buildKeypadSection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Enter Code',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        _buildPinDisplay(),
        const SizedBox(height: 24),
        _buildKeypad(),
        const SizedBox(height: 24),
        _isLoading
            ? const CircularProgressIndicator()
            : SizedBox(
          width: 300,
          child: ElevatedButton(
            onPressed: _pin.length == 4 ? _submitPrintJob : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _pin.length == 4 ? Colors.green : Colors.grey,
              minimumSize: const Size(double.infinity, 50),
            ),
            child: const Text(
              'Print',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBookshopBody() {
    if (_isLoading) {
      return ListView.builder(
        padding: const EdgeInsets.all(16.0),
        itemCount: _limit,
        itemBuilder: (context, index) {
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 8.0),
            child: Shimmer.fromColors(
              baseColor: Colors.grey[300]!,
              highlightColor: Colors.grey[100]!,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(width: double.infinity, height: 16.0, color: Colors.white),
                    const SizedBox(height: 8),
                    Container(width: 150.0, height: 16.0, color: Colors.white),
                    const SizedBox(height: 4),
                    Container(width: 100.0, height: 16.0, color: Colors.white),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }

    if (_bookshopOrders.isEmpty) {
      return const Center(child: Text("There are no orders at this time."));
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16.0),
      itemCount: _bookshopOrders.length + (_isLoadMoreLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _bookshopOrders.length) {
          return Shimmer.fromColors(
            baseColor: Colors.grey[300]!,
            highlightColor: Colors.grey[100]!,
            child: Card(
              margin: const EdgeInsets.symmetric(vertical: 8.0),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Container(height: 100, color: Colors.white),
              ),
            ),
          );
        }
        final job = _bookshopOrders[index];
        String statusText = '';
        Color statusColor = Colors.grey;
        bool showButton = false;
        String buttonText = '';
        Color buttonColor = Colors.grey;
        IconData? buttonIcon;
        final currency = job.currency ?? 'SAR';
        final number = job.invoiceNumber == null ? '#0' : "#${job.invoiceNumber}";
        final colorText = job.color == true ? 'Color' : 'B&W';
        final sideText = job.doubleSided ? 'Double' : 'Single';
        final priceText = job.price != null ? '${job.price} $currency' : '-';

        if (job.transactionId == null) {
          statusText = "Waiting for customers input";
          statusColor = Colors.grey;
        } else {
          showButton = true;
          if (job.status == "Queued") {
            buttonText = 'Pay';
            buttonColor = Colors.green;
            buttonIcon = Icons.attach_money;
            statusText = "Need Approval";
            statusColor = Colors.yellow[700]!;
          } else if (job.status != "Queued" && (job.count == 0 || job.count == null)) {
            buttonText = 'Print';
            buttonColor = Colors.blue;
            buttonIcon = Icons.print;
            statusText = "New";
            statusColor = Colors.green;
          } else if (job.status != "Queued" && job.count != null && job.count! > 0) {
            buttonText = 'Reprint';
            buttonColor = Colors.blue;
            buttonIcon = Icons.print_outlined;
            statusText = 'Print ${job.count!}';
            statusColor = Colors.blue;
          } else {
            showButton = false;
          }
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth > 600;

            if (isDesktop) {
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 8.0),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              number,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Icon(Icons.phone, size: 18, color: Colors.grey),
                                const SizedBox(width: 8),
                                Text(job.phone ?? '-'),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.palette, size: 18, color: Colors.grey),
                                const SizedBox(width: 8),
                                Text('Type: $colorText'),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.copy, size: 18, color: Colors.grey),
                                const SizedBox(width: 8),
                                Text('Sides: $sideText'),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.description, size: 18, color: Colors.grey),
                                const SizedBox(width: 8),
                                Text('Pages: ${job.totalPages}'),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.copy, size: 18, color: Colors.grey),
                                const SizedBox(width: 8),
                                Text('Copies: ${job.copies ?? '-'}'),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.description, size: 18, color: Colors.grey),
                                const SizedBox(width: 8),
                                Text('Total Pages: ${job.totalPages * (job.copies ?? 1)}'),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.attach_money, size: 18, color: Colors.grey),
                                const SizedBox(width: 8),
                                Text('Price: $priceText'),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.schedule, size: 18, color: Colors.grey),
                                const SizedBox(width: 8),
                                Text(_formatCreatedAt(job.createdAt)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 6.0),
                            decoration: BoxDecoration(
                              color: statusColor,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              statusText,
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (showButton)
                            ElevatedButton.icon(
                              onPressed: () {
                                debugPrint('Action for Job ${job.id}: $buttonText');
                                _handleButtonAction(job, buttonText);
                              },
                              icon: Icon(buttonIcon),
                              label: Text(buttonText),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: buttonColor,
                                foregroundColor: Colors.white,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            } else {
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 8.0),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '#${job.id}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                            decoration: BoxDecoration(
                              color: statusColor,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              job.status,
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.phone, size: 18, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text(job.phone ?? '-'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.palette, size: 18, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text('Type: $colorText'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.copy, size: 18, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text('Sides: $sideText'),
                        ],
                      ),

                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.description, size: 18, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text('Pages: ${job.totalPages}'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.copy, size: 18, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text('Copies: ${job.copies ?? '-'}'),
                        ],
                      ),
                      Row(
                        children: [
                          const Icon(Icons.description, size: 18, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text('Total Pages: ${job.totalPages * (job.copies ?? 1)}'),
                        ],
                      ),
                      Row(
                        children: [
                          const Icon(Icons.attach_money, size: 18, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text('Price: $priceText'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.schedule, size: 18, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text(_formatCreatedAt(job.createdAt)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerRight,
                        child: showButton
                            ? ElevatedButton.icon(
                          onPressed: () {
                            debugPrint('Action for Job ${job.id}: $buttonText');
                            _handleButtonAction(job, buttonText);
                          },
                          icon: Icon(buttonIcon),
                          label: Text(buttonText),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: buttonColor,
                            foregroundColor: Colors.white,
                          ),
                        )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              );
            }
          },
        );
      },
    );
  }

  String _formatCreatedAt(String? createdAt) {
    String formattedDate = '-';

    if (createdAt != null) {
      try {
        final DateTime dateTime = DateTime.parse(createdAt);
        final day = dateTime.day.toString().padLeft(2, '0');
        final month = dateTime.month.toString().padLeft(2, '0');
        final hour = dateTime.hour.toString().padLeft(2, '0');
        final minute = dateTime.minute.toString().padLeft(2, '0');
        formattedDate = '$day/$month $hour:$minute';
      } catch (e) {
        formattedDate = '-';
      }
    }

    return formattedDate;
  }

  void _handleButtonAction(PrintJob job, String buttonText) {
    if (buttonText == 'Pay' && job.code != null) {
      _showCashApproveDialog(job.id, job.code!);
    } else {
      _showPrintDialog(job);
    }
  }

  Future<void> _showPrintDialog(PrintJob job) async {
    // State: 1: Loading, 2: Success/List, 3: Error
    int currentDialogStep = 1;
    PrintJobResponse? printJobResponse;
    String errorMessage = '';

    bool isApiCallTriggered = false;

    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        Future<void> fetchPrintJobDetails(StateSetter setStateInDialog) async {
          setStateInDialog(() {
            currentDialogStep = 1; // Set ke Loading
            errorMessage = '';
          });

          try {
            if (job.code == null) {
              throw Exception("Print code not found");
            }

            final response = await _printJobService.getPrintJobByCode(job.code!, true);
            printJobResponse = response;

            setStateInDialog(() {
              currentDialogStep = 2; // Set ke List/Success
            });
          } catch (e) {
            String errorMsg = e.toString().contains("404")
                ? "Print Job not found"
                : "Failed: ${e.toString()}";

            setStateInDialog(() {
              currentDialogStep = 3; // Set ke Error
              errorMessage = errorMsg;
            });
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMsg)));
            }
          }
        }

        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setStateInDialog) {

            if (!isApiCallTriggered) {
              isApiCallTriggered = true;
              fetchPrintJobDetails(setStateInDialog);
            }
            Widget buildContent() {
              if (currentDialogStep == 1) {
                return const SizedBox(
                  height: 150,
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              if (currentDialogStep == 2 && printJobResponse != null) {

                final invoiceStatusText = printJobResponse!.isUseInvoice ? 'Yes' : 'No';
                final separatorStatusText = printJobResponse!.isUseSeparator ? 'Yes' : 'No';

                return SizedBox(
                  width: double.maxFinite,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const SizedBox(
                            width: 105.0,
                            child: Text('Print Invoice'),
                          ),
                          Text(
                            invoiceStatusText,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const SizedBox(
                            width: 105.0,
                            child: Text('Print Separator'),
                          ),
                          Text(
                            separatorStatusText,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),

                      const Divider(height: 20),

                      ListView.builder(
                        shrinkWrap: true,
                        itemCount: printJobResponse!.printFiles.length,
                        itemBuilder: (context, index) {
                          final file = printJobResponse!.printFiles[index];
                          final currency = file.currency ?? 'SAR';
                          final colorText = file.color == true ? 'Color' : 'B&W';
                          final doubleSideText = file.doubleSided ? 'Double' : 'Single';
                          final pagesRange = '${file.pagesStart} - ${file.pageEnd}';
                          final priceText = file.price != null ? '${file.price} $currency' : '-';

                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${index + 1}. ID: #${file.invoiceNumber}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16.0,
                                  ),
                                ),
                                const SizedBox(height: 4.0),
                                Wrap(
                                  spacing: 8.0,
                                  runSpacing: 4.0,
                                  children: [
                                    _buildRichTextItem('Type:', colorText),
                                    _buildRichTextItem('Side:', doubleSideText),
                                    _buildRichTextItem('Pages:', '${file.totalPages}'),
                                    _buildRichTextItem('Page Range:', pagesRange),
                                    _buildRichTextItem('Copies:', '${file.copies ?? '-'}'),
                                    _buildRichTextItem('Total Pages:', '${file.totalPages * (file.copies ?? 1)}'),
                                    _buildRichTextItem('Orientation:', file.pageOrientation ?? '-'),
                                    _buildRichTextItem('Price:', priceText),
                                    _buildRichTextItem('Print Count:', '${file.count ?? '-'}'),
                                    _buildRichTextItem('Phone:', '${file.phone ?? '-'}'),
                                    _buildRichTextItem('Trans. ID:', '${file.transactionId ?? '-'}'),
                                    _buildRichTextItem('Created:', _formatCreatedAt(file.createdAt)),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                );
              }
              return SingleChildScrollView(
                child: ListBody(
                  children: <Widget>[
                    Text(errorMessage, style: const TextStyle(color: Colors.red)),
                    const SizedBox(height: 10),
                    const Text('Print job not found or already expired'),
                  ],
                ),
              );
            }
            return AlertDialog(
              title: Text('Print'),
              content: buildContent(),
              actions: <Widget>[
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
                if (currentDialogStep == 2)
                  ElevatedButton(
                    child: const Text('Print'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      if (job.code != null) {
                        if (mounted) {
                          setState(() {
                            _pin = job.code!;
                          });
                          _submitPrintJob();
                        }
                      } else {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Error: Print code does not valid.')),
                          );
                        }
                      }
                    },
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildRichTextItem(String label, String value) {
    // if (value == '-') return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(
            fontSize: 14.0,
            color: Colors.black,
          ),
          children: <TextSpan>[
            // Label dalam bold
            TextSpan(
              text: '$label ',
            ),
            TextSpan(
              text: '$value',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const TextSpan(text: ' |'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_userRole != null &&
        ['shopowner', 'shopmanager', 'cashier', 'coffeshop'].contains(_userRole)) {
      return Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Text("Hlaprint"),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _loadOrders(isRefresh: true),
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _goToSettings,
            ),
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: _logout,
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_isLoading)
              Padding(
                padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _email,
                      style: TextStyle(fontSize: 14, color: Colors.grey[700]),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Role: ${_userRole ?? '-'}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
            if (!_isLoading)
              const Divider(height: 1, thickness: 1),
            Expanded(
              child: _buildBookshopBody(),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Text("Hlaprint"),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _goToSettings,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final centeredKeypad = Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: _buildKeypadSection(),
                ),
              ),
            ),
          );
          final userHeader = _buildUserInfoHeader();
          return Column(
            children: [
              Expanded(
                child: constraints.maxWidth > 600
                    ? Row(children: [
                  Expanded(
                    flex: 1,
                    child: Container(
                      color: hexToColor(buttonBlue),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20.0),
                          child: Image.asset(
                            'assets/images/printer.jpeg',
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const VerticalDivider(thickness: 1, width: 1),
                  Expanded(
                    flex: 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        userHeader,
                        const SizedBox(height: 16),
                        centeredKeypad,
                      ],
                    ),
                  ),
                ])
                    : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    userHeader,
                    const SizedBox(height: 16),
                    centeredKeypad,
                  ],
                ),
              ),

              if (_isGsProcessing) ...[
                const Divider(height: 1),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  color: Colors.white,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        "Processing Print Job... ${(_gsProgress * 100).toInt()}%",
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: Colors.black),
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: _gsProgress,
                        backgroundColor: Colors.grey[300],
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}