"""
step 2 of 2: check the clean csv and split it into the 3nf tables.

reads data/clean/online_retail_clean.csv.gz (made by scripts/clean_data.py) and
first checks that it is ready for the database: the columns, no blank cells, the
key (Invoice, LineNo), the functional dependencies, the quantity signs and the
prices. if anything is wrong it lists the problems and stops without writing.
then it writes one csv per table for sql/load_data.sql:

    data/clean/{countries,customers,products,inventory,invoices,invoice_lines}.csv

and the table counts to data/clean/tables_report.json.

usage:  python3 scripts/build_tables.py data/clean/online_retail_clean.csv.gz
"""
import json
import math
import sys
from decimal import Decimal
from pathlib import Path

import numpy as np
import pandas as pd

CLEAN = Path(sys.argv[1] if len(sys.argv) > 1 else "data/clean/online_retail_clean.csv.gz")
OUT = Path("data/clean")
OUT.mkdir(parents=True, exist_ok=True)

COLUMNS = ["Invoice", "LineNo", "StockCode", "Description", "Quantity", "InvoiceDate", "Price",
           "Customer ID", "Country", "IsGuest"]
# codes that are real customer charges but not physical stock (no inventory row)
NON_STOCK_CODES = {"POST", "DOT", "C2", "M", "D", "S", "BANK CHARGES", "PADS"}
NON_STOCK_PREFIXES = ("GIFT_0001_",)  # gift vouchers (22016 is also a voucher, caught by its description)
# country labels kept as they are (the real country is unknown) but flagged as not being one country
NON_COUNTRY_LABELS = {"Unspecified", "European Community", "Channel Islands", "West Indies"}

df = pd.read_csv(CLEAN, dtype=str, keep_default_na=False)

# ---------------------------------------------------------------- checks
problems = []


def check(ok, message: str) -> None:
    if not bool(ok):
        problems.append(message)


def many(n: int, word: str) -> str:
    return f"{n:,} {word}" + ("" if n == 1 else "s")


def stop_if_problems() -> None:
    if problems:
        print(f"{CLEAN} is not ready for the database:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        sys.exit(1)


check(list(df.columns) == COLUMNS, f"columns must be {COLUMNS}, found {list(df.columns)}")
stop_if_problems()

blank = (df == "").sum()
check(blank.sum() == 0, "blank cells in " + ", ".join(f"{c} ({n:,})" for c, n in blank.items() if n))
for col in ["Invoice", "StockCode", "Description", "Country"]:
    check((df[col] == df[col].str.strip()).all(), f"{col} has leading or trailing spaces")
check(~df["Description"].str.contains("  ").any(), "Description has repeated spaces")
check((df["StockCode"] == df["StockCode"].str.upper()).all(), "StockCode must be upper case")
check(df["Invoice"].str.fullmatch(r"C?\d+").all(), "Invoice must be digits, with a C prefix on credit notes")
check(df["LineNo"].str.fullmatch(r"[1-9]\d*").all(), "LineNo must be a whole number from 1")
check(df["Quantity"].str.fullmatch(r"-?[1-9]\d*").all(), "Quantity must be a whole number other than 0")
check(df["Price"].str.fullmatch(r"\d+\.\d{2,3}").all(), "Price must be 0 or more, with 2 or 3 decimals")
check(df["InvoiceDate"].str.fullmatch(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d").all()
      and pd.to_datetime(df["InvoiceDate"], format="%Y-%m-%d %H:%M:%S", errors="coerce").notna().all(),
      "InvoiceDate must be a valid date written as yyyy-mm-dd hh:mm:ss")
check(df["Customer ID"].str.fullmatch(r"[1-9]\d*").all(), "Customer ID must be a whole number")
check(df["IsGuest"].isin(["0", "1"]).all(), "IsGuest must be 0 or 1")

# key, document rules and functional dependencies (numbers read leniently here, so
# every problem in the file is listed in one run, not only the first one)
dup = df.duplicated(["Invoice", "LineNo"], keep=False)
check(not dup.any(), f"(Invoice, LineNo) must be unique, but {many(int(dup.sum()), 'row')} share a key"
                     + (f" (e.g. invoice {df.loc[dup, 'Invoice'].iloc[0]})" if dup.any() else ""))
line_num = pd.to_numeric(df["LineNo"], errors="coerce")
if line_num.notna().all():
    per_invoice = line_num.groupby(df["Invoice"])
    check(((per_invoice.transform("min") == 1) & (per_invoice.transform("max") == per_invoice.transform("size"))).all(),
          "LineNo must run 1, 2, 3 ... inside each invoice")
qty_num = pd.to_numeric(df["Quantity"], errors="coerce")
credit = df["Invoice"].str.startswith("C")
wrong_sign = (credit & (qty_num > 0)) | (~credit & (qty_num < 0))
check(not wrong_sign.any(), f"Quantity must be negative on C credit notes and positive on other invoices, "
                            f"but {many(int(wrong_sign.sum()), 'row')} {'is' if int(wrong_sign.sum()) == 1 else 'are'} not"
                            + (f" (e.g. invoice {df.loc[wrong_sign, 'Invoice'].iloc[0]})" if wrong_sign.any() else ""))
for lhs, rhs in [("Invoice", "InvoiceDate"), ("Invoice", "Customer ID"), ("Invoice", "Country"),
                 ("Customer ID", "Country"), ("Customer ID", "IsGuest"), ("StockCode", "Description")]:
    n = df.groupby(lhs)[rhs].nunique()
    bad = n[n > 1]
    check(bad.empty, f"{lhs} -> {rhs} must hold, but {many(len(bad), 'value')} of {lhs} "
                     f"{'has' if len(bad) == 1 else 'have'} more than one {rhs}"
                     + (f" (e.g. {bad.index[0]})" if len(bad) else ""))
stop_if_problems()

line_no = df["LineNo"].astype(int)
qty = df["Quantity"].astype(int)


def money(x) -> Decimal:
    return Decimal(str(x))


# ---------------------------------------------------------------- build tables
df["invoice_type"] = np.where(credit, "Return", "Sale")
df["qty"] = qty
df["price"] = df["Price"].astype(float)

# countries: every country label in the data
all_countries = sorted(set(df["Country"]))
countries = pd.DataFrame({"country_id": range(1, len(all_countries) + 1), "country_name": all_countries})
countries["is_country"] = (~countries["country_name"].isin(NON_COUNTRY_LABELS)).astype(int)
cid = dict(zip(countries.country_name, countries.country_id))

# customers: registered customers and the guest accounts, each with its one country
people = df.drop_duplicates("Customer ID")[["Customer ID", "Country", "IsGuest"]]
customers = pd.DataFrame({"customer_id": people["Customer ID"].astype(int).values,
                          "country_id": people["Country"].map(cid).values,
                          "is_guest": people["IsGuest"].astype(int).values})
customers = customers.sort_values("customer_id").reset_index(drop=True)
customers["email"] = None
customers["phone"] = None

# products: the clean csv already has one description per stock code
products = (df.drop_duplicates("StockCode")[["StockCode", "Description"]]
            .rename(columns={"StockCode": "stock_code", "Description": "description"})
            .sort_values("stock_code").reset_index(drop=True))

# list price = the price the product was most often sold at (tie: most recent); fallback any positive price; else 0
sale_lines = df[(df.invoice_type == "Sale") & (df.price > 0)]
any_lines = df[df.price > 0]


def modal_price(frame):
    return (frame.groupby(["StockCode", "Price"]).agg(n=("qty", "size"), last=("InvoiceDate", "max")).reset_index()
            .sort_values(["StockCode", "n", "last"], ascending=[True, False, False])
            .drop_duplicates("StockCode").set_index("StockCode")["Price"])


lp = modal_price(sale_lines).combine_first(modal_price(any_lines))
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

# invoices, in the order they first appear in the file
invoices = (df.drop_duplicates("Invoice")[["Invoice", "Customer ID", "InvoiceDate", "invoice_type"]]
            .rename(columns={"Invoice": "invoice_no", "Customer ID": "customer_id", "InvoiceDate": "invoice_date"}))
invoices["status"] = "Completed"
invoices["cancelled_at"] = None

# invoice lines, keyed by (invoice_no, line_no)
lines = pd.DataFrame({"invoice_no": df["Invoice"], "line_no": line_no, "stock_code": df["StockCode"],
                      "quantity": df["qty"], "unit_price": df["Price"].map(lambda p: f"{money(p):.3f}")})


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

csv_rev = sum((Decimal(q) * Decimal(p) for q, p in zip(df["Quantity"], df["Price"])), Decimal("0"))
line_rev = sum((Decimal(int(q)) * Decimal(p) for q, p in zip(lines.quantity, lines.unit_price)), Decimal("0"))
summary = {
    "clean_csv": str(CLEAN),
    "clean_csv_rows": int(len(df)),
    "checks": "all passed",
    "sale_invoices": int((invoices.invoice_type == "Sale").sum()),
    "return_invoices": int((invoices.invoice_type == "Return").sum()),
    "registered_customers": int((customers.is_guest == 0).sum()),
    "guest_accounts": int((customers.is_guest == 1).sum()),
    "stock_items": int(products.is_stock_item.sum()),
    "non_stock_items": int((products.is_stock_item == 0).sum()),
    "max_lines_per_invoice": int(lines.line_no.max()),
    "clean_csv_revenue": str(csv_rev),
    "invoice_lines_revenue": str(line_rev),
    "revenue_reconciles": csv_rev == line_rev,
}
report = {"summary": summary, "table_rows": counts}
(OUT / "tables_report.json").write_text(json.dumps(report, indent=2, default=str))
print(json.dumps(report, indent=2, default=str))
