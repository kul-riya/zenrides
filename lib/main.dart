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
  runApp(const ZenRidesApp());
}

enum _Boot { opening, ready, failed }

class ZenRidesApp extends StatefulWidget {
  const ZenRidesApp({super.key});

  @override
  State<ZenRidesApp> createState() => _ZenRidesAppState();
}

class _ZenRidesAppState extends State<ZenRidesApp> {
  var _boot = _Boot.opening;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    if (kIsWeb) unawaited(MapsBridge.loadMaps());
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform).timeout(const Duration(seconds: 8));
      if (mounted) setState(() => _boot = _Boot.ready);
    } catch (error, stack) {
      FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack, library: 'zenrides'));
      if (mounted) setState(() => _boot = _Boot.failed);
    }
  }

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
      home: switch (_boot) {
        _Boot.opening => const _OpeningPage(),
        _Boot.failed => const _StartupPage(),
        _Boot.ready => kIsWeb ? const AuthGate(ready: RideHost()) : const RideHost(),
      },
    );
  }
}

class _OpeningPage extends StatelessWidget {
  const _OpeningPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Sign in', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            SizedBox(height: 12),
            Text('Opening ZenRides…'),
          ],
        ),
      ),
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
