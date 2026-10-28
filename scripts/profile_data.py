"""
profile the raw kodes csv before cleaning.

finds the anomalies and checks which functional dependencies really hold in
the flat file. writes data/profile/profile_report.json and prints a summary.

usage:  python3 scripts/profile_data.py data/raw/online_retail_data.csv
"""
import json
import sys
from pathlib import Path

import pandas as pd

RAW = Path(sys.argv[1] if len(sys.argv) > 1 else "data/raw/online_retail_data.csv")
OUT = Path("data/profile")
OUT.mkdir(parents=True, exist_ok=True)

df = pd.read_csv(RAW, dtype=str, keep_default_na=False)
df["qty"] = df["Quantity"].astype(int)
df["price"] = df["Price"].astype(float)
df["revenue"] = df["qty"] * df["price"]
prefix = df["Invoice"].str.extract(r"^([A-Za-z]*)")[0]
has_cust = df["Customer ID"].str.strip() != ""

report = {}

# 1. shape and basic profile
report["rows"] = int(len(df))
report["columns"] = list(df.columns[:8])
report["date_range"] = [df["InvoiceDate"].min(), df["InvoiceDate"].max()]
report["distinct"] = {c: int(df[c].nunique()) for c in df.columns[:8]}
report["blank_values"] = {c: int((df[c].str.strip() == "").sum()) for c in df.columns[:8]}

# 2. duplicates
report["exact_duplicate_rows"] = int(df.duplicated(subset=df.columns[:8], keep="first").sum())

# 3. invoice types and quantity signs
report["invoice_prefix_rows"] = {k or "(none)": int(v) for k, v in prefix.value_counts().items()}
report["invoice_prefix_invoices"] = {
    k or "(none)": int(v) for k, v in df.groupby(prefix)["Invoice"].nunique().items()
}
report["cancellation_rows_with_positive_qty"] = int(((prefix == "C") & (df.qty > 0)).sum())
neg_plain = (prefix != "C") & (df.qty < 0)
report["non_cancellation_rows_with_negative_qty"] = int(neg_plain.sum())
report["non_cancellation_negative_qty_all_price0_no_customer"] = bool(
    ((df.price[neg_plain] == 0) & (~has_cust[neg_plain])).all()
)

# 4. prices
report["price_negative_rows"] = int((df.price < 0).sum())
report["price_zero_rows"] = int((df.price == 0).sum())
report["price_zero_rows_with_customer"] = int(((df.price == 0) & has_cust).sum())
report["price_max_decimals"] = int(df["Price"].str.split(".").str[1].fillna("").str.len().max())

# 5. missing values
blank_desc = df["Description"].str.strip() == ""
report["blank_description_rows"] = int(blank_desc.sum())
report["blank_description_all_price0_no_customer"] = bool(
    ((df.price[blank_desc] == 0) & (~has_cust[blank_desc])).all()
)
report["missing_customer_rows"] = int((~has_cust).sum())
report["missing_customer_invoices"] = int(df.loc[~has_cust, "Invoice"].nunique())
report["missing_customer_revenue_share_pct"] = round(
    float(df.loc[~has_cust, "revenue"].sum() / df["revenue"].sum() * 100), 2
)

# 6. text formatting problems
report["stockcode_untrimmed_rows"] = int((df.StockCode != df.StockCode.str.strip()).sum())
report["description_untrimmed_rows"] = int((df.Description != df.Description.str.strip()).sum())
report["description_double_space_rows"] = int(df.Description.str.contains("  ").sum())
upper = df.StockCode.str.strip().str.upper()
case_variants = df.groupby(upper)["StockCode"].nunique()
report["stockcodes_with_case_variants"] = int((case_variants > 1).sum())
report["stockcode_case_examples"] = sorted(
    df.loc[upper.isin(case_variants[case_variants > 1].index[:3]), "StockCode"].unique().tolist()
)

# 7. functional dependency checks (on de-duplicated rows)
d = df.drop_duplicates(subset=df.columns[:8]).copy()
d["sc"] = d.StockCode.str.strip().str.upper()
d["desc_norm"] = d.Description.str.strip().str.replace(r"\s+", " ", regex=True).str.upper()
fd = {}
for col in ["InvoiceDate", "Customer ID", "Country"]:
    n = d.groupby("Invoice")[col].nunique()
    fd[f"Invoice -> {col}"] = {"violations": int((n > 1).sum()), "of": int(len(n))}
cust = d[d["Customer ID"].str.strip() != ""]
n = cust.groupby("Customer ID")["Country"].nunique()
fd["Customer ID -> Country"] = {"violations": int((n > 1).sum()), "of": int(len(n))}
withdesc = d[d.Description.str.strip() != ""]
n = withdesc.groupby("StockCode")["Description"].nunique()
fd["StockCode -> Description (raw)"] = {"violations": int((n > 1).sum()), "of": int(len(n))}
n = withdesc.groupby("sc")["desc_norm"].nunique()
fd["StockCode -> Description (trimmed, upper-cased)"] = {"violations": int((n > 1).sum()), "of": int(len(n))}
sales = d[(d.price > 0) & (~d.Invoice.str.match(r"^[A-Za-z]"))]
n = sales.groupby("sc")["price"].nunique()
fd["StockCode -> Price"] = {"violations": int((n > 1).sum()), "of": int(len(n))}
g = d.groupby(["Invoice", "sc"]).agg(n=("qty", "size"), prices=("price", "nunique"))
fd["(Invoice, StockCode) unique"] = {
    "groups_with_repeats": int((g.n > 1).sum()),
    "repeats_with_different_prices": int(((g.n > 1) & (g.prices > 1)).sum()),
}
multi_date = d.groupby("Invoice")["InvoiceDate"].agg(["min", "max", "nunique"])
multi_date = multi_date[multi_date["nunique"] > 1]
spread = (pd.to_datetime(multi_date["max"]) - pd.to_datetime(multi_date["min"])).dt.total_seconds() / 60
fd["Invoice -> InvoiceDate"]["max_spread_minutes"] = float(spread.max()) if len(spread) else 0.0
report["functional_dependencies"] = fd

# 8. special (non-product) stock codes
special = d[~d.sc.str.match(r"^\d{5}")]
report["special_stockcodes"] = (
    special.groupby("sc")
    .agg(rows=("Invoice", "size"), description=("desc_norm", lambda s: s.value_counts().index[0]))
    .sort_values("rows", ascending=False)
    .head(25)
    .reset_index()
    .to_dict(orient="records")
)

# 9. outliers and country labels
report["quantity_min_max"] = [int(df.qty.min()), int(df.qty.max())]
report["country_labels_to_review"] = [
    c for c in sorted(df.Country.unique())
    if c in {"EIRE", "RSA", "USA", "Unspecified", "European Community", "Channel Islands", "West Indies"}
]

(OUT / "profile_report.json").write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
