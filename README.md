# kodes retail store — relational database

database technology final project (aol), binus university. kodes retail's single csv of 1,067,371 transaction lines becomes a 7-table relational database in 3nf, imported in full, with five business queries, a stock trigger and a stored procedure.

the full documentation (case, sample data, anomalies, normalization, erd, data cleaning, results) is on the notion page; this repo holds the code and data it refers to.

## what's here

| path | what it is |
| --- | --- |
| `sql/schema.sql` | phase 2: database, 7 tables, every constraint, and the full csv import and cleaning |
| `sql/queries.sql` | phase 3: the five required queries |
| `sql/advanced.sql` | phase 4: the stock trigger, supporting triggers, `GetCustomerInvoiceHistory`, and a rolled-back demo |
| `backup/kodes_retail_backup.sql` | export of the finished database (all three scripts run), restorable without the csv |
| `backup/kodes_retail_backup.sql.gz` | the same backup compressed, for phpmyadmin's upload limit |
| `docs/erd.png` | the refined erd in crow's foot notation (`erd.dot` and `legend.dot` are its graphviz source) |
| `data/online_retail_data.zip` | the source csv as given for the project |
| `analysis/profile_data.py` | recomputes every count in the anomaly chapter from the csv |
| `analysis/verify_import.py`, `verify_queries.py`, `export_tables.sh` | rebuild the tables and query results independently in pandas and compare them with the database |

## run it

option a, build from the csv (about 2 minutes):

1. unzip `data/online_retail_data.zip`, then set the path on the line marked `csv path` in `sql/schema.sql`.
2. allow local file loading once: `SET GLOBAL local_infile = 1;`
3. from the command line (xampp shell or a terminal):

```
mysql -u root --local-infile=1 < sql/schema.sql
mysql -u root < sql/queries.sql
mysql -u root < sql/advanced.sql
```

option b, restore the finished database (about 15 seconds):

```
mysql -u root < backup/kodes_retail_backup.sql
```

both were tested on mysql 8.0.46 and mariadb 10.11 with identical results. xampp ships mariadb 10.4, which was not tested directly; the scripts avoid mysql-only syntax (no `REGEXP_LIKE`, no `utf8mb4_0900` collations).

## results at a glance

| item | result |
| --- | --- |
| csv rows | 1,067,371 = 1,039,526 invoice lines + 5,305 stock adjustments + 22,523 repeated rows + 17 test rows |
| tables | country 43 · customer 5,940 · product 5,129 · inventory 5,106 · invoice 48,364 · invoice_line 1,039,526 · stock_adjustment 5,305 |
| query 1 | 3,920 goods under 5.00 raised by 8% (3,914 prices change after rounding) |
| query 2 | invoice 581587 cancelled, all 16 lines kept |
| query 3 | 43 countries; united kingdom first with 17,454,608.28 from 36,527 invoices |
| query 4 | 1,213 customers above the 2,751.38 average spend |
| query 5 | 1,505 goods never bought from germany but bought in 2 or more other countries |
| trigger demo | 14 of 14 invalid changes refused |
