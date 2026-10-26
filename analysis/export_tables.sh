#!/bin/sh
# export the 7 tables of a fresh build (right after schema.sql) as tab-separated files
# usage: sh export_tables.sh export_dir [mysql options, e.g. -u root -p]
out="$1"; shift
mkdir -p "$out"
for t in country customer product inventory invoice stock_adjustment; do
  mysql "$@" -B --default-character-set=utf8mb4 kodes_retail -e "SELECT * FROM $t" > "$out/$t.tsv"
done
mysql "$@" -B --default-character-set=utf8mb4 kodes_retail \
  -e "SELECT invoice_no, line_no, stock_code, quantity, unit_price FROM invoice_line ORDER BY invoice_no, line_no" > "$out/invoice_line.tsv"
