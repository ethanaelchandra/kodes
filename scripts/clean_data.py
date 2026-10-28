"""
clean the raw kodes csv and split it into the normalized (3nf) tables.

every removed row is written to data/clean/rejected_rows.csv.gz with the rule
that removed it, and every step is counted in data/clean/cleaning_report.json,
so the full dataset is accounted for (kept + rejected = raw).

usage:  python3 scripts/clean_data.py data/raw/online_retail_data.csv
output: data/clean/{countries,customers,products,inventory,invoices,invoice_lines}.csv
"""
import json
import math
import sys
from decimal import Decimal
from pathlib import Path

import numpy as np
import pandas as pd

RAW = Path(sys.argv[1] if len(sys.argv) > 1 else "data/raw/online_retail_data.csv")
OUT = Path("data/clean")
OUT.mkdir(parents=True, exist_ok=True)

SRC_COLS = ["Invoice", "StockCode", "Description", "Quantity", "InvoiceDate", "Price", "Customer ID", "Country"]

# codes that are bookkeeping or test entries, not customer transactions
INTERNAL_CODES = {"B", "TEST001", "TEST002", "AMAZONFEE", "CRUK", "ADJUST", "ADJUST2"}
# codes that are real customer charges but not physical stock (no inventory row)
NON_STOCK_CODES = {"POST", "DOT", "C2", "M", "D", "S", "BANK CHARGES", "PADS"}
NON_STOCK_PREFIXES = ("GIFT_0001_",)  # gift vouchers (22016 is also a voucher, caught by its description)
COUNTRY_RENAMES = {"EIRE": "Ireland", "RSA": "South Africa", "USA": "United States"}
# labels kept as they are (the real country is unknown) but flagged as not being one country
NON_COUNTRY_LABELS = {"Unspecified", "European Community", "Channel Islands", "West Indies"}
# guest accounts get ids 1..n: real customer ids start at 12346 and new customers continue
# from the auto_increment counter (18288), so the three ranges never collide
GUEST_ID_START = 1

raw = pd.read_csv(RAW, dtype=str, keep_default_na=False)
raw.insert(0, "source_line", np.arange(2, len(raw) + 2))  # line number in the csv (header is line 1)

steps, fixes, rejected = [], [], []  # removal rules r1-r4, corrections c1-c7


def money(x) -> Decimal:
    return Decimal(str(x))


def revenue(frame: pd.DataFrame) -> Decimal:
    return sum((Decimal(q) * Decimal(p) for q, p in zip(frame["Quantity"], frame["Price"])), Decimal("0"))


def drop(frame: pd.DataFrame, mask: pd.Series, step: str, reason: str) -> pd.DataFrame:
    removed = frame[mask]
    if len(removed):
        rejected.append(removed[["source_line"] + SRC_COLS].assign(reason=reason))
    steps.append({
        "step": step,
        "rule": reason,
        "rows_removed": int(mask.sum()),
        "rows_remaining": int((~mask).sum()),
        "examples": removed[SRC_COLS].head(3).to_dict(orient="records"),
    })
    return frame[~mask].copy()


df = raw.copy()
summary = {"raw_rows": int(len(raw)), "raw_invoices": int(raw.Invoice.nunique()), "raw_revenue": str(revenue(raw))}

# r1. exact duplicates: identical in all 8 columns, including the timestamp to the minute
df = drop(df, df.duplicated(subset=SRC_COLS, keep="first"), "r1", "exact duplicate of an earlier row")

# c1, c2. standardise text (no rows removed)
before_code, before_desc = df["StockCode"].copy(), df["Description"].copy()
for col in ["Invoice", "StockCode", "Description", "Customer ID", "Country"]:
    df[col] = df[col].str.strip()
df["StockCode"] = df["StockCode"].str.upper()
df["Description"] = df["Description"].str.replace(r"\s+", " ", regex=True)
fixes.append({"fix": "c1", "rule": "stock codes trimmed and upper-cased (e.g. 15056bl -> 15056BL)",
              "values_changed": int((before_code != df["StockCode"]).sum())})
fixes.append({"fix": "c2", "rule": "descriptions trimmed and repeated spaces collapsed",
              "values_changed": int((before_desc != df["Description"]).sum())})

prefix = df["Invoice"].str.extract(r"^([A-Z]*)")[0]
qty = df["Quantity"].astype(int)
price = df["Price"].astype(float)
no_customer = df["Customer ID"] == ""

# r2. bookkeeping / test entries (bad-debt adjustments, amazon fees, charity commission, manual adjustments, test products)
mask = (prefix == "A") | df["StockCode"].isin(INTERNAL_CODES)
df = drop(df, mask, "r2", "internal bookkeeping or test entry, not a customer transaction")

# r3. warehouse adjustments: price 0 with no customer (damaged, lost, found, '?', blank descriptions, stock write-offs)
price = df["Price"].astype(float)
no_customer = df["Customer ID"] == ""
df = drop(df, (price == 0) & no_customer, "r3", "zero-price line with no customer (warehouse stock adjustment, not a sale)")

# r4. quantity sign must match the document type: 'C' credit notes negative, normal invoices positive
qty = df["Quantity"].astype(int)
is_credit = df["Invoice"].str.startswith("C")
mask = (is_credit & (qty > 0)) | (~is_credit & (qty < 0)) | (qty == 0)
df = drop(df, mask, "r4", "quantity sign does not match the document type")

# sanity checks after removals
price = df["Price"].astype(float)
assert (df["Description"] != "").all(), "blank descriptions left"
assert (price >= 0).all(), "negative prices left"
assert (df["Price"].str.split(".").str[1].fillna("").str.len() <= 3).all()

# c3. Invoice -> InvoiceDate: a few invoices span 1-9 minutes; use the first timestamp
dates = df.groupby("Invoice")["InvoiceDate"].transform("min")
fixes.append({"fix": "c3", "rule": "invoice date set to the earliest timestamp of the invoice",
              "invoices_changed": int(df.loc[dates != df["InvoiceDate"], "Invoice"].nunique())})
df["InvoiceDate"] = dates

# c4 (done before c5 so ties compare clean names). standard country names
fixes.append({"fix": "c4", "rule": "country labels standardised: " + ", ".join(f"{k} -> {v}" for k, v in COUNTRY_RENAMES.items()),
              "rows_changed": int(df["Country"].isin(COUNTRY_RENAMES).sum())})
df["Country"] = df["Country"].replace(COUNTRY_RENAMES)

# c5. Customer ID -> Country: 13 customers appear under two countries; keep the one with most invoices (tie: latest)
reg = df[df["Customer ID"] != ""]
inv_country = reg.drop_duplicates("Invoice")[["Invoice", "Customer ID", "Country", "InvoiceDate"]]
cc = (inv_country.groupby(["Customer ID", "Country"])
      .agg(invoices=("Invoice", "nunique"), last=("InvoiceDate", "max")).reset_index()
      .sort_values(["Customer ID", "invoices", "last"], ascending=[True, False, False]))
home = cc.drop_duplicates("Customer ID").set_index("Customer ID")["Country"]
multi = cc.groupby("Customer ID").size()
multi = multi[multi > 1].index
fixes.append({"fix": "c5", "rule": "customer country = country with the most invoices (tie: most recent)",
              "customers_changed": int(len(multi)),
              "details": cc[cc["Customer ID"].isin(multi)].assign(chosen=lambda x: x["Customer ID"].map(home)).to_dict(orient="records")})

# c7. guest checkouts: rows without a customer id go to one guest account per country
guest_countries = sorted(df.loc[df["Customer ID"] == "", "Country"].unique())
guest_ids = {c: GUEST_ID_START + i for i, c in enumerate(guest_countries)}
fixes.append({"fix": "c7", "rule": f"rows without Customer ID assigned to a guest account per country (ids {GUEST_ID_START}..{GUEST_ID_START + len(guest_ids) - 1})",
              "rows_changed": int((df["Customer ID"] == "").sum()),
              "guest_accounts": len(guest_ids)})
df["customer_id"] = np.where(df["Customer ID"] == "",
                             df["Country"].map(guest_ids).astype("Int64").astype(str),
                             df["Customer ID"].str.replace(r"\.0$", "", regex=True))

# ---------------------------------------------------------------- build tables
df["invoice_type"] = np.where(df["Invoice"].str.startswith("C"), "Return", "Sale")
df["qty"] = df["Quantity"].astype(int)
df["price"] = df["Price"].astype(float)

# countries: every country label seen in the source (after renames)
all_countries = sorted(set(raw["Country"].str.strip().replace(COUNTRY_RENAMES)))
countries = pd.DataFrame({"country_id": range(1, len(all_countries) + 1), "country_name": all_countries})
countries["is_country"] = (~countries["country_name"].isin(NON_COUNTRY_LABELS)).astype(int)
cid = dict(zip(countries.country_name, countries.country_id))

# customers
registered = pd.DataFrame({"customer_id": home.index.str.replace(r"\.0$", "", regex=True).astype(int),
                           "country_id": home.map(cid).values, "is_guest": 0})
guests = pd.DataFrame({"customer_id": list(guest_ids.values()),
                       "country_id": [cid[c] for c in guest_ids], "is_guest": 1})
customers = pd.concat([registered, guests]).sort_values("customer_id").reset_index(drop=True)
customers["email"] = None
customers["phone"] = None

# products. c6: canonical description = most frequent (tie: most recent)
desc = (df.groupby(["StockCode", "Description"]).agg(n=("qty", "size"), last=("InvoiceDate", "max")).reset_index()
        .sort_values(["StockCode", "n", "last"], ascending=[True, False, False]).drop_duplicates("StockCode"))
n_desc = df.groupby("StockCode")["Description"].nunique()
fixes.append({"fix": "c6", "rule": "one canonical description per stock code (most frequent, tie: most recent)",
              "products_changed": int((n_desc > 1).sum()),
              "rows_changed": int((df["Description"] != df["StockCode"].map(desc.set_index("StockCode")["Description"])).sum())})

# list price = the price the product was most often sold at (tie: most recent); fallback any positive price; else 0
sale_lines = df[(df.invoice_type == "Sale") & (df.price > 0)]
any_lines = df[df.price > 0]


def modal_price(frame):
    return (frame.groupby(["StockCode", "Price"]).agg(n=("qty", "size"), last=("InvoiceDate", "max")).reset_index()
            .sort_values(["StockCode", "n", "last"], ascending=[True, False, False])
            .drop_duplicates("StockCode").set_index("StockCode")["Price"])


lp = modal_price(sale_lines).combine_first(modal_price(any_lines))
products = desc[["StockCode", "Description"]].rename(columns={"StockCode": "stock_code", "Description": "description"})
products["unit_price"] = products["stock_code"].map(lp).fillna("0").map(lambda p: f"{money(p):.2f}")
products["is_stock_item"] = (~products["stock_code"].isin(NON_STOCK_CODES)
                             & ~products["stock_code"].str.startswith(NON_STOCK_PREFIXES)
                             & ~products["description"].str.contains("GIFT VOUCHER", case=False)).astype(int)

# inventory (stock items only). the csv has no stock counts, so opening stock is a planning estimate:
# quantity_on_hand = busiest month's net units, reorder_level = average monthly net units (rounded up)
stock_codes = set(products.loc[products.is_stock_item == 1, "stock_code"])
mv = df[df["StockCode"].isin(stock_codes)].assign(month=lambda x: x["InvoiceDate"].str[:7])
monthly = mv.groupby(["StockCode", "month"])["qty"].sum()
inv_stats = monthly.groupby(level=0).agg(peak="max", avg="mean")
inventory = pd.DataFrame({"stock_code": sorted(stock_codes)})
inventory["quantity_on_hand"] = inventory.stock_code.map(inv_stats["peak"]).fillna(0).clip(lower=0).astype(int)
inventory["reorder_level"] = inventory.stock_code.map(inv_stats["avg"]).fillna(0).clip(lower=0).map(math.ceil).astype(int)

# invoices
invoices = (df.drop_duplicates("Invoice")[["Invoice", "customer_id", "InvoiceDate", "invoice_type"]]
            .rename(columns={"Invoice": "invoice_no", "InvoiceDate": "invoice_date"}))
invoices["status"] = "Completed"
invoices["cancelled_at"] = None

# invoice lines: line_no = position of the line inside its invoice in the source file
lines = df[["Invoice", "StockCode", "qty", "Price"]].rename(
    columns={"Invoice": "invoice_no", "StockCode": "stock_code", "qty": "quantity", "Price": "unit_price"})
lines.insert(1, "line_no", df.groupby("Invoice").cumcount() + 1)
lines["unit_price"] = lines["unit_price"].map(lambda p: f"{money(p):.3f}")

# ---------------------------------------------------------------- write
def write(frame: pd.DataFrame, name: str):
    out = frame.copy()
    for c in out.columns:  # mysql load data treats backslash as an escape character
        if out[c].dtype == object:
            out[c] = out[c].map(lambda v: v.replace("\\", "\\\\") if isinstance(v, str) else v)
    out.to_csv(OUT / f"{name}.csv", index=False, na_rep="\\N", lineterminator="\n")
    return len(frame)


counts = {name: write(frame, name) for name, frame in [
    ("countries", countries), ("customers", customers), ("products", products),
    ("inventory", inventory), ("invoices", invoices), ("invoice_lines", lines)]}

rej = pd.concat(rejected)
rej.to_csv(OUT / "rejected_rows.csv.gz", index=False, compression="gzip")

kept_rev = revenue(df)
line_rev = sum((Decimal(int(q)) * Decimal(p) for q, p in zip(lines.quantity, lines.unit_price)), Decimal("0"))
summary.update({
    "kept_rows": int(len(df)),
    "rejected_rows": int(len(rej)),
    "kept_plus_rejected_equals_raw": int(len(df) + len(rej)) == int(len(raw)),
    "kept_invoices": int(df.Invoice.nunique()),
    "kept_revenue": str(kept_rev),
    "invoice_lines_revenue": str(line_rev),
    "revenue_reconciles": kept_rev == line_rev,
    "sale_invoices": int((invoices.invoice_type == "Sale").sum()),
    "return_invoices": int((invoices.invoice_type == "Return").sum()),
    "registered_customers": int((customers.is_guest == 0).sum()),
    "guest_accounts": int((customers.is_guest == 1).sum()),
    "stock_items": int(products.is_stock_item.sum()),
    "non_stock_items": int((products.is_stock_item == 0).sum()),
    "max_lines_per_invoice": int(lines.line_no.max()),
})
fixes.sort(key=lambda f: f["fix"])
report = {"summary": summary, "removal_rules": steps, "corrections": fixes, "table_rows": counts,
          "rejected_by_reason": rej["reason"].value_counts().to_dict(),
          "guest_accounts": {str(v): k for k, v in guest_ids.items()}}
(OUT / "cleaning_report.json").write_text(json.dumps(report, indent=2, default=str))
print(json.dumps({k: report[k] for k in ["summary", "table_rows", "rejected_by_reason"]}, indent=2))
for s in steps:
    print(f"rule {s['step']}: -{s['rows_removed']:,} -> {s['rows_remaining']:,}  ({s['rule']})")
for f in fixes:
    print(f"correction {f['fix']}: {f['rule']}  " + json.dumps({k: v for k, v in f.items() if k not in ('fix', 'rule', 'details')}))
