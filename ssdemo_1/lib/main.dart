import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Demo backend endpoint (can point to Plaid sandbox proxy)
const String demoApiBaseUrl = "http://localhost:3000";

/// Backend endpoints used for Plaid sandbox flow
const String createLinkTokenEndpoint = "$demoApiBaseUrl/create_link_token";
const String exchangePublicTokenEndpoint = "$demoApiBaseUrl/exchange_public_token";
const String transactionsEndpoint = "$demoApiBaseUrl/transactions";

/// Simulates Plaid sandbox connection using backend endpoints
Future<void> connectBankDemo(BuildContext context) async {
  try {
    // 1. Ask backend to create a Plaid link_token
    final linkTokenResponse = await http
        .post(Uri.parse(createLinkTokenEndpoint))
        .timeout(const Duration(seconds: 10));

    if (linkTokenResponse.statusCode != 200) {
      throw Exception("Failed to create link token");
    }

    debugPrint("Link token response: ${linkTokenResponse.body}");

    // For demo purposes we simulate receiving a public_token
    const simulatedPublicToken = "public-sandbox-demo-token";

    // 2. Send public_token to backend to exchange for access_token
    final exchangeResponse = await http.post(
      Uri.parse(exchangePublicTokenEndpoint),
      headers: {"Content-Type": "application/json"},
      body: '{"public_token": "$simulatedPublicToken"}',
    );

    if (exchangeResponse.statusCode != 200) {
      throw Exception("Failed to exchange public token");
    }

    debugPrint("Token exchange response: ${exchangeResponse.body}");

    // 3. Request transactions from backend
    final transactionsResponse = await http.get(
      Uri.parse(transactionsEndpoint),
    );

    if (transactionsResponse.statusCode != 200) {
      throw Exception("Failed to fetch transactions");
    }

    debugPrint("Transactions: ${transactionsResponse.body}");

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Plaid sandbox connection simulated successfully."),
      ),
    );
  } catch (e) {
    debugPrint("Plaid sandbox flow error: $e");
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Plaid connection failed: $e"),
      ),
    );
  }
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
class DashboardContent extends StatefulWidget {
  const DashboardContent({super.key});

  @override
  State<DashboardContent> createState() => _DashboardContentState();
}

class _DashboardContentState extends State<DashboardContent> {

  final List<Map<String, String>> demoTransactions = const [
    {"name": "Netflix", "category": "Subscription", "amount": "\$15.99"},
    {"name": "Starbucks", "category": "Coffee", "amount": "\$5.20"},
    {"name": "Uber", "category": "Transport", "amount": "\$22.40"},
    {"name": "Amazon", "category": "Shopping", "amount": "\$64.56"},
    {"name": "Apple", "category": "App Store", "amount": "\$3.99"},
  ];

  List<Map<String, dynamic>> sandboxTransactions = [];

  Future<void> connectAndLoadTransactions() async {
    try {
      final linkTokenResponse = await http
          .post(Uri.parse(createLinkTokenEndpoint))
          .timeout(const Duration(seconds: 10));

      if (linkTokenResponse.statusCode != 200) {
        throw Exception("Failed to create link token");
      }

      const simulatedPublicToken = "public-sandbox-demo-token";

      final exchangeResponse = await http.post(
        Uri.parse(exchangePublicTokenEndpoint),
        headers: {"Content-Type": "application/json"},
        body: '{"public_token": "$simulatedPublicToken"}',
      );

      if (exchangeResponse.statusCode != 200) {
        throw Exception("Failed to exchange public token");
      }

      final transactionsResponse = await http.get(
        Uri.parse(transactionsEndpoint),
      );

      if (transactionsResponse.statusCode != 200) {
        throw Exception("Failed to fetch transactions");
      }

      final decoded = jsonDecode(transactionsResponse.body);

      final transactions = List<Map<String, dynamic>>.from(
        decoded["transactions"] ?? [],
      );

      setState(() {
        sandboxTransactions = transactions;
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Plaid sandbox transactions loaded."),
        ),
      );

    } catch (e) {
      debugPrint("Plaid sandbox flow error: $e");

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Plaid connection failed: $e")),
      );
    }
  }

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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (isDesktop)
                    const Text(
                      "Dashboard",
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                  ElevatedButton.icon(
                    onPressed: connectAndLoadTransactions,
                    icon: const Icon(Icons.link),
                    label: const Text("Connect Bank"),
                  ),
                ],
              ),
              const SizedBox(height: 20),

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

              const SizedBox(height: 8),

              ...sandboxTransactions.map((t) => TransactionItem(
                    t["name"]?.toString() ?? "Unknown",
                    t["category"]?.toString() ?? "Unknown",
                    "\$${t["amount"] ?? "0"}",
                  )),

              ...demoTransactions.map((t) => TransactionItem(
                    t["name"]!,
                    t["category"]!,
                    t["amount"]!,
                  )),
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
