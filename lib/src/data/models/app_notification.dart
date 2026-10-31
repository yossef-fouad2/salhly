import 'package:equatable/equatable.dart';

class AppNotification extends Equatable {
  const AppNotification({
    required this.id,
    required this.userId,
    required this.titleEn,
    required this.titleAr,
    required this.bodyEn,
    required this.bodyAr,
    required this.createdAt,
    this.readAt,
  });

  final String id;
  final String userId;
  final String titleEn;
  final String titleAr;
  final String bodyEn;
  final String bodyAr;
  final DateTime createdAt;
  final DateTime? readAt;

  bool get isRead => readAt != null;

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    return AppNotification(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      titleEn: json['title_en'] as String,
      titleAr: json['title_ar'] as String,
      bodyEn: json['body_en'] as String,
      bodyAr: json['body_ar'] as String,
      createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      readAt: json['read_at'] == null
          ? null
          : DateTime.parse(json['read_at'] as String).toUtc(),
    );
  }

  String title(String languageCode) => languageCode == 'ar' ? titleAr : titleEn;

  String body(String languageCode) => languageCode == 'ar' ? bodyAr : bodyEn;

  AppNotification withReadAt(DateTime timestamp) {
    if (isRead) return this;
    return AppNotification(
      id: id,
      userId: userId,
      titleEn: titleEn,
      titleAr: titleAr,
      bodyEn: bodyEn,
      bodyAr: bodyAr,
      createdAt: createdAt,
      readAt: timestamp.toUtc(),
    );
  }

  @override
  List<Object?> get props => [
    id,
    userId,
    titleEn,
    titleAr,
    bodyEn,
    bodyAr,
    createdAt,
    readAt,
  ];
}
