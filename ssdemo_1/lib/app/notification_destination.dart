int? notificationTabIndexFor(String? notification) => switch (notification) {
  'transaction_review' => 0,
  'budget' => 2,
  'subscription_review' => 3,
  _ => null,
};
