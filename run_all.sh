#!/usr/bin/env bash
# rebuild the whole kodes project from the raw csv, in phase order:
#   profile -> clean -> schema (phase 2) -> import -> queries (phase 3)
#   -> triggers + procedure (phase 4) -> backup
#
# run from anywhere; needs python3 with pandas, and the mysql + mysqldump clients.
#   ./run_all.sh                                    # mysql user root, no password
#   MYSQL_ARGS="-u root -h 127.0.0.1" ./run_all.sh  # other connection options
#   MYSQL_PWD=secret ./run_all.sh                   # password via environment
set -euo pipefail
cd "$(dirname "$0")"

RAW=data/raw/online_retail_data.csv.gz
ARGS=${MYSQL_ARGS:-"-u root"}
MYSQL="mysql --default-character-set=utf8mb4 $ARGS"
mkdir -p docs/results backup

echo "1/7 profiling the raw csv"
python3 scripts/profile_data.py "$RAW" > /dev/null

echo "2/7 cleaning it and splitting it into the 3nf tables"
python3 scripts/clean_data.py "$RAW" > docs/results/cleaning_output.txt
python3 scripts/normalization_samples.py "$RAW" > /dev/null
python3 scripts/draw_erd.py > /dev/null   # docs/erd.svg (+ erd.png if playwright is installed)

echo "3/7 creating the schema (schema.sql)"
$MYSQL < sql/schema.sql

echo "4/7 importing the full dataset (load_data.sql)"
$MYSQL -e "SET GLOBAL local_infile = 1;"
$MYSQL --local-infile=1 -t kodes_retail < sql/load_data.sql > docs/results/load_data_output.txt

echo "5/7 running the phase 3 queries (queries.sql)"
$MYSQL -t kodes_retail < sql/queries.sql > docs/results/queries_output.txt

echo "6/7 installing the triggers and the stored procedure, with tests (advanced.sql)"
$MYSQL -t kodes_retail < sql/advanced.sql > docs/results/advanced_output.txt

echo "7/7 writing the backup (backup/kodes_retail_backup.sql.gz)"
# definer clauses are removed so the backup restores under any mysql account, and the
# mysql-8-only 'default encryption' clause is removed so it also restores on mariadb (xampp)
mysqldump $ARGS --default-character-set=utf8mb4 --single-transaction \
          --routines --triggers --databases kodes_retail \
  | sed -E -e 's/DEFINER=`[^`]+`@`[^`]+`//g' \
           -e "s#/\\*!80016 DEFAULT ENCRYPTION='N' \\*/##" \
  | gzip -9 > backup/kodes_retail_backup.sql.gz

echo "done. outputs are in docs/results/ and backup/"
