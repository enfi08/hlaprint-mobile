import 'dart:io';
import 'package:dio/dio.dart';
import 'package:Hlaprint/constants.dart';
import 'package:Hlaprint/models/print_job_model.dart';
import 'package:Hlaprint/services/auth_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:sentry/sentry.dart';
import 'dart:convert';

class PrintJobService {
  final AuthService _authService = AuthService();
  final Dio _dio = Dio();

  Future<PrintJobResponse> getPrintJobByCode(String code, bool isWithDetail) async {
    final token = await _authService.getToken();
    if (token == null) {
      throw Exception("Authentication token is missing.");
    }

    final path = isWithDetail ? 'printCodeDetail' : 'printCode';
    final url = '$baseUrl/api/$path/$code';
    final headers = {
      "Authorization": "Bearer $token",
      "Accept": "application/json",
    };

    try {
      final response = await _dio.get(url, options: Options(headers: headers));

      if (response.statusCode == 200) {
        return printJobResponseFromJson(response.toString());
      } else if (response.statusCode == 404) {
        throw Exception("Print job not found. Please check your 4-digits Code.");
      } else if (response.statusCode == 401) {
        throw Exception("Unauthorized. Session expired.");
      } else {
        throw Exception("Failed to load print job: ${response.statusCode}");
      }
    } on DioException catch (e, s) {
      if (e.response != null) {
        if (e.response?.statusCode == 404) {
          throw Exception("Print job not found. Please check your 4-digits Code.");
        } else if (e.response?.statusCode == 401) {
          throw Exception("Unauthorized. Session expired.");
        } else {
          await Sentry.captureException(
            e,
            stackTrace: s,
          );
        }
      }
      throw Exception("Failed to connect to the server: ${e.message}");
    }
  }

  Future<File> downloadFile(String url, String filename) async {
    final dir = await getTemporaryDirectory();
    final savePath = '${dir.path}/$filename';
    await _dio.download(url, savePath);
    return File(savePath);
  }

  Future<void> updatePrintJobStatus(int printJobId, String status) async {
    int maxRetries = 3;
    int attempt = 0;

    while (attempt < maxRetries) {
      try {
        attempt++;
        final response = await http.post(
          Uri.parse('$baseUrl/api/update-status'),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, dynamic>{
            'pass': '123qwe123.,',
            'printJobId': printJobId.toString(),
            'status': status,
          }),
        ).timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          return;
        } else {
          if (attempt == maxRetries) {
            try {
              final errorData = json.decode(response.body);
              throw Exception(errorData['message'] ?? 'Failed to update print job status.');
            } catch (_) {
              throw Exception('Failed to update print job status. Status Code: ${response.statusCode}');
            }
          }
        }
      } catch (e) {
        if (attempt == maxRetries) {
          throw Exception("Failed to update status after $maxRetries attempts. Error: $e");
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<String> fetchInvoiceHtml(String invoiceUrl) async {
    int maxRetries = 3;
    int attempt = 0;
    while (attempt < maxRetries) {
      try {
        attempt++;
        final response = await http
            .get(Uri.parse(invoiceUrl))
            .timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          return response.body;
        } else {
          if (attempt == maxRetries) {
            throw Exception("Failed to fetch invoice HTML. Status: ${response.statusCode}");
          }
        }
      } catch (e) {
        if (attempt == maxRetries) {
          throw Exception("Failed to fetch invoice HTML after $maxRetries attempts. Error: $e");
        }

        await Future.delayed(const Duration(seconds: 2));
      }
    }
    throw Exception("Failed to fetch invoice HTML: Unknown error");
  }
}