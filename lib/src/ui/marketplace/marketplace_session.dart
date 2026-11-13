import 'dart:async';

import '../../data/models/user_model.dart';
import '../auth/bloc/session_bloc.dart';

bool marketplaceAuthorized(
  SessionState state,
  String userId, [
  UserRole? role,
]) =>
    state.status == SessionStatus.authenticated &&
    state.user?.id == userId &&
    (role == null || state.user?.role == role);

bool marketplaceAccessError(String message) => const {
  'marketplace.errors.access',
  'errors.not_authenticated',
  'errors.auth_failed',
}.contains(message);

bool marketplaceStillUncertain(bool wasUncertain, String message) =>
    message == 'marketplace.errors.uncertain' ||
    (wasUncertain &&
        !const {
          'marketplace.errors.conflict',
          'marketplace.errors.status',
        }.contains(message));

/// A page belongs to one continuous session, not just to an account ID.
class MarketplaceSession {
  MarketplaceSession({
    required this._session,
    required this._userId,
    required this._onRevoked,
    this._role,
  }) {
    _revoked = !marketplaceAuthorized(_session.state, _userId, _role);
    _subscription = _session.stream.listen((state) {
      if (!marketplaceAuthorized(state, _userId, _role)) revoke();
    });
  }

  final SessionBloc _session;
  final String _userId;
  final UserRole? _role;
  final void Function() _onRevoked;
  late final StreamSubscription<SessionState> _subscription;
  late bool _revoked;

  bool get active =>
      !_revoked && marketplaceAuthorized(_session.state, _userId, _role);

  void revoke() {
    if (_revoked) return;
    _revoked = true;
    _onRevoked();
  }

  Future<void> close() {
    _revoked = true;
    return _subscription.cancel();
  }
}
