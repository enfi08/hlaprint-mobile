import 'dart:convert';

class PrintJob {
  final int id;
  final String filename;
  final bool color;
  final bool doubleSided;
  final int pagesStart;
  final int pageEnd;
  final String pageSize;
  final int copies;
  final String pageOrientation;
  final String totalPrice;
  final int totalPages;
  final String invoiceFilename;
  final String status;

  PrintJob({
    required this.id,
    required this.filename,
    required this.color,
    required this.doubleSided,
    required this.pagesStart,
    required this.pageEnd,
    required this.pageSize,
    required this.copies,
    required this.pageOrientation,
    required this.totalPrice,
    required this.totalPages,
    required this.invoiceFilename,
    required this.status,
  });

  factory PrintJob.fromJson(Map<String, dynamic> json) {
    return PrintJob(
      id: json['id'] as int,
      filename: json['filename'] as String,
      color: json['color'] as bool,
      doubleSided: json['double_sided'] as bool,
      pagesStart: json['pages_start'] as int,
      pageEnd: json['page_end'] as int,
      pageSize: json['page_size'] as String,
      copies: json['copies'] as int,
      pageOrientation: json['page_orientation'] as String,
      totalPrice: json['total_price'] as String,
      totalPages: json['total_pages'] as int,
      invoiceFilename: json['invoice_filename'] as String,
      status: json['status'] as String,
    );
  }
}

List<PrintJob> printJobsFromJson(String str) {
  final jsonData = json.decode(str);
  return List<PrintJob>.from(jsonData['print_files'].map((x) => PrintJob.fromJson(x)));
}