import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:salahly/src/data/models/user_model.dart';
import 'package:salahly/src/data/repositories/auth_repository.dart';

class ProfileState extends Equatable {
  const ProfileState({
    required this.user,
    this.isSaving = false,
    this.saved = false,
    this.errorMessage,
  });

  final AppUser user;
  final bool isSaving;
  final bool saved;
  final String? errorMessage;

  @override
  List<Object?> get props => [user, isSaving, saved, errorMessage];
}

class ProfileCubit extends Cubit<ProfileState> {
  ProfileCubit(this._repository, AppUser user)
    : super(ProfileState(user: user));

  final AuthRepository _repository;

  Future<void> save({required String name, String? phone, String? city}) async {
    if (state.isSaving) return;
    emit(ProfileState(user: state.user, isSaving: true));
    final result = await _repository.updateProfile(
      name: name,
      phone: phone,
      city: city,
    );
    if (isClosed) return;
    result.fold(
      (failure) =>
          emit(ProfileState(user: state.user, errorMessage: failure.message)),
      (user) => emit(ProfileState(user: user, saved: true)),
    );
  }
}
