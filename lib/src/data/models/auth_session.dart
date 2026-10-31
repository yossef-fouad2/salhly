import 'package:equatable/equatable.dart';

import 'user_model.dart';

enum SignUpResult { authenticated, confirmationRequired }

/// A recovery session is valid at Supabase but cannot enter the app shell yet.
class AuthSession extends Equatable {
  const AuthSession({this.user, this.needsPasswordUpdate = false});

  final AppUser? user;
  final bool needsPasswordUpdate;

  @override
  List<Object?> get props => [user, needsPasswordUpdate];
}
