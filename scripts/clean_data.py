"""
step 1 of 2: clean the raw kodes csv.

removes the rows that are not customer transactions (rules r1-r4) and fixes the
values that break the business rules (corrections c1-c7). the result is one clean
flat file with the raw csv's 8 columns, in the same order, plus two new ones:

    data/clean/online_retail_clean.csv.gz
    Invoice, LineNo, StockCode, Description, Quantity, InvoiceDate, Price,
    Customer ID, Country, IsGuest

- LineNo: position of the line on its invoice, so (Invoice, LineNo) identifies a row
- IsGuest: 1 when the line had no customer id and now carries its country's guest account

every removed row is written to data/clean/rejected_rows.csv.gz with the rule that
removed it, and every step is counted in data/clean/cleaning_report.json, so the
full dataset is accounted for (kept + rejected = raw).

step 2, scripts/build_tables.py, checks the clean file and splits it into the 3nf
tables for the database.

usage:  python3 scripts/clean_data.py data/raw/online_retail_data.csv.gz
"""
import gzip
import json
import sys
from decimal import Decimal
from pathlib import Path

import numpy as np
import pandas as pd

RAW = Path(sys.argv[1] if len(sys.argv) > 1 else "data/raw/online_retail_data.csv.gz")
OUT = Path("data/clean")
OUT.mkdir(parents=True, exist_ok=True)
CLEAN_CSV = OUT / "online_retail_clean.csv.gz"

SRC_COLS = ["Invoice", "StockCode", "Description", "Quantity", "InvoiceDate", "Price", "Customer ID", "Country"]
CLEAN_COLS = ["Invoice", "LineNo", "StockCode", "Description", "Quantity", "InvoiceDate", "Price",
              "Customer ID", "Country", "IsGuest"]

# codes that are bookkeeping or test entries, not customer transactions
INTERNAL_CODES = {"B", "TEST001", "TEST002", "AMAZONFEE", "CRUK", "ADJUST", "ADJUST2"}
COUNTRY_RENAMES = {"EIRE": "Ireland", "RSA": "South Africa", "USA": "United States"}
# guest accounts get ids 1..n: real customer ids start at 12346 and new customers continue
# from the auto_increment counter (18288), so the three ranges never collide
GUEST_ID_START = 1

raw = pd.read_csv(RAW, dtype=str, keep_default_na=False)
raw.insert(0, "source_line", np.arange(2, len(raw) + 2))  # line number in the csv (header is line 1)

steps, fixes, rejected = [], [], []  # removal rules r1-r4, corrections c1-c7


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


def price_text(p: str) -> str:
    """two decimals, or three when the price needs them (0.001)"""
    d = Decimal(p)
    return f"{d:.2f}" if d == d.quantize(Decimal("0.01")) else f"{d:.3f}"


def write_csv_gz(frame: pd.DataFrame, path: Path) -> None:
    """csv inside gzip with a fixed timestamp, so the same data always gives the same file"""
    text = frame.to_csv(index=False, lineterminator="\n")
    with open(path, "wb") as f, gzip.GzipFile(filename="", mode="wb", fileobj=f, mtime=0, compresslevel=9) as gz:
        gz.write(text.encode("utf-8"))


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
registered = df["Customer ID"] != ""
home_country = df.loc[registered, "Customer ID"].map(home)
fixes.append({"fix": "c5", "rule": "customer country = country with the most invoices (tie: most recent)",
              "customers_changed": int(len(multi)),
              "rows_changed": int((df.loc[registered, "Country"] != home_country).sum()),
              "details": cc[cc["Customer ID"].isin(multi)].assign(chosen=lambda x: x["Customer ID"].map(home)).to_dict(orient="records")})
df.loc[registered, "Country"] = home_country

# c6. StockCode -> Description: one canonical description per stock code (most frequent, tie: most recent)
desc = (df.groupby(["StockCode", "Description"]).agg(n=("Invoice", "size"), last=("InvoiceDate", "max")).reset_index()
        .sort_values(["StockCode", "n", "last"], ascending=[True, False, False]).drop_duplicates("StockCode")
        .set_index("StockCode")["Description"])
n_desc = df.groupby("StockCode")["Description"].nunique()
fixes.append({"fix": "c6", "rule": "one canonical description per stock code (most frequent, tie: most recent)",
              "products_changed": int((n_desc > 1).sum()),
              "rows_changed": int((df["Description"] != df["StockCode"].map(desc)).sum())})
df["Description"] = df["StockCode"].map(desc)

# c7. guest checkouts: rows without a customer id go to one guest account per country
guest_countries = sorted(df.loc[df["Customer ID"] == "", "Country"].unique())
guest_ids = {c: GUEST_ID_START + i for i, c in enumerate(guest_countries)}
is_guest = df["Customer ID"] == ""
fixes.append({"fix": "c7", "rule": f"rows without Customer ID assigned to a guest account per country (ids {GUEST_ID_START}..{GUEST_ID_START + len(guest_ids) - 1})",
              "rows_changed": int(is_guest.sum()),
              "guest_accounts": len(guest_ids)})
df["Customer ID"] = np.where(is_guest,
                             df["Country"].map(guest_ids).astype("Int64").astype(str),
                             df["Customer ID"].str.replace(r"\.0$", "", regex=True))  # 13085.0 -> 13085
df["IsGuest"] = is_guest.astype(int)

# line number inside each invoice, in the order of the source file
df["LineNo"] = df.groupby("Invoice").cumcount() + 1
df["Price"] = df["Price"].map(price_text)

# lines that differ only by LineNo once the fixes are applied (a minute apart, or a
# spelling variant of the description): separate lines in the raw file, kept as such
same = df.duplicated(subset=SRC_COLS, keep=False)

# ---------------------------------------------------------------- write
write_csv_gz(df[CLEAN_COLS], CLEAN_CSV)
rej = pd.concat(rejected)
write_csv_gz(rej, OUT / "rejected_rows.csv.gz")

summary.update({
    "kept_rows": int(len(df)),
    "rejected_rows": int(len(rej)),
    "kept_plus_rejected_equals_raw": int(len(df) + len(rej)) == int(len(raw)),
    "kept_invoices": int(df.Invoice.nunique()),
    "kept_revenue": str(revenue(df)),
    "clean_csv": str(CLEAN_CSV),
    "clean_columns": CLEAN_COLS,
    "registered_customers": int(df.loc[df.IsGuest == 0, "Customer ID"].nunique()),
    "guest_accounts": len(guest_ids),
    "stock_codes": int(df.StockCode.nunique()),
    "countries": int(df.Country.nunique()),
    "zero_price_lines_kept": int((df.Price.astype(float) == 0).sum()),
    "lines_identical_except_line_no": int(same.sum()),
})
fixes.sort(key=lambda f: f["fix"])
report = {"summary": summary, "removal_rules": steps, "corrections": fixes,
          "rejected_by_reason": rej["reason"].value_counts().to_dict(),
          "guest_accounts": {str(v): k for k, v in guest_ids.items()},
          "lines_identical_except_line_no": df.loc[same, CLEAN_COLS].to_dict(orient="records")}
(OUT / "cleaning_report.json").write_text(json.dumps(report, indent=2, default=str))
print(json.dumps({k: report[k] for k in ["summary", "rejected_by_reason"]}, indent=2))
for s in steps:
    print(f"rule {s['step']}: -{s['rows_removed']:,} -> {s['rows_remaining']:,}  ({s['rule']})")
for f in fixes:
    print(f"correction {f['fix']}: {f['rule']}  " + json.dumps({k: v for k, v in f.items() if k not in ('fix', 'rule', 'details')}))
print(f"clean csv: {CLEAN_CSV} ({len(df):,} rows, columns: {', '.join(CLEAN_COLS)})")
