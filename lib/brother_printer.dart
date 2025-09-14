import 'package:flutter/services.dart';

class BrotherPrinter {
  static const _channel = MethodChannel('brother_printer');

  /// Set default printer (contoh pakai IP address)
  static Future<bool> setDefaultPrinter(String ip) async {
    final result = await _channel.invokeMethod('setDefaultPrinter', {"ip": ip});
    return result == true;
  }

  /// scan printer di jaringan
  static Future<List<dynamic>> discoverPrinters() async {
    final result = await _channel.invokeMethod('discoverPrinters');
    return result ?? [];
  }


  /// Print file (path local PDF/gambar)
  static Future<bool> printFile(String filePath) async {
    final result = await _channel.invokeMethod('printFile', {"path": filePath});
    return result == true;
  }
}
