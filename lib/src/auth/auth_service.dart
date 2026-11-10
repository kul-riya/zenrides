import 'package:firebase_auth/firebase_auth.dart';

/// Thrown by AuthService in place of FirebaseAuthException, so callers never
/// need to import firebase_auth to read the message.
class AuthException implements Exception {
  AuthException(this.message);

  final String message;
}

class AuthUser {
  const AuthUser({required this.uid, required this.displayName});

  final String uid;
  final String? displayName;
}

/// Opaque handle for the code sent to a phone number, passed back into
/// confirmCode. Callers never see the underlying ConfirmationResult.
class PhoneCodeSent {
  const PhoneCodeSent(this._confirmation);

  final ConfirmationResult _confirmation;
}

/// Wraps sign-in so the ride never calls FirebaseAuth directly. Web uses
/// phone OTP. A phone with no session signs in anonymously so the uid can
/// be stored on users/{uid}.
abstract class AuthService {
  AuthUser? get currentUser;

  Stream<AuthUser?> authStateChanges();

  Future<AuthUser> signInAnonymously();

  Future<PhoneCodeSent> sendCode(String phoneE164);

  Future<AuthUser> confirmCode(PhoneCodeSent sent, String smsCode);

  Future<void> setDisplayName(String name);

  Future<void> signOut();
}

class FirebaseAuthService implements AuthService {
  const FirebaseAuthService();

  @override
  AuthUser? get currentUser => _wrap(FirebaseAuth.instance.currentUser);

  @override
  Stream<AuthUser?> authStateChanges() => FirebaseAuth.instance.authStateChanges().map(_wrap);

  @override
  Future<AuthUser> signInAnonymously() async {
    try {
      final result = await FirebaseAuth.instance.signInAnonymously();
      final user = _wrap(result.user);
      if (user == null) throw AuthException('Could not sign in.');
      return user;
    } on FirebaseAuthException catch (error) {
      throw AuthException(error.message ?? 'Could not sign in.');
    }
  }

  @override
  Future<PhoneCodeSent> sendCode(String phoneE164) async {
    try {
      // No container: Firebase renders an invisible reCAPTCHA.
      final result = await FirebaseAuth.instance.signInWithPhoneNumber(phoneE164);
      return PhoneCodeSent(result);
    } on FirebaseAuthException catch (error) {
      throw AuthException(error.message ?? 'Could not send the code.');
    }
  }

  @override
  Future<AuthUser> confirmCode(PhoneCodeSent sent, String smsCode) async {
    try {
      await sent._confirmation.confirm(smsCode);
      return _wrap(FirebaseAuth.instance.currentUser)!;
    } on FirebaseAuthException catch (error) {
      throw AuthException(error.message ?? 'That code was not accepted.');
    }
  }

  @override
  Future<void> setDisplayName(String name) async {
    try {
      await FirebaseAuth.instance.currentUser?.updateDisplayName(name);
      await FirebaseAuth.instance.currentUser?.reload();
    } on FirebaseAuthException catch (error) {
      throw AuthException(error.message ?? 'Could not save that name.');
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } on FirebaseAuthException catch (error) {
      throw AuthException(error.message ?? 'Could not log out.');
    }
  }

  AuthUser? _wrap(User? user) => user == null ? null : AuthUser(uid: user.uid, displayName: user.displayName);
}
