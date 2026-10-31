import 'package:equatable/equatable.dart';

/// Local service-area wall-clock hours, not appointment slots.
class ProviderAvailability extends Equatable {
  const ProviderAvailability({
    required this.weekday,
    required this.startMinute,
    required this.endMinute,
  });

  final int weekday;
  final int startMinute;
  final int endMinute;

  factory ProviderAvailability.fromJson(Map<String, dynamic> json) {
    return ProviderAvailability(
      weekday: json['weekday'] as int,
      startMinute: json['start_minute'] as int,
      endMinute: json['end_minute'] as int,
    );
  }

  Map<String, int> toJson() => {
    'weekday': weekday,
    'start_minute': startMinute,
    'end_minute': endMinute,
  };

  @override
  List<Object> get props => [weekday, startMinute, endMinute];
}

enum ProviderVerificationStatus { pending, verified, rejected }

class ProviderVerification extends Equatable {
  const ProviderVerification({
    required this.id,
    required this.documentPath,
    required this.mimeType,
    required this.sizeBytes,
    required this.status,
    required this.submittedAt,
    this.reviewedAt,
    this.reviewNote,
  });

  final String id;
  final String documentPath;
  final String mimeType;
  final int sizeBytes;
  final ProviderVerificationStatus status;
  final DateTime submittedAt;
  final DateTime? reviewedAt;
  final String? reviewNote;

  factory ProviderVerification.fromJson(Map<String, dynamic> json) {
    return ProviderVerification(
      id: json['id'] as String,
      documentPath: json['document_path'] as String,
      mimeType: json['mime_type'] as String,
      sizeBytes: json['size_bytes'] as int,
      status: ProviderVerificationStatus.values.byName(
        json['status'] as String,
      ),
      submittedAt: DateTime.parse(json['submitted_at'] as String).toUtc(),
      reviewedAt: json['reviewed_at'] == null
          ? null
          : DateTime.parse(json['reviewed_at'] as String).toUtc(),
      reviewNote: json['review_note'] as String?,
    );
  }

  @override
  bool get stringify => false;

  @override
  List<Object?> get props => [
    id,
    documentPath,
    mimeType,
    sizeBytes,
    status,
    submittedAt,
    reviewedAt,
    reviewNote,
  ];
}

class ProviderProfile extends Equatable {
  ProviderProfile({
    required this.userId,
    this.bio = '',
    List<String> skillIds = const [],
    List<String> serviceAreas = const [],
    List<ProviderAvailability> availability = const [],
    this.verification,
  }) : skillIds = List.unmodifiable(skillIds),
       serviceAreas = List.unmodifiable(serviceAreas),
       availability = List.unmodifiable(availability);

  factory ProviderProfile.empty(String userId) =>
      ProviderProfile(userId: userId);

  final String userId;
  final String bio;
  final List<String> skillIds;
  final List<String> serviceAreas;
  final List<ProviderAvailability> availability;
  final ProviderVerification? verification;

  bool get canEdit =>
      verification?.status != ProviderVerificationStatus.pending;

  bool get canSubmit =>
      verification == null ||
      verification!.status == ProviderVerificationStatus.rejected;

  factory ProviderProfile.fromJson(Map<String, dynamic> json) {
    return ProviderProfile(
      userId: json['user_id'] as String,
      bio: json['bio'] as String,
      skillIds: (json['skill_ids'] as List<Object?>).cast<String>(),
      serviceAreas: (json['service_areas'] as List<Object?>).cast<String>(),
      availability: (json['availability'] as List<Object?>)
          .map(
            (item) =>
                ProviderAvailability.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      verification: json['verification'] == null
          ? null
          : ProviderVerification.fromJson(
              json['verification'] as Map<String, dynamic>,
            ),
    );
  }

  static const _unchanged = Object();

  ProviderProfile copyWith({
    String? userId,
    String? bio,
    List<String>? skillIds,
    List<String>? serviceAreas,
    List<ProviderAvailability>? availability,
    Object? verification = _unchanged,
  }) {
    return ProviderProfile(
      userId: userId ?? this.userId,
      bio: bio ?? this.bio,
      skillIds: skillIds ?? this.skillIds,
      serviceAreas: serviceAreas ?? this.serviceAreas,
      availability: availability ?? this.availability,
      verification: identical(verification, _unchanged)
          ? this.verification
          : verification as ProviderVerification?,
    );
  }

  /// Shape validation only; active category membership is checked on save/submit.
  String? validate({bool forSubmission = false}) {
    if (userId.trim().isEmpty) return 'provider.errors.invalid_profile';
    final bioLength = bio.trim().runes.length;
    if (bioLength > 1000 || (forSubmission && bioLength < 20)) {
      return 'provider.errors.bio';
    }
    if (skillIds.length > 20 ||
        (forSubmission && skillIds.isEmpty) ||
        skillIds.any((id) => id.trim().isEmpty || id != id.trim()) ||
        skillIds.map((id) => id.toLowerCase()).toSet().length !=
            skillIds.length) {
      return 'provider.errors.skills';
    }
    final areas = serviceAreas.map((area) => area.trim()).toList();
    if (areas.length > 10 ||
        (forSubmission && areas.isEmpty) ||
        areas.any((area) => area.runes.length < 2 || area.runes.length > 100) ||
        areas.map((area) => area.toLowerCase()).toSet().length !=
            areas.length) {
      return 'provider.errors.areas';
    }
    if (availability.length > 7 ||
        (forSubmission && availability.isEmpty) ||
        availability.map((hours) => hours.weekday).toSet().length !=
            availability.length ||
        availability.any(
          (hours) =>
              hours.weekday < 1 ||
              hours.weekday > 7 ||
              hours.startMinute < 0 ||
              hours.startMinute > 1439 ||
              hours.endMinute < 1 ||
              hours.endMinute > 1440 ||
              hours.startMinute >= hours.endMinute,
        )) {
      return 'provider.errors.availability';
    }
    return null;
  }

  @override
  bool get stringify => false;

  @override
  List<Object?> get props => [
    userId,
    bio,
    skillIds,
    serviceAreas,
    availability,
    verification,
  ];
}
