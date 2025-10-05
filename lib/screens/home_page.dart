import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hlaprint/colors.dart';
import 'package:hlaprint/models/print_job_model.dart';
import 'package:hlaprint/screens/settings_page.dart';
import 'package:hlaprint/services/auth_service.dart';
import 'package:hlaprint/services/print_job_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:hlaprint/constants.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

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
  bool _isLoading = false;
  String _pin = '';
  String _printerStatus = '';

  @override
  void initState() {
    super.initState();
    for (var controller in _pinControllers) {
      controller.addListener(_updatePin);
    }

    platform.setMethodCallHandler((call) async {
      if (call.method == "onPrinterStatus") {
        setState(() {
          _printerStatus = call.arguments; // "Online" / "Offline"
          // ScaffoldMessenger.of(context).showSnackBar(
          //   SnackBar(
          //     content: Text('printer status: $_printerStatus')
          //   ),
          // );
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
            // ScaffoldMessenger.of(context).showSnackBar(
            //   SnackBar(
            //       content: Text(
            //           'Print job $jobId completed by OS. Starting delay for $totalPages pages.')
            //   ),
            // );

            // Menjalankan Timer untuk delay
            Timer(Duration(seconds: delaySeconds), () async {
              await _updatePrintJobStatus(jobId, 'Completed', currentStatus: 'Sent To Printer');
              debugPrint('Print job $jobId status set to Completed after $delaySeconds seconds.');
              // ScaffoldMessenger.of(context).showSnackBar(
              //   SnackBar(
              //     content: Text('Print job $jobId status set to Completed after $delaySeconds seconds.'),
              //     backgroundColor: Colors.green,
              //   ),
              // );
            });
          }
        });
      }
    });

  }

  @override
  void dispose() {
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
    } catch (e) {
      debugPrint("Failed to update print job status for $printJobId: $e");
    }
  }

  Future<void> _submitPrintJob() async {
    final prefs = await SharedPreferences.getInstance();
    final userRole = prefs.getString(userRoleKey);
    final bwPrinterName = prefs.getString(printerNameKey);
    final colorPrinterName = prefs.getString(printerColorNameKey);

    if (bwPrinterName == null || bwPrinterName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(userRole != null && userRole != 'darkstore'
              ? 'Please to setting, and set the b/w printer'
              : 'Please to setting, and set the default print.'),
        ),
      );
      return;
    }

    // platform.invokeMethod("startMonitorPrinter", {"printerName": printerName}); return;

    setState(() {
      _isLoading = true;
    });

    try {
      PrintJobResponse response = await _printJobService.getPrintJobByCode(_pin);

      if (userRole != null && userRole != 'darkstore') {
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
          if (userRole != null && userRole != 'darkstore' && response.printFiles.first.color == true) {
            invoicePrinter = colorPrinterName!;
          }
          await _printInvoiceFromHtml(invoicePrinter, response);
        }

        // Menggunakan loop untuk memproses setiap pekerjaan cetak satu per satu
        for (int i = 0; i < response.printFiles.length; i++) {
          final job = response.printFiles[i];
          File? downloadedFile;

          String selectedPrinter;
          if (userRole != null && userRole != 'darkstore' && job.color == true) {
            selectedPrinter = colorPrinterName!;
          } else {
            selectedPrinter = bwPrinterName;
          }

          try {
            await _updatePrintJobStatus(job.id, 'Processing', currentStatus: job.status);

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Downloading file ${i + 1} of ${response.printFiles.length}...')),
            );

            // Download file untuk pekerjaan saat ini
            downloadedFile = await _printJobService.downloadFile(
              job.filename,
              job.invoiceFilename,
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
      } catch (e) {
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
            'color': color ?? false,
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
      } on PlatformException catch (e) {
        debugPrint("Failed to print: '${e.message}'.");
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
      } catch (e) {
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
    } catch (e) {
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
      } on PlatformException catch (e) {
        debugPrint("Failed to print: '${e.message}'.");
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
      } catch (e) {
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

  @override
  Widget build(BuildContext context) {
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