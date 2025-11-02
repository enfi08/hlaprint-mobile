import 'dart:convert';

User userFromJson(String str) => User.fromJson(json.decode(str));

String userToJson(User data) => json.encode(data.toJson());

class User {
  final int id;
  final String name;
  final String email;
  final String role;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String shopId;
  final int isAdmin;
  final int companyId;
  final bool isSkipCashier;

  User({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.createdAt,
    required this.updatedAt,
    required this.shopId,
    required this.isAdmin,
    required this.companyId,
    required this.isSkipCashier,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
    id: json["id"],
    name: json["name"],
    email: json["email"],
    role: json["role"],
    createdAt: DateTime.parse(json["created_at"]),
    updatedAt: DateTime.parse(json["updated_at"]),
    shopId: json["shop_id"],
    isAdmin: json["is_admin"],
    companyId: json["company_id"],
    isSkipCashier: json["is_skip_cashier_flow"],
  );

  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "email": email,
    "role": role,
    "created_at": createdAt.toIso8601String(),
    "updated_at": updatedAt.toIso8601String(),
    "shop_id": shopId,
    "is_admin": isAdmin,
    "company_id": companyId,
    "is_skip_cashier_flow": isSkipCashier,
  };
}