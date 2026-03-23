import 'package:flutter/material.dart';

// App entry point
void main() => runApp(const SmartSpendApp());

// Root app widget
class SmartSpendApp extends StatelessWidget {
  const SmartSpendApp({super.key});

  @override
  Widget build(BuildContext context) {
    // App configuration
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SmartSpend',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
      ),
      home: const MainScreen(),
    );
  }
}

// Main screen with bottom navigation
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  // current selected tab
  int index = 0;

  // pages for each tab
  final pages = const [
    HomePage(),
    CashFlowPage(),
    TransactionsPage(),
    BudgetPage(),
    SubscriptionsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    // show selected page
    return Stack(
      children: [
        Scaffold(
          body: pages[index],
          bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) => setState(() => index = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Flow'),
              NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Activity'),
              NavigationDestination(icon: Icon(Icons.pie_chart_outline), label: 'Budget'),
              NavigationDestination(icon: Icon(Icons.subscriptions_outlined), label: 'Subs'),
            ],
          ),
        ),
        Positioned(
          right: 18,
          bottom: 96,
          child: AIAssistantButton(
            onTap: () {
              showModalBottomSheet(
                context: context,
                backgroundColor: Colors.transparent,
                builder: (context) => const AIAssistantPanel(),
              );
            },
          ),
        ),
      ],
    );
  }
}

// Home dashboard page
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    // avoid system UI overlap
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('SmartSpend', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),

          const Text('Total Balance'),
          const Text('\$12,430', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Net this month: +\$481', style: TextStyle(color: Colors.green)),

          const SizedBox(height: 20),

          Row(
            children: const [
              Expanded(child: SummaryCard(title: 'Income', value: '\$4,200')),
              SizedBox(width: 12),
              Expanded(child: SummaryCard(title: 'Expenses', value: '\$3,719')),
            ],
          ),

          const SizedBox(height: 20),


          const Text('Recent Transactions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const ListTile(
            leading: Icon(Icons.shopping_cart),
            title: Text('Amazon'),
            subtitle: Text('Mar 10 • 2:45 PM'),
            trailing: Text('- \$64'),
          ),
          const ListTile(
            leading: Icon(Icons.local_cafe),
            title: Text('Starbucks'),
            subtitle: Text('Mar 9 • 9:20 AM'),
            trailing: Text('- \$5'),
          ),
          const ListTile(
            leading: Icon(Icons.directions_car),
            title: Text('Uber'),
            subtitle: Text('Mar 8 • 6:10 PM'),
            trailing: Text('- \$22'),
          ),

          const SizedBox(height: 20),

          const Text('Upcoming Subscriptions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Monthly total: \$25.98',
            style: TextStyle(color: Colors.black54),
          ),
          const ListTile(
            leading: Icon(Icons.tv),
            title: Text('Netflix'),
            subtitle: Text('Renews Mar 15'),
            trailing: Text('\$15.99'),
          ),
          const ListTile(
            leading: Icon(Icons.music_note),
            title: Text('Spotify'),
            subtitle: Text('Renews Mar 18'),
            trailing: Text('\$9.99'),
          ),
        ],
      ),
    );
  }
}

// Cash flow page
class CashFlowPage extends StatelessWidget {
  const CashFlowPage({super.key});

  @override
  Widget build(BuildContext context) {
    // avoid system UI overlap
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Cash Flow', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Track monthly money in and out'),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: const [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Income', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('\$4,200'),
                  ],
                ),
                SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Expenses', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('\$3,719'),
                  ],
                ),
                SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Net', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('+\$481'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ChartBar(label: 'Jan', height: 60),
                ChartBar(label: 'Feb', height: 90),
                ChartBar(label: 'Mar', height: 70),
                ChartBar(label: 'Apr', height: 110),
                ChartBar(label: 'May', height: 80),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.trending_up, color: Colors.green),
                    SizedBox(width: 8),
                    Text(
                      'Trend Summary',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                Text('• Spending increased slightly compared to last month'),
                SizedBox(height: 6),
                Text('• Shopping remains the largest expense category'),
                SizedBox(height: 6),
                Text('• Net cash flow is still positive this month'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// summary card widget
class SummaryCard extends StatelessWidget {
  final String title;
  final String value;

  const SummaryCard({super.key, required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(title),
        ],
      ),
    );
  }
}

// chart bar widget
class ChartBar extends StatelessWidget {
  final String label;
  final double height;

  const ChartBar({super.key, required this.label, required this.height});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          width: 22,
          height: height,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Colors.green, Colors.lightGreen],
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
            ),
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 4,
                offset: Offset(0, 2),
              )
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

class CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;

  const CategoryChip({super.key, required this.label, this.selected = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? Colors.green : Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.white : Colors.green,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class AIAssistantButton extends StatelessWidget {
  final VoidCallback onTap;

  const AIAssistantButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined, color: Colors.green),
              SizedBox(width: 8),
              Text(
                'AI',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.green,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AIAssistantPanel extends StatelessWidget {
  const AIAssistantPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(24),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.smart_toy_outlined, color: Colors.green),
              SizedBox(width: 10),
              Text(
                'AI Assistant',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          SizedBox(height: 12),
          Text(
            'This is a floating AI chatbot placeholder. Later it can provide spending insights, subscription reminders, and budget suggestions.',
            style: TextStyle(height: 1.4),
          ),
          SizedBox(height: 14),
          TextField(
            decoration: InputDecoration(
              hintText: 'Ask about your spending...',
              prefixIcon: Icon(Icons.chat_bubble_outline),
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}

// transactions list page
class TransactionsPage extends StatelessWidget {
  const TransactionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // avoid system UI overlap
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search transactions',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.green.withOpacity(0.06),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: const [
                SizedBox(height: 4),
                ListTile(
                  leading: Icon(Icons.shopping_cart),
                  title: Text('Amazon'),
                  subtitle: Text('Mar 10 • 2:45 PM • Shopping'),
                  trailing: Text('- \$64'),
                ),
                ListTile(
                  leading: Icon(Icons.local_cafe),
                  title: Text('Starbucks'),
                  subtitle: Text('Mar 9 • 9:20 AM • Coffee'),
                  trailing: Text('- \$5'),
                ),
                ListTile(
                  leading: Icon(Icons.directions_car),
                  title: Text('Uber'),
                  subtitle: Text('Mar 8 • 6:10 PM • Transport'),
                  trailing: Text('- \$22'),
                ),
                ListTile(
                  leading: Icon(Icons.tv),
                  title: Text('Netflix'),
                  subtitle: Text('Mar 7 • 11:30 PM • Subscription'),
                  trailing: Text('- \$15.99'),
                ),
                ListTile(
                  leading: Icon(Icons.attach_money),
                  title: Text('Freelance Payment'),
                  subtitle: Text('Mar 6 • 1:15 PM • Income'),
                  trailing: Text('+ \$500'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// budget page
class BudgetPage extends StatelessWidget {
  const BudgetPage({super.key});

  @override
  Widget build(BuildContext context) {
    // avoid system UI overlap
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Budget', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Simple category-based budget view'),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Budget Insight: Your shopping category is close to its monthly limit.',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          _budgetItem('Food', '\$230 / \$350', 0.66, false),
          const SizedBox(height: 14),
          _budgetItem('Transport', '\$95 / \$150', 0.63, false),
          const SizedBox(height: 14),
          _budgetItem('Shopping', '\$320 / \$400', 0.80, true),
          const SizedBox(height: 14),
          _budgetItem('Entertainment', '\$75 / \$120', 0.62, false),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.smart_toy_outlined, color: Colors.green),
                    SizedBox(width: 10),
                    Text(
                      'AI Analysis',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                Text('• Shopping is the category closest to its budget limit'),
                SizedBox(height: 6),
                Text('• Food and transport spending are still within a healthy range'),
                SizedBox(height: 10),
                Text(
                  'Suggestion: Try reducing non-essential shopping this week to stay within budget.',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // budget item widget
  Widget _budgetItem(String title, String amount, double progress, bool isWarning) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 12),
              Text(amount),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            color: isWarning ? Colors.orange : Colors.green,
            backgroundColor: Colors.black12,
          ),
          SizedBox(
            height: 24,
            child: Align(
              alignment: Alignment.centerLeft,
              child: isWarning
                  ? const Text(
                      'Almost over budget',
                      style: TextStyle(color: Colors.orange, fontSize: 12),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

// subscriptions page
class SubscriptionsPage extends StatelessWidget {
  const SubscriptionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // avoid system UI overlap
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          Text('Subs', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          Text('Recurring monthly payments'),
          SizedBox(height: 16),
          ListTile(
            leading: Icon(Icons.tv),
            title: Text('Netflix'),
            subtitle: Text('Renews Mar 15'),
            trailing: Text('\$15.99'),
          ),
          ListTile(
            leading: Icon(Icons.music_note),
            title: Text('Spotify'),
            subtitle: Text('Renews Mar 18'),
            trailing: Text('\$9.99'),
          ),
          ListTile(
            leading: Icon(Icons.cloud),
            title: Text('iCloud'),
            subtitle: Text('Renews Mar 22'),
            trailing: Text('\$2.99'),
          ),
          ListTile(
            leading: Icon(Icons.school),
            title: Text('Notion Student Plus'),
            subtitle: Text('Renews Mar 28'),
            trailing: Text('\$4.99'),
          ),
        ],
      ),
    );
  }
}