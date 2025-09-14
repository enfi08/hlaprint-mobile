import 'dart:io';
import 'package:dio/dio.dart';
import 'package:hlaprint/constants.dart';
import 'package:hlaprint/models/print_job_model.dart';
import 'package:hlaprint/services/auth_service.dart';
import 'package:path_provider/path_provider.dart';

class PrintJobService {
  final AuthService _authService = AuthService();
  final Dio _dio = Dio();

  Future<List<PrintJob>> getPrintJobByCode(String code) async {
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
        return printJobsFromJson(response.toString());
      } else if (response.statusCode == 404) {
        throw Exception("Print job not found. Please check your 4-digits Code.");
      } else if (response.statusCode == 401) {
        throw Exception("Unauthorized. Session expired.");
      } else {
        throw Exception("Failed to load print job: ${response.statusCode}");
      }
    } on DioException catch (e) {
      if (e.response != null) {
        if (e.response?.statusCode == 404) {
          throw Exception("Print job not found. Please check your 4-digits Code.");
        } else if (e.response?.statusCode == 401) {
          throw Exception("Unauthorized. Session expired.");
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
}