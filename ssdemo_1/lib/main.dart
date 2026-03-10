import 'package:flutter/material.dart';

/// Demo backend endpoint (can point to Plaid sandbox proxy)
const String demoApiBaseUrl = "http://localhost:3000";

/// Example endpoints your backend could expose
const String connectEndpoint = "$demoApiBaseUrl/connect";
const String transactionsEndpoint = "$demoApiBaseUrl/transactions";

/// Placeholder function for future Plaid sandbox connection
/// Later you can replace the print statements with a real HTTP request
Future<void> connectBankDemo(BuildContext context) async {
  // TODO: Replace this with real backend call to Plaid sandbox
  // Example:
  // final response = await http.get(Uri.parse(connectEndpoint));

  debugPrint("Calling backend: $connectEndpoint");

  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text("Simulating Plaid sandbox connection..."),
    ),
  );

  // After backend is ready you could fetch transactions like:
  // http.get(Uri.parse(transactionsEndpoint));
}

void main() {
  runApp(const SmartSpend());
}

/// Root application
class SmartSpend extends StatelessWidget {
  const SmartSpend({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "SmartSpend Demo",
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const DashboardPage(),
    );
  }
}

/// Main dashboard page
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    // Mobile layout
    if (width < 800) {
      return const MobileDashboard();
    }

    // Desktop layout
    return const DesktopDashboard();
  }
}

/// Desktop layout
class DesktopDashboard extends StatelessWidget {
  const DesktopDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: const [
          SizedBox(width: 220, child: Sidebar()),
          Expanded(child: DashboardContent()),
        ],
      ),
    );
  }
}

/// Mobile layout
class MobileDashboard extends StatelessWidget {
  const MobileDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Dashboard"),

        actions: const [],
      ),

      /// Mobile sidebar menu
      drawer: const Drawer(
        child: Sidebar(),
      ),

      body: const DashboardContent(),
    );
  }
}

/// Sidebar (visual only)
class Sidebar extends StatelessWidget {
  const Sidebar({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade100,
      child: Column(
        children: const [
          SizedBox(height: 40),
          NavItem("Dashboard"),
          NavItem("Accounts"),
          NavItem("Transactions"),
          NavItem("Cash Flow"),
          NavItem("Reports"),
          NavItem("Budget"),
        ],
      ),
    );
  }
}

class NavItem extends StatelessWidget {
  final String label;

  const NavItem(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      onTap: () {},
    );
  }
}

/// Main dashboard content
class DashboardContent extends StatelessWidget {
  const DashboardContent({super.key});

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width > 800;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              /// Top row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  /// Only show title on desktop
                  if (isDesktop)
                    const Text(
                      "Dashboard",
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                  ElevatedButton.icon(
                    onPressed: () async {
                      await connectBankDemo(context);
                    },
                    icon: const Icon(Icons.link),
                    label: const Text("Connect Bank"),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              /// Summary cards
              const Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  SummaryCard("Income", "\$4200"),
                  SummaryCard("Expenses", "\$3719"),
                  SummaryCard("Net", "\$480"),
                  SummaryCard("Savings", "11%"),
                ],
              ),

              const SizedBox(height: 24),

              /// Chart placeholder
              Container(
                height: 250,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(20),
                  child: FakeCashFlowChart(),
                ),
              ),

              const SizedBox(height: 24),

              const Text(
                "Recent Transactions",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const TransactionItem("Netflix", "Subscription", "\$15.99"),
              const TransactionItem("Starbucks", "Coffee", "\$5.20"),
              const TransactionItem("Uber", "Transport", "\$22.40"),
              const TransactionItem("Amazon", "Shopping", "\$64.56"),
              const TransactionItem("Apple", "App Store", "\$3.99"),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small stat card
class SummaryCard extends StatelessWidget {
  final String title;
  final String value;

  const SummaryCard(this.title, this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final cardWidth = screenWidth > 800 ? 160.0 : (screenWidth - 60) / 2;

    return Container(
      width: cardWidth,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            blurRadius: 10,
            color: Colors.black12,
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(title),
        ],
      ),
    );
  }
}

/// Simple fake cash flow chart for demo
class FakeCashFlowChart extends StatelessWidget {
  const FakeCashFlowChart({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: const [
        ChartBar(height: 120, label: 'Jan'),
        ChartBar(height: 150, label: 'Feb'),
        ChartBar(height: 90, label: 'Mar'),
        ChartBar(height: 170, label: 'Apr'),
        ChartBar(height: 140, label: 'May'),
      ],
    );
  }
}

class ChartBar extends StatelessWidget {
  final double height;
  final String label;

  const ChartBar({required this.height, required this.label, super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          width: 18,
          height: height,
          decoration: BoxDecoration(
            color: Colors.blue,
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    );
  }
}

/// Transaction row
class TransactionItem extends StatelessWidget {
  final String name;
  final String category;
  final String amount;

  const TransactionItem(
    this.name,
    this.category,
    this.amount, {
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.receipt),
      title: Text(name),
      subtitle: Text(category),
      trailing: Text(
        amount,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }
}