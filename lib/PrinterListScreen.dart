import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

class PrinterListScreen extends StatefulWidget {
  const PrinterListScreen({super.key});

  @override
  _PrinterListScreenState createState() => _PrinterListScreenState();
}

class _PrinterListScreenState extends State<PrinterListScreen> {
  List<Printer> _printers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchPrinters();
  }

  Future<void> _fetchPrinters() async {
    print('Mulai mencari printer...'); // <--- Tambahkan ini
    setState(() {
      _isLoading = true;
    });

    try {
      final printers = await Printing.listPrinters();
      print('Pencarian selesai. Ditemukan ${printers.length} printer.'); // <--- Tambahkan ini
      // Periksa detail printer yang ditemukan
      for (var printer in printers) {
        print('Nama Printer: ${printer.name}');
        print('URL Printer: ${printer.url}');
      }
      setState(() {
        _printers = printers;
      });
    } catch (e) {
      print('Error fetching printers: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Daftar Printer Wi-Fi'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchPrinters,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _printers.isEmpty
          ? const Center(child: Text('Tidak ada printer yang ditemukan di jaringan Wi-Fi.'))
          : ListView.builder(
        itemCount: _printers.length,
        itemBuilder: (context, index) {
          final printer = _printers[index];
          return ListTile(
            title: Text(printer.name ?? 'Nama Tidak Diketahui'),
            subtitle: Text(printer.url ?? 'Alamat Tidak Diketahui'),
            leading: const Icon(Icons.wifi),
          );
        },
      ),
    );
  }
}