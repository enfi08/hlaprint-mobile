import 'dart:async';

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
import 'package:flutter/services.dart';
import 'package:hlaprint/constants.dart';
import 'package:shimmer/shimmer.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

import '../models/user_detail_model.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

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
  bool _isLoading = false;
  String _pin = '';
  String _name = '';
  String _email = '';
  String _printerStatus = '';
  bool _isSkipCashier = false;
  String? _userRole;
  List<PrintJob> _bookshopOrders = [];
  Timer? _autoRefreshTimer;

  final _scrollController = ScrollController();
  int _currentPage = 1;
  final int _limit = 8;
  bool _isLoadMoreLoading = false;
  bool _hasNextPage = true;

  @override
  void initState() {
    super.initState();
    _loadUserRoleAndData();
    _startAutoRefresh();
    _scrollController.addListener(_onScroll);

    for (var controller in _pinControllers) {
      controller.addListener(_updatePin);
    }

    platform.setMethodCallHandler((call) async {
      if (call.method == "onPrinterStatus") {
        setState(() {
          _printerStatus = call.arguments; // "Online" / "Offline"
        });
      } else if (call.method == "onPrintJobCompleted") {
        setState(() {
          final Map<Object?, Object?>? args = call.arguments;
          if (args is Map) {
            final int jobId = args['printJobId'] as int;
            final int totalPages = args['totalPages'] as int;

            if (jobId == -1 || jobId == -2) {
              debugPrint('print job Invoice on Separator');
              return;
            }
            int delaySeconds = 0;
            if (totalPages > 0) {
              delaySeconds = 15;
              if (totalPages > 1) {
                delaySeconds += (totalPages - 1) * 3;
              }
            }
            debugPrint('Print job $jobId completed by OS. Starting delay for $totalPages pages.');

            // Menjalankan Timer untuk delay
            Timer(Duration(seconds: delaySeconds), () async {
              await _updatePrintJobStatus(jobId, 'Completed', currentStatus: 'Sent To Printer');
              debugPrint('Print job $jobId status set to Completed after $delaySeconds seconds.');
            });
          }
        });
      }
    });

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

  Future<void> _fetchAndSaveUserRole() async {
    try {
      final User user = await _userService.getUser();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(userRoleKey, user.role);
      await prefs.setBool(skipCashierKey, user.isSkipCashier);

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
    _scrollController.dispose();
    for (var controller in _pinControllers) {
      controller.removeListener(_updatePin);
      controller.dispose();
    }
    super.dispose();
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

  Future<void> _submitPrintJob() async {
    final prefs = await SharedPreferences.getInstance();
    final bwPrinterName = prefs.getString(printerNameKey);
    final colorPrinterName = prefs.getString(printerColorNameKey);

    if (bwPrinterName == null || bwPrinterName.isEmpty) {
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
      PrintJobResponse response = await _printJobService.getPrintJobByCode(_pin);

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

            final String invoiceFilenameToDownload = Uri.parse(job.filename).pathSegments.last;
            downloadedFile = await _printJobService.downloadFile(
              job.filename,
              invoiceFilenameToDownload,
            );

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Download complete. Printing file ${i + 1} of ${response.printFiles.length}...')),
            );

            // Kirim ke native code dan tunggu sampai selesai
            await _printFile(selectedPrinter, downloadedFile, job);
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
        invoiceUrl = '$baseUrl/PrintInvoicesNanaNew/${jobResponse
            .transactionId}/${jobResponse.companyId}/$colorStatus';
      } else {
        invoiceUrl =
        '$baseUrl/PrintInvoices/${jobResponse.transactionId}/$colorStatus';
      }

      try {
        final htmlContent = await _printJobService.fetchInvoiceHtml(
            invoiceUrl);

        final tempDir = await Directory.systemTemp.createTemp();
        final inputHtml = File(p.join(tempDir.path, 'input.html'));
        await inputHtml.writeAsString(htmlContent);

        final outputPdf = File(p.join(tempDir.path, 'output.pdf'));

        final exePath = p.join(
          Directory.current.path,
          'wkhtmltopdf.exe',
        );

        final result = await Process.run(
          exePath,
          [inputHtml.path, outputPdf.path],
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
  }

  Future<void> _printInvoiceFile(String printerName, File file, bool? color) async {
    if (Platform.isWindows) {
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
    } else if (Platform.isMacOS) {
      try {
        final result = await Process.run('lpr', [file.path]);
        if (result.exitCode == 0) {
          debugPrint('File berhasil dikirim ke printer.');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('File berhasil dikirim ke printer.'),
            ),
          );
        } else {
          debugPrint('Gagal mencetak file. Error: ${result.stderr}');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Gagal mencetak file'),
            ),
          );
          throw Exception('Failed to send print job to lpr: ${result.stderr}');
        }
      } catch (e, s) {
        await Sentry.captureException(
          e,
          stackTrace: s,
        );
        debugPrint("Error printing file: $e");
        rethrow;
      }
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
      final result = await platform.invokeMethod(
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
      if (result == 'success') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Separator page printed.'),
            backgroundColor: Colors.green,
          ),
        );
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

  Future<void> _printFile(String printerName, File file, PrintJob job) async {
    if (Platform.isWindows) {
      try {
        final String result = await platform.invokeMethod(
          'printPDF',
          {
            'printJobId': job.id,
            'filePath': file.path,
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
          await _updatePrintJobStatus(job.id, 'Sent To Printer', currentStatus: job.status);
          debugPrint('Pekerjaan cetak sudah dikirim ke printer.');
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Gagal mencetak: $result'),
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
    } else if (Platform.isMacOS) {
      try {
        // Logika cetak macOS tidak diubah, hanya bagian Windows yang diperbaiki
        final result = await Process.run('lpr', [file.path]);

        if (result.exitCode == 0) {
          debugPrint('File berhasil dikirim ke printer.');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('File berhasil dikirim ke printer.'),
            ),
          );
        } else {
          debugPrint('Gagal mencetak file. Error: ${result.stderr}');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Gagal mencetak file'),
            ),
          );
          throw Exception(
              'Failed to send print job to lpr: ${result.stderr}');
        }
      } catch (e, s) {
        await Sentry.captureException(
          e,
          stackTrace: s,
        );
        debugPrint("Error printing file: $e");
        rethrow;
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
        final number = job.invoiceNumber == null ? '#0' : "#${job.invoiceNumber}";
        final colorText = job.color == true ? 'Color' : 'B&W';
        final sideText = job.doubleSided ? 'Double' : 'Single';
        final priceText = job.price != null ? '${job.price} SAR' : '-';

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

        String formattedDate = '-';
        if (job.createdAt != null) {
          final DateTime dateTime = DateTime.parse(job.createdAt!);
          final day = dateTime.day.toString().padLeft(2, '0');
          final month = dateTime.month.toString().padLeft(2, '0');
          final hour = dateTime.hour.toString().padLeft(2, '0');
          final minute = dateTime.minute.toString().padLeft(2, '0');
          formattedDate = '$day/$month $hour:$minute';
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
                                Text('Color: $colorText'),
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
                                Text(formattedDate),
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
                          Text('Color: $colorText'),
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
                          const Icon(Icons.attach_money, size: 18, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text('Price: $priceText'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.description, size: 18, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text('Total Pages: ${job.totalPages}'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.schedule, size: 18, color: Colors.grey),
                          const SizedBox(width: 8),
                          Text(formattedDate),
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

            final response = await _printJobService.getPrintJobByCode(job.code!);
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
                          final colorText = file.color == true ? 'Color' : 'B&W';
                          final doubleSideText = file.doubleSided ? 'Double' : 'Single';
                          final pagesRange = '${file.pagesStart ?? '-'} - ${file.pageEnd ?? '-'}';

                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${index + 1}. File ID: ${file.id}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                Text('  Color: $colorText | Side: $doubleSideText | Pages: ${file.totalPages}'),
                                Text('  Range: $pagesRange | Copies: ${file.copies ?? '-'}'),
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

  @override
  Widget build(BuildContext context) {
    if (_userRole != null &&
        ['shopowner', 'shopmanager', 'cashier', 'coffeshop'].contains(_userRole)) {
      return Scaffold(
        appBar: AppBar(
          title: const Text("Hlaprint"),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _loadOrders(isRefresh: true),
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SettingsPage()),
                );
              },
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
        title: const Text("Hlaprint"),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth > 600) {
            return Row(
              children: [
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
                  child: SingleChildScrollView(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: _buildKeypadSection(),
                      ),
                    ),
                  ),
                ),
              ],
            );
          } else {
            return Center(
              child: SingleChildScrollView(
                child: _buildKeypadSection(),
              ),
            );
          }
        },
      ),
    );
  }
}