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
    return Scaffold(
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
            subtitle: Text('Mar 10'),
            trailing: Text('- \$64'),
          ),
          const ListTile(
            leading: Icon(Icons.local_cafe),
            title: Text('Starbucks'),
            subtitle: Text('Mar 9'),
            trailing: Text('- \$5'),
          ),
          const ListTile(
            leading: Icon(Icons.directions_car),
            title: Text('Uber'),
            subtitle: Text('Mar 8'),
            trailing: Text('- \$22'),
          ),

          const SizedBox(height: 20),

          const Text('Upcoming Subscriptions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
              color: Colors.green.withOpacity(0.08),
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
              color: Colors.white,
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
        color: Colors.green.withOpacity(0.1),
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
      children: [
        Container(
          width: 16,
          height: height,
          color: Colors.green,
        ),
        const SizedBox(height: 4),
        Text(label),
      ],
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
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          Text('Activity', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          Text('Recent spending and income'),
          SizedBox(height: 16),
          ListTile(
            leading: Icon(Icons.shopping_cart),
            title: Text('Amazon'),
            subtitle: Text('Mar 10 • Shopping'),
            trailing: Text('- \$64'),
          ),
          ListTile(
            leading: Icon(Icons.local_cafe),
            title: Text('Starbucks'),
            subtitle: Text('Mar 9 • Coffee'),
            trailing: Text('- \$5'),
          ),
          ListTile(
            leading: Icon(Icons.directions_car),
            title: Text('Uber'),
            subtitle: Text('Mar 8 • Transport'),
            trailing: Text('- \$22'),
          ),
          ListTile(
            leading: Icon(Icons.tv),
            title: Text('Netflix'),
            subtitle: Text('Mar 7 • Subscription'),
            trailing: Text('- \$15.99'),
          ),
          ListTile(
            leading: Icon(Icons.attach_money),
            title: Text('Freelance Payment'),
            subtitle: Text('Mar 6 • Income'),
            trailing: Text('+ \$500'),
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
          _budgetItem('Food', '\$230 / \$350', 0.66),
          const SizedBox(height: 14),
          _budgetItem('Transport', '\$95 / \$150', 0.63),
          const SizedBox(height: 14),
          _budgetItem('Shopping', '\$320 / \$400', 0.80),
          const SizedBox(height: 14),
          _budgetItem('Entertainment', '\$75 / \$120', 0.62),
        ],
      ),
    );
  }

  // budget item widget
  Widget _budgetItem(String title, String amount, double progress) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(amount),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: progress, minHeight: 8),
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