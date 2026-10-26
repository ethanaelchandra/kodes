"""independent rebuild of the cleaned tables in pandas, compared with a fresh build of the database.

usage:  python verify_import.py online_retail_data.csv export_dir   (export_dir from export_tables.sh)
"""
import sys, re, math
from decimal import Decimal, ROUND_HALF_UP
import pandas as pd, numpy as np

csv_path, export_dir = sys.argv[1], sys.argv[2]
df = pd.read_csv(csv_path, dtype=str, keep_default_na=False, na_filter=False)
df['src_row'] = np.arange(1, len(df) + 1)
df['ts'] = pd.to_datetime(df.InvoiceDate)
start = int(df.loc[df.ts < df.ts.shift(), 'src_row'].min())
df['part'] = np.where(df.src_row >= start, 2, 1)
df['first_part'] = df.groupby('Invoice').part.transform('min')
df['code'] = df.StockCode.str.strip().str.upper()
keep = df[(df.part == df.first_part) & ~df.code.isin(['TEST001', 'TEST002'])].copy()
removed_block = int(((df.part != df.first_part)).sum())
removed_test = int(df.code.isin(['TEST001', 'TEST002']).sum())
print('second export starts at src_row', start, '| block rows removed', removed_block, '| test rows', removed_test, '| kept', len(keep))

cmap = {'EIRE': 'Ireland', 'RSA': 'South Africa', 'USA': 'United States', 'Korea': 'South Korea'}
keep['country'] = keep.Country.str.strip().map(lambda c: cmap.get(c, c))
keep['desc'] = keep.Description.map(lambda s: re.sub(r'\s+', ' ', s).strip(' ') or None)
keep['qty'] = keep.Quantity.astype(int)
keep['p1000'] = keep.Price.map(lambda s: int((Decimal(s) * 1000).to_integral_value(ROUND_HALF_UP)))
keep['cust'] = keep['Customer ID'].map(lambda s: int(float(s)) if s else None)

g = keep.groupby('Invoice')
doc = pd.DataFrame({'date': g.ts.min(), 'cust': g.cust.max(), 'country': g.country.max(),
                    'anyprice': g.p1000.apply(lambda s: (s != 0).any()), 'hascust': g.cust.apply(lambda s: s.notna().any())})
def dtype(inv, r):
    if inv.startswith('C'): return 'CREDIT_NOTE'
    if inv.startswith('A'): return 'ADJUSTMENT'
    if not r.anyprice and not r.hascust: return 'STOCK_ADJ'
    return 'SALE'
doc['type'] = [dtype(i, r) for i, r in doc.iterrows()]
print('documents by type:', doc.type.value_counts().to_dict())
keep = keep.join(doc.type, on='Invoice')

ex = {t: pd.read_csv(f'{export_dir}/{t}.tsv', sep='\t', dtype=str, keep_default_na=False, na_values=['NULL']) for t in
      ['country', 'customer', 'product', 'inventory', 'invoice', 'invoice_line', 'stock_adjustment']}
ok = True
def check(name, cond, detail=''):
    global ok
    ok &= bool(cond)
    print(('PASS ' if cond else 'FAIL ') + name + (f'  {detail}' if detail else ''))

# invoices
inv = doc[doc.type != 'STOCK_ADJ']
e = ex['invoice'].set_index('invoice_no')
check('invoice count', len(inv) == len(e), f'{len(inv)} vs {len(e)}')
check('invoice types', (inv.type == e.loc[inv.index, 'invoice_type']).all())
check('invoice dates (earliest kept)', (inv.date.dt.strftime('%Y-%m-%d %H:%M:%S') == e.loc[inv.index, 'invoice_date']).all())
ec = pd.to_numeric(e.loc[inv.index, 'customer_id'], errors='coerce')
check('invoice customers', ((inv.cust.isna() & ec.isna()) | (inv.cust == ec)).all())
cty = ex['country'].set_index('country_id').country_name
check('invoice countries', (inv.country.values == cty.loc[e.loc[inv.index, 'country_id']].values).all())

# lines
lines = keep[keep.type != 'STOCK_ADJ'].sort_values('src_row').copy()
lines['line_no'] = lines.groupby('Invoice').cumcount() + 1
neg = lines.p1000 < 0
cpos = (lines.type == 'CREDIT_NOTE') & (lines.qty > 0)
lines['q2'] = np.where(neg | cpos, -lines.qty, lines.qty)
lines['up1000'] = lines.p1000.abs()
el = ex['invoice_line']
el['up1000'] = el.unit_price.map(lambda s: int((Decimal(s) * 1000).to_integral_value()))
m = lines.merge(el, left_on=['Invoice', 'line_no'], right_on=['invoice_no', el.line_no.astype(int)], how='outer', indicator=True, suffixes=('', '_db'))
check('invoice line count', len(lines) == len(el), f'{len(lines)} vs {len(el)}')
check('every line matched by (invoice, line_no)', (m._merge == 'both').all(), str(m._merge.value_counts().to_dict()))
mm = m[m._merge == 'both']
check('line stock codes', (mm.code == mm.stock_code).all())
check('line quantities (sign rules applied)', (mm.q2 == mm.quantity.astype(int)).all(), f'{int(neg.sum())} price-sign moves, {int(cpos.sum())} credit-note flip')
check('line prices', (mm.up1000 == mm.up1000_db).all())
src_val = (lines.qty * lines.p1000).sum() / 1000; db_val = (mm.quantity.astype(int) * mm.up1000_db).sum() / 1000
print(f'      source net value {src_val:,.2f} | database net value {db_val:,.2f} | difference {db_val - src_val:,.2f}')

# stock adjustments
adj = keep[keep.type == 'STOCK_ADJ'].sort_values('src_row')
ea = ex['stock_adjustment']
check('stock adjustment count', len(adj) == len(ea), f'{len(adj)} vs {len(ea)}')
check('adjustment codes and quantities in order', (adj.code.values == ea.stock_code.values).all() and (adj.qty.values == ea.quantity_change.astype(int).values).all())

# customers
cu = inv[inv.cust.notna()].reset_index().sort_values(['cust', 'date', 'Invoice'], ascending=[True, False, False]).drop_duplicates('cust')
eu = ex['customer'].set_index('customer_id')
check('customer count', len(cu) == len(eu), f'{len(cu)} vs {len(eu)}')
eu.index = eu.index.astype(int)
check('registered country = latest invoice country', (cu.country.values == cty.loc[eu.loc[cu.cust.astype(int), 'country_id']].values).all())

# products: names
named = keep[keep.desc.notna()]
gg = named.groupby(['code', 'desc']).agg(priced=('p1000', lambda s: int((s > 0).any())), cnt=('desc', 'size'), last=('ts', 'max')).reset_index()
gg['upper'] = gg.desc.map(lambda d: d == d.upper() and re.search('[A-Za-z]{3}', d) is not None)
gg = gg[(gg.priced == 1) | gg.upper].sort_values(['code', 'priced', 'cnt', 'last', 'desc'], ascending=[True, False, False, False, True])
names = gg.drop_duplicates('code').set_index('code').desc
# products: list price
sl = keep[(keep.type == 'SALE') & (keep.p1000 > 0) & (keep.qty > 0)]
last = sl.groupby('code').ts.max()
rec = sl[sl.ts >= sl.code.map(last) - pd.Timedelta(days=90)]
pr = rec.groupby(['code', 'p1000']).agg(reg=('cust', lambda s: int(s.notna().sum())), cnt=('cust', 'size'), mx=('ts', 'max')).reset_index()
pr = pr.sort_values(['code', 'reg', 'cnt', 'mx', 'p1000'], ascending=[True, False, False, False, False]).drop_duplicates('code').set_index('code').p1000
svc = {'POST', 'DOT', 'C2', 'C3', 'M', 'D', 'S', 'B', 'BANK CHARGES', 'AMAZONFEE', 'CRUK', 'ADJUST', 'ADJUST2'}
codes = sorted(keep.code.unique())
ep = ex['product'].set_index('stock_code')
check('product count', len(codes) == len(ep), f'{len(codes)} vs {len(ep)}')
def r2(p1000):
    return str((Decimal(int(p1000)) / 1000).quantize(Decimal('0.01'), ROUND_HALF_UP))
bad_name = bad_price = bad_type = 0
for c in codes:
    t = 'SERVICE' if c in svc else ('VOUCHER' if c.startswith('GIFT') else 'GOODS')
    nm = names.get(c, f'UNNAMED ITEM {c}')[:100]
    price = '0.00' if t == 'SERVICE' else r2(pr.get(c, 0))
    row = ep.loc[c]
    bad_type += row.product_type != t; bad_name += row.description != nm; bad_price += row.unit_price != price
check('product types', bad_type == 0, f'{bad_type} differ')
check('product names', bad_name == 0, f'{bad_name} differ')
check('product list prices', bad_price == 0, f'{bad_price} differ')

# inventory
mx = keep.ts.max()
st = keep[keep.type.isin(['SALE', 'CREDIT_NOTE']) & (keep.ts >= mx - pd.Timedelta(days=90))].groupby('code').qty.sum().clip(lower=0)
goods = [c for c in codes if c not in svc and not c.startswith('GIFT')]
ei = ex['inventory'].set_index('stock_code')
check('inventory rows = goods', len(goods) == len(ei), f'{len(goods)} vs {len(ei)}')
qty_ok = all(int(ei.loc[c, 'qty_on_hand']) == int(st.get(c, 0)) for c in goods)
reo_ok = all(int(ei.loc[c, 'reorder_level']) == math.ceil(int(st.get(c, 0)) / 13) for c in goods)
check('opening stock = net units of the last 90 days', qty_ok)
check('reorder level = ceil(units / 13)', reo_ok)
print('\nALL CHECKS PASSED' if ok else '\nSOME CHECKS FAILED')
