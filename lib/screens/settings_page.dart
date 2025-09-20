import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _selectedPrinter;
  List<String> _printers = [];

  @override
  void initState() {
    super.initState();
    _loadPrinters();
    _loadSelectedPrinter();
  }

  Future<void> _loadPrinters() async {
    if (Platform.isWindows) {
      final result = await Process.run('powershell', ['(Get-CimInstance Win32_Printer).Name']);
      if (result.exitCode == 0) {
        setState(() {
          _printers = result.stdout.toString().split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          // Jika tidak ada printer yang dipilih, atur pilihan default
          if (_selectedPrinter == null && _printers.isNotEmpty) {
            _selectedPrinter = _printers.first;
          }
        });
      }
    }
  }

  Future<void> _loadSelectedPrinter() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedPrinter = prefs.getString('printer_name');
    });
  }

  Future<void> _savePrinterName() async {
    if (_selectedPrinter != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('printer_name', _selectedPrinter!);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Default Printer has been saved successfully!')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Setting Default Printer'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Select Printer:',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            DropdownButton<String>(
              isExpanded: true,
              value: _selectedPrinter,
              hint: const Text('Please select printer'),
              items: _printers.map<DropdownMenuItem<String>>((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value),
                );
              }).toList(),
              onChanged: (String? newValue) {
                setState(() {
                  _selectedPrinter = newValue;
                });
              },
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _selectedPrinter != null ? _savePrinterName : null,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}