import 'package:google_sign_in/google_sign_in.dart';

/// Google OAuth entry point for the iOS YouTube Music connection flow.
///
/// Google OAuth is deliberately kept separate from the private InnerTube
/// cookie session: an OAuth identity token is not an InnerTube SAPISID
/// session and must never be treated as one.
class YtGoogleOAuth {
  YtGoogleOAuth._();

  static const String clientId =
      '991393004481-hngkr0vlfqd3jqqgh0qs3dfeoqssvbgp.apps.googleusercontent.com';

  static final GoogleSignIn _google = GoogleSignIn.instance;
  static Future<void>? _initialization;

  static Future<void> _initialize() {
    return _initialization ??= _google.initialize(clientId: clientId);
  }

  static Future<GoogleSignInAccount> signIn() async {
    await _initialize();
    if (!_google.supportsAuthenticate()) {
      throw StateError('Google Sign-In is not supported on this platform.');
    }
    return _google.authenticate();
  }

  static Future<void> signOut() async {
    await _initialize();
    await _google.signOut();
  }
}
