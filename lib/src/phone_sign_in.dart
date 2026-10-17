import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Turns a typed phone number into E.164. A 10-digit number is treated as India.
String? phoneE164(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[^\d+]'), '');
  if (cleaned.startsWith('+') && cleaned.length > 8) return cleaned;
  final digits = cleaned.replaceAll('+', '');
  if (digits.length == 10) return '+91$digits';
  if (digits.length > 10) return '+$digits';
  return null;
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.ready});

  final Widget ready;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  User? _user;
  var _named = false;
  late final StreamSubscription<User?> _auth;

  @override
  void initState() {
    super.initState();
    final current = FirebaseAuth.instance.currentUser;
    _user = current;
    _named = (current?.displayName ?? '').trim().isNotEmpty;
    _auth = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (!mounted) return;
      setState(() {
        _user = user;
        _named = (user?.displayName ?? '').trim().isNotEmpty;
      });
    });
  }

  @override
  void dispose() {
    _auth.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    if (user == null) return const PhoneSignIn();
    if (!_named) {
      return NameEntry(onSaved: () => setState(() => _named = true));
    }
    return widget.ready;
  }
}

class PhoneSignIn extends StatefulWidget {
  const PhoneSignIn({super.key});

  @override
  State<PhoneSignIn> createState() => _PhoneSignInState();
}

class _PhoneSignInState extends State<PhoneSignIn> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  ConfirmationResult? _sent;
  var _busy = false;
  String _error = '';

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final number = phoneE164(_phone.text);
    if (number == null) {
      setState(() => _error = 'Enter a phone number with country code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      // No container: Firebase renders an invisible reCAPTCHA.
      final sent = await FirebaseAuth.instance.signInWithPhoneNumber(number);
      if (!mounted) return;
      setState(() => _sent = sent);
    } on FirebaseAuthException catch (error) {
      setState(() => _error = error.message ?? 'Could not send the code.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final sent = _sent;
    final sms = _code.text.trim();
    if (sent == null || sms.isEmpty) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await sent.confirm(sms);
    } on FirebaseAuthException catch (error) {
      setState(() => _error = error.message ?? 'That code was not accepted.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sent = _sent != null;
    return _AuthCard(
      title: sent ? 'Enter the code' : 'Sign in',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: sent ? _code : _phone,
            keyboardType: TextInputType.phone,
            autofocus: true,
            decoration: InputDecoration(
              labelText: sent ? 'SMS code' : 'Phone number',
              hintText: sent ? '123456' : '+91 98765 43210',
            ),
            onSubmitted: (_) => sent ? _confirm() : _send(),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_error, style: const TextStyle(color: Color(0xFF9A3412))),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : (sent ? _confirm : _send),
            child: Text(_busy ? 'Please wait' : sent ? 'Continue' : 'Send code'),
          ),
          if (sent)
            TextButton(
              onPressed: _busy ? null : () => setState(() => _sent = null),
              child: const Text('Use a different number'),
            ),
        ],
      ),
    );
  }
}

class NameEntry extends StatefulWidget {
  const NameEntry({super.key, required this.onSaved});

  final VoidCallback onSaved;

  @override
  State<NameEntry> createState() => _NameEntryState();
}

class _NameEntryState extends State<NameEntry> {
  final _name = TextEditingController();
  var _busy = false;
  String _error = '';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter the name other riders should see.');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await FirebaseAuth.instance.currentUser?.updateDisplayName(name);
      await FirebaseAuth.instance.currentUser?.reload();
      widget.onSaved();
    } on FirebaseAuthException catch (error) {
      setState(() => _error = error.message ?? 'Could not save that name.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AuthCard(
      title: 'Your name',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('This name is shown on every ride you join.'),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (_) => _save(),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_error, style: const TextStyle(color: Color(0xFF9A3412))),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Please wait' : 'Continue'),
          ),
        ],
      ),
    );
  }
}

class _AuthCard extends StatelessWidget {
  const _AuthCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEEF1F5),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
