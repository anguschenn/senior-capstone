import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/app_theme.dart';
import '../services/auth_service.dart';
import '../widgets/common/ui.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _passwordFocusNode = FocusNode();
  final _confirmPasswordFocusNode = FocusNode();

  bool _isSignUp = false;
  bool _submitting = false;
  bool _passwordVisible = false;
  String _error = '';
  String _message = '';

  @override
  void initState() {
    super.initState();
    _emailController.addListener(_clearError);
    _passwordController.addListener(_clearError);
    _confirmPasswordController.addListener(_clearError);
  }

  void _clearError() {
    if (_error.isNotEmpty) setState(() => _error = '');
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    super.dispose();
  }

  String _friendlyError(Object e) {
    if (e is AuthException) return e.message;
    return 'Something went wrong. Please try again.';
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Email and password are required.');
      return;
    }
    final emailRegExp = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    if (!emailRegExp.hasMatch(email)) {
      setState(() => _error = 'Please enter a valid email address.');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    if (_isSignUp && _confirmPasswordController.text != password) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = '';
      _message = '';
    });
    try {
      // On success the auth gate swaps this page for the app, so only the
      // "confirm your email" case needs a message here.
      if (_isSignUp) {
        final result = await AuthService.instance.signUp(
          email: email,
          password: password,
        );
        if (!mounted) return;
        if (result.requiresEmailConfirmation) {
          setState(() {
            _message = 'Account created. Check your email to confirm it.';
            _isSignUp = false;
            _passwordController.clear();
            _confirmPasswordController.clear();
          });
        }
      } else {
        await AuthService.instance.signIn(email: email, password: password);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _sendPasswordReset() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email above to reset your password.');
      return;
    }
    final emailRegExp = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    if (!emailRegExp.hasMatch(email)) {
      setState(() => _error = 'Please enter a valid email address.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = '';
      _message = '';
    });
    try {
      await AuthService.instance.resetPasswordForEmail(email);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Reset link sent to $email')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _setSignUp(bool isSignUp) {
    if (isSignUp == _isSignUp) return;
    setState(() {
      _isSignUp = isSignUp;
      _error = '';
      _message = '';
      _passwordController.clear();
      _confirmPasswordController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final motion = MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 250);

    // Fades and folds [child] in or out, so rows that come and go (the
    // confirm field, Forgot password, notices) don't make the form jump.
    Widget reveal(Widget? child) => AnimatedSwitcher(
      duration: motion,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1,
          child: child,
        ),
      ),
      child: child ?? const SizedBox(width: double.infinity),
    );

    // Swaps one line of text for another with a cross-fade.
    Widget fade(Widget child) => AnimatedSwitcher(
      duration: motion,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: child,
    );

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 24,
                bottom: 24 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 48,
                    maxWidth: 420,
                  ),
                  // Centre instead of IntrinsicHeight: SegmentedTabs uses a
                  // LayoutBuilder, which has no intrinsic height.
                  child: Center(
                    child: AutofillGroup(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'SmartSpend',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.9,
                            ),
                          ),
                          const SizedBox(height: 6),
                          fade(
                            Text(
                              _isSignUp ? 'Create account' : 'Sign in',
                              key: ValueKey(_isSignUp),
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 15, color: c.muted),
                            ),
                          ),
                          const SizedBox(height: 24),
                          SegmentedTabs<bool>(
                            margin: EdgeInsets.zero,
                            value: _isSignUp,
                            segments: const {false: 'Sign In', true: 'Sign Up'},
                            onChanged: _setSignUp,
                          ),
                          const SizedBox(height: 20),
                          TextField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.username],
                            textInputAction: TextInputAction.next,
                            onSubmitted: (_) =>
                                _passwordFocusNode.requestFocus(),
                            decoration: const InputDecoration(
                              hintText: 'Email',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _passwordController,
                            focusNode: _passwordFocusNode,
                            obscureText: !_passwordVisible,
                            autofillHints: [
                              _isSignUp
                                  ? AutofillHints.newPassword
                                  : AutofillHints.password,
                            ],
                            textInputAction: _isSignUp
                                ? TextInputAction.next
                                : TextInputAction.done,
                            onSubmitted: (_) {
                              if (_isSignUp) {
                                _confirmPasswordFocusNode.requestFocus();
                              } else {
                                _submit();
                              }
                            },
                            decoration: InputDecoration(
                              hintText: 'Password',
                              suffixIcon: IconButton(
                                tooltip: _passwordVisible
                                    ? 'Hide password'
                                    : 'Show password',
                                icon: Icon(
                                  _passwordVisible
                                      ? Icons.visibility_rounded
                                      : Icons.visibility_off_rounded,
                                  size: 20,
                                  color: c.muted,
                                ),
                                onPressed: () => setState(
                                  () => _passwordVisible = !_passwordVisible,
                                ),
                              ),
                            ),
                          ),
                          reveal(
                            _isSignUp
                                ? Padding(
                                    key: const ValueKey('confirm'),
                                    padding: const EdgeInsets.only(top: 12),
                                    child: TextField(
                                      controller: _confirmPasswordController,
                                      focusNode: _confirmPasswordFocusNode,
                                      obscureText: !_passwordVisible,
                                      autofillHints: const [
                                        AutofillHints.newPassword,
                                      ],
                                      textInputAction: TextInputAction.done,
                                      onSubmitted: (_) => _submit(),
                                      decoration: const InputDecoration(
                                        hintText: 'Confirm password',
                                      ),
                                    ),
                                  )
                                : Align(
                                    key: const ValueKey('forgot'),
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed: _submitting
                                          ? null
                                          : _sendPasswordReset,
                                      style: TextButton.styleFrom(
                                        foregroundColor: c.muted,
                                      ),
                                      child: const Text('Forgot password'),
                                    ),
                                  ),
                          ),
                          reveal(
                            _error.isEmpty
                                ? null
                                : _Notice(
                                    key: ValueKey('error:$_error'),
                                    icon: Icons.error_outline_rounded,
                                    color: c.bad,
                                    text: _error,
                                  ),
                          ),
                          reveal(
                            _message.isEmpty
                                ? null
                                : _Notice(
                                    key: ValueKey('message:$_message'),
                                    icon: Icons.mark_email_read_rounded,
                                    color: c.good,
                                    text: _message,
                                  ),
                          ),
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: _submitting ? null : _submit,
                            // Keep the button's own colours while it works,
                            // instead of Material's grey disabled look.
                            style: FilledButton.styleFrom(
                              disabledBackgroundColor: c.button,
                              disabledForegroundColor: c.onButton,
                            ),
                            child: fade(
                              _submitting
                                  ? SizedBox(
                                      key: const ValueKey('spinner'),
                                      width: 18,
                                      height: 18,
                                      // The theme's spinner colour is the
                                      // button fill, so it would vanish on
                                      // the button.
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: c.onButton,
                                      ),
                                    )
                                  : Text(
                                      _isSignUp ? 'Create Account' : 'Sign In',
                                      key: ValueKey(_isSignUp),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One line of feedback under the form: an error or a "check your email".
class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 13.5, color: color)),
          ),
        ],
      ),
    );
  }
}
