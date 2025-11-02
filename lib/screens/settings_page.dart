import 'package:flutter/material.dart';
import 'package:hlaprint/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'dart:io';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _appVersion = 'Loading...';
  String? _selectedPrinter;
  String? _selectedColorPrinter;
  List<String> _printers = [];
  String? _userRole;

  @override
  void initState() {
    super.initState();
    _loadUserRole();
    _loadPrinters();
    _loadSelectedPrinter();
    _loadSelectedColorPrinter();
    _loadVersionInfo();
  }

  Future<void> _loadUserRole() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _userRole = prefs.getString(userRoleKey);
      });
    }
  }

  Future<void> _loadPrinters() async {
    if (Platform.isWindows) {
      final result = await Process.run('powershell', ['(Get-CimInstance Win32_Printer).Name']);
      if (result.exitCode == 0) {
        setState(() {
          final String output = result.stdout?.toString() ?? '';
          _printers = output.split('\n')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();
        });
      }
    }
  }

  Future<void> _loadSelectedPrinter() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedPrinter = prefs.getString(printerNameKey);
    });
  }

  Future<void> _loadSelectedColorPrinter() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _selectedColorPrinter = prefs.getString(printerColorNameKey);
      });
    }
  }

  Future<void> _savePrinterName() async {
    final prefs = await SharedPreferences.getInstance();
    bool changesMade = false;

    if (_selectedPrinter != null) {
      await prefs.setString(printerNameKey, _selectedPrinter!);
      changesMade = true;
    }

    if (_userRole != 'darkstore' && _selectedColorPrinter != null) {
      await prefs.setString(printerColorNameKey, _selectedColorPrinter!);
      changesMade = true;
    }

    if (changesMade && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Default Printer has been saved successfully!')),
      );
    }
  }

  Future<void> _loadVersionInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _appVersion = 'Version ${packageInfo.version} (${packageInfo.buildNumber})';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool showColorPrinterOption = _userRole != null && _userRole != 'darkstore';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Setting Default Printer'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    showColorPrinterOption ? 'B/W Printer:' : 'Select Printer:',
                    style: const TextStyle(fontSize: 16),
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
                  if (showColorPrinterOption) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'Color Printer:',
                      style: TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: _selectedColorPrinter,
                      hint: const Text('Please select color printer'),
                      items: _printers.map<DropdownMenuItem<String>>((String value) {
                        return DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        setState(() {
                          _selectedColorPrinter = newValue;
                        });
                      },
                    ),
                  ],
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _selectedPrinter != null ? _savePrinterName : null,
                    child: const Text('Save'),
                  ),

                  const SizedBox(height: 20),
                  Text(
                    _appVersion,
                    style: TextStyle(color: Colors.grey[600], fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

          ],
        ),
      ),
    );
  }
}