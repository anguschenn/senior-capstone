import 'package:flutter/material.dart';

import 'app/smart_spend_app.dart';
import 'core/config/api_config.dart';
import 'core/config/env_config.dart';
import 'core/config/supabase_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EnvConfig.load();
  await AppSupabase.init();
  ApiConfig.init();
  runApp(const SmartSpendApp());
}
