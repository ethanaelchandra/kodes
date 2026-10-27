-- =============================================================================
-- kodes retail | import the cleaned csv files (full dataset, not a sample)
-- file    : load_data.sql
-- needs   : schema.sql already run; csv files made by scripts/clean_data.py
-- run     : from the repository root, with local infile enabled on both sides:
--             mysql -u root -p -e "SET GLOBAL local_infile = 1;"
--             mysql --local-infile=1 -u root -p kodes_retail < sql/load_data.sql
-- note    : parents are loaded before children so every foreign key is checked
--           while loading (foreign_key_checks stays on).
-- =============================================================================

USE kodes_retail;
SET NAMES utf8mb4;

LOAD DATA LOCAL INFILE 'data/clean/countries.csv'
INTO TABLE countries
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(country_id, country_name);

LOAD DATA LOCAL INFILE 'data/clean/customers.csv'
INTO TABLE customers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(customer_id, country_id, is_guest, email, phone);

LOAD DATA LOCAL INFILE 'data/clean/products.csv'
INTO TABLE products
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(stock_code, description, unit_price, is_stock_item);

LOAD DATA LOCAL INFILE 'data/clean/inventory.csv'
INTO TABLE inventory
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(stock_code, quantity_on_hand, reorder_level);

LOAD DATA LOCAL INFILE 'data/clean/invoices.csv'
INTO TABLE invoices
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(invoice_no, customer_id, invoice_date, invoice_type, status, cancelled_at);

LOAD DATA LOCAL INFILE 'data/clean/invoice_lines.csv'
INTO TABLE invoice_lines
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(invoice_no, line_no, stock_code, quantity, unit_price);

ANALYZE TABLE countries, customers, products, inventory, invoices, invoice_lines;

-- ---------------------------------------------------------------- verification
-- expected rows: countries 43, customers 5938, products 4753, inventory 4737,
--                invoices 48235, invoice_lines 1026947
SELECT 'countries' AS table_name, COUNT(*) AS row_count FROM countries
UNION ALL SELECT 'customers',     COUNT(*) FROM customers
UNION ALL SELECT 'products',      COUNT(*) FROM products
UNION ALL SELECT 'inventory',     COUNT(*) FROM inventory
UNION ALL SELECT 'invoices',      COUNT(*) FROM invoices
UNION ALL SELECT 'invoice_lines', COUNT(*) FROM invoice_lines;

-- expected net revenue of all imported lines: 19224458.348
SELECT SUM(quantity * unit_price) AS imported_net_revenue FROM invoice_lines;
