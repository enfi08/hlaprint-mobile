class User {
  final String token;
  final String userRole;
  final String? shopId;
  final bool isSkipCashier;

  User({
    required this.token,
    required this.userRole,
    this.shopId,
    required this.isSkipCashier,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      token: json['token'],
      userRole: json["user_role"],
      shopId: json["shop_id"],
      isSkipCashier: json["is_skip_cashier_flow"]
    );
  }
}