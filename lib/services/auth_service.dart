import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../utils/log.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  User? get currentUser => _auth.currentUser;
  bool get isSignedIn => _auth.currentUser != null;
  String get userId => _auth.currentUser?.uid ?? '';
  String get displayName => _auth.currentUser?.displayName ?? '';
  String get email => _auth.currentUser?.email ?? '';

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<UserCredential?> signInWithEmail(String email, String password) async {
    try {
      final cred = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      log('[Auth] email sign-in: ${cred.user?.uid}');
      return cred;
    } on FirebaseAuthException catch (e) {
      log('[Auth] email error: ${e.code} ${e.message}');
      throw e;
    }
  }

  Future<UserCredential?> signInWithGoogle() async {
    try {
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return null;
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final cred = await _auth.signInWithCredential(credential);
      log('[Auth] Google sign-in: ${cred.user?.uid}');
      return cred;
    } catch (e) {
      log('[Auth] Google error: $e');
      throw e;
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
    log('[Auth] signed out');
  }

  Future<void> createAccount(String email, String password) async {
    try {
      final cred = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      log('[Auth] account created: ${cred.user?.uid}');
    } on FirebaseAuthException catch (e) {
      log('[Auth] create error: ${e.code} ${e.message}');
      rethrow;
    }
  }
}

final authServiceProvider = Provider<AuthService>((ref) => AuthService());
