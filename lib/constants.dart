
const bool isStaging = false;

const String baseUrl = isStaging ? "http://hlaprint.com:8000" : "https://hlaprint.com";

const String tokenKey = isStaging ? "staging_auth_token" : "auth_token";
const String userRoleKey = isStaging ? "staging_user_role" : "user_role";
const String userIdKey = isStaging ? "staging_user_id" : "user_id";
const String nameKey = isStaging ? "staging_user_name" : "user_name";
const String emailKey = isStaging ? "staging_user_email" : "user_email";
const String shopIdKey = isStaging ? "staging_shop_id" : "shop_id";
const String skipCashierKey = isStaging ? "staging_is_skip_cashier" : "is_skip_cashier";
const String printerNameKey = isStaging ? "staging_printer_name" : "printer_name";
const String printerColorNameKey = isStaging ? "staging_printer_color_name" : "printer_color_name";
const String ipPrinterKey = isStaging ? "staging_ip_printer" : "ip_printer";