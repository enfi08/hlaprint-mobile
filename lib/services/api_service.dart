import 'dart:convert';
import 'package:Hlaprint/constants.dart';
import 'package:sentry/sentry.dart';
import 'package:http/http.dart' as http;

import 'package:Hlaprint/models/user_model.dart';
import 'package:Hlaprint/services/auth_service.dart';

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
          if (user.shopId == null) {
            throw Exception('This user account is missing a Shop ID. Please contact the administrator.');
          }
          await _authService.save(user.token, user.userRole, user.shopId!, user.isSkipCashier);
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
      if (e.toString().contains("Shop ID")) {
        rethrow;
      }
      throw Exception('Failed to connect to the server: $e');
    }
  }
}
