KoDes Retail · Relational database overhaul

Database course project. The single CSV export of KoDes Retail (1,067,371 transaction lines, December 2009 to December 2011) is profiled, cleaned, normalized to 3NF and rebuilt as a MySQL 8 database with constraints, five business queries, inventory triggers and a stored procedure.

Full documentation (case, anomalies and functional dependencies, UNF to 3NF step by step, ERD, data cleaning process, query results): https://app.notion.com/p/40687299610c8124acdafc7bbd130ab2

Deliverables

- `sql/schema.sql`: phase 2, every CREATE TABLE statement with primary and foreign keys, ON DELETE and ON UPDATE actions, NOT NULL, UNIQUE, CHECK and DEFAULT constraints
- `sql/queries.sql`: phase 3, the five business scenarios (price update, order cancellation, sales per country, VIP customers, Germany cross-selling)
- `sql/advanced.sql`: phase 4, the inventory triggers and the stored procedure `GetCustomerInvoiceHistory`, with a self-cleaning test section
- `backup/kodes_retail_backup.sql.gz`: full database backup (schema, all data, triggers, procedure), the clean state before `queries.sql`
- `docs/erd.svg`, `docs/erd.png`: crow's foot ERD

Supporting files

- `sql/load_data.sql`: imports the cleaned CSV files (the full dataset, not a sample)
- `scripts/profile_data.py`: finds the anomalies and tests the functional dependencies in the raw CSV
- `scripts/clean_data.py`: step 1, the cleaning rules; turns the raw CSV into the clean CSV
- `scripts/build_tables.py`: step 2, checks the clean CSV (columns, blanks, keys, functional dependencies, quantity signs, prices) and splits it into the 3NF tables
- `scripts/normalization_samples.py`: the UNF, 1NF, 2NF and 3NF example tables used in the documentation
- `scripts/draw_erd.py`: draws the ERD
- `data/raw/online_retail_data.csv.gz`: the raw CSV as provided, gzipped
- `data/clean/online_retail_clean.csv.gz`: the clean CSV, gzipped: the raw CSV's 8 columns plus `LineNo` and `IsGuest`, 1,026,947 rows, every correction applied
- `data/clean/*.csv`: one cleaned CSV per table, ready for import
- `data/clean/rejected_rows.csv.gz`: every removed row with the rule that removed it
- `data/clean/cleaning_report.json`, `data/clean/tables_report.json`, `data/profile/profile_report.json`: the counts behind every number in the documentation
- `docs/results/*.txt`: the output of each script from the last full run
- `run_all.sh`: rebuilds everything from the raw CSV in phase order

Final database. Legend: Rows = rows after import, PK = primary key

| Table | Rows | PK |
|---|---|---|
| countries | 43 | country_id |
| customers | 5,938 | customer_id |
| products | 4,753 | stock_code |
| inventory | 4,737 | stock_code |
| invoices | 48,235 | invoice_no |
| invoice_lines | 1,026,947 | invoice_no, line_no |

- 1,026,947 raw rows imported and 40,424 rejected with a recorded reason (= 1,067,371).
- customers holds 5,923 registered customers and 15 guest accounts (one per country) for sales without a customer ID.

How to run

Option A, restore the backup (fastest):

```
gunzip -c backup/kodes_retail_backup.sql.gz | mysql -u root -p
```

In phpMyAdmin: open Import and choose the `.sql.gz` file.

Option B, rebuild everything from the raw CSV (Python 3 with pandas, MySQL 8.0.16 or newer):

```
pip install pandas
./run_all.sh                        # mysql user root, no password
MYSQL_PWD=yourpassword ./run_all.sh # with a password
```

Option C, step by step from the repository root (phase 4 before phase 3, so the cancellation in query 2 also returns its goods to stock):

```
python3 scripts/clean_data.py data/raw/online_retail_data.csv.gz
python3 scripts/build_tables.py data/clean/online_retail_clean.csv.gz
mysql -u root -p < sql/schema.sql
mysql -u root -p -e "SET GLOBAL local_infile = 1;"
mysql --local-infile=1 -u root -p kodes_retail < sql/load_data.sql
mysql --default-character-set=utf8mb4 -u root -p kodes_retail < sql/advanced.sql
mysql --default-character-set=utf8mb4 -u root -p kodes_retail < sql/queries.sql
```

About the backup and the queries

- The backup is the clean database: taken after the import and `advanced.sql`, just before `queries.sql`. Restoring it and then running `queries.sql` gives the results in `docs/results/queries_output.txt` (only the `cancelled_at` timestamp of query 2 differs, because it records the moment of the run).
- `queries.sql` changes data on purpose (query 1 raises prices, query 2 cancels invoice 581587), so restore the backup again before a second run.
- The test section of `advanced.sql` rolls itself back, so it can be run any number of times.

Tested on MySQL 8.0.46 and MariaDB 10.11: every script runs on both with the same results, and the backup restores on both. `run_all.sh` removes the definer and the two MySQL-only parts that mysqldump writes (`regexp_like` and the encryption option), which is what makes the backup restore on MariaDB. Every feature used exists from MariaDB 10.2, so XAMPP's MariaDB 10.4 should run it as well.
