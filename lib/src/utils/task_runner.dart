import 'package:fpdart/fpdart.dart';

import '../services/internet_connection_service.dart';
import 'error_handler.dart';
import 'failure.dart';
import 'logger.dart';
import 'typedefs.dart';

/// A reusable generic function to handle potential exceptions in async tasks
/// and map them to the [Either] type matching [FutureEither<T>].
///
/// If [requiresNetwork] is `true` and [isNetworkAvailable] returns `false`,
/// the [action] will not be executed and a [NetworkFailure] will be returned.
FutureEither<T> runTask<T>(
  Future<T> Function() action, {
  bool requiresNetwork = false,
}) async {
  try {
    if (requiresNetwork &&
        !await InternetConnectionService().hasConnection()) {
      return left(const NetworkFailure('errors.network'));
    }
    final result = await action();
    return right(result);
  } catch (error, stackTrace) {
    if (error is Failure) return left(error);
    AppLogger.error('Task execution failed', error, stackTrace);
    return left(ServerFailure(AppErrorHandler.format(error), error: error));
  }
}
