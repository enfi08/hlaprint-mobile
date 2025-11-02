import 'dart:io';
import 'package:dio/dio.dart';
import 'package:hlaprint/constants.dart';
import 'package:hlaprint/models/print_job_model.dart';
import 'package:hlaprint/services/auth_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:sentry/sentry.dart';
import 'dart:convert';

class PrintJobService {
  final AuthService _authService = AuthService();
  final Dio _dio = Dio();

  Future<PrintJobResponse> getPrintJobByCode(String code) async {
    final token = await _authService.getToken();
    if (token == null) {
      throw Exception("Authentication token is missing.");
    }

    final url = '$baseUrl/api/printCode/$code';
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
    );

    if (response.statusCode != 200) {
      final errorData = json.decode(response.body);
      throw Exception(errorData['message'] ?? 'Failed to update print job status.');
    }
  }

  Future<String> fetchInvoiceHtml(String invoiceUrl) async {
    final response = await http.get(Uri.parse(invoiceUrl));

    if (response.statusCode == 200) {
      return response.body;
    } else {
      throw Exception('Failed to fetch invoice HTML.');
    }
  }
}