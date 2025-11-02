import 'dart:convert';

class PrintJobResponse {
  final int transactionId;
  final int companyId;
  final bool isUseSeparator;
  final bool isUseInvoice;
  final String userRole;
  final List<PrintJob> printFiles;

  PrintJobResponse({
    required this.transactionId,
    required this.companyId,
    required this.isUseSeparator,
    required this.isUseInvoice,
    required this.userRole,
    required this.printFiles,
  });

  factory PrintJobResponse.fromJson(Map<String, dynamic> json) {
    return PrintJobResponse(
      transactionId: json['transaction_id'] as int,
      companyId: json['company_id'] as int,
      isUseSeparator: json['isUseSeparator'] as bool,
      isUseInvoice: json['isUseInvoice'] as bool,
      userRole: json['user_role'] as String,
      printFiles: List<PrintJob>.from(
          json['print_files'].map((x) => PrintJob.fromJson(x))),
    );
  }
}

class PrintJob {
  final int id;
  final int? transactionId;
  final String filename;
  final String? phone;
  final bool? color;
  final bool doubleSided;
  final int pagesStart;
  final int pageEnd;
  final String? pageSize;
  final int? copies;
  final String? pageOrientation;
  final String? totalPrice;
  final int totalPages;
  final String status;
  final int? invoiceNumber;
  final String? code;
  final int? count;
  final String? price;
  final String? createdAt;

  PrintJob({
    required this.id,
    this.transactionId,
    required this.filename,
    this.phone,
    required this.color,
    required this.doubleSided,
    required this.pagesStart,
    required this.pageEnd,
    this.pageSize,
    this.copies,
    this.pageOrientation,
    this.totalPrice,
    required this.totalPages,
    required this.status,
    this.invoiceNumber,
    this.code,
    this.count,
    this.price,
    this.createdAt,
  });

  PrintJob copyWith({
    int? id,
    int? transactionId,
    String? filename,
    String? phone,
    bool? color,
    bool? doubleSided,
    int? pagesStart,
    int? pageEnd,
    String? pageSize,
    int? copies,
    String? pageOrientation,
    String? totalPrice,
    int? totalPages,
    String? status,
    int? invoiceNumber,
    String? code,
    int? count,
    String? price,
    String? createdAt,
  }) {
    return PrintJob(
      id: id ?? this.id,
      transactionId: transactionId ?? this.transactionId,
      filename: filename ?? this.filename,
      phone: phone ?? this.phone,
      color: color ?? this.color,
      doubleSided: doubleSided ?? this.doubleSided,
      pagesStart: pagesStart ?? this.pagesStart,
      pageEnd: pageEnd ?? this.pageEnd,
      pageSize: pageSize ?? this.pageSize,
      copies: copies ?? this.copies,
      pageOrientation: pageOrientation ?? this.pageOrientation,
      totalPrice: totalPrice ?? this.totalPrice,
      totalPages: totalPages ?? this.totalPages,
      status: status ?? this.status,
      invoiceNumber: invoiceNumber ?? this.invoiceNumber,
      code: code ?? this.code,
      count: count ?? this.count,
      price: price ?? this.price,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory PrintJob.fromJson(Map<String, dynamic> json) {
    return PrintJob(
      id: json['id'] as int,
      transactionId: json['transaction_id'] as int?,
      filename: json['filename'] as String,
      phone: json['phone'] as String?,
      color: json['color'] as bool?,
      doubleSided: json['double_sided'] as bool,
      pagesStart: json['pages_start'] as int,
      pageEnd: json['page_end'] as int,
      pageSize: json['page_size'] as String?,
      copies: json['copies'] as int?,
      pageOrientation: json['page_orientation'] as String?,
      totalPrice: json['total_price'] as String?,
      totalPages: json['total_pages'] as int,
      status: json['status'] as String,
      invoiceNumber: json['invoice_number'] as int?,
      code: json['code'] as String?,
      count: json['count'] as int?,
      price: json['price'] as String?,
      createdAt: json['created_at'] as String?,
    );
  }
}

PrintJobResponse printJobResponseFromJson(String str) {
  final jsonData = json.decode(str);
  return PrintJobResponse.fromJson(jsonData);
}