import 'dart:async';

import 'package:fpdart/fpdart.dart';
import 'package:salahly/src/data/models/matching.dart';
import 'package:salahly/src/data/models/provider_profile.dart';
import 'package:salahly/src/data/models/service_category.dart';
import 'package:salahly/src/data/models/service_request.dart';
import 'package:salahly/src/data/repositories/catalog_repository.dart';
import 'package:salahly/src/data/repositories/demo_auth_repository.dart';
import 'package:salahly/src/data/repositories/matching_repository.dart';
import 'package:salahly/src/data/repositories/provider_repository.dart';
import 'package:salahly/src/data/repositories/service_request_repository.dart';
import 'package:salahly/src/utils/failure.dart';
import 'package:salahly/src/utils/typedefs.dart';

import 'marketplace_ui_fakes.dart';

export 'marketplace_ui_fakes.dart';

ProviderMatchingProfile matchingProfile({
  String providerId = uiProviderId,
  String name = 'Synthetic Matching Provider',
  bool discoverable = false,
  double? latitude,
  double? longitude,
  Map<String, int> years = const {},
  int revision = 0,
}) => ProviderMatchingProfile(
  providerId: providerId,
  providerName: name,
  discoverable: discoverable,
  latitude: latitude,
  longitude: longitude,
  experienceYears: years,
  revision: revision,
  consentedAt: discoverable ? uiNow : null,
  updatedAt: revision > 0 ? uiNow : null,
);

ProviderMatch matchingCandidate({
  String providerId = uiProviderId,
  String name = 'Synthetic Matching Provider',
  MatchingQuery query = const MatchingQuery(requestId: uiRequestId),
  MatchingRules rules = const MatchingRules(),
  double? latitude,
  double? longitude,
  int? years,
  List<ProviderAvailability> hours = const [],
}) => scoreProviderMatch(
  query: query,
  rules: rules,
  profile: matchingProfile(
    providerId: providerId,
    name: name,
    discoverable: true,
    latitude: latitude,
    longitude: longitude,
    years: {'demo-plumbing': ?years},
    revision: 1,
  ),
  categoryId: 'demo-plumbing',
  availability: hours,
);

MatchResults matchingResults({
  MatchingQuery query = const MatchingQuery(requestId: uiRequestId),
  MatchingRules rules = const MatchingRules(),
  List<ProviderMatch>? items,
  bool hasMore = false,
}) => MatchResults(
  listing: uiListing(),
  rules: rules,
  mode: query.mode,
  items: items ?? [matchingCandidate(query: query, rules: rules)],
  hasMore: hasMore,
);

List<ProviderMatch> matchingCandidates(
  int count, {
  MatchingQuery query = const MatchingQuery(requestId: uiRequestId),
  MatchingRules rules = const MatchingRules(),
}) => [
  for (var index = 0; index < count; index++)
    matchingCandidate(
      providerId: 'synthetic-provider-$index',
      name: 'Synthetic Provider $index',
      query: query,
      rules: rules,
    ),
]..sort((left, right) => compareProviderMatches(left, right, query.mode));

class MatchingUiRepository extends MatchingRepository {
  MatchingUiRepository(DemoAuthRepository auth) : super(authRepository: auth);

  bool demoMode = false;
  @override
  bool get isDemo => demoMode;

  MatchResults? results;
  ProviderMatchingProfile profile = matchingProfile();
  MatchingEligibility eligibility = MatchingEligibility(
    skillIds: const ['demo-plumbing'],
    eligible: true,
  );
  String currentName = 'Sample Marketplace Provider';
  Failure? readFailure;
  Failure? profileFailure;
  Failure? eligibilityFailure;
  Failure? saveFailure;
  Failure? retryFailure;
  bool storedPending = false;
  ProviderMatchingDraft? retainedDraft;
  int profileLoads = 0;
  int eligibilityLoads = 0;
  final reads =
      <
        ({
          MatchingQuery query,
          MatchingCursor? before,
          int limit,
          String userId,
        })
      >[];
  final drafts = <ProviderMatchingDraft>[];
  final retries = <ProviderMatchingDraft?>[];
  Completer<Either<Failure, MatchResults>>? pendingMatches;
  Completer<Either<Failure, ProviderMatchingProfile>>? pendingProfile;
  Completer<Either<Failure, MatchingEligibility>>? pendingEligibility;
  Completer<Either<Failure, ProviderMatchingProfile>>? pendingSave;
  FutureEither<MatchResults> Function(MatchingQuery, MatchingCursor?)?
  onMatches;

  @override
  FutureEither<MatchResults> loadMatches(
    MatchingQuery query, {
    required String userId,
    MatchingCursor? before,
    int limit = 20,
  }) async {
    reads.add((query: query, before: before, limit: limit, userId: userId));
    if (onMatches != null) return onMatches!(query, before);
    if (pendingMatches != null) return pendingMatches!.future;
    if (readFailure != null) return left(readFailure!);
    final page = results;
    return right(
      page == null
          ? matchingResults(query: query)
          : MatchResults(
              listing: page.listing,
              rules: page.rules,
              mode: query.mode,
              items: page.items,
              hasMore: page.hasMore,
            ),
    );
  }

  @override
  FutureEither<ProviderMatchingProfile> loadProfile({
    required String userId,
  }) async {
    profileLoads++;
    if (pendingProfile != null) return pendingProfile!.future;
    final failure = profileFailure ?? readFailure;
    return failure == null ? right(profile) : left(failure);
  }

  @override
  FutureEither<MatchingEligibility> loadEligibility({
    required String userId,
  }) async {
    eligibilityLoads++;
    if (pendingEligibility != null) return pendingEligibility!.future;
    return eligibilityFailure == null
        ? right(eligibility)
        : left(eligibilityFailure!);
  }

  @override
  bool hasPendingSave({required String userId}) => storedPending;

  ProviderMatchingProfile saved(ProviderMatchingDraft draft) =>
      ProviderMatchingProfile(
        providerId: draft.providerId,
        providerName: draft.discoverable ? currentName : profile.providerName,
        discoverable: draft.discoverable,
        latitude: draft.parsedLatitude,
        longitude: draft.parsedLongitude,
        experienceYears: draft.parsedExperienceYears,
        revision: draft.expectedRevision + 1,
        consentedAt: draft.discoverable ? uiNow : profile.consentedAt,
        updatedAt: uiNow,
      );

  Either<Failure, ProviderMatchingProfile> _finish(
    Either<Failure, ProviderMatchingProfile> result,
  ) => result.fold(
    (failure) {
      final definite = const {
        'matching.errors.conflict',
        'matching.errors.ineligible',
        'matching.errors.invalid',
        'matching.errors.consent',
        'matching.errors.location',
        'matching.errors.experience',
      }.contains(failure.message);
      storedPending =
          !definite &&
          (storedPending ||
              failure.message == 'matching.errors.uncertain' ||
              failure is NetworkFailure);
      if (!storedPending) retainedDraft = null;
      return left(failure);
    },
    (value) {
      profile = value;
      storedPending = false;
      retainedDraft = null;
      return right(value);
    },
  );

  @override
  FutureEither<ProviderMatchingProfile> saveProfile(
    ProviderMatchingDraft draft, {
    required String userId,
  }) async {
    drafts.add(draft);
    retainedDraft = draft;
    return _finish(
      pendingSave != null
          ? await pendingSave!.future
          : saveFailure != null
          ? left(saveFailure!)
          : right(saved(draft)),
    );
  }

  @override
  FutureEither<ProviderMatchingProfile> retryPendingSave({
    required String userId,
  }) async {
    retries.add(retainedDraft);
    return _finish(
      retryFailure != null
          ? left(retryFailure!)
          : retainedDraft == null
          ? right(profile)
          : right(saved(retainedDraft!)),
    );
  }
}

class MatchingUiCatalog extends CatalogRepository {
  int loads = 0;
  Failure? failure;
  final List<ServiceCategory> categories = const [
    ServiceCategory(
      id: 'demo-plumbing',
      slug: 'plumbing',
      nameEn: 'Plumbing',
      nameAr: '\u0627\u0644\u0633\u0628\u0627\u0643\u0629',
      descriptionEn: '',
      descriptionAr: '',
      iconKey: 'plumbing',
      sortOrder: 1,
      isActive: true,
    ),
    ServiceCategory(
      id: 'demo-electrical',
      slug: 'electrical',
      nameEn: 'Electrical',
      nameAr: '\u0627\u0644\u0643\u0647\u0631\u0628\u0627\u0621',
      descriptionEn: '',
      descriptionAr: '',
      iconKey: 'electrical',
      sortOrder: 2,
      isActive: true,
    ),
  ];

  @override
  FutureEither<List<ServiceCategory>> loadCategories() async {
    loads++;
    return failure == null ? right(categories) : left(failure!);
  }
}

class MatchingUiPrivateProviders extends ProviderRepository {
  MatchingUiPrivateProviders(DemoAuthRepository auth)
    : super(authRepository: auth);
  int loads = 0;
  @override
  FutureEither<ProviderProfile> loadProfile(String userId) async {
    loads++;
    return right(
      ProviderProfile(
        userId: userId,
        bio: 'NEVER RENDER PRIVATE M5 BIO',
        skillIds: const ['demo-plumbing'],
        serviceAreas: const ['Private home address 55'],
      ),
    );
  }
}

class MatchingUiPrivateRequests extends ServiceRequestRepository {
  MatchingUiPrivateRequests(DemoAuthRepository auth)
    : super(authRepository: auth);
  int loads = 0;
  @override
  FutureEither<ServiceRequest> loadRequest(
    String requestId, {
    required String userId,
  }) async {
    loads++;
    return right(
      ServiceRequest(
        id: requestId,
        customerId: userId,
        categoryId: 'demo-plumbing',
        categoryNameEn: 'Plumbing',
        categoryNameAr: '\u0633\u0628\u0627\u0643\u0629',
        categoryIconKey: 'plumbing',
        title: 'NEVER COPY PRIVATE REQUEST TITLE',
        description: 'NEVER COPY PRIVATE REQUEST DESCRIPTION',
        city: 'Private city',
        address: 'Private home address 55',
        preferredAt: uiNow.add(const Duration(days: 2)),
        status: ServiceRequestStatus.open,
        createdAt: uiNow,
        consentedAt: uiNow,
        photos: const [],
      ),
    );
  }
}
