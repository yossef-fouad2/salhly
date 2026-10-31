import 'package:equatable/equatable.dart';

enum UserRole { customer, provider }

class AppUser extends Equatable {
  final String id;
  final String email;
  final String name;
  final UserRole role;
  final String? phone;
  final String? city;

  const AppUser({
    required this.id,
    required this.email,
    required this.name,
    this.role = UserRole.customer,
    this.phone,
    this.city,
  });

  factory AppUser.fromProfile(Map<String, dynamic> json, {required String email}) {
    return AppUser(
      id: json['id'] as String,
      email: email,
      name: json['full_name'] as String,
      role: UserRole.values.byName(json['role'] as String),
      phone: json['phone'] as String?,
      city: json['city'] as String?,
    );
  }

  AppUser withProfile({required String name, String? phone, String? city}) {
    return AppUser(
      id: id,
      email: email,
      name: name,
      role: role,
      phone: phone,
      city: city,
    );
  }

  @override
  List<Object?> get props => [id, email, name, role, phone, city];
}
