import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hlaprint/colors.dart';
import 'package:hlaprint/models/print_job_model.dart';
import 'package:hlaprint/screens/settings_page.dart';
import 'package:hlaprint/services/auth_service.dart';
import 'package:hlaprint/services/cash_approve_service.dart';
import 'package:hlaprint/services/print_count_service.dart';
import 'package:hlaprint/services/print_job_service.dart';
import 'package:hlaprint/services/order_list_service.dart';
import 'package:hlaprint/services/user_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sentry/sentry.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:hlaprint/constants.dart';
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
  final UserService _userService = UserService();
  final Map<int, int> _jobBatchTracker = {};
  final Set<int> _completedJobs = {};
  final List<Timer> _cleanupTimers = [];
  String _bwPrinterName = '';
  String _colorPrinterName = '';
  bool _isBwPrinterOnline = false;
  bool _isColorPrinterOnline = false;
  bool _isSmartCopiesActive = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  bool _hasCheckedLoginSave = false;
  bool _isLoading = false;
  String _pin = '';
  String _name = '';
  String _email = '';
  bool _isSkipCashier = false;
  String? _userRole;
  List<PrintJob> _bookshopOrders = [];
  Timer? _autoRefreshTimer;
  Timer? _printerStatusTimer;
  int _secretTapCount = 0;
  DateTime? _lastTapTime;

  final _scrollController = ScrollController();
  ScaffoldMessengerState? _scaffoldMessenger;
  int _currentPage = 1;
  final int _limit = 8;
  bool _isLoadMoreLoading = false;
  bool _hasNextPage = true;
  bool _isGsProcessing = false;
  double _gsProgress = 0.0;
  int _currentCopyProcessing = 1;
  int _totalCopiesProcessing = 1;
  int _currentJobIndex = 1;
  int _totalJobs = 1;

  @override
  void initState() {
    super.initState();
    _loadCachedUserData();
    _loadUserRoleAndData();
    _startAutoRefresh();
    _loadPrinterPreferences();
    _startPrinterStatusTimer();
    _scrollController.addListener(_onScroll);

    for (var controller in _pinControllers) {
      controller.addListener(_updatePin);
    }

    platform.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPrintJobCompleted':
          final args = call.arguments as Map;
          final int printJobId = args['printJobId'];

          _handleJobCompletion(printJobId);
          break;

        case 'onPrintJobFailed':
          final args = call.arguments as Map;
          final int printJobId = args['printJobId'];
          final String reason = args['error'] ?? "Unknown";

          debugPrint("DART: Job #$printJobId FAILED/CANCELLED. Reason: $reason");

          if (_jobBatchTracker.containsKey(printJobId)) {
            _jobBatchTracker.remove(printJobId);
          }
          break;
        case 'onPrinterStatus':
          String status = call.arguments as String;
          debugPrint("PRINTER STATUS: $status");
          break;

        default:
          debugPrint('Unknown method ${call.method}');
      }
    });

  }

  void _startPrinterStatusTimer() {
    _printerStatusTimer?.cancel();
    _printerStatusTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_isLoading || _isGsProcessing || _isDownloading) {
        return;
      }
      _loadPrinterPreferences();
    });
  }

  void _stopPrinterStatusTimer() {
    _printerStatusTimer?.cancel();
    _printerStatusTimer = null;

    if (mounted) {
      setState(() {
        _isBwPrinterOnline = true;
        _isColorPrinterOnline = true;
      });
    }
  }

  // Fungsi untuk mengecek koneksi langsung ke IP Printer (Khusus Android/Jaringan)
  Future<bool> _checkNetworkPrinterOnline(String ip) async {
    if (ip.isEmpty) return false;
    try {
      // Port 9100 adalah port standar RAW/JetDirect untuk hampir semua printer jaringan/thermal
      final socket = await Socket.connect(ip, 9100, timeout: const Duration(seconds: 2));
      socket.destroy(); // Langsung tutup jika berhasil connect
      return true;
    } catch (e) {
      // Jika timeout atau rute tidak ditemukan, berarti offline
      return false;
    }
  }

  // Fungsi untuk mengecek status printer di MacOS menggunakan CUPS (lpstat)
  Future<bool> _checkMacPrinterOnline(String printerName) async {
    if (printerName.isEmpty) return false;
    try {
      final result = await Process.run('lpstat', ['-p', printerName]);
      if (result.exitCode == 0) {
        final output = result.stdout.toString().toLowerCase();
        // Jika antrean CUPS melaporkan printer disabled, paused, atau rejecting, anggap offline (merah)
        if (output.contains('disabled') || output.contains('paused') || output.contains('rejecting')) {
          return false;
        }
        // Jika "idle" atau "processing", berarti printer online (hijau)
        return true;
      }
      return false;
    } catch (e) {
      debugPrint("MacOS printer status error: $e");
      return false;
    }
  }

  void _handleJobCompletion(int printJobId) async {
    debugPrint("DART LOG: Memproses sinyal Completed untuk Job #$printJobId");
    bool readyToComplete = true;

    if (_jobBatchTracker.containsKey(printJobId)) {
      _jobBatchTracker[printJobId] = _jobBatchTracker[printJobId]! - 1;
      final int remaining = _jobBatchTracker[printJobId]!;

      debugPrint("TRACKER: Job #$printJobId sisa antrian: $remaining");

      if (remaining > 0) {
        readyToComplete = false;
      } else {
        _jobBatchTracker.remove(printJobId);
      }
    }

    if (readyToComplete) {
      _completedJobs.add(printJobId);
      final timer = Timer(const Duration(minutes: 2), () {
        _completedJobs.remove(printJobId);
      });
      _cleanupTimers.add(timer);
      try {
        debugPrint("✅ FINAL: Semua batch selesai. Update status Completed ke Server...");
        await _printJobService.updatePrintJobStatus(printJobId, 'Completed');
      } catch (e) {
        debugPrint("DART ERROR: Gagal update status: $e");
      }
    }
  }

  Future<void> _loadPrinterPreferences() async {
    final prefs = await SharedPreferences.getInstance();

    if (Platform.isAndroid) {
      String ip = prefs.getString(ipPrinterKey) ?? '';
      bool isOnline = false;

      if (ip.isNotEmpty) {
        isOnline = await _checkNetworkPrinterOnline(ip);
      }

      if (mounted) {
        if (_bwPrinterName != ip || _isBwPrinterOnline != isOnline) {
          setState(() {
            _bwPrinterName = ip; // Gunakan IP sebagai nama di UI
            _isBwPrinterOnline = isOnline;
          });
        }
      }
      return;
    }

    String newBwName = prefs.getString(printerNameKey) ?? '';
    String newColorName = prefs.getString(printerColorNameKey) ?? '';

    if (Platform.isMacOS) {
      bool bwStatus = false;
      bool colorStatus = false;

      if (newBwName.isNotEmpty) {
        bwStatus = await _checkMacPrinterOnline(newBwName);
      }

      if (newColorName.isNotEmpty &&
          ['shopowner', 'shopmanager', 'cashier', 'coffeshop'].contains(_userRole)) {
        colorStatus = await _checkMacPrinterOnline(newColorName);
      }

      if (mounted) {
        if (_bwPrinterName != newBwName ||
            _colorPrinterName != newColorName ||
            _isBwPrinterOnline != bwStatus ||
            _isColorPrinterOnline != colorStatus) {
          setState(() {
            _bwPrinterName = newBwName;
            _colorPrinterName = newColorName;
            _isBwPrinterOnline = bwStatus;
            _isColorPrinterOnline = colorStatus;
          });
        }
      }
      return;
    }
    // Jika platform bukan windows, logic sederhana
    if (!Platform.isWindows) {
      if (mounted) {
        setState(() {
          _bwPrinterName = newBwName;
          _colorPrinterName = newColorName;
        });
      }
      return;
    }

    bool bwStatus = false;
    bool colorStatus = false;

    if (newBwName.isNotEmpty) {
      try {
        final bool result = await platform.invokeMethod(
            'getPrinterStatus', {'printerName': newBwName});
        bwStatus = result;
        //debugPrint("🔍 [Cek Printer BW] Nama: $newBwName | Status Online: $result");
      } catch (e) {
        debugPrint("Error check BW printer: $e"); // Commented to reduce log spam on timer
      }
    }

    if (newColorName.isNotEmpty &&
        ['shopowner', 'shopmanager', 'cashier', 'coffeshop'].contains(_userRole)) {
      try {
        final bool result = await platform.invokeMethod(
            'getPrinterStatus', {'printerName': newColorName});
        colorStatus = result;
        //debugPrint("🔍 [Cek Printer Color] Nama: $newColorName | Status Online: $result");
      } catch (e) {
        debugPrint("Error check Color printer: $e");
      }
    }

    if (mounted) {
      // Optimasi: Hanya setState jika ada perubahan value untuk mencegah flicker UI saat Timer berjalan
      if (_bwPrinterName != newBwName ||
          _colorPrinterName != newColorName ||
          _isBwPrinterOnline != bwStatus ||
          _isColorPrinterOnline != colorStatus) {

        setState(() {
          _bwPrinterName = newBwName;
          _colorPrinterName = newColorName;
          _isBwPrinterOnline = bwStatus;
          _isColorPrinterOnline = colorStatus;
        });
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

  void _handleSecretTap() async {
    final now = DateTime.now();
    if (_lastTapTime == null || now.difference(_lastTapTime!) > const Duration(seconds: 1)) {
      _secretTapCount = 0;
    }
    _lastTapTime = now;
    _secretTapCount++;

    if (_secretTapCount == 5) {
      _secretTapCount = 0; // Reset
      await _toggleSslMode();
    }
  }

  Future<void> _toggleSslMode() async {
    final prefs = await SharedPreferences.getInstance();
    bool currentSslStatus = prefs.getBool('ssl_enabled') ?? true;
    bool newStatus = !currentSslStatus;

    await prefs.setBool('ssl_enabled', newStatus);

    String message = newStatus
        ? "SSL Enabled (SECURE MODE).\nThe apps will close. Please reopen it to apply the changes."
        : "SSL Disabled (BYPASS MODE).\nThe apps will close. Please reopen it to apply the changes.";

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Row(
            children: [
              Icon(newStatus ? Icons.security : Icons.no_encryption_gmailerrorred,
                  color: newStatus ? Colors.green : Colors.red),
              const SizedBox(width: 10),
              const Text("Developer Mode"),
            ],
          ),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => exit(0),
              child: const Text("OK"),
            ),
          ],
        ),
      ),
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
    _scaffoldMessenger?.clearMaterialBanners();
    _scrollController.dispose();
    _completedJobs.clear();
    _jobBatchTracker.clear();
    _stopPrinterStatusTimer();
    for (var t in _cleanupTimers) {
      t.cancel();
    }
    _cleanupTimers.clear();
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
      File? originalFile,
      String printerName,
      PrintJob job,
      String? ipPrinter,
      {required int currentJobIndex, required int totalJobs}
      ) async {
    final jobId = job.id;
    final startPage = job.pagesStart;
    final endPage = job.pageEnd;
    final copies = job.copies ?? 1;
    final Map<int, String> batchCache = {};
    const int batchSize = 10;
    final prefs = await SharedPreferences.getInstance();
    final String altPrintMode = prefs.getString(alternativePrintModeKey) ?? printDefault;
    final int totalPagesToPrint =(endPage - startPage + 1);
    final bool usePrinterCopies = totalPagesToPrint < batchSize;
    final int outerLoopLimit = usePrinterCopies ? 1 : copies;
    final int copiesForPrintCommand = usePrinterCopies ? copies : 1;
    String pageSizeRaw = job.pageSize ?? "A4";
    String pageSize = pageSizeRaw.toUpperCase().trim();
    if (pageSize.isEmpty) pageSize = "A4";
    int totalPages = endPage - startPage + 1;
    int numberOfBatches = (totalPages / batchSize).ceil();
    int totalOperations = usePrinterCopies ? numberOfBatches : (copies * numberOfBatches);
    setState(() {
      _jobBatchTracker[jobId] = totalOperations;
      _isSmartCopiesActive = usePrinterCopies;
      _isGsProcessing = true;
      _gsProgress = 0.0;
      _totalCopiesProcessing = copies;
      _currentCopyProcessing = 1;
      _currentJobIndex = currentJobIndex;
      _totalJobs = totalJobs;
    });

    try {
      debugPrint("Processing Job with Mode: $altPrintMode");
      debugPrint("Starting Pagination Print: $totalPages pages in $numberOfBatches batches.");
      debugPrint("TRACKER INIT: Job #$jobId akan diproses dalam $totalOperations operasi (Copies: $copies, Batches: $numberOfBatches)");
      debugPrint("Strategy: ${usePrinterCopies ? 'OPTIMIZED (Single Job, Native Copies)' : 'MANUAL LOOP (Multiple Jobs)'}");
      debugPrint("Total Pages: $totalPagesToPrint | Batch Size: $batchSize");
      debugPrint("Requested Copies: $copies | Loop Runs: $outerLoopLimit | Copies Per Command: $copiesForPrintCommand | pageSize: $pageSize");

      for (int c = 0; c < outerLoopLimit; c++) {
        if (mounted) {
          setState(() {
            _currentCopyProcessing = c + 1;
          });
        }
        debugPrint("  > Sending Copy ${c + 1} of $copies...");
        for (int i = 0; i < numberOfBatches; i++) {
          int currentBatchStart = startPage + (i * batchSize);
          int currentBatchEnd = currentBatchStart + batchSize - 1;
          if (currentBatchEnd > endPage) {
            currentBatchEnd = endPage;
          }
          double progress = (i + 1) / numberOfBatches;
          setState(() => _gsProgress = progress);

          debugPrint("Processing Batch ${i +
              1}/$numberOfBatches (Page $currentBatchStart - $currentBatchEnd)...");

          final dir = await getTemporaryDirectory();
          String? batchOutputPath = batchCache[i];
          bool isCached = batchOutputPath != null && File(batchOutputPath).existsSync();
          if (!isCached) {
            final newPath = '${dir.path}${Platform
                .pathSeparator}job_${jobId}_batch_${i}_${DateTime
                .now()
                .millisecondsSinceEpoch}.pdf';

            if (File(newPath).existsSync()) {
              try {
                File(newPath).deleteSync();
              } catch (_) {}
            }

            bool success = false;
            if (Platform.isWindows && altPrintMode == printDefault) {
              if (originalFile != null) {
                success = await _runGhostscriptCommand(
                    originalFile.path,
                    newPath,
                    30,
                    startPage: currentBatchStart,
                    endPage: currentBatchEnd
                );
              } else {
                debugPrint("Error: Original file is missing for Windows print job.");
                success = false;
              }
            } else if (Platform.isAndroid || Platform.isMacOS || (Platform.isWindows && altPrintMode == printTypeB)) {
              success = await _rasterizePdfApi(
                  job.filename,
                  newPath,
                  startPage: currentBatchStart,
                  endPage: currentBatchEnd
              );
            }

            if (success && File(newPath).existsSync()) {
              batchOutputPath = newPath;
              batchCache[i] = newPath;
              debugPrint("Batch ${i + 1} Generated & Cached.");
            } else {
              debugPrint("Batch ${i + 1} Print Type A. Fallback...");
              batchOutputPath = null;
              if (!Platform.isWindows && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Failed to print: error during process the file.'),
                    backgroundColor: Colors.red,
                  ),
                );
                setState(() {
                  _isGsProcessing = false;
                });
                return;
              }
            }
          } else {
            debugPrint("Batch ${i + 1} Found in Cache. Skipping Ghostscript.");
          }

          PrintJob jobToPrint = job.copyWith(copies: copiesForPrintCommand);
          if (batchOutputPath != null) {
            debugPrint("Batch ${i + 1} Success. Sending to printer...");
            if (Platform.isWindows) {
              await _printFileForWindows(
                  printerName, File(batchOutputPath), jobToPrint, pageSize);
            } else {
              await _printFile(printerName, File(batchOutputPath), jobToPrint, ipPrinter ?? "", pageSize);
            }
          } else if (Platform.isWindows && originalFile != null) {
            debugPrint("Batch ${i + 1}. Fallback to Sumatra per page...");
            bool isSumatraSuccess = await _printWithSumatra(originalFile.path, printerName, jobToPrint, pageSize, currentBatchStart, currentBatchEnd);
            if (isSumatraSuccess) {
              debugPrint("Sumatra sent command. Requesting C++ to monitor spooler...");
              await Future.delayed(const Duration(milliseconds: 500));
              try {
                await platform.invokeMethod('monitorLastJob', {
                  'printerName': printerName,
                  'printJobId': jobId,
                });
              } catch (e) {
                debugPrint("Gagal memanggil monitor C++: $e");
              }
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Failed to print with Type A'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }

          if (i == 0 && c == 0 && !_completedJobs.contains(jobId)) {
            debugPrint("Last batch sent. Updating status to 'Sent To Printer'...");
            await _updatePrintJobStatus(
                jobId, 'Sent To Printer', currentStatus: 'Processing');
          }
          int dynamicDelay = 500;
          if (numberOfBatches > 50) {
            dynamicDelay = 200; // Percepat jika batch sangat banyak
          }
          await Future.delayed(Duration(milliseconds: dynamicDelay));
        }
      }

      setState(() => _gsProgress = 1.0);
      debugPrint("All batches processed successfully.");
    } catch (e) {
      debugPrint("Pagination Print Error: $e");
      _jobBatchTracker.remove(jobId);
      rethrow;
    } finally {
      debugPrint("Cleaning up temporary batch files...");
      for (var path in batchCache.values) {
        try {
          final f = File(path);
          if (f.existsSync()) {
            f.deleteSync();
          }
        } catch (e) {
          debugPrint("Error deleting temp file $path: $e");
        }
      }
      if (mounted) setState(() => _isGsProcessing = false);
    }
  }

  Future<bool> _printSeparatorWithSumatra(String filePath, String printerName, String pageSize) async {
    debugPrint("Attempting fallback print separator with SumatraPDF...");

    List<String> settingsParts = [];

    settingsParts.add("duplex");
    settingsParts.add("monochrome");
    settingsParts.add("fit");

    if (pageSize == 'A4') {
      debugPrint("Target size is A4. Using printer default for Separator.");
    } else {
      String exactPaperName = await _resolvePaperNameForSumatra(printerName, pageSize);
      settingsParts.add("paper=$exactPaperName");
    }

    String printSettings = settingsParts.join(",");
    List<String> args = [
      '-print-to', printerName,
      '-silent',
    ];

    if (printSettings.isNotEmpty) {
      args.add('-print-settings');
      args.add(printSettings);
    }
    args.add(filePath);

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
        debugPrint("SumatraPDF failed with exit code: ${result.exitCode}");
        return false;
      }
    } catch (e) {
      debugPrint("Exception running SumatraPDF: $e");
      return false;
    }
  }

  Future<bool> _printInvoiceWithSumatra(String filePath, String printerName, String pageSize) async {
    debugPrint("Attempting fallback print invoice with SumatraPDF...");

    List<String> settingsParts = [];

    settingsParts.add("simplex");
    settingsParts.add("monochrome");
    settingsParts.add("fit");
    if (pageSize == 'A4') {
      debugPrint("Target size is A4. Using printer default for Invoice.");
    } else {
      String exactPaperName = await _resolvePaperNameForSumatra(printerName, pageSize);
      settingsParts.add("paper=$exactPaperName");
    }

    String printSettings = settingsParts.join(",");
    List<String> args = [
      '-print-to', printerName,
      '-silent',
    ];

    if (printSettings.isNotEmpty) {
      args.add('-print-settings');
      args.add(printSettings);
    }
    args.add(filePath);

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
        debugPrint("SumatraPDF failed with exit code: ${result.exitCode}");
        return false;
      }
    } catch (e) {
      debugPrint("Exception running SumatraPDF: $e");
      return false;
    }
  }
  // Helper untuk mencari nama kertas yang cocok di driver
  Future<String> _resolvePaperNameForSumatra(String printerName, String targetSize) async {
    try {
      // 1. Minta daftar kertas dari Driver via Native C++
      final List<Object?> result = await platform.invokeMethod('getPrinterPaperSizes', {
        'ip': printerName, // Kirim nama printer
      });

      // Casting ke List<String>
      List<String> availablePapers = result.map((e) => e.toString()).toList();

      debugPrint("Driver Papers for $printerName: $availablePapers");

      String targetUpper = targetSize.toUpperCase().trim(); // misal "A5"

      // 2. LOGIKA PENCOCOKAN (Fuzzy Matching)

      // Prioritas A: Cari yang sama persis (Case Insensitive)
      for (var paper in availablePapers) {
        if (paper.toUpperCase() == targetUpper) return paper;
      }

      // Prioritas B: Cari yang MENGANDUNG kata tersebut (misal "A5" ada di "ISO A5" atau "A5 148x210")
      // Kita cari yang stringnya paling pendek tapi mengandung kata kunci (untuk menghindari 'A5' match dengan 'A5 Extra Large')
      String? bestMatch;
      int shortestLength = 999;

      for (var paper in availablePapers) {
        String pUpper = paper.toUpperCase();

        // Khusus F4, cari juga "FOLIO" atau "OFICIO"
        if (targetUpper == "F4") {
          if (pUpper.contains("FOLIO") || pUpper.contains("OFICIO") || pUpper.contains("F4")) {
            return paper; // Ketemu F4/Folio
          }
        }

        // Pencocokan standar (Contains)
        // Tambahkan spasi agar "A5" tidak match dengan "A50" (jika ada)
        // Cek: "A5", "A5 ", " A5"
        bool match = pUpper == targetUpper ||
            pUpper.contains("$targetUpper ") ||
            pUpper.contains(" $targetUpper") ||
            pUpper.contains(targetUpper); // Fallback longgar

        if (match) {
          if (paper.length < shortestLength) {
            shortestLength = paper.length;
            bestMatch = paper;
          }
        }
      }

      if (bestMatch != null) return bestMatch;

      // 3. Jika tidak ketemu sama sekali, kembalikan default A4 (atau biarkan Sumatra pakai default printer)
      debugPrint("Paper size $targetSize not found in driver. Defaulting to A4.");
      return "A4";

    } catch (e) {
      debugPrint("Failed to resolve paper name: $e");
      return "A4"; // Fallback jika error
    }
  }

  Future<bool> _printWithSumatra(String filePath, String printerName, PrintJob printJob, String pageSize, int customStartPage, int customEndPage) async {
    debugPrint("Attempting fallback print with SumatraPDF...");

    final startPage = customStartPage;
    final endPage = customEndPage;
    final isDuplex = printJob.doubleSided;
    final isColor = printJob.color ?? false;
    final orientation = printJob.pageOrientation;
    final copies = printJob.copies ?? 1;

    if (pageSize == "F4") pageSize = "Folio";
    debugPrint("SumatraPDF Print: Copies=$copies, Orientation=$orientation, Duplex=$isDuplex, Color=$isColor, Range=$startPage-$endPage, pageSize=$pageSize");

    List<String> settingsParts = [];

    if (startPage != 0 || endPage != 0) {
      if (startPage == endPage) {
        settingsParts.add("$startPage");
      } else {
        settingsParts.add("$startPage-$endPage");
      }
    }
    settingsParts.add("paper=$pageSize");
    if (copies > 1) {
      settingsParts.add("${copies}x");
    }
    if (pageSize == "A4") {
      // Jika A4, JANGAN kirim parameter paper=.
      // Biarkan SumatraPDF mengikuti default setting dari Driver Printer (biasanya A4).
      debugPrint("Target size is A4. Using printer default configuration (skipping paper argument).");
    } else {
      // Jika BUKAN A4 (misal A5, F4, Legal), baru kita cari nama spesifik di driver
      debugPrint("Target size is $pageSize. Resolving specific paper name from driver...");

      // Panggil fungsi helper resolve yang sudah dibuat sebelumnya
      String exactPaperName = await _resolvePaperNameForSumatra(printerName, pageSize);

      debugPrint("Resolved Paper Name for Sumatra: $exactPaperName");
      settingsParts.add("paper=$exactPaperName");
    }
    if (isDuplex) {
      settingsParts.add("duplex");
    } else {
      settingsParts.add("simplex");
    }
    if (isColor) {
      settingsParts.add("color");
    } else {
      settingsParts.add("monochrome");
    }
    if (orientation != null && orientation.toString().toLowerCase() != 'auto') {
      settingsParts.add(orientation.toString());
    }
    settingsParts.add("fit");

    String printSettings = settingsParts.join(",");
    List<String> args = [
      '-print-to', printerName,
      '-silent',
    ];

    if (printSettings.isNotEmpty) {
      args.add('-print-settings');
      args.add(printSettings);
    }
    args.add(filePath);

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
        debugPrint("SumatraPDF failed with exit code: ${result.exitCode}");
        return false;
      }
    } catch (e) {
      debugPrint("Exception running SumatraPDF: $e");
      return false;
    }
  }


  Future<void> _submitPrintJob() async {
    final String? userRole = _userRole;
    final prefs = await SharedPreferences.getInstance();
    final String altPrintMode = prefs.getString(alternativePrintModeKey) ?? printDefault;

    String ipPrinter = "";
    if (Platform.isAndroid) {
      ipPrinter = await _getPrinterIP();
      if (ipPrinter.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please go to settings, and set the IP Printer.'),
          ),
        );
        return;
      }
    }
    if ((Platform.isWindows || Platform.isMacOS) && _bwPrinterName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(userRole != 'darkstore'
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

      if (userRole != 'darkstore') {
        final bool needsColorPrinter = response.printFiles.any((job) => job.color == true);
        if (needsColorPrinter && _colorPrinterName.isEmpty) {
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
        String docPageSizeRaw = response.printFiles.first.pageSize ?? "A4";
        String docPageSize = docPageSizeRaw.toUpperCase().trim();
        if (docPageSize.isEmpty) docPageSize = "A4";

        if (response.isUseInvoice) {
          String invoicePrinter = _bwPrinterName;
          if (userRole != null && userRole != 'darkstore' && response.printFiles.first.color == true) {
            invoicePrinter = _colorPrinterName;
          }
          await _printInvoiceFromHtml(invoicePrinter, response, ipPrinter, docPageSize);
        }

        // Menggunakan loop untuk memproses setiap pekerjaan cetak satu per satu
        for (int i = 0; i < response.printFiles.length; i++) {
          final job = response.printFiles[i];
          File? downloadedFile;

          String selectedPrinter;
          if (userRole != 'darkstore' && job.color == true) {
            selectedPrinter = _colorPrinterName;
          } else {
            selectedPrinter = _bwPrinterName;
          }

          try {
            await _updatePrintJobStatus(job.id, 'Processing', currentStatus: job.status);

            if (Platform.isWindows && altPrintMode != printTypeB) {
              final String filenameToDownload = Uri.parse(job.filename).pathSegments.last;
              final Directory tempDir = await getTemporaryDirectory();
              final String savePath = p.join(tempDir.path, filenameToDownload);

              setState(() {
                _isDownloading = true;
                _downloadProgress = 0.0;
              });

              try {
                await Dio().download(
                  job.filename,
                  savePath,
                  onReceiveProgress: (received, total) {
                    if (total > 0) {
                      setState(() {
                        _downloadProgress = received / total;
                      });
                    }
                  },
                );

                downloadedFile = File(savePath);
              } catch (e) {
                debugPrint("Download Error: $e");
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to download file: $e')),
                );
                rethrow;
              } finally {
                if (mounted) {
                  setState(() {
                    _isDownloading = false;
                  });
                }
              }
            }

            await _processAndPrintStreamed(
                downloadedFile,
                selectedPrinter,
                job,
                ipPrinter,
                currentJobIndex: i + 1,
                totalJobs: response.printFiles.length);
            await _updatePrintCount(job.id);
            if (i < response.printFiles.length - 1) {
              debugPrint("Waiting for printer buffer...");
              await Future.delayed(const Duration(seconds: 2));
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
              await downloadedFile.delete();
              debugPrint("Temporary file deleted for job ${i + 1}.");
            }
          }
        }

        if (response.isUseSeparator) {
          await _printSeparatorFromAsset(_bwPrinterName, ipPrinter, docPageSize);
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No print jobs found.')),
        );
      }
    } catch (e) {
      if (e is DioException && e.response?.statusCode == 500) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Session expired or Server Error. Logging out...')),
          );
        }
        await _logout();
        return;
      }
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

  Future<void> _printInvoiceFromHtml(String printerName, PrintJobResponse jobResponse, String ipPrinter, String pageSize) async {
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
      int pageOrientation = 3;
      if (jobResponse.userRole == 'darkstore') {
        String path = "PrintInvoicesNanaNew";
        if (Platform.isAndroid) {
          path = "PrintInvoicesNanaAndroid";
        }
        invoiceUrl = '$baseUrl/$path/${jobResponse
            .transactionId}/${jobResponse.companyId}/$colorStatus';
      } else {
        pageOrientation = 4;
        invoiceUrl =
        '$baseUrl/PrintInvoices/${jobResponse.transactionId}/$colorStatus';
      }

      if (Platform.isWindows) {
        await _printInvoiceForWindows(printerName, invoiceUrl, color, pageSize);
      } else if (Platform.isMacOS) {
        await _printInvoiceForMac(printerName, jobResponse.transactionId, jobResponse.companyId, colorStatus, jobResponse.userRole, pageSize);
      } else if (Platform.isAndroid) {
        debugPrint('invoice url: $invoiceUrl');
        await _printInvoiceForAndroid(invoiceUrl, pageOrientation, ipPrinter, pageSize);
      }
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
      _loadPrinterPreferences();
    }
  }

  Widget _buildUserInfoHeader() {
    final bool showDivider = _name.isNotEmpty || _email.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. BANNER WARNING (Dikeluarkan dari Row dan diletakkan di paling atas)
        if (((Platform.isWindows || Platform.isMacOS) && _bwPrinterName.isEmpty) || (Platform.isAndroid && _bwPrinterName.isEmpty))
          MaterialBanner(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            content: Text(
              Platform.isAndroid
                  ? 'Please go to settings, and set the IP Printer.'
                  : (_userRole != 'darkstore'
                  ? 'Please to setting, and set the b/w printer'
                  : 'Please to setting, and set the default print.'),
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            leading: const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
            backgroundColor: Colors.orangeAccent[700],
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => const SettingsPage()))
                      .then((_) => _loadPrinterPreferences());
                },
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('SETTINGS'),
              ),
            ],
          ),

        // 2. BAGIAN NAMA, EMAIL, DAN LAMPU INDIKATOR
        Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 8.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center, // Sejajarkan secara vertikal
              children: [
                // Bungkus Column teks dengan Expanded agar tidak error jika teks panjang
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis, // Otomatis dipotong (...) jika kepanjangan
                      ),
                      Text(
                        _email,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16), // Jarak aman antara teks dan indikator

                // 3. LAMPU INDIKATOR SAJA
                _buildPrinterStatusInfo(),
              ],
            )
        ),

        if (showDivider)
          const Divider(height: 1, thickness: 1),
      ],
    );
  }


  Future<void> _printInvoiceForWindows(String printerName, String invoiceUrl, bool? color, String pageSize) async {
    try {
      final htmlContent = await _printJobService.fetchInvoiceHtml(
          invoiceUrl);

      final tempDir = await Directory.systemTemp.createTemp();
      final inputHtml = File(p.join(tempDir.path, 'input.html'));
      await inputHtml.writeAsString(htmlContent);

      final outputPdf = File(p.join(tempDir.path, 'output.pdf'));

      final String execDir = p.dirname(Platform.resolvedExecutable);
      final exePath = p.join(execDir, 'wkhtmltopdf.exe');
      final prefs = await SharedPreferences.getInstance();
      final String altPrintMode = prefs.getString(alternativePrintModeKey) ?? printDefault;

      final result = await Process.run(
        exePath,
        [inputHtml.path, outputPdf.path],
        workingDirectory: execDir,
      );
      if (result.exitCode == 0) {
        debugPrint("Invoice url: $invoiceUrl");
        if (altPrintMode == printTypeA) {
          await _printInvoiceWithSumatra(outputPdf.path, printerName, pageSize);
        } else {
          await _printInvoiceFile(printerName, outputPdf, color, pageSize);
        }
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

  Future<void> _printInvoiceForMac(String printerName, int transId, int companyId, String color, String role, String pageSize) async {
    try {
      final path = role == 'darkstore' ? "macos-invoice-nana-pdf" : "macos-invoice-pdf";
      final bytes = await generateInvoicePdf(path, transId, companyId, color);

      final dir = await getTemporaryDirectory();
      final filePath = "${dir.path}/invoice_print.pdf";
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      String macMedia = switch (pageSize) {
        'LETTER' => "na_letter_8.5x11in",
        'LEGAL'  => "na_legal_8.5x14in",
        'A3'     => "iso_a3_297x420mm",
        'A5'     => "iso_a5_148x210mm",
        'F4'     => "om_f4_210x330mm",
        _        => "iso_a4_210x297mm",
      };

      List<String> args = [];
      args.add('-P');
      args.add(printerName);

      args.add('-o');
      args.add('sides=one-sided');

      args.addAll([
        '-o', 'BRMonoColor=Mono',
        '-o', 'ColorModel=Gray',
        '-o', 'ColorMode=Monochrome',
        '-o', 'SelectColor=Grayscale',
        '-o', 'APPrinterPreset=BlackAndWhite'
      ]);

      args.add('-o');
      args.add('portrait');

      args.add('-o');
      args.add('fit-to-page');

      args.add('-o');
      args.add('media=$macMedia');

      args.add(file.path);

      debugPrint("MacOS executing: lpr ${args.join(' ')}");

      final result = await Process.run('lpr', args);

      if (result.exitCode == 0) {
        debugPrint('MacOS: Invoice berhasil dikirim ke printer.');
      } else {
        debugPrint('MacOS: Gagal mencetak file. Error: ${result.stderr}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to print invoice: ${result.stderr}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      print("❌ Error printing invoice: $e");
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

  Future<void> _printSeparatorForMac(String printerName, File file, String pageSize) async {
    String macMedia = switch (pageSize) {
      'LETTER' => "na_letter_8.5x11in",
      'LEGAL'  => "na_legal_8.5x14in",
      'A3'     => "iso_a3_297x420mm",
      'A5'     => "iso_a5_148x210mm",
      'F4'     => "om_f4_210x330mm",
      _        => "iso_a4_210x297mm",
    };
    List<String> args = [];
    args.add('-P');
    args.add(printerName);
    args.add('-o');
    args.add('sides=two-sided-long-edge');

    args.addAll([
      '-o', 'BRMonoColor=Mono',
      '-o', 'ColorModel=Gray',
      '-o', 'ColorMode=Monochrome',
      '-o', 'SelectColor=Grayscale',
      '-o', 'APPrinterPreset=BlackAndWhite'
    ]);

    args.add('-o');
    args.add('portrait');

    args.add('-o');
    args.add('fit-to-page');

    args.add('-o');
    args.add('media=$macMedia');

    args.add(file.path);

    debugPrint("MacOS executing: lpr ${args.join(' ')}");

    final result = await Process.run('lpr', args);

    if (result.exitCode == 0) {
      debugPrint('MacOS: Invoice berhasil dikirim ke printer.');
    } else {
      debugPrint('MacOS: Gagal mencetak separator. Error: ${result.stderr}');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to print separator: ${result.stderr}'),
          backgroundColor: Colors.red,
        ),
      );
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

  Future<bool> _rasterizePdfApi(String fileUrl, String outputPath, {required int startPage, required int endPage}) async {
    try {
      debugPrint("Rasterizing via API: $fileUrl, pages $startPage-$endPage");
      final response = await http.post(
        Uri.parse("$baseUrl/api/rasterize-pdf"),
        headers: {"Content-Type": "application/x-www-form-urlencoded"},
        body: {
          'pdf_url': fileUrl,
          'page_start': startPage.toString(),
          'page_end': endPage.toString(),
        },
      );

      if (response.statusCode == 200) {
        final file = File(outputPath);
        await file.writeAsBytes(response.bodyBytes);
        return true;
      } else {
        debugPrint("API Rasterize failed: ${response.statusCode} - ${response.body}");
        return false;
      }
    } catch (e) {
      debugPrint("Exception in API Rasterize: $e");
      return false;
    }
  }


  Future<void> _printInvoiceForAndroid(String invoiceUrl, int pageOrientation, String ipPrinter, String pageSize) async {
    try {
      final bytes = await fetchInvoicePdf(invoiceUrl);

      final dir = await getTemporaryDirectory();
      final filePath = "${dir.path}/invoice_print.pdf";
      final file = File(filePath);
      await file.writeAsBytes(bytes);
      final params = {
        "filePath": filePath,
        "orientation": pageOrientation,
        "ip": ipPrinter,
        "duplex": false,
        "pageSize": pageSize,
      };

      String result = await platform.invokeMethod<String>(
        "printInvoicePdf",
        params,
      ) ?? "error";

      if (result == "success") {
        print("✅ Invoice printed successfully");
      } else {
        print("❌ Print failed: $result");
      }

    } catch (e) {
      print("❌ Error printing invoice: $e");
    }
  }


  Future<void> _printInvoiceFile(String printerName, File file, bool? color, String pageSize) async {
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
          'pageSize': pageSize,
          'pageOrientation': 'auto',
        },
      );

      if (result == 'success') {
      } else if (result == 'Sent To Printer') {
      } else {
        throw Exception("Platform channel result: $result");
      }
    } on PlatformException catch (e, s) {
      debugPrint("Platform channel invoice print failed: $e. Attempting fallback to SumatraPDF...");

      bool isFallbackSuccess = await _printInvoiceWithSumatra(file.path, printerName, pageSize);
      if (isFallbackSuccess) {
        debugPrint("Fallback to SumatraPDF (Invoice) successful.");
      } else {
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
  }

  Future<void> _printSeparatorFromAsset(String printerName, String ipPrinter, String pageSize) async {
    File? tempFile;
    try {
      final byteData = await rootBundle.load('assets/pdf/separator.pdf');
      final tempDir = await Directory.systemTemp.createTemp();
      tempFile = File(p.join(tempDir.path, 'separator.pdf'));
      await tempFile.writeAsBytes(byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ));
      final prefs = await SharedPreferences.getInstance();
      final String altPrintMode = prefs.getString(alternativePrintModeKey) ?? printDefault;
      if (Platform.isWindows) {
        if (altPrintMode == printTypeA) {
          await _printSeparatorWithSumatra(tempFile.path, printerName, pageSize);
        } else {
          try {
            await platform.invokeMethod(
              'printPDF',
              {
                'filePath': tempFile.path,
                'printerName': printerName,
                'printJobId': -2,
                'color': false,
                'doubleSided': true,
                'copies': 1,
                'pageSize': pageSize,
                'pageOrientation': 'auto',
              },
            );
          } catch (e, s) {
            debugPrint("Platform channel separator print failed: $e. Attempting fallback to SumatraPDF...");
            try {
              await _printSeparatorWithSumatra(tempFile.path, printerName, pageSize);
              debugPrint("Fallback separator successful.");
            } catch (fallbackError) {
              debugPrint("Fallback separator failed. Reporting to Sentry.");
              await Sentry.captureException(e, stackTrace: s);
            }
          }
        }
      } else if (Platform.isAndroid) {
        await platform.invokeMethod(
          'printInvoicePdf',
          {
            'filePath': tempFile.path,
            "orientation": 3,
            "ip": ipPrinter,
            "duplex": true,
            "pageSize": pageSize,
          },
        );
      } else if (Platform.isMacOS) {
        await _printSeparatorForMac(printerName, tempFile, pageSize);
      }
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

  Future<void> _printFileForWindows(String printerName, File file, PrintJob job, String pageSize) async {
    try {
      final String result = await platform.invokeMethod(
        'printPDF',
        {
          'printJobId': job.id,
          'filePath': file.path,
          'printerName': printerName,
          'color': job.color,
          'doubleSided': job.doubleSided,
          'copies': job.copies,
          'pageSize': pageSize,
          'pageOrientation': job.pageOrientation,
        },
      );
      if (result == 'success') {
        debugPrint('Cetak berhasil!');
      } else if (result == 'Sent To Printer') {
        debugPrint('Pekerjaan cetak sudah dikirim ke printer.');
      } else {
        throw Exception("Platform channel result: $result");
      }
    } on PlatformException catch (e, s) {
      debugPrint("Platform channel print failed: $e. Attempting fallback to SumatraPDF...");

      bool isFallbackSuccess = await _printWithSumatra(file.path, printerName, job, pageSize, 0, 0);
      if (isFallbackSuccess) {
        debugPrint("Fallback to SumatraPDF successful.");
        await Future.delayed(const Duration(milliseconds: 500));

        try {
          await platform.invokeMethod('monitorLastJob', {
            'printerName': printerName,
            'printJobId': job.id,
          });
        } catch (e) {
          debugPrint("Monitor failed: $e");
        }
      } else {
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
  }
  Future<void> _printFile(String printerName, File file, PrintJob job, String ipPrinter, String pageSize) async {
    if (Platform.isAndroid) {
      int pageOrientation;
      if (job.pageOrientation == "auto") {
        pageOrientation = -1;
      } else {
        pageOrientation = job.pageOrientation == "portrait" ? 3 : 4; // 3 = portrait, 4 = landscape
      }
      final params = {
        "filePath": file.path,
        "duplex": job.doubleSided,
        "color": job.color == true ? "color" : "monochrome",
        "orientation": pageOrientation,
        'pageSize': pageSize,
        "ip": ipPrinter,
        "copies": job.copies ?? 1,
      };
      final String result = await platform.invokeMethod("printPDF", params);
      if (result == "success") {
        debugPrint('job id: ${job.id} | current status: ${job.status}');
      } else {
        debugPrint('Failed print: $result');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed print: $result'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } else if (Platform.isMacOS) {
      String macMedia = switch (pageSize) {
        'LETTER' => "na_letter_8.5x11in",
        'LEGAL'  => "na_legal_8.5x14in",
        'A3'     => "iso_a3_297x420mm",
        'A5'     => "iso_a5_148x210mm",
        'F4'     => "om_f4_210x330mm",
        _        => "iso_a4_210x297mm", // Default (A4)
      };
      try {
        List<String> args = [];

        if (printerName.isNotEmpty) {
          args.add('-P');
          args.add(printerName);
        }

        if (job.doubleSided) {
          args.add('-o');
          args.add('sides=two-sided-long-edge');
        } else {
          args.add('-o');
          args.add('sides=one-sided');
        }

        if (job.pagesStart > 0 && job.pageEnd > 0) {
          args.add('-o');
          args.add('page-ranges=${job.pagesStart}-${job.pageEnd}');
        }

        if (job.color == false) {
          args.addAll([
            '-o', 'BRMonoColor=Mono',
            '-o', 'ColorModel=Gray',
            '-o', 'ColorMode=Monochrome',
            '-o', 'SelectColor=Grayscale',
            '-o', 'APPrinterPreset=BlackAndWhite'
          ]);
        }

        if (job.pageOrientation != null && job.pageOrientation != 'auto') {
          args.add('-o');
          args.add(job.pageOrientation == 'landscape' ? 'landscape' : 'portrait');
        }

        args.add('-o');
        args.add('fit-to-page');

        args.add('-o');
        args.add('media=$macMedia');

        args.add(file.path);

        debugPrint("MacOS executing: lpr ${args.join(' ')}");

        final result = await Process.run('lpr', args);

        if (result.exitCode == 0) {
          debugPrint('MacOS: File berhasil dikirim ke printer.');
          _handleJobCompletion(job.id);
        } else {
          debugPrint('MacOS: Gagal mencetak file. Error: ${result.stderr}');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to print -> error: ${result.stderr}'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } catch (e, s) {
        // await Sentry.captureException(e, stackTrace: s);
        // debugPrint("Error printing file (Mac): $e");
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error System: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
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

  Widget _buildPrinterStatusInfo() {
    if (Platform.isIOS) return const SizedBox.shrink();

    bool showColorPrinter = ['shopowner', 'shopmanager', 'cashier', 'coffeshop'].contains(_userRole) &&
        _colorPrinterName.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end, // Rata kanan
      children: [
        if (_bwPrinterName.isNotEmpty)
          _buildLedStatus(
            _bwPrinterName,
            _isBwPrinterOnline,
            label: showColorPrinter ? 'B/W: ' : '',
          ),

        if (showColorPrinter) ...[
          const SizedBox(height: 4),
          _buildLedStatus(
            _colorPrinterName,
            _isColorPrinterOnline,
            label: 'Color: ',
          ),
        ],
      ],
    );
  }

  Widget _buildLedStatus(String name, bool isOnline, {String label = ''}) {
    String displayName = name.length > 50 ? '${name.substring(0, 47)}...' : name;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (label.isNotEmpty)
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[800],
              fontWeight: FontWeight.bold,
            ),
          ),
        Text(
          displayName,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey[700],
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 6),
        // LED Indicator
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isOnline ? Colors.green : Colors.red,
            boxShadow: [
              BoxShadow(
                color: (isOnline ? Colors.green : Colors.red).withOpacity(0.4),
                blurRadius: 4,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
      ],
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
            children: [
              GestureDetector(
                onTap: _handleSecretTap,
                child: Container(
                  margin: const EdgeInsets.only(right: 8.0),
                  child: Image.asset(
                    'assets/icon/icon.png',
                    height: 30,
                    width: 30,
                    errorBuilder: (context, error, stackTrace) {
                      return const Icon(Icons.broken_image, color: Colors.white);
                    },
                  ),
                ),
              ),
              const Text("Hlaprint"),
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. BANNER WARNING (Jika printer belum diatur)
                  if (((Platform.isWindows || Platform.isMacOS) && _bwPrinterName.isEmpty) || (Platform.isAndroid && _bwPrinterName.isEmpty))
                    MaterialBanner(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      content: Text(
                        Platform.isAndroid
                            ? 'Please go to settings, and set the IP Printer.'
                            : (_userRole != 'darkstore'
                            ? 'Please to setting, and set the b/w printer'
                            : 'Please to setting, and set the default print.'),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                      leading: const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
                      backgroundColor: Colors.orangeAccent[700],
                      actions: [
                        TextButton(
                          onPressed: () {
                            Navigator.of(context)
                                .push(MaterialPageRoute(builder: (_) => const SettingsPage()))
                                .then((_) => _loadPrinterPreferences());
                          },
                          style: TextButton.styleFrom(foregroundColor: Colors.white),
                          child: const Text('SETTINGS'),
                        ),
                      ],
                    ),

                  // 2. INFO USER & INDIKATOR PRINTER
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 8.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start, // Sejajar di atas
                      children: [
                        // Kolom info user dibungkus Expanded agar tidak bertabrakan dengan indikator printer
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _name,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis, // Potong teks kepanjangan (...)
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _email,
                                style: TextStyle(fontSize: 14, color: Colors.grey[700]),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Role: ${_userRole ?? '-'}',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontStyle: FontStyle.italic,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16), // Jarak aman pemisah

                        // Widget Indikator Printer
                        _buildPrinterStatusInfo(),
                      ],
                    ),
                  ),
                ],
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
          children: [
            GestureDetector(
              onTap: _handleSecretTap,
              child: Container(
                margin: const EdgeInsets.only(right: 8.0),
                child: Image.asset(
                  'assets/icon/icon.png',
                  height: 30,
                  width: 30,
                  errorBuilder: (context, error, stackTrace) {
                    return const Icon(Icons.broken_image, color: Colors.white);
                  },
                ),
              ),
            ),
            const Text("Hlaprint"),
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

              if (_isDownloading) ...[
                const Divider(height: 1),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  color: Colors.white,
                  child: SafeArea(
                    top: false,
                    bottom: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          "Downloading File... ${(_downloadProgress * 100).toInt()}%",
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12, color: Colors.black),
                        ),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: _downloadProgress,
                          backgroundColor: Colors.grey[300],
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              if (_isGsProcessing) ...[
                const Divider(height: 1),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  color: Colors.white,
                  child: SafeArea(
                    top: false,
                    bottom: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _totalCopiesProcessing > 1
                              ? "Processing Print Job.. ${(_gsProgress * 100).toInt()}% for copy ${_isSmartCopiesActive ? _totalCopiesProcessing : _currentCopyProcessing}"
                              : "Processing Print Job... ${(_gsProgress * 100).toInt()}%${_totalJobs > 1 ? ' for #$_currentJobIndex' : ''}",
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
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}