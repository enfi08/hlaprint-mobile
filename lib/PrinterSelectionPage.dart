import 'package:flutter/material.dart';
import 'brother_printer.dart';

class PrinterSelectionPage extends StatefulWidget {
  const PrinterSelectionPage({super.key});

  @override
  State<PrinterSelectionPage> createState() => _PrinterSelectionPageState();
}

class _PrinterSelectionPageState extends State<PrinterSelectionPage> {
  List<Map<String, dynamic>> _printers = [];
  bool _loading = true;
  final _ipController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadPrinters();
  }

  Future<void> _loadPrinters() async {
    print("👉 Memanggil discoverPrinters()");
    try {
      final printers = await BrotherPrinter.discoverPrinters();
      print("👉 Hasil discoverPrinters: $printers");

      setState(() {
        _printers = List<Map<String, dynamic>>.from(printers);
        _loading = false;
      });
    } catch (e) {
      print("❌ Error discoverPrinters: $e");
      setState(() {
        _printers = [];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Pilih Printer")),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _printers.isEmpty
          ? _buildManualInput(context)
          : ListView.builder(
        itemCount: _printers.length,
        itemBuilder: (context, index) {
          final printer = _printers[index];
          return ListTile(
            leading: const Icon(Icons.print),
            title: Text(printer["model"] ?? "Unknown"),
            subtitle: Text("IP: ${printer["ip"]}"),
            onTap: () {
              Navigator.pop(context, printer);
            },
          );
        },
      ),
    );
  }

  Widget _buildManualInput(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text("Tidak ada printer ditemukan.\nMasukkan IP printer manual:"),
          const SizedBox(height: 16),
          TextField(
            controller: _ipController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: "IP Address",
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              if (_ipController.text.isNotEmpty) {
                Navigator.pop(context, {
                  "model": "Manual Input",
                  "ip": _ipController.text,
                });
              }
            },
            child: const Text("Gunakan Printer"),
          ),
        ],
      ),
    );
  }
}
