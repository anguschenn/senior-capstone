# SmartSpend

**Senior Capstone Project — Semester 1**

Developed by Angus Chen, Xinhang Yang, Abdur Khan, and Christopher Barbosa.

---

SmartSpend is a personal finance management application designed to give users a clear and complete picture of their financial health. Rather than juggling multiple banking apps or spreadsheets, SmartSpend lets you connect all your bank accounts in one place, automatically syncs your transactions, and surfaces the insights that actually matter. Whether you want to know where your money is going each month, spot subscriptions you forgot about, or get a forward-looking view of your spending habits, SmartSpend brings it all together in a single, easy-to-navigate dashboard.

---

# Features — Work in Progress

**Multi-Account Overview**
Connect multiple bank accounts through Plaid and view all your balances and recent activity from a single dashboard. Accounts are synced automatically so your data is always up to date.

**Transaction Tracking and Categorization**
Every transaction is pulled in from your connected accounts and automatically assigned a category — groceries, dining, transport, and more. Categories are assigned with a confidence score, and low-confidence items are surfaced for your review. When you correct a categorization the app learns from it, storing your preferences so future transactions are categorized consistently.

**Budget Management**
Set spending limits for each category and track your progress over a month, a year, or all time. Budget cards show you exactly how much you have left and flag categories where you are approaching or over your limit.

**Subscription Detection**
SmartSpend scans your transaction history and automatically identifies recurring charges — streaming services, software subscriptions, gym memberships, and anything else that bills on a regular cycle. Every detected subscription is listed with its amount, frequency, and next charge date.

**Cash Flow Analysis**
See a breakdown of your income versus expenses across any time period. Trend summaries help you understand whether your financial position is improving or declining month over month.

**Spending Predictions and Budget Suggestions**
SmartSpend forecasts whether you are on track to exceed your budget in any category before the month ends, estimates upcoming subscription costs, and evaluates progress toward savings goals. Budget suggestions are generated automatically based on your actual spending history.

**AI Financial Assistant**
An integrated AI chat assistant lets you ask natural language questions about your finances — things like "how much did I spend on food last month?" or "where can I cut back?". The assistant routes questions through a hybrid engine that combines deterministic lookups against your real transaction data with an LLM for open-ended advice, and cites specific transactions to back up its answers.

---

# Built With

- Flutter
- Python / Flask
- Supabase
- Plaid

---

# Folder Structure

```
senior-capstone/
├── python/          # Flask backend — API routes, Plaid sync, AI assistant
├── ssdemo_1/        # Flutter frontend — UI, screens, and state management
├── db/              # Database schema and migration scripts
└── scripts/         # Developer convenience scripts
```

---

# Running the App

Both the backend and frontend require environment variables to be configured before running. Copy the provided `.env.example` files and fill in your own credentials.

Once configured, start the Python backend server and then run the Flutter app targeting your preferred platform (web recommended for development).

Refer to each subdirectory's README for more detailed setup instructions.

---

> **Note:** This project is currently in Semester 1 of a two-semester capstone. Many features are still under active development and this README will be updated as the project progresses into Semester 2.
