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
  final List<TextEditingController> _pinControllers =
  List.generate(4, (_) => TextEditingController());
  final PrintJobService _printJobService = PrintJobService();
  bool _isLoading = false;
  String _pin = '';

  @override
  void initState() {
    super.initState();
    for (var controller in _pinControllers) {
      controller.addListener(_updatePin);
    }
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

  Future<void> _updatePrintJobStatus(int printJobId, String status) async {
    try {
      await _printJobService.updatePrintJobStatus(printJobId, status);
      debugPrint("Status for job $printJobId updated to: $status");
    } catch (e) {
      debugPrint("Failed to update print job status for $printJobId: $e");
    }
  }

  Future<void> _submitPrintJob() async {
    if (_pin.length != 4) return;

    setState(() {
      _isLoading = true;
    });

    try {
      PrintJobResponse response = await _printJobService.getPrintJobByCode(_pin);

      if (response.printFiles.isNotEmpty) {
        await _printInvoiceFromHtml(response);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${response.printFiles.length} print jobs found. Starting...')),
        );

        // Menggunakan loop untuk memproses setiap pekerjaan cetak satu per satu
        for (int i = 0; i < response.printFiles.length; i++) {
          final job = response.printFiles[i];
          File? downloadedFile;

          try {
            await _updatePrintJobStatus(job.id, 'Processing');

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
            await _printFile(downloadedFile, job);

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Print job ${i + 1} sent successfully!')),
            );
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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Print job ${i + 1} DONE!')),
            );
          }
        }

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All print jobs processed!')),
        );

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

  Future<void> _printInvoiceFromHtml(PrintJobResponse jobResponse) async {
    if (jobResponse.userRole != "online") {
      String colorStatus = '';
      if (jobResponse.printFiles.length == 1) {
        bool? color = jobResponse.printFiles.first.color;
        if (color == true) {
          colorStatus = 'color';
        } else if (color == false) {
          colorStatus = 'bw';
        }
      }

      String invoiceUrl;
      if (jobResponse.userRole == 'darkstore') {
        invoiceUrl = '$baseUrl/PrintInvoicesNana/${jobResponse
            .transactionId}/$colorStatus';
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
          await _printInvoiceFile(outputPdf);

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invoice printed!')),
          );
        } else {

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

  Future<void> _printInvoiceFile(File file) async {
    const platform = MethodChannel('com.hlaprint.app/printing');
    if (Platform.isWindows) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final printerName = prefs.getString('printer_name');

        if (printerName == null || printerName.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please to setting, and set the default print.'),
            ),
          );
          return;
        }

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


  Future<void> _printFile(File file, PrintJob job) async {
    const platform = MethodChannel('com.hlaprint.app/printing');
    if (Platform.isWindows) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final printerName = prefs.getString('printer_name');

        if (printerName == null || printerName.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please to setting, and set the default print.'),
            ),
          );
          return;
        }
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cetak berhasil!'),
              backgroundColor: Colors.green,
            ),
          );
        } else if (result == 'Sent To Printer') {
          await _updatePrintJobStatus(job.id, 'Sent To Printer');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Pekerjaan cetak sudah dikirim ke printer.'),
              backgroundColor: Colors.blue,
            ),
          );
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
              'Submit',
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