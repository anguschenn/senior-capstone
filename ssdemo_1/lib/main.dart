import 'package:flutter/material.dart';

import 'app/app_theme.dart';
import 'app/smart_spend_app.dart';
import 'core/config/api_config.dart';
import 'core/config/env_config.dart';
import 'core/config/supabase_client.dart';
import 'widgets/common/ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  trackPointerForMenus();
  await EnvConfig.load();
  await AppSupabase.init();
  ApiConfig.init();
  await AppearanceController.instance.load();
  runApp(const SmartSpendApp());
}
