import 'dart:math';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import '../../utils/failure.dart';

final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

String _newId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

bool _textWithin(String text, int minimum, int maximum) {
  final length = text.trim().runes.length;
  return length >= minimum && length <= maximum;
}

enum ServiceRequestStatus { open, cancelled }

/// Session-only input. Identity equality avoids comparing megabytes on keystrokes.
final class RequestPhotoInput {
  const RequestPhotoInput._(this.id, this.bytes, this.mimeType, this.extension);
  static const maxBytes = 5242880;
  final String id;
  final Uint8List bytes;
  final String mimeType;
  final String extension;
  int get sizeBytes => bytes.length;

  factory RequestPhotoInput.fromBytes(Uint8List bytes, {String? id}) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const ServerFailure('requests.errors.photo_size');
    }
    final jpeg =
        bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    const pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    final png =
        bytes.length >= pngSignature.length &&
        Iterable<int>.generate(pngSignature.length)
            .every((i) => bytes[i] == pngSignature[i]);
    if (!jpeg && !png) throw const ServerFailure('requests.errors.photo_type');
    final identifier = id ?? _newId();
    if (!_uuidV4.hasMatch(identifier)) {
      throw const ServerFailure('requests.errors.photos');
    }
    return RequestPhotoInput._(
      identifier,
      Uint8List.fromList(bytes).asUnmodifiableView(),
      jpeg ? 'image/jpeg' : 'image/png',
      jpeg ? 'jpg' : 'png',
    );
  }
}

class ServiceRequestDraft extends Equatable {
  ServiceRequestDraft({
    required this.id,
    this.categoryId,
    this.title = '',
    this.description = '',
    this.city = '',
    this.address = '',
    this.preferredAt,
    List<RequestPhotoInput> photos = const [],
    this.consent = false,
  }) : photos = List.unmodifiable(photos);

  factory ServiceRequestDraft.create({String? categoryId, String city = ''}) =>
      ServiceRequestDraft(id: _newId(), categoryId: categoryId, city: city);

  final String id;
  final String? categoryId;
  final String title;
  final String description;
  final String city;
  final String address;
  final DateTime? preferredAt;
  final List<RequestPhotoInput> photos;
  final bool consent;

  static bool validId(String id) => _uuidV4.hasMatch(id);

  ServiceRequestDraft copyWith({
    String? categoryId,
    bool clearCategory = false,
    String? title,
    String? description,
    String? city,
    String? address,
    DateTime? preferredAt,
    bool clearPreferredAt = false,
    List<RequestPhotoInput>? photos,
    bool? consent,
  }) => ServiceRequestDraft(
    id: id,
    categoryId: clearCategory ? null : categoryId ?? this.categoryId,
    title: title ?? this.title,
    description: description ?? this.description,
    city: city ?? this.city,
    address: address ?? this.address,
    preferredAt: clearPreferredAt ? null : preferredAt ?? this.preferredAt,
    photos: photos ?? this.photos,
    consent: consent ?? this.consent,
  );

  String? validate({DateTime? now}) {
    if (!validId(id)) return 'requests.errors.invalid_request';
    if (categoryId == null || categoryId!.trim().isEmpty) {
      return 'requests.errors.category';
    }
    if (!_textWithin(title, 5, 120)) return 'requests.errors.title';
    if (!_textWithin(description, 10, 2000)) {
      return 'requests.errors.description';
    }
    if (!_textWithin(city, 2, 100)) return 'requests.errors.city';
    if (!_textWithin(address, 5, 500)) return 'requests.errors.address';
    final clock = now ?? DateTime.now();
    if (preferredAt != null &&
        (!preferredAt!.isAfter(clock) ||
            preferredAt!.isAfter(clock.add(const Duration(days: 180))))) {
      return 'requests.errors.preferred_time';
    }
    if (photos.length > 3 ||
        photos.map((photo) => photo.id).toSet().length != photos.length) {
      return 'requests.errors.photos';
    }
    if (!consent) return 'requests.errors.consent';
    return null;
  }

  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [
    id,
    categoryId,
    title,
    description,
    city,
    address,
    preferredAt,
    photos,
    consent,
  ];
}

class ServiceRequestPhoto extends Equatable {
  const ServiceRequestPhoto({
    required this.id,
    required this.storagePath,
    required this.mimeType,
    required this.sizeBytes,
    required this.position,
  });

  factory ServiceRequestPhoto.fromJson(Map<String, dynamic> json) =>
      ServiceRequestPhoto(
        id: json['id'] as String,
        storagePath: json['storage_path'] as String,
        mimeType: json['mime_type'] as String,
        sizeBytes: json['size_bytes'] as int,
        position: json['position'] as int,
      );

  final String id;
  final String storagePath;
  final String mimeType;
  final int sizeBytes;
  final int position;

  Map<String, Object> toJson() => {
    'id': id,
    'storage_path': storagePath,
    'mime_type': mimeType,
    'size_bytes': sizeBytes,
    'position': position,
  };

  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [id, storagePath, mimeType, sizeBytes, position];
}

class ServiceRequest extends Equatable {
  ServiceRequest({
    required this.id,
    required this.customerId,
    required this.categoryId,
    required this.categoryNameEn,
    required this.categoryNameAr,
    required this.categoryIconKey,
    required this.title,
    required this.description,
    required this.city,
    required this.address,
    this.preferredAt,
    required this.status,
    required this.createdAt,
    required this.consentedAt,
    this.cancelledAt,
    List<ServiceRequestPhoto> photos = const [],
  }) : photos = List.unmodifiable(photos);

  factory ServiceRequest.fromJson(Map<String, dynamic> json) {
    final photos =
        (json['photos'] as List)
            .map(
              (photo) =>
                  ServiceRequestPhoto.fromJson(photo as Map<String, dynamic>),
            )
            .toList()
          ..sort((a, b) => a.position.compareTo(b.position));
    final request = ServiceRequest(
      id: json['id'] as String,
      customerId: json['customer_id'] as String,
      categoryId: json['category_id'] as String,
      categoryNameEn: json['category_name_en'] as String,
      categoryNameAr: json['category_name_ar'] as String,
      categoryIconKey: json['category_icon_key'] as String,
      title: json['title'] as String,
      description: json['description'] as String,
      city: json['city'] as String,
      address: json['address'] as String,
      preferredAt: json['preferred_at'] == null
          ? null
          : DateTime.parse(json['preferred_at'] as String).toUtc(),
      status: ServiceRequestStatus.values.byName(json['status'] as String),
      createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
      consentedAt: DateTime.parse(json['consented_at'] as String).toUtc(),
      cancelledAt: json['cancelled_at'] == null
          ? null
          : DateTime.parse(json['cancelled_at'] as String).toUtc(),
      photos: photos,
    );
    if (!ServiceRequestDraft.validId(request.id) ||
        request.customerId.isEmpty ||
        request.categoryId.isEmpty ||
        request.categoryNameEn.isEmpty ||
        request.categoryNameAr.isEmpty ||
        request.categoryIconKey.isEmpty ||
        !_textWithin(request.title, 5, 120) ||
        !_textWithin(request.description, 10, 2000) ||
        !_textWithin(request.city, 2, 100) ||
        !_textWithin(request.address, 5, 500) ||
        photos.length > 3 ||
        photos.map((photo) => photo.id).toSet().length != photos.length ||
        (request.status == ServiceRequestStatus.open &&
            request.cancelledAt != null) ||
        (request.status == ServiceRequestStatus.cancelled &&
            (request.cancelledAt == null ||
                request.cancelledAt!.isBefore(request.createdAt)))) {
      throw const FormatException('Invalid service request.');
    }
    for (final (index, photo) in photos.indexed) {
      final extension = switch (photo.mimeType) {
        'image/jpeg' => 'jpg',
        'image/png' => 'png',
        _ => '',
      };
      if (!ServiceRequestDraft.validId(photo.id) ||
          extension.isEmpty ||
          photo.position != index + 1 ||
          photo.sizeBytes <= 0 ||
          photo.sizeBytes > RequestPhotoInput.maxBytes ||
          photo.storagePath !=
              '${request.customerId}/${request.id}/${photo.id}.$extension') {
        throw const FormatException('Invalid request photo.');
      }
    }
    return request;
  }

  final String id;
  final String customerId;
  final String categoryId;
  final String categoryNameEn;
  final String categoryNameAr;
  final String categoryIconKey;
  final String title;
  final String description;
  final String city;
  final String address;
  final DateTime? preferredAt;
  final ServiceRequestStatus status;
  final DateTime createdAt;
  final DateTime consentedAt;
  final DateTime? cancelledAt;
  final List<ServiceRequestPhoto> photos;

  String categoryName(String languageCode) =>
      languageCode == 'ar' ? categoryNameAr : categoryNameEn;

  Map<String, Object?> toJson() => {
    'id': id,
    'customer_id': customerId,
    'category_id': categoryId,
    'category_name_en': categoryNameEn,
    'category_name_ar': categoryNameAr,
    'category_icon_key': categoryIconKey,
    'title': title,
    'description': description,
    'city': city,
    'address': address,
    'preferred_at': preferredAt?.toUtc().toIso8601String(),
    'status': status.name,
    'created_at': createdAt.toUtc().toIso8601String(),
    'consented_at': consentedAt.toUtc().toIso8601String(),
    'cancelled_at': cancelledAt?.toUtc().toIso8601String(),
    'photos': photos.map((photo) => photo.toJson()).toList(),
  };

  @override
  bool get stringify => false;
  @override
  List<Object?> get props => [
    id,
    customerId,
    categoryId,
    categoryNameEn,
    categoryNameAr,
    categoryIconKey,
    title,
    description,
    city,
    address,
    preferredAt,
    status,
    createdAt,
    consentedAt,
    cancelledAt,
    photos,
  ];
}

class ServiceRequestPage {
  ServiceRequestPage({
    required List<ServiceRequest> items,
    required this.hasMore,
  }) : items = List.unmodifiable(items);
  final List<ServiceRequest> items;
  final bool hasMore;
}
