import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    return web;
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBdI4o_BumCve4hDs7mni6auXv5Qw5wTUA',
    appId: '1:126377853304:web:45ec8ab47663f5924fc88d',
    messagingSenderId: '126377853304',
    projectId: 'myzenrides',
    authDomain: 'myzenrides.firebaseapp.com',
    storageBucket: 'myzenrides.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBdI4o_BumCve4hDs7mni6auXv5Qw5wTUA',
    appId: '1:126377853304:android:66aaa37dd2af923778dbb2',
    messagingSenderId: '126377853304',
    projectId: 'myzenrides',
    storageBucket: 'myzenrides.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBdI4o_BumCve4hDs7mni6auXv5Qw5wTUA',
    appId: '1:126377853304:ios:66aaa37dd2af923778dbb2',
    messagingSenderId: '126377853304',
    projectId: 'myzenrides',
    storageBucket: 'myzenrides.firebasestorage.app',
  );
}
