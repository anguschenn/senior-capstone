import '../core/config/supabase_client.dart';

class SubscriptionService {
  const SubscriptionService._();
  static const instance = SubscriptionService._();

  Future<void> confirm(String id) async {
    await AppSupabase.client
        .from('subscriptions')
        .update({'needs_confirmation': false, 'user_confirmed': true})
        .eq('id', id);
  }

  Future<void> dismiss(String id) async {
    await AppSupabase.client
        .from('subscriptions')
        .update({'is_active': false})
        .eq('id', id);
  }
}
