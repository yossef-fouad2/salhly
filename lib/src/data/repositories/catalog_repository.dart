import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:salahly/src/data/models/service_category.dart';
import 'package:salahly/src/utils/task_runner.dart';
import 'package:salahly/src/utils/typedefs.dart';

class CatalogRepository {
  CatalogRepository({this._client});

  final SupabaseClient? _client;

  bool get isDemo => _client == null;

  FutureEither<List<ServiceCategory>> loadCategories() {
    return runTask(() async {
      final client = _client;
      if (client == null) return _demoCategories;

      final rows = await client
          .from('service_categories')
          .select(
            'id,slug,name_en,name_ar,description_en,description_ar,icon_key,sort_order,is_active',
          )
          .eq('is_active', true)
          .order('sort_order');
      return List<ServiceCategory>.unmodifiable(
        rows.map(ServiceCategory.fromJson),
      );
    });
  }

  static const _demoCategories = <ServiceCategory>[
    ServiceCategory(
      id: 'demo-plumbing',
      slug: 'plumbing',
      nameEn: 'Plumbing',
      nameAr: 'السباكة',
      descriptionEn: 'Help with leaking taps, pipes and household plumbing.',
      descriptionAr:
          'المساعدة في إصلاح تسربات الصنابير والأنابيب والسباكة المنزلية.',
      iconKey: 'plumbing',
      sortOrder: 1,
      isActive: true,
    ),
    ServiceCategory(
      id: 'demo-electrical',
      slug: 'electrical',
      nameEn: 'Electrical',
      nameAr: 'الكهرباء',
      descriptionEn:
          'Help with lighting, sockets and household electrical issues.',
      descriptionAr: 'المساعدة في الإضاءة والمقابس ومشكلات الكهرباء المنزلية.',
      iconKey: 'electrical',
      sortOrder: 2,
      isActive: true,
    ),
    ServiceCategory(
      id: 'demo-carpentry',
      slug: 'carpentry',
      nameEn: 'Carpentry',
      nameAr: 'النجارة',
      descriptionEn: 'Help with doors, cupboards and wooden furniture repairs.',
      descriptionAr: 'المساعدة في إصلاح الأبواب والخزائن والأثاث الخشبي.',
      iconKey: 'carpentry',
      sortOrder: 3,
      isActive: true,
    ),
    ServiceCategory(
      id: 'demo-air-conditioning',
      slug: 'air_conditioning',
      nameEn: 'Air conditioning',
      nameAr: 'التكييف',
      descriptionEn:
          'Help with air conditioner cleaning, maintenance and cooling issues.',
      descriptionAr: 'المساعدة في تنظيف المكيفات وصيانتها وحل مشكلات التبريد.',
      iconKey: 'air_conditioning',
      sortOrder: 4,
      isActive: true,
    ),
    ServiceCategory(
      id: 'demo-appliance-repair',
      slug: 'appliance_repair',
      nameEn: 'Appliance repair',
      nameAr: 'إصلاح الأجهزة',
      descriptionEn:
          'Help with washing machines, refrigerators and home appliances.',
      descriptionAr: 'المساعدة في إصلاح الغسالات والثلاجات والأجهزة المنزلية.',
      iconKey: 'appliance_repair',
      sortOrder: 5,
      isActive: true,
    ),
    ServiceCategory(
      id: 'demo-painting',
      slug: 'painting',
      nameEn: 'Painting',
      nameAr: 'الدهانات',
      descriptionEn:
          'Help with interior painting, wall preparation and touch-ups.',
      descriptionAr:
          'المساعدة في الدهانات الداخلية وتجهيز الجدران وترميم الطلاء.',
      iconKey: 'painting',
      sortOrder: 6,
      isActive: true,
    ),
  ];
}
