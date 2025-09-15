import 'package:flutter/material.dart';
import 'package:hlaprint/colors.dart';
import 'package:hlaprint/models/print_job_model.dart';
import 'package:hlaprint/screens/settings_page.dart';
import 'package:hlaprint/services/auth_service.dart';
import 'package:hlaprint/services/print_job_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:pdf/widgets.dart' as pw;
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

  Future<void> _submitPrintJob() async {
    if (_pin.length != 4) return;

    setState(() {
      _isLoading = true;
    });

    try {
      List<PrintJob> jobs = await _printJobService.getPrintJobByCode(_pin);

      if (jobs.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${jobs.length} print jobs found. Starting...')),
        );

        for (int i = 0; i < jobs.length; i++) {
          final job = jobs[i];
          File? downloadedFile;

          try {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Downloading file ${i + 1} of ${jobs.length}...')),
            );

            // Download file untuk pekerjaan saat ini
            downloadedFile = await _printJobService.downloadFile(
              job.filename,
              job.invoiceFilename,
            );

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Download complete. Printing file ${i + 1} of ${jobs.length}...')),
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
            // Anda bisa memilih untuk continue ke pekerjaan berikutnya atau break
            continue;
          } finally {
            // Hapus file sementara setelah setiap pekerjaan selesai atau gagal
            if (downloadedFile != null && await downloadedFile.exists()) {
              await downloadedFile.delete();
              debugPrint("Temporary file deleted for job ${i + 1}.");
            }
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
      });
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
              content: Text('Silakan ke Pengaturan, pilih default print.'),
            ),
          );
          return;
        }
        final String result = await platform.invokeMethod(
          'printPDF',
          {
            'filePath': file.path,
            'printerName': printerName,
            'color': job.color, // <--- Metadata ditambahkan
            'doubleSided': job.doubleSided,
            'pagesStart': job.pagesStart,
            'pageEnd': job.pageEnd,
            'copies': job.copies,
            'pageOrientation': job.pageOrientation,
          },
        );
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
