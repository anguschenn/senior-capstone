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
  static const _minPasswordLength = 6;
  static const _passwordRule = 'At least $_minPasswordLength characters';
  static final _emailRegExp = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _passwordFocusNode = FocusNode();
  final _confirmPasswordFocusNode = FocusNode();

  bool _isSignUp = false;
  bool _submitting = false;
  bool _passwordVisible = false;

  // Problems with what was typed show under their own field; [_error] is
  // for what the server says, shown above the button.
  String? _emailError;
  String? _passwordError;
  String? _confirmError;
  String _error = '';
  String _message = '';

  @override
  void initState() {
    super.initState();
    _emailController.addListener(() => _clearErrors(email: true));
    _passwordController.addListener(() => _clearErrors(password: true));
    _confirmPasswordController.addListener(() => _clearErrors(confirm: true));
  }

  void _clearErrors({
    bool email = false,
    bool password = false,
    bool confirm = false,
  }) {
    final stale =
        _error.isNotEmpty ||
        (email && _emailError != null) ||
        (password && _passwordError != null) ||
        (confirm && _confirmError != null);
    if (!stale) return;
    setState(() {
      _error = '';
      if (email) _emailError = null;
      if (password) _passwordError = null;
      if (confirm) _confirmError = null;
    });
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

  String? _checkEmail(String email, {String empty = 'Enter your email'}) {
    if (email.isEmpty) return empty;
    if (!_emailRegExp.hasMatch(email)) return 'Enter a valid email address';
    return null;
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final emailError = _checkEmail(email);
    final passwordError = password.isEmpty
        ? 'Enter your password'
        : password.length < _minPasswordLength
        ? _passwordRule
        : null;
    final confirmError =
        _isSignUp && _confirmPasswordController.text != password
        ? 'Passwords do not match'
        : null;
    if (emailError != null || passwordError != null || confirmError != null) {
      setState(() {
        _emailError = emailError;
        _passwordError = passwordError;
        _confirmError = confirmError;
      });
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
    final emailError = _checkEmail(
      email,
      empty: 'Enter your email to get a reset link',
    );
    if (emailError != null) {
      setState(() => _emailError = emailError);
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
      _emailError = null;
      _passwordError = null;
      _confirmError = null;
      _error = '';
      _message = '';
      _passwordController.clear();
      _confirmPasswordController.clear();
    });
  }

  /// A filled field with its label inside the box. An outline border would
  /// float the label up onto the border line, outside the fill.
  InputDecoration _field(
    AppColors c, {
    required String label,
    String? helper,
    String? error,
    Widget? suffix,
  }) {
    final labelStyle = WidgetStateTextStyle.resolveWith(
      (states) => TextStyle(
        color: states.contains(WidgetState.error) ? c.bad : c.muted,
      ),
    );
    return InputDecoration(
      labelText: label,
      labelStyle: labelStyle,
      floatingLabelStyle: labelStyle,
      helperText: helper,
      helperStyle: TextStyle(color: c.muted),
      errorText: error,
      suffixIcon: suffix,
      border: UnderlineInputBorder(
        borderSide: BorderSide.none,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final motion = MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 250);

    // The old content fades out in the first half and the new one fades in
    // in the second, so the two are never seen on top of each other.
    Widget handOver(Widget child, Animation<double> animation) =>
        FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: const Interval(0.5, 1),
          ),
          child: child,
        );

    // Fades and folds [child] in or out, so rows that come and go (the
    // confirm field, Forgot password, notices) don't make the form jump.
    Widget reveal(Widget? child) => AnimatedSwitcher(
      duration: motion,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => handOver(
        SizeTransition(sizeFactor: animation, axisAlignment: -1, child: child),
        animation,
      ),
      child: child ?? const SizedBox(width: double.infinity),
    );

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              // A fixed gap above the form rather than centring it, so the
              // form stays put when a row appears or goes below it.
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 24 + constraints.maxHeight * 0.1,
                bottom: 24 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
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
                        Text(
                          'All your accounts in one place',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 15, color: c.muted),
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
                          onSubmitted: (_) => _passwordFocusNode.requestFocus(),
                          decoration: _field(
                            c,
                            label: 'Email',
                            error: _emailError,
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
                          decoration: _field(
                            c,
                            label: 'Password',
                            // New accounts see the rule before they hit it.
                            helper: _isSignUp ? _passwordRule : null,
                            error: _passwordError,
                            suffix: IconButton(
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
                                    decoration: _field(
                                      c,
                                      label: 'Confirm password',
                                      error: _confirmError,
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
                          // instead of the theme's greyed-out disabled look.
                          style:
                              FilledButton.styleFrom(
                                disabledForegroundColor: c.onButton,
                              ).copyWith(
                                backgroundBuilder: pressableFill(
                                  fill: c.button,
                                  disabledFill: c.button,
                                ),
                              ),
                          child: AnimatedSwitcher(
                            duration: motion,
                            transitionBuilder: handOver,
                            child: _submitting
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
