import 'dart:convert';
import 'package:hlaprint/constants.dart';
import 'package:sentry/sentry.dart';
import 'package:hlaprint/models/user_model.dart';
import 'package:hlaprint/services/auth_service.dart';
import 'package:http/http.dart' as http;

class ApiService {
  final AuthService _authService = AuthService();

  Future<User> login(String email, String password) async {
    final url = Uri.parse('$baseUrl/api/login');
    final headers = {"Content-Type": "application/json"};
    final body = jsonEncode({
      "email": email,
      "password": password,
    });

    try {
      final response = await http.post(
        url,
        headers: headers,
        body: body,
      );

      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(response.body);
        if (jsonResponse['status'] == 200) {
          User user = User.fromJson(jsonResponse);
          await _authService.save(user.token, user.userRole, user.shopId, user.isSkipCashier);
          return user;
        } else {
          throw Exception(jsonResponse['message']);
        }
      } else if (response.statusCode == 401) {
        final jsonResponse = jsonDecode(response.body);
        throw Exception(jsonResponse['message']);
      } else {
        throw Exception('Failed to login: ${response.statusCode}');
      }
    } catch (e, s) {
      await Sentry.captureException(
        e,
        stackTrace: s,
      );
      throw Exception('Failed to connect to the server: $e');
    }
  }
}
