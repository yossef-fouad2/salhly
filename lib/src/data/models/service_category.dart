import 'package:equatable/equatable.dart';

class ServiceCategory extends Equatable {
  const ServiceCategory({
    required this.id,
    required this.slug,
    required this.nameEn,
    required this.nameAr,
    required this.descriptionEn,
    required this.descriptionAr,
    required this.iconKey,
    required this.sortOrder,
    required this.isActive,
  });

  final String id;
  final String slug;
  final String nameEn;
  final String nameAr;
  final String descriptionEn;
  final String descriptionAr;
  final String iconKey;
  final int sortOrder;
  final bool isActive;

  factory ServiceCategory.fromJson(Map<String, dynamic> json) {
    return ServiceCategory(
      id: json['id'] as String,
      slug: json['slug'] as String,
      nameEn: json['name_en'] as String,
      nameAr: json['name_ar'] as String,
      descriptionEn: json['description_en'] as String,
      descriptionAr: json['description_ar'] as String,
      iconKey: json['icon_key'] as String,
      sortOrder: json['sort_order'] as int,
      isActive: json['is_active'] as bool,
    );
  }

  String name(String languageCode) => languageCode == 'ar' ? nameAr : nameEn;

  String description(String languageCode) =>
      languageCode == 'ar' ? descriptionAr : descriptionEn;

  bool matches(String query) {
    final search = query.trim().toLowerCase();
    return search.isEmpty ||
        [
          nameEn,
          nameAr,
          descriptionEn,
          descriptionAr,
          slug,
          slug.replaceAll('_', ' '),
        ].any((text) => text.toLowerCase().contains(search));
  }

  @override
  List<Object?> get props => [
    id,
    slug,
    nameEn,
    nameAr,
    descriptionEn,
    descriptionAr,
    iconKey,
    sortOrder,
    isActive,
  ];
}
