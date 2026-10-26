"""recompute the five queries in pandas from a fresh build and compare with what queries.sql returned.

usage:
  1. build the database with schema.sql and export the tables (export_tables.sh)
  2. run queries.sql with tab-separated output:  mysql -u root -B < queries.sql > queries_output.tsv
  3. python verify_queries.py export_dir queries_output.tsv
"""
import sys, json
from decimal import Decimal, ROUND_HALF_UP
import pandas as pd, numpy as np

HEADERS = ('products_to_raise', 'stock_code\tdescription\tprice_before', 'prices_changed', 'stock_code\tdescription\tprice_after',
           'invoice_no\tinvoice_type', 'invoices_cancelled', 'invoice_no\tstatus', 'country\tcompleted_invoices',
           'customer_id\tcustomer_name', 'average_total_spend', 'stock_code\tdescription\tbuying_countries')


def split_result_sets(path):
    sets, cur = [], None
    for ln in open(path, encoding='utf-8').read().split('\n'):
        if ln.startswith(HEADERS):
            cur = [ln]
            sets.append(cur)
        elif cur is not None and ln:
            cur.append(ln)
    return sets

ex_dir, res_path = sys.argv[1], sys.argv[2]
rd = lambda t: pd.read_csv(f'{ex_dir}/{t}.tsv', sep='\t', dtype=str, keep_default_na=False, na_values=['NULL'])
country, customer, product, invoice, line = rd('country'), rd('customer'), rd('product'), rd('invoice'), rd('invoice_line')
sets = {s[0].split('\t')[0] + ':' + s[0].split('\t')[-1]: [r.split('\t') for r in s] for s in split_result_sets(res_path)}
def get(prefix):
    return next(v for k, v in sets.items() if k.startswith(prefix))
ok = True
def check(name, cond, detail=''):
    global ok; ok &= bool(cond); print(('PASS ' if cond else 'FAIL ') + name + (f'  {detail}' if detail else ''))
D = lambda s: Decimal(s)
# q1
p = product.copy(); p['price'] = p.unit_price.map(D)
sel = p[(p.product_type == 'GOODS') & (p.price > 0) & (p.price < 5)]
new = sel.price.map(lambda x: (x * Decimal('1.08')).quantize(Decimal('0.01'), ROUND_HALF_UP))
check('q1 products to raise', len(sel) == int(get('products_to_raise')[1][0]), f'{len(sel)}')
check('q1 prices changed', int((new != sel.price).sum()) == int(get('prices_changed')[1][0]), f'{int((new != sel.price).sum())}')
# q2 + data for 3-5
inv = invoice.set_index('invoice_no')
inv.loc['581587', 'status'] = 'Cancelled'
l = line.copy(); l['val'] = l.quantity.astype(int) * l.unit_price.map(D)
q2 = l[l.invoice_no == '581587']
r2 = get('invoice_no:invoice_value')[1]
check('q2 lines kept and value', len(q2) == int(r2[4]) and q2.val.sum().quantize(Decimal('0.01'), ROUND_HALF_UP) == D(r2[5]), f'{len(q2)} lines, {q2.val.sum()}')
l = l.join(inv[['invoice_type', 'status', 'country_id', 'customer_id']], on='invoice_no')
done = l[(l.status == 'Completed') & l.invoice_type.isin(['SALE', 'CREDIT_NOTE'])]
cname = country.set_index('country_id').country_name
# q3
g = done.groupby('country_id')
q3 = pd.DataFrame({
    'country': cname.loc[list(g.groups.keys())].values,
    'inv': g.apply(lambda x: x.loc[x.invoice_type == 'SALE', 'invoice_no'].nunique()).values,
    'rev': g.apply(lambda x: x.loc[x.invoice_type == 'SALE', 'val'].sum()).values,
    'ret': g.apply(lambda x: x.loc[x.invoice_type == 'CREDIT_NOTE', 'val'].sum()).values,
    'net': g.val.sum().values})
q3['rev'] = q3.rev.map(lambda x: Decimal(x).quantize(Decimal('0.01'), ROUND_HALF_UP))
q3 = q3.sort_values(['rev', 'country'], ascending=[False, True])
sq3 = get('country:net_revenue')[1:]
same = len(q3) == len(sq3) and all(a == b[0] and int(i) == int(b[1]) and r == D(b[2]) and Decimal(rt).quantize(Decimal('0.01'), ROUND_HALF_UP) == D(b[3]) and Decimal(n).quantize(Decimal('0.01'), ROUND_HALF_UP) == D(b[4])
                                   for (a, i, r, rt, n), b in zip(q3[['country', 'inv', 'rev', 'ret', 'net']].values, sq3))
check('q3 every country, count and amount, in the same order', same, f'{len(q3)} countries')
# q4
spend = done[done.customer_id.notna()].groupby('customer_id').val.sum()
allc = customer.customer_id
per = pd.Series([spend.get(c, Decimal(0)) for c in allc], index=allc)
avg = sum(per.values, Decimal(0)) / len(per)
vip = spend[spend > avg]
sq4 = get('customer_id:total_spend')[1:]
check('q4 average', avg.quantize(Decimal('0.01'), ROUND_HALF_UP) == D(get('average_total_spend')[1][0]), f'{avg:.4f}')
check('q4 same customers', set(vip.index) == {r[0] for r in sq4}, f'{len(vip)} vs {len(sq4)}')
check('q4 same totals', all(vip[r[0]].quantize(Decimal('0.01'), ROUND_HALF_UP) == D(r[6]) for r in sq4))
# q5
sales = l[(l.invoice_type == 'SALE') & (l.status == 'Completed') & (l.quantity.astype(int) > 0)]
sales = sales.join(product.set_index('stock_code').product_type, on='stock_code')
de = set(sales.loc[sales.country_id.map(cname) == 'Germany', 'stock_code'])
gs = sales[(sales.product_type == 'GOODS') & ~sales.stock_code.isin(de)].groupby('stock_code').country_id.nunique()
q5 = gs[gs >= 2]
sq5 = get('stock_code:countries')[1:]
check('q5 same products', set(q5.index) == {r[0] for r in sq5}, f'{len(q5)} vs {len(sq5)}')
check('q5 same country counts', all(int(q5[r[0]]) == int(r[2]) for r in sq5))
print('\nALL QUERY CHECKS PASSED' if ok else '\nSOME QUERY CHECKS FAILED')
