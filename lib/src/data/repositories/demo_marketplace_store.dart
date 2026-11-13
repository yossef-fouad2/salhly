import '../models/marketplace.dart';
import '../models/matching.dart';
import '../models/provider_profile.dart';
import '../models/service_request.dart';
import '../models/user_model.dart';

/// Session-local synthetic data, shared by M6-M8 repositories only.
/// This is not an authorization boundary or a substitute for production RLS.
class DemoMarketplaceStore {
  DemoMarketplaceStore() {
    final timestamp = DateTime.utc(2026, 11, 11);
    matchingProfiles.addAll({
      sampleProviderId: ProviderMatchingProfile(
        providerId: sampleProviderId,
        providerName: 'Sample Marketplace Provider',
        discoverable: true,
        latitude: 30.04,
        longitude: 31.24,
        experienceYears: const {'demo-plumbing': 4},
        revision: 1,
        consentedAt: timestamp,
        updatedAt: timestamp,
      ),
      'demo-matching-new': ProviderMatchingProfile(
        providerId: 'demo-matching-new',
        providerName: 'Sample New Provider',
        discoverable: true,
        revision: 1,
        consentedAt: timestamp,
        updatedAt: timestamp,
      ),
      'demo-matching-experienced': ProviderMatchingProfile(
        providerId: 'demo-matching-experienced',
        providerName: 'Sample Experienced Provider',
        discoverable: true,
        latitude: 30.12,
        longitude: 31.35,
        experienceYears: const {'demo-plumbing': 10},
        revision: 1,
        consentedAt: timestamp,
        updatedAt: timestamp,
      ),
    });
    for (final id in const ['demo-matching-new', 'demo-matching-experienced']) {
      matchingProviders[id] = DemoMarketplaceProvider(
        skillIds: const ['demo-plumbing'],
        serviceAreas: const ['Cairo'],
      );
    }
    matchingAvailability.addAll({
      sampleProviderId: const [
        ProviderAvailability(weekday: 1, startMinute: 540, endMinute: 1020),
      ],
      'demo-matching-new': const [],
      'demo-matching-experienced': const [
        ProviderAvailability(weekday: 1, startMinute: 600, endMinute: 1080),
      ],
    });
  }

  static const sampleProviderId = 'demo-marketplace-provider';

  final requests = <String, ServiceRequest>{};
  final listings = <String, MarketplaceListing>{};
  final quotes = <String, ProviderQuote>{};
  final jobs = <String, ServiceJob>{};
  final matchingProfiles = <String, ProviderMatchingProfile>{};
  // Discovery-only fixtures cannot submit M7 quotes or impersonate accounts.
  final matchingProviders = <String, DemoMarketplaceProvider>{};
  final matchingAvailability = <String, List<ProviderAvailability>>{};
  MatchingRules matchingRules = const MatchingRules();

  // A separate, explicitly labelled fixture, never a review of an M5 submission.
  final providers = <String, DemoMarketplaceProvider>{
    sampleProviderId: DemoMarketplaceProvider(
      skillIds: const ['demo-plumbing'],
      serviceAreas: const ['Cairo'],
    ),
  };

  void cancelRequest(ServiceRequest request) {
    requests[request.id] = request;
    final listing = listings[request.id];
    if (listing != null) {
      listings[request.id] = listing.withStatus(ServiceRequestStatus.cancelled);
    }
    for (final quote in quotes.values.toList()) {
      if (quote.requestId == request.id &&
          quote.status == QuoteStatus.pending) {
        quotes[quote.id] = quote.copyWith(
          status: QuoteStatus.cancelled,
          updatedAt: request.cancelledAt,
        );
      }
    }
  }
}

class DemoMarketplaceProvider {
  DemoMarketplaceProvider({
    required List<String> skillIds,
    required List<String> serviceAreas,
    this.verified = true,
    this.role = UserRole.provider,
  }) : skillIds = List.unmodifiable(skillIds),
       serviceAreas = List.unmodifiable(serviceAreas);

  final List<String> skillIds;
  final List<String> serviceAreas;
  final bool verified;
  final UserRole role;
}
