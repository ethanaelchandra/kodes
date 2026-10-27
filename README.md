kodes retail · relational database overhaul

database course project. the single csv export of kodes retail (1,067,371 transaction lines, december 2009 to december 2011) is profiled, cleaned, normalized to 3nf and rebuilt as a mysql 8 database with constraints, five business queries, inventory triggers and a stored procedure.

full documentation (case, anomalies and functional dependencies, unf to 3nf step by step, erd, data cleaning process, query results): https://app.notion.com/p/40687299610c8124acdafc7bbd130ab2

deliverables

- `sql/schema.sql`: phase 2, every create table statement with primary and foreign keys, on delete and on update actions, not null, unique, check and default constraints
- `sql/queries.sql`: phase 3, the five business scenarios (price update, order cancellation, sales per country, vip customers, germany cross-selling)
- `sql/advanced.sql`: phase 4, the inventory triggers and the stored procedure `GetCustomerInvoiceHistory`, with a self-cleaning test section
- `backup/kodes_retail_backup.sql.gz`: full database backup (schema, all data, triggers, procedure)
- `docs/erd.svg`, `docs/erd.png`: crow's foot erd

supporting files

- `sql/load_data.sql`: imports the cleaned csv files (the full dataset, not a sample)
- `scripts/profile_data.py`: finds the anomalies and tests the functional dependencies in the raw csv
- `scripts/clean_data.py`: the cleaning rules and the split into the 3nf tables
- `scripts/normalization_samples.py`: the unf, 1nf, 2nf and 3nf example tables used in the documentation
- `scripts/draw_erd.py`: draws the erd
- `data/raw/online_retail_data.csv.gz`: the raw csv as provided, gzipped
- `data/clean/*.csv`: one cleaned csv per table, ready for import
- `data/clean/rejected_rows.csv.gz`: every removed row with the rule that removed it
- `data/clean/cleaning_report.json`, `data/profile/profile_report.json`: the counts behind every number in the documentation
- `docs/results/*.txt`: the output of each script from the last full run
- `run_all.sh`: rebuilds everything from the raw csv in phase order

final database. legend: rows = rows after import, pk = primary key

| table | rows | pk |
|---|---|---|
| countries | 43 | country_id |
| customers | 5,938 | customer_id |
| products | 4,753 | stock_code |
| inventory | 4,737 | stock_code |
| invoices | 48,235 | invoice_no |
| invoice_lines | 1,026,947 | invoice_no, line_no |

- 1,026,947 raw rows imported and 40,424 rejected with a recorded reason (= 1,067,371).
- customers holds 5,923 registered customers and 15 guest accounts (one per country) for sales without a customer id.

how to run

option a, restore the backup (fastest):

```
gunzip -c backup/kodes_retail_backup.sql.gz | mysql -u root -p
```

in phpmyadmin: open import and choose the `.sql.gz` file.

option b, rebuild everything from the raw csv (python 3 with pandas, mysql 8.0.16 or newer):

```
pip install pandas
./run_all.sh                        # mysql user root, no password
MYSQL_PWD=yourpassword ./run_all.sh # with a password
```

option c, step by step from the repository root:

```
python3 scripts/clean_data.py data/raw/online_retail_data.csv.gz
mysql -u root -p < sql/schema.sql
mysql -u root -p -e "SET GLOBAL local_infile = 1;"
mysql --local-infile=1 -u root -p kodes_retail < sql/load_data.sql
mysql --default-character-set=utf8mb4 -u root -p kodes_retail < sql/queries.sql
mysql --default-character-set=utf8mb4 -u root -p kodes_retail < sql/advanced.sql
```

tested on mysql 8.0.46. the scripts avoid mysql-8-only collations, so they also run on mariadb 10.4 or newer (xampp). note that `queries.sql` changes data on purpose (query 1 raises prices, query 2 cancels invoice 581587), and the backup already includes those changes.
