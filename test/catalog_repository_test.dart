import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:salahly/src/data/models/service_category.dart';
import 'package:salahly/src/data/repositories/catalog_repository.dart';

void main() {
  late CatalogRepository repository;
  late List<ServiceCategory> categories;

  setUp(() async {
    repository = CatalogRepository();
    categories = (await repository.loadCategories()).fold(
      (failure) => throw TestFailure(failure.message),
      (value) => value,
    );
  });

  test('null client is explicit demo with six active, sorted categories', () {
    expect(repository.isDemo, isTrue);
    expect(categories.map((category) => category.slug), [
      'plumbing',
      'electrical',
      'carpentry',
      'air_conditioning',
      'appliance_repair',
      'painting',
    ]);
    expect(categories.map((category) => category.id).toSet(), hasLength(6));
    expect(categories.every((category) => category.isActive), isTrue);
    for (var index = 1; index < categories.length; index++) {
      expect(
        categories[index].sortOrder,
        greaterThan(categories[index - 1].sortOrder),
      );
    }
  });

  test('all demo categories have distinct English and Arabic content', () {
    for (final category in categories) {
      expect(category.name('en'), isNotEmpty);
      expect(category.name('ar'), isNotEmpty);
      expect(category.name('ar'), isNot(category.name('en')));
      expect(category.description('en'), isNotEmpty);
      expect(category.description('ar'), isNotEmpty);
      expect(category.description('ar'), isNot(category.description('en')));
      expect(category.name('unknown'), category.nameEn);
      expect(category.iconKey, category.slug);
    }
  });

  test('search trims whitespace and matches either language without case', () {
    expect(
      categories
          .where((category) => category.matches('  PLUMBING  '))
          .map((category) => category.slug),
      ['plumbing'],
    );
    expect(
      categories
          .where((category) => category.matches('  الكهرباء '))
          .map((category) => category.slug),
      ['electrical'],
    );
    for (final category in categories) {
      expect(category.matches(category.nameEn.toUpperCase()), isTrue);
      expect(category.matches(category.nameAr), isTrue);
    }
  });

  test('search includes descriptions and both slug forms', () {
    final cooling = categories.singleWhere(
      (category) => category.slug == 'air_conditioning',
    );
    expect(cooling.matches('cooling'), isTrue);
    expect(cooling.matches('التبريد'), isTrue);
    expect(cooling.matches('AIR_CONDITIONING'), isTrue);
    expect(cooling.matches('air conditioning'), isTrue);
    expect(cooling.matches('painting'), isFalse);
  });

  test('blank search retains catalog order; unmatched search is empty', () {
    expect(
      categories.where((category) => category.matches(' \t ')),
      orderedEquals(categories),
    );
    expect(
      categories.where((category) => category.matches('unlisted-service')),
      isEmpty,
    );
    expect(() => categories.clear(), throwsUnsupportedError);
  });

  test('maps the exact SQL fields, including active status and language', () {
    final category = ServiceCategory.fromJson(const {
      'id': '00000000-0000-0000-0000-000000000001',
      'slug': 'plumbing',
      'name_en': 'Plumbing',
      'name_ar': 'السباكة',
      'description_en': 'Repair pipes.',
      'description_ar': 'إصلاح الأنابيب.',
      'icon_key': 'plumbing',
      'sort_order': 20,
      'is_active': false,
    });
    expect(category.id, '00000000-0000-0000-0000-000000000001');
    expect(category.name('ar'), 'السباكة');
    expect(category.description('en'), 'Repair pipes.');
    expect(category.description('ar'), 'إصلاح الأنابيب.');
    expect(category.sortOrder, 20);
    expect(category.isActive, isFalse);
  });

  test('a configured client failure never falls back to demo data', () async {
    final client = _FailingClient();
    addTearDown(client.dispose);
    final liveRepository = CatalogRepository(client: client);

    expect(liveRepository.isDemo, isFalse);
    expect((await liveRepository.loadCategories()).isLeft(), isTrue);
  });
}

class _FailingClient extends SupabaseClient {
  _FailingClient() : super('https://example.invalid', 'test-anon-key');

  @override
  SupabaseQueryBuilder from(String table) {
    throw const PostgrestException(message: 'Simulated failure', code: '503');
  }
}
