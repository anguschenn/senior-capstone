import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Earth palette: warm, low-saturation pigments. Category colours are the
/// same in light and dark mode; text on them is always [AppPalette.ink].
class AppPalette {
  static const ink = Color(0xFF1C1B1F);

  // Every category has its own colour, so no two cards look alike.
  static const food = Color(0xFFD28A5A); // terracotta
  static const transport = Color(0xFF7E9DB5); // slate blue
  static const shopping = Color(0xFFC98D97); // dusty rose
  static const bills = Color(0xFFB5BE78); // pistachio
  static const subscriptions = Color(0xFFA897BC); // lavender
  static const entertainment = Color(0xFFDDB45C); // mustard
  static const housing = Color(0xFFA97C5E); // walnut
  static const health = Color(0xFF7DB2AC); // teal
  static const fees = Color(0xFF9C8C7C); // mocha
  static const cash = Color(0xFFE3B8A0); // peach
  static const other = Color(0xFFBFB4A2); // stone
  static const income = Color(0xFF7DAE6E); // leaf green

  /// Wallet card colours, in the order accounts are listed.
  static const walletCards = <Color>[
    Color(0xFF35506D),
    Color(0xFFB08F55),
    Color(0xFF6E5A7E),
    Color(0xFF7A5A48),
    Color(0xFF4F6B78),
  ];

  /// The "All Accounts" card.
  static const walletAll = Color(0xFF46604E);
}

/// Surface and text colours that change between light and dark mode.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.background,
    required this.card,
    required this.raised,
    required this.line,
    required this.text,
    required this.muted,
    required this.good,
    required this.goodTint,
    required this.warn,
    required this.bad,
    required this.button,
    required this.onButton,
    required this.cardShadow,
  });

  final Color background;
  final Color card;

  /// One step above [card]: chips, segmented controls, secondary buttons.
  final Color raised;
  final Color line;
  final Color text;
  final Color muted;
  final Color good;
  final Color goodTint;
  final Color warn;
  final Color bad;

  /// Primary button fill and its label colour.
  final Color button;
  final Color onButton;

  /// Shadow under the stacked wallet and budget cards.
  final Color cardShadow;

  static const dark = AppColors(
    background: Color(0xFF171513),
    card: Color(0xFF2B2825),
    raised: Color(0xFF3A3632),
    line: Color(0xFF423D38),
    text: Color(0xFFF5F2EC),
    muted: Color(0xFF9C958B),
    good: Color(0xFF7FB36F),
    goodTint: Color(0xFF2E3A28),
    warn: Color(0xFFE0A84E),
    bad: Color(0xFFE07A6A),
    button: Color(0xFFF5F2EC),
    onButton: Color(0xFF1C1B1F),
    cardShadow: Color(0x59000000),
  );

  static const light = AppColors(
    background: Color(0xFFE8E2D6),
    card: Color(0xFFFBF8F2),
    raised: Color(0xFFE0D9CC),
    line: Color(0xFFE3DCCF),
    text: Color(0xFF1C1B1F),
    muted: Color(0xFF7D766C),
    good: Color(0xFF4F7A45),
    goodTint: Color(0xFFDCE8D3),
    warn: Color(0xFFA86F12),
    bad: Color(0xFFB4483A),
    button: Color(0xFF1C1B1F),
    onButton: Color(0xFFFBF8F2),
    cardShadow: Color(0x473C2814),
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      background: l(background, other.background),
      card: l(card, other.card),
      raised: l(raised, other.raised),
      line: l(line, other.line),
      text: l(text, other.text),
      muted: l(muted, other.muted),
      good: l(good, other.good),
      goodTint: l(goodTint, other.goodTint),
      warn: l(warn, other.warn),
      bad: l(bad, other.bad),
      button: l(button, other.button),
      onButton: l(onButton, other.onButton),
      cardShadow: l(cardShadow, other.cardShadow),
    );
  }
}

extension AppColorsContext on BuildContext {
  AppColors get colors =>
      Theme.of(this).extension<AppColors>() ?? AppColors.light;
}

class AppTheme {
  static ThemeData light() => _build(Brightness.light, AppColors.light);
  static ThemeData dark() => _build(Brightness.dark, AppColors.dark);

  static ThemeData _build(Brightness brightness, AppColors c) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppPalette.walletAll,
          brightness: brightness,
        ).copyWith(
          primary: c.text,
          onPrimary: c.background,
          surface: c.card,
          onSurface: c.text,
          error: c.bad,
        );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      platform: TargetPlatform.iOS,
    );
    return base.copyWith(
      extensions: [c],
      scaffoldBackgroundColor: c.background,
      canvasColor: c.background,
      cardColor: c.card,
      dividerColor: c.line,
      splashFactory: NoSplash.splashFactory,
      textTheme: base.textTheme.apply(bodyColor: c.text, displayColor: c.text),
      iconTheme: IconThemeData(color: c.text),
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        foregroundColor: c.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.card,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.button,
          foregroundColor: c.onButton,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: c.text),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.text,
          side: BorderSide(color: c.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.raised,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        hintStyle: TextStyle(color: c.muted),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: c.text),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.button,
        contentTextStyle: TextStyle(color: c.onButton),
      ),
    );
  }
}

/// System / Light / Dark choice, saved on the device.
class AppearanceController extends ValueNotifier<ThemeMode> {
  AppearanceController._() : super(ThemeMode.system);

  static final instance = AppearanceController._();
  static const _prefsKey = 'appearance_mode';

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      value = switch (prefs.getString(_prefsKey)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {}
  }

  Future<void> set(ThemeMode mode) async {
    value = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, mode.name);
    } catch (_) {}
  }
}
