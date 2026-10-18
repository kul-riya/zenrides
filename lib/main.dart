import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
import 'src/maps_bridge.dart';
import 'src/phone_sign_in.dart';
import 'src/ride_controller.dart';
import 'src/ride_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  var firebaseReady = false;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    firebaseReady = true;
  } catch (error, stack) {
    FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack, library: 'zenrides'));
  }
  if (kIsWeb) {
    try {
      await MapsBridge.loadMaps();
    } catch (error, stack) {
      FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack, library: 'zenrides'));
    }
  }
  runApp(ZenRidesApp(firebaseReady: firebaseReady));
}

class ZenRidesApp extends StatelessWidget {
  const ZenRidesApp({super.key, required this.firebaseReady});

  final bool firebaseReady;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZenRides',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F172A)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFEEF1F5),
      ),
      home: !firebaseReady
          ? const _StartupPage()
          : kIsWeb
              ? const AuthGate(ready: RideHost())
              : const RideHost(),
    );
  }
}

class _StartupPage extends StatelessWidget {
  const _StartupPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'ZenRides could not reach Firebase. Check the connection, then refresh.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, height: 1.4),
          ),
        ),
      ),
    );
  }
}

class RideHost extends StatefulWidget {
  const RideHost({super.key});

  @override
  State<RideHost> createState() => _RideHostState();
}

class _RideHostState extends State<RideHost> {
  late final RideController ride;

  @override
  void initState() {
    super.initState();
    ride = RideController();
    unawaited(ride.restoreIdentity().then((_) => ride.start()));
  }

  @override
  void dispose() {
    ride.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RideScope(ride: ride, child: const RideShell());
  }
}
