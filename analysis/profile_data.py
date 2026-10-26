"""profile online_retail_data.csv: every count used in chapter 3 of the documentation.

usage:  python profile_data.py path/to/online_retail_data.csv
needs:  pandas
row numbers are the csv's line numbers (header = row 1), the same numbers a
spreadsheet shows.
"""
import re
import sys

import pandas as pd

SERVICE = ['POST', 'DOT', 'C2', 'C3', 'M', 'D', 'S', 'B', 'BANK CHARGES', 'AMAZONFEE', 'CRUK', 'ADJUST', 'ADJUST2']


def load(path):
    df = pd.read_csv(path, dtype=str, keep_default_na=False, na_filter=False)
    df.index = df.index + 2
    df.index.name = 'row'
    df['code'] = df.StockCode.str.strip().str.upper()
    df['desc'] = df.Description.str.strip().str.replace(r'\s+', ' ', regex=True)
    df['q'] = pd.to_numeric(df.Quantity)
    df['p'] = pd.to_numeric(df.Price)
    df['ts'] = pd.to_datetime(df.InvoiceDate)
    return df


def section(title):
    print(f'\n== {title}')


def main(path):
    raw = load(path)
    cust = raw['Customer ID'] != ''
    inv = raw.Invoice
    cpre = inv.str.fullmatch(r'C\d{6}')
    apre = inv.str.fullmatch(r'A\d{6}')

    section('file')
    print(f'rows {len(raw):,} | documents {inv.nunique():,} | columns {list(raw.columns[:8])}')
    print(f'dates {raw.ts.min()} to {raw.ts.max()}')
    print(f'rows past spreadsheet row 1,048,576: {(raw.index > 1048576).sum():,}')
    print(f'united kingdom share: {raw.Country.eq("United Kingdom").mean():.1%} | pound sign rows: {raw.Description.str.contains("£").sum()}')

    section('1 repeated export block')
    jump = raw.index[raw.ts < raw.ts.shift()]
    start = int(jump.min())
    s1, s2 = raw.loc[:start - 1], raw.loc[start:]
    a = s1[s1.ts >= s2.ts.min().normalize()]
    b = s2[s2.Invoice.isin(set(s1.Invoice))]
    cols = ['Invoice', 'StockCode', 'Description', 'Quantity', 'InvoiceDate', 'Price', 'Customer ID', 'Country']
    same = a[cols].apply(tuple, axis=1).value_counts().sort_index().equals(b[cols].apply(tuple, axis=1).value_counts().sort_index())
    print(f'second export starts at row {start:,}; rows {b.index.min():,}-{b.index.max():,} repeat rows {a.index.min():,}-{a.index.max():,}')
    print(f'{len(b):,} rows, {b.Invoice.nunique():,} invoices, same rows: {same}')
    base = raw.drop(index=b.index)

    section('2 identical lines inside one invoice (without the block)')
    dup = base.duplicated(cols)
    print(f'{dup.sum():,} extra copies in {base[dup].Invoice.nunique():,} invoices')
    top = base[base.duplicated(cols, keep=False)].groupby(cols).size().sort_values().tail(1)
    print('largest:', top.index[0][:3], 'x', int(top.iloc[0]))

    section('3-4 names')
    named = base[base.desc != '']
    g = named.groupby('code').desc.nunique()
    upper = named[(named.desc == named.desc.str.upper()) & named.desc.str.contains('[A-Za-z]{3}')]
    gu = upper.groupby('code').desc.nunique()
    print(f'codes with 2+ descriptions: {(g > 1).sum():,} (max {g.max()}); with 2+ product-style names: {(gu > 1).sum():,}')
    print('20685:', named[named.code == '20685'].desc.value_counts().to_dict())
    n2c = upper.groupby('desc').code.nunique()
    print(f'product-style names used by 2+ codes: {(n2c > 1).sum()}; BATHROOM METAL SIGN ->',
          sorted(upper[upper.desc == 'BATHROOM METAL SIGN'].code.unique()))

    section('5-7 text')
    d = raw.Description
    lead, trail, dbl = d.str.match(r'^\s'), d.str.contains(r'\s$'), d.str.contains(r'\S\s{2,}\S')
    print(f'leading space {lead.sum():,} | trailing {trail.sum():,} | double inside {dbl.sum():,} | any {(lead | trail | dbl).sum():,}')
    print(f'missing description {(d == "").sum():,} | backslash {d.str.contains(chr(92), regex=False).sum()}')
    numd = raw[inv.str.fullmatch(r'\d{6}')]
    agg = numd.groupby('Invoice').agg(z=('p', lambda s: (s == 0).all()), nc=('Customer ID', lambda s: (s == '').all()), n=('p', 'size'))
    wh = agg[agg.z & agg.nc]
    print(f'warehouse-note documents (numeric, every line price 0, no customer): {len(wh):,} documents, {wh.n.sum():,} lines')

    section('8-11 stock codes')
    sc = raw.StockCode
    print(f'lower-case code rows {(sc.str.contains("[a-z]") & ~sc.str.startswith("gift_")).sum():,} | padded {(sc != sc.str.strip()).sum()}')
    sp = raw.groupby('code').StockCode.nunique()
    print(f'raw spellings {sc.nunique():,} -> codes {raw.code.nunique():,}; codes in 2 spellings {(sp > 1).sum()}')
    print(f'service rows {raw.code.isin(SERVICE).sum():,} | voucher rows {raw.code.str.startswith("GIFT").sum():,} | test rows {raw.code.str.startswith("TEST").sum()}')

    section('12-17 documents, quantities and prices')
    print(f'C rows {cpre.sum():,} ({inv[cpre].nunique():,} documents) | A rows {apre.sum()} | C with quantity > 0: {list(raw.index[cpre & (raw.q > 0)])}')
    neg = (raw.q < 0) & ~cpre
    print(f'negative quantity without C: {neg.sum():,} (all price 0: {(raw.p[neg] == 0).all()}, none with a customer: {(~cust[neg]).all()})')
    print(f'negative price rows {(raw.p < 0).sum()} | price 0 rows {(raw.p == 0).sum():,} ({((raw.p == 0) & cust).sum()} with a customer)')
    print(f'prices with 3+ decimals: {raw.Price.str.contains(r"[.][0-9]{3,}$").sum()}')

    section('18-21 customers and countries')
    print(f'missing customer {(~cust).sum():,} ({(~cust).mean():.1%}); priced normal sales among them {((~cust) & inv.str.fullmatch(r"[0-9]{6}") & (raw.q > 0) & (raw.p > 0)).sum():,}')
    print(f'customer ids written as decimals: {raw["Customer ID"].str.endswith(".0").sum():,} of {cust.sum():,}')
    c2 = base[base['Customer ID'] != ''].groupby('Customer ID').Country.nunique()
    print(f'customers under two countries: {(c2 > 1).sum()}')
    print('labels:', {c: int(raw.Country.eq(c).sum()) for c in ['EIRE', 'USA', 'RSA', 'Korea', 'Channel Islands', 'Unspecified', 'European Community', 'West Indies']})

    section('22-28 dependencies and outliers (without the block)')
    t = base.groupby('Invoice').InvoiceDate.nunique()
    print(f'invoices with two timestamps: {(t > 1).sum()}')
    sales = base[inv.loc[base.index].str.fullmatch(r'\d{6}') & (base.q > 0) & (base.p > 0)]
    pc = sales.groupby('code').p.nunique()
    print(f'priced codes {len(pc):,}; with 2+ prices {(pc > 1).sum():,}')
    s = sales.assign(day=sales.ts.dt.date, guest=sales['Customer ID'] == '')
    m = s.groupby(['code', 'day', 'guest']).p.median().unstack().dropna()
    print(f'guest / registered price on the same product and day: median ratio {(m[True] / m[False]).median():.2f}')
    pairs = base.groupby(['Invoice', 'code']).size()
    print(f'(invoice, code) pairs on 2+ lines: {(pairs > 1).sum():,}')
    print('largest quantities:', raw.loc[raw.q.abs() >= 70000, ['Invoice', 'code', 'Quantity', 'InvoiceDate']].values.tolist())
    cr = base[base.Invoice.str.startswith('C') & (base['Customer ID'] != '')]
    first = sales.groupby(['Customer ID', 'code']).ts.min().rename('fs')
    crk = cr.join(first, on=['Customer ID', 'code'])
    print(f'credit-note lines with no earlier sale of that code to that customer: {(crk.fs.isna() | (crk.fs > crk.ts)).sum():,}')
    nums = pd.to_numeric(raw.Invoice.str.lstrip('CA')).unique()
    print(f'invoice numbers {nums.min()}-{nums.max()}: {(nums.max() - nums.min() + 1) - len(nums):,} unused')

    section('functional dependencies (without the block, codes trimmed and upper-cased)')
    tests = [('Invoice', 'InvoiceDate', base), ('Invoice', 'Customer ID', base), ('Invoice', 'Country', base),
             ('Customer ID', 'Country', base[base['Customer ID'] != '']), ('code', 'desc', named),
             ('desc', 'code', named), ('code', 'p', sales), (['Invoice', 'code'], 'q', base)]
    for lhs, rhs, data in tests:
        v = data.groupby(lhs)[rhs].nunique()
        print(f'{lhs} -> {rhs}: {(v > 1).sum():,} violating determinants')


if __name__ == '__main__':
    main(sys.argv[1])
