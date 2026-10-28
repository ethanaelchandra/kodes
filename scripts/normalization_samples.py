"""
build the sample tables used in the documentation to show each normal form
(unf -> 1nf -> 2nf -> 3nf) on three real invoices from the raw csv:

  554159 and 564481  same customer (12464, belgium) buying the same bread bins
                     at two different prices -> price belongs to the sale line
  492581             the same product (85123A) twice on one invoice at two
                     prices -> (invoice, stockcode) is not a key, line_no is needed

usage:  python3 scripts/normalization_samples.py data/raw/online_retail_data.csv.gz
output: docs/normalization_samples.md (markdown tables)
"""
import sys
from pathlib import Path

import pandas as pd

RAW = Path(sys.argv[1] if len(sys.argv) > 1 else "data/raw/online_retail_data.csv.gz")
INVOICES = ["554159", "564481", "492581"]

df = pd.read_csv(RAW, dtype=str, keep_default_na=False)
s = df[df.Invoice.isin(INVOICES)].copy()
s["Invoice"] = pd.Categorical(s["Invoice"], INVOICES, ordered=True)
s = s.sort_values("Invoice", kind="stable")
s["Invoice"] = s["Invoice"].astype(str)
s["Description"] = s["Description"].str.strip()
s["Customer ID"] = s["Customer ID"].str.replace(r"\.0$", "", regex=True)
s["LineNo"] = s.groupby("Invoice").cumcount() + 1


def md(frame: pd.DataFrame) -> str:
    cols = list(frame.columns)
    out = ["| " + " | ".join(cols) + " |", "|" + "|".join(["---"] * len(cols)) + "|"]
    for _, r in frame.iterrows():
        out.append("| " + " | ".join(str(r[c]).replace("|", "\\|") for c in cols) + " |")
    return "\n".join(out)


parts = []

# unf: one record per invoice, the product columns form a repeating group
unf = s[["Invoice", "InvoiceDate", "Customer ID", "Country", "StockCode", "Description", "Quantity", "Price"]].copy()
first = ~unf["Invoice"].duplicated()
for c in ["Invoice", "InvoiceDate", "Customer ID", "Country"]:
    unf.loc[~first, c] = ""
parts.append(("unf", md(unf)))

# 1nf: flat, atomic, key (Invoice, LineNo)
one = s[["Invoice", "LineNo", "StockCode", "Description", "Quantity", "InvoiceDate", "Price", "Customer ID", "Country"]]
parts.append(("1nf", md(one)))

# 2nf: header split from lines
inv = s.drop_duplicates("Invoice")[["Invoice", "InvoiceDate", "Customer ID", "Country"]]
lines2 = s[["Invoice", "LineNo", "StockCode", "Description", "Quantity", "Price"]]
parts.append(("2nf invoice", md(inv)))
parts.append(("2nf invoice_line", md(lines2)))

# 3nf: product and customer split out
prod = s.drop_duplicates("StockCode")[["StockCode", "Description"]]
cust = s.drop_duplicates("Customer ID")[["Customer ID", "Country"]]
inv3 = s.drop_duplicates("Invoice")[["Invoice", "InvoiceDate", "Customer ID"]]
lines3 = s[["Invoice", "LineNo", "StockCode", "Quantity", "Price"]]
parts.append(("3nf customer", md(cust)))
parts.append(("3nf product", md(prod)))
parts.append(("3nf invoice", md(inv3)))
parts.append(("3nf invoice_line", md(lines3)))

out = Path("docs/normalization_samples.md")
out.write_text("\n\n".join(f"{name}\n\n{table}" for name, table in parts) + "\n")
print(out.read_text())
