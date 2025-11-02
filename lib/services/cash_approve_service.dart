import 'package:dio/dio.dart';
import 'package:hlaprint/constants.dart';
import 'package:sentry/sentry.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hlaprint/services/auth_service.dart';

class CashApproveService {
  final AuthService _authService = AuthService();
  final Dio _dio = Dio();

  Future<void> cashApprove(String code) async {
    final token = await _authService.getToken();
    if (token == null) {
      throw Exception("Authentication token is missing.");
    }
    final prefs = await SharedPreferences.getInstance();
    final shopId = prefs.getString(shopIdKey);
    if (shopId == null) {
      throw Exception("Shop ID is missing.");
    }

    final url = '$baseUrl/api/cash_approve';
    final headers = {
      "Authorization": "Bearer $token",
      "Content-Type": "application/json",
      "Accept": "application/json",
    };

    final data = {
      "shop_id": shopId,
      "code": code,
    };

    try {
      final response = await _dio.put(
        url,
        data: data,
        options: Options(headers: headers),
      );

      if (response.statusCode != 200) {
        throw Exception("Failed to approve cash transaction: ${response.statusCode}");
      }
    } on DioException catch (e, s) {
      await Sentry.captureException(
        e,
        stackTrace: s,
      );
      if (e.response != null) {
        throw Exception("Server error: ${e.response?.statusCode} - ${e.response?.data['message']}");
      }
      throw Exception("Failed to connect to the server: ${e.message}");
    }
  }
}