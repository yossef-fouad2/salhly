import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:salahly/src/data/models/service_category.dart';
import 'package:salahly/src/data/repositories/catalog_repository.dart';

class HomeState extends Equatable {
  const HomeState({
    this.categories = const [],
    this.query = '',
    this.isLoading = false,
    this.errorMessage,
  });

  final List<ServiceCategory> categories;
  final String query;
  final bool isLoading;
  final String? errorMessage;

  List<ServiceCategory> get visibleCategories => List.unmodifiable(
    categories.where((category) => category.matches(query)),
  );

  @override
  List<Object?> get props => [categories, query, isLoading, errorMessage];
}

class HomeCubit extends Cubit<HomeState> {
  HomeCubit(this._repository) : super(const HomeState());

  final CatalogRepository _repository;

  Future<void> load() async {
    if (state.isLoading) return;
    emit(
      HomeState(
        categories: state.categories,
        query: state.query,
        isLoading: true,
      ),
    );
    final result = await _repository.loadCategories();
    if (isClosed) return;
    result.fold(
      (failure) => emit(
        HomeState(
          categories: state.categories,
          query: state.query,
          errorMessage: failure.message,
        ),
      ),
      (categories) =>
          emit(HomeState(categories: categories, query: state.query)),
    );
  }

  void search(String query) {
    emit(
      HomeState(
        categories: state.categories,
        query: query,
        isLoading: state.isLoading,
        errorMessage: state.errorMessage,
      ),
    );
  }
}
