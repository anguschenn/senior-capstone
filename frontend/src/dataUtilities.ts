import {
  AccountBase,
  AccountsGetResponse,
  AssetReport,
  AuthGetResponse,
  CraCheckReportBaseReportGetResponse,
  CraCheckReportIncomeInsightsGetResponse,
  CraCheckReportPartnerInsightsGetResponse,
  IdentityGetResponse,
  IncomeVerificationPaystubsGetResponse,
  InstitutionsGetByIdResponse,
  InvestmentsHoldingsGetResponse,
  InvestmentsTransactionsGetResponse,
  ItemGetResponse,
  LiabilitiesGetResponse,
  PaymentInitiationPaymentGetResponse,
  Paystub,
  SignalEvaluateResponse,
  StatementsListResponse,
  Transaction,
  TransferAuthorizationCreateResponse,
  TransferCreateResponse,
} from "plaid/dist/api";

const formatCurrency = (
  number: number | null | undefined,
  code: string | null | undefined
) => {
  if (number != null && number !== undefined) {
    const formattedNumber = parseFloat(number.toFixed(2)).toLocaleString("en");
    return code ? ` ${formattedNumber} ${code}` : ` ${formattedNumber}`;
  }
  return "no data";
};

const sortByAccountId = <T extends { account_id: string }>(items: T[]): T[] =>
  [...items].sort((a, b) => (a.account_id > b.account_id ? 1 : -1));

const findById = <T>(
  items: T[],
  selector: (item: T) => string,
  id: string
): T | undefined => items.find((item) => selector(item) === id);

const pickAccountBalance = (account: AccountBase): number | null | undefined =>
  account.balances.available || account.balances.current;

const formatAccountBalance = (account: AccountBase): string =>
  formatCurrency(pickAccountBalance(account), account.balances.iso_currency_code);

export interface Categories {
  title: string;
  field: string;
}

const category = (title: string, field: string): Categories => ({ title, field });

//interfaces for categories in each individual product
interface AuthDataItem {
  routing: string;
  account: string;
  balance: string;
  name: string;
}

interface TransactionsDataItem {
  amount: string;
  date: string;
  name: string;
  category?: string;
  website?: string;
}

interface IdentityDataItem {
  addresses: string;
  phoneNumbers: string;
  emails: string;
  names: string;
}

interface AccountsDataItem {
  balance: string;
  subtype: string | null;
  mask: string;
  name: string;
}

interface BalanceDataItem {
  current: string;
  available: string;
  subtype: string | null;
  mask: string;
  name: string;
}

interface InvestmentsDataItem {
  mask: string;
  quantity: string;
  price: string;
  value: string;
  name: string;
}

interface InvestmentsTransactionItem {
  amount: number;
  date: string;
  name: string;
}

interface LiabilitiesDataItem {
  amount: string;
  date: string;
  name: string;
  type: string;
}

interface PaymentDataItem {
  paymentId: string;
  amount: string;
  status: string;
  statusUpdate: string;
  recipientId: string;
}
interface ItemDataItem {
  billed: string;
  available: string;
  name: string;
}

interface AssetsDataItem {
  account: string;
  balance: string;
  transactions: number;
  daysAvailable: number;
}

interface TransferDataItem {
  transferId: string;
  amount: string;
  type: string;
  achClass: string | null;
  network: string;
}

interface TransferAuthorizationDataItem {
  authorizationId: string;
  authorizationDecision: string;
  decisionRationaleCode: string | null;
  decisionRationaleDescription: string | null;
}

interface StatementsDataItem {
  account: string | null;
  date: string | null;
}

interface SignalDataItem {
  currentBalance: string | undefined | null;
  availableBalance: string | undefined | null;
  rulesetOutcome: string | undefined | null;
  stsHeader: string;
  customerInitiatedReturnScore: string | undefined | null;
  bankInitiatedReturnScore: string | undefined | null;
  daysSinceFirstPlaidConnection: string | undefined | null;
}

interface IncomePaystubsDataItem {
  description: string;
  currentAmount: number | null;
  currency: number | null;
}

interface CreditReportGetItem {
  institution: string;
  accountName: string;
  averageDaysBetweenTransactions: string | null;
  averageInflowAmount: string | null;
  averageOutflowAmount: string  | null;
  averageBalance: string | null;
  balance: string | null;
}

interface CreditInsightsGetItem {
  incomeSourcesCount: number | null;
  historicalAnnualIncome: string | null;
  forecastedAnnualIncome: string | null;
}

interface CreditPartnerInsightsGetItem {
  firstDetectScore: number | null;
  cashScore: number | null;
}

export interface ErrorDataItem {
  error_type: string;
  error_code: string;
  error_message: string;
  display_message: string | null;
  status_code: number | null;
}

//all possible product data interfaces
export type DataItem =
  | AuthDataItem
  | TransactionsDataItem
  | IdentityDataItem
  | AccountsDataItem
  | BalanceDataItem
  | InvestmentsDataItem
  | InvestmentsTransactionItem
  | LiabilitiesDataItem
  | ItemDataItem
  | PaymentDataItem
  | AssetsDataItem
  | TransferDataItem
  | TransferAuthorizationDataItem
  | IncomePaystubsDataItem
  | SignalDataItem
  | StatementsDataItem
  | CreditReportGetItem
  | CreditInsightsGetItem
  | CreditPartnerInsightsGetItem;

export type Data = Array<DataItem>;

export const authCategories: Array<Categories> = [
  category("Name", "name"),
  category("Balance", "balance"),
  category("Account #", "account"),
  category("Routing #", "routing"),
];

export const transactionsCategories: Array<Categories> = [
  category("Name", "name"),
  category("Amount", "amount"),
  category("Date", "date"),
  category("Category", "category"),
  category("Website", "website"),
];

export const identityCategories: Array<Categories> = [
  category("Names", "names"),
  category("Emails", "emails"),
  category("Phone numbers", "phoneNumbers"),
  category("Addresses", "addresses"),
];

export const balanceCategories: Array<Categories> = [
  category("Name", "name"),
  category("Current Balance", "current"),
  category("Available Balance", "available"),
  category("Subtype", "subtype"),
  category("Mask", "mask"),
];

export const investmentsCategories: Array<Categories> = [
  category("Account Mask", "mask"),
  category("Name", "name"),
  category("Quantity", "quantity"),
  category("Close Price", "price"),
  category("Value", "value"),
];

export const investmentsTransactionsCategories: Array<Categories> = [
  category("Name", "name"),
  category("Amount", "amount"),
  category("Date", "date"),
];

export const liabilitiesCategories: Array<Categories> = [
  category("Name", "name"),
  category("Type", "type"),
  category("Last Payment Date", "date"),
  category("Last Payment Amount", "amount"),
];

export const itemCategories: Array<Categories> = [
  category("Institution Name", "name"),
  category("Billed Products", "billed"),
  category("Available Products", "available"),
];

export const accountsCategories: Array<Categories> = [
  category("Name", "name"),
  category("Balance", "balance"),
  category("Subtype", "subtype"),
  category("Mask", "mask"),
];

export const paymentCategories: Array<Categories> = [
  category("Payment ID", "paymentId"),
  category("Amount", "amount"),
  category("Status", "status"),
  category("Status Update", "statusUpdate"),
  category("Recipient ID", "recipientId"),
];

export const assetsCategories: Array<Categories> = [
  category("Account", "account"),
  category("Transactions", "transactions"),
  category("Balance", "balance"),
  category("Days Available", "daysAvailable"),
];

export const transferCategories: Array<Categories> = [
  category("Transfer ID", "transferId"),
  category("Amount", "amount"),
  category("Type", "type"),
  category("ACH Class", "achClass"),
  category("Network", "network"),
  category("Status", "status"),
];

export const transferAuthorizationCategories: Array<Categories> = [
  category("Authorization ID", "authorizationId"),
  category("Authorization Decision", "authorizationDecision"),
  category("Decision rationale code", "decisionRationaleCode"),
  category("Decision rationale description", "decisionRationaleDescription"),
];

export const signalCategories: Array<Categories> = [
  category("Current Balance", "currentBalance"),
  category("Available Balance", "availableBalance"),
  category("Ruleset evaluation outcome", "rulesetOutcome"),
  category(
    "Fields to right returned for Signal Transaction Scores templates only ➡️",
    "stsHeader"
  ),
  category("Customer Initiated Return Score", "customerInitiatedReturnScore"),
  category("Bank Initiated Return Score", "bankInitiatedReturnScore"),
  category(
    "Sample core attribute: Days since first Plaid connection",
    "daysSinceFirstPlaidConnection"
  ),
];

export const statementsCategories: Array<Categories> = [
  category("Account name", "account"),
  category("Statement Date", "date"),
];

export const incomePaystubsCategories: Array<Categories> = [
  category("Description", "description"),
  category("Current Amount", "currentAmount"),
  category("Currency", "currency"),
];


export const checkReportBaseReportCategories: Array<Categories> = [
  category("Account Name", "accountName"),
  category("Balance", "balance"),
  category("Avg. Balance", "averageBalance"),
  category("Avg. Inflow Amount", "averageInflowAmount"),
  category("Avg. Outflow Amount", "averageOutflowAmount"),
  category("Avg. Days Between Transactions", "averageDaysBetweenTransactions"),
];

export const checkReportInsightsCategories: Array<Categories> = [
  category("Income Sources", "incomeSourcesCount"),
  category("Historical Annual Income", "historicalAnnualIncome"),
  category("Forecasted Annual Income", "forecastedAnnualIncome"),
];

export const checkReportPartnerInsightsCategories: Array<Categories> = [
  category("CashScore®", "cashScore"),
  category("FirstDetect Score", "firstDetectScore"),
];

export const transformAuthData = (data: AuthGetResponse) => {
  return data.numbers.ach!.map((achNumbers) => {
    const account = findById(
      data.accounts || [],
      (a) => a.account_id,
      achNumbers.account_id!
    );
    if (!account) {
      return {
        name: "",
        balance: "no data",
        account: achNumbers.account!,
        routing: achNumbers.routing!,
      };
    }
    const obj: DataItem = {
      name: account.name,
      balance: formatAccountBalance(account),
      account: achNumbers.account!,
      routing: achNumbers.routing!,
    };
    return obj;
  });
};

export const transformStatementsData = (data: {json: StatementsListResponse}) => {
  const account = data.json.accounts[0]!.account_name;
  const statements = data.json.accounts[0]!.statements;
  return statements!.map((s) => {
    const item: DataItem = {
      date: Intl.DateTimeFormat('en', { month: 'long', year:'numeric' }).format(new Date(s.year!, s.month!)),
      account: account,
    };
    return item;
  });
};

export const transformTransactionsData = (data: {
  latest_transactions: Transaction[];
}): Array<DataItem> => {
  return data.latest_transactions!.map((t) => {
    const item: TransactionsDataItem = {
      name: t.name || "",
      amount: formatCurrency(t.amount!, t.iso_currency_code),
      date: t.authorized_date || t.date || "",
      category: t.personal_finance_category?.primary || "",
      website: t.website || t.counterparties?.[0]?.website || "",
    };
    return item;
  });
};

interface IdentityData {
  identity: IdentityGetResponse["accounts"];
}

export const transformIdentityData = (data: IdentityData) => {
  const final: Array<DataItem> = [];
  const identityData = data.identity![0];
  identityData.owners.forEach((owner) => {
    const names = owner.names.map((name) => {
      return name;
    });
    const emails = owner.emails.map((email) => {
      return email.data;
    });
    const phones = owner.phone_numbers.map((phone) => {
      return phone.data;
    });
    const addresses = owner.addresses.map((address) => {
      return `${address.data.street} ${address.data.city}, ${address.data.region} ${address.data.postal_code}`;
    });

    const num = Math.max(
      emails.length,
      names.length,
      phones.length,
      addresses.length
    );

    for (let i = 0; i < num; i++) {
      const obj = {
        names: names[i] || "",
        emails: emails[i] || "",
        phoneNumbers: phones[i] || "",
        addresses: addresses[i] || "",
      };
      final.push(obj);
    }
  });

  return final;
};

export const transformBalanceData = (data: AccountsGetResponse) => {
  const balanceData = data.accounts;

  return balanceData.map((account: AccountBase) => {
    const obj: DataItem = {
      name: account.name,
      current: formatCurrency(
        account.balances.current,
        account.balances.iso_currency_code
      ),
      available: formatCurrency(
        account.balances.available,
        account.balances.iso_currency_code
      ),
      subtype: account.subtype,
      mask: account.mask!,
    };
    return obj;
  });
};

interface InvestmentData {
  error: null;
  holdings: InvestmentsHoldingsGetResponse;
}

export const transformInvestmentsData = (data: InvestmentData) => {
  const holdingsData = sortByAccountId(data.holdings.holdings!);
  return holdingsData.map((holding) => {
    const account = findById(
      data.holdings.accounts || [],
      (acc) => acc.account_id,
      holding.account_id
    );
    const security = findById(
      data.holdings.securities || [],
      (sec) => sec.security_id!,
      holding.security_id!
    );
    if (!account || !security) {
      return {
        mask: "",
        name: "",
        quantity: formatCurrency(holding.quantity, ""),
        price: "no data",
        value: "no data",
      };
    }
    const value = holding.quantity * security.close_price!;

    const obj: DataItem = {
      mask: account.mask!,
      name: security.name!,
      quantity: formatCurrency(holding.quantity, ""),
      price: formatCurrency(
        security.close_price!,
        account.balances.iso_currency_code
      ),
      value: formatCurrency(value, account.balances.iso_currency_code),
    };
    return obj;
  });
};

interface InvestmentsTransactionData {
  error: null;
  investments_transactions: InvestmentsTransactionsGetResponse;
}

export const transformInvestmentTransactionsData = (
  data: InvestmentsTransactionData
) => {
  const investmentTransactionsData = sortByAccountId(
    data.investments_transactions.investment_transactions!
  );
  return investmentTransactionsData.map((investmentTransaction) => {
    const security = findById(
      data.investments_transactions.securities || [],
      (sec) => sec.security_id!,
      investmentTransaction.security_id!
    );

    const obj: DataItem = {
      name: security?.name || "",
      amount: investmentTransaction.amount,
      date: investmentTransaction.date,
    };
    return obj;
  });
};

interface LiabilitiesDataResponse {
  error: null;
  liabilities: LiabilitiesGetResponse;
}

export const transformLiabilitiesData = (data: LiabilitiesDataResponse) => {
  const liabilitiesData = data.liabilities.liabilities;
  const mapLiabilityGroup = <
    T extends {
      account_id: string;
      last_payment_date?: string | null;
      last_payment_amount?: number | null;
    }
  >(
    entries: T[] | null | undefined,
    typeLabel: string
  ): DataItem[] => {
    if (!entries) return [];
    return entries.map((entry) => {
      const account = findById(
        data.liabilities.accounts,
        (acc) => acc.account_id,
        entry.account_id
      );
      return {
        name: account?.name || "",
        type: typeLabel,
        date: entry.last_payment_date ?? "",
        amount: formatCurrency(
          entry.last_payment_amount,
          account?.balances.iso_currency_code || null
        ),
      };
    });
  };

  return []
    .concat(mapLiabilityGroup(liabilitiesData.credit, "credit card"))
    .concat(mapLiabilityGroup(liabilitiesData.mortgage, "mortgage"))
    .concat(mapLiabilityGroup(liabilitiesData.student, "student loan"));
};

export const transformSignalData = (data: SignalEvaluateResponse) => {
  const currentBalance = data.core_attributes?.current_balance;
  const availableBalance = data.core_attributes?.available_balance;
  const result = (data.ruleset as any)?.result;
  const customerRisk = data.scores?.customer_initiated_return_risk;
  const bankRisk = data.scores?.bank_initiated_return_risk;

  return [
    {
      currentBalance: formatCurrency(currentBalance, null),
      availableBalance: formatCurrency(availableBalance, null),
      rulesetOutcome: result || "N/A - enter a RULESET_KEY in .env for results",
      stsHeader: "",
      customerInitiatedReturnScore: customerRisk?.score?.toString() ?? "N/A",
      bankInitiatedReturnScore: bankRisk?.score?.toString() ?? "N/A",
      daysSinceFirstPlaidConnection:
        data.core_attributes?.days_since_first_plaid_connection?.toString() ?? "N/A",
    },
  ];
};

export const transformTransferAuthorizationData = (
  data: TransferAuthorizationCreateResponse
): Array<DataItem> => {
  const transferAuthorizationData = data.authorization;
  return [
    {
      authorizationId: transferAuthorizationData.id,
      authorizationDecision: transferAuthorizationData.decision,
      decisionRationaleCode:
        transferAuthorizationData.decision_rationale != null
          ? transferAuthorizationData.decision_rationale.code
          : "null",
      decisionRationaleDescription:
        transferAuthorizationData.decision_rationale != null
          ? transferAuthorizationData.decision_rationale.description
          : "null",
    },
  ];
};

export const transformTransferData = (
  data: TransferCreateResponse
): Array<DataItem> => {
  const transferData = data.transfer;
  return [
    {
      transferId: transferData.id,
      amount: transferData.amount,
      type: transferData.type,
      achClass: transferData.ach_class || null,
      network: transferData.network,
      status: transferData.status,
    },
  ];
};

interface ItemData {
  item: ItemGetResponse["item"];
  institution: InstitutionsGetByIdResponse["institution"];
}

export const transformItemData = (data: ItemData): Array<DataItem> => {
  return [
    {
      name: data.institution.name,
      billed: data.item.billed_products.join(", "),
      available: data.item.available_products.join(", "),
    },
  ];
};

export const transformAccountsData = (data: AccountsGetResponse) => {
  const accountsData = data.accounts;
  return accountsData.map((account) => {
    const obj: DataItem = {
      name: account.name,
      balance: formatAccountBalance(account),
      subtype: account.subtype,
      mask: account.mask!,
    };
    return obj;
  });
};

interface PaymentData {
  payment: PaymentInitiationPaymentGetResponse;
}

export const transformPaymentData = (data: PaymentData) => {
  const statusUpdate =
    typeof data.payment.last_status_update === "string"
      ? data.payment.last_status_update.replace("T", " ").replace("Z", "")
      : new Date(data.payment.last_status_update * 1000) // Java data comes as timestamp
          .toISOString()
          .replace("T", " ")
          .replace("Z", "");
  return [
    {
      paymentId: data.payment.payment_id,
      amount: `${data.payment.amount.currency} ${data.payment.amount.value}`,
      status: data.payment.status,
      statusUpdate: statusUpdate,
      recipientId: data.payment.recipient_id,
    },
  ];
};

interface AssetResponseData {
  json: AssetReport;
}

export const transformAssetsData = (data: AssetResponseData) => {
  const assetItems = data.json.items;
  return assetItems.flatMap((item) => {
    return item.accounts.map((account) => {
      const obj: DataItem = {
        account: account.name,
        balance: formatCurrency(
          account.balances.available || account.balances.current,
          account.balances.iso_currency_code
        ),
        transactions: account.transactions!.length,
        daysAvailable: account.days_available!,
      };
      return obj;
    });
  });
};

interface IncomePaystub {
  paystubs: IncomeVerificationPaystubsGetResponse;
}

export const transformIncomePaystubsData = (data: IncomePaystub) => {
  const paystubsItemsArray: Array<Paystub> = data.paystubs.paystubs;
  var finalArray: Array<IncomePaystubsDataItem> = [];
  for (var i = 0; i < paystubsItemsArray.length; i++) {
    var ActualEarningVariable: any = paystubsItemsArray[i].earnings;
    for (var j = 0; j < ActualEarningVariable.breakdown.length; j++) {
      var payStubItem: IncomePaystubsDataItem = {
        description:
          paystubsItemsArray[i].employer.name +
          "_" +
          ActualEarningVariable.breakdown[j].description,
        currentAmount: ActualEarningVariable.breakdown[j].current_amount,
        currency: ActualEarningVariable.breakdown[j].iso_currency_code,
      };
      finalArray.push(payStubItem);
    }
  }
  return finalArray;
};

export const transformBaseReportGetData = (data: CraCheckReportBaseReportGetResponse) => {
  const report = data.report;
  return report.items.flatMap((item) =>
    item.accounts.map((account) => {
      const accountInsights = account.account_insights;
      const averageInflow = accountInsights?.average_inflow_amounts?.pop()?.total_amount;
      const averageOutflow = accountInsights?.average_outflow_amounts?.pop()?.total_amount;
      return {
        accountName: account.name,
        averageDaysBetweenTransactions: accountInsights?.average_days_between_transactions?.toFixed(2),
        averageInflowAmount:  formatCurrency(averageInflow?.amount, averageInflow?.iso_currency_code),
        averageOutflowAmount: formatCurrency(averageOutflow?.amount, averageOutflow?.iso_currency_code),
        averageBalance: formatCurrency(account.balances.average_balance, account.balances.iso_currency_code),
        balance: formatCurrency(account.balances.available, account.balances.iso_currency_code)
      };
    })) as Array<CreditReportGetItem>;
};


export const transformIncomeInsightsData = (data: CraCheckReportIncomeInsightsGetResponse) => {
  const report = data.report?.bank_income_summary
  const historicalIncome = report?.historical_annual_income?.pop()
  const forecastedIncome = report?.forecasted_annual_income?.pop()
  return [
    {
      incomeSourcesCount: report?.income_sources_count,
      historicalAnnualIncome: formatCurrency(historicalIncome?.amount, historicalIncome?.iso_currency_code),
      forecastedAnnualIncome: formatCurrency(forecastedIncome?.amount, forecastedIncome?.iso_currency_code)
    }
  ] as Array<CreditInsightsGetItem>;
};


export const transformPartnerInsightsData = (data: CraCheckReportPartnerInsightsGetResponse) => {
  const report = data.report?.prism
  return [
    {
      cashScore: report?.cash_score?.score,
      firstDetectScore: report?.first_detect?.score,
    }
  ] as Array<CreditPartnerInsightsGetItem>;
};
