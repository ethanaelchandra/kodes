-- =============================================================================
-- kodes retail | phase 3: data transactions & queries (dml)
-- file    : queries.sql
-- needs   : schema.sql + load_data.sql. running advanced.sql first is better:
--           then the cancellation in query 2 also puts its goods back in stock
--           (run_all.sh runs advanced.sql first for that reason).
-- run     : mysql --default-character-set=utf8mb4 -u root -p kodes_retail < sql/queries.sql
-- notes   : - revenue = quantity * unit_price of the line (price at time of sale).
--           - only 'Completed' invoices count; 'Cancelled' ones stay in the
--             database for audit but are excluded from every figure.
--           - 'Return' invoices (source C-prefixed credit notes) have negative
--             quantities, so adding them to sales gives net revenue.
--           - per-invoice totals are aggregated first (derived table on the
--             invoice_lines primary key), which keeps each report at about
--             1 second on the full 1,026,947-line dataset.
--           - query 1 and query 2 change data on purpose.
-- =============================================================================

USE kodes_retail;
-- literals and @variables use the same collation as the tables
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;


-- =============================================================================
-- query 1: price adjustment campaign (UPDATE)
-- raise the list price (products.unit_price) by 8% for every product that
-- currently costs less than 5.00, rounded to the cent. historical invoice lines
-- keep the price that was actually paid, because they store their own
-- unit_price, so the campaign never rewrites past sales.
-- =============================================================================

-- 1a. preview: how many products will be repriced
SELECT COUNT(*)        AS products_below_5,
       MIN(unit_price) AS lowest_price,
       MAX(unit_price) AS highest_price
FROM products
WHERE unit_price < 5.00;

START TRANSACTION;

-- 1b. keep the old prices so the change can be checked afterwards
CREATE TEMPORARY TABLE q1_old_prices AS
SELECT stock_code, unit_price AS old_price
FROM products
WHERE unit_price < 5.00;

-- 1c. the price change itself
UPDATE products
SET unit_price = ROUND(unit_price * 1.08, 2)
WHERE unit_price < 5.00;

-- rows actually changed: a price of 0.00, or of a few cents, rounds back to the
-- same value, because 8% of it is less than half a cent
SELECT ROW_COUNT() AS products_repriced;

COMMIT;

-- 1d. before vs after for a sample of products
SELECT o.stock_code,
       p.description,
       o.old_price,
       p.unit_price                                       AS new_price,
       ROUND((p.unit_price - o.old_price) / o.old_price * 100, 1) AS pct_change
FROM q1_old_prices AS o
JOIN products      AS p ON p.stock_code = o.stock_code
WHERE o.stock_code IN ('85123A', '84879', '22197', '21212', '85099B')
ORDER BY o.stock_code;

DROP TEMPORARY TABLE q1_old_prices;


-- =============================================================================
-- query 2: order cancellation processing (UPDATE, soft cancel)
-- a customer asks to cancel invoice 581587. the invoice is not deleted: its
-- status becomes 'Cancelled' and cancelled_at records when. the header and all
-- its lines stay in the database as the audit record. only a completed sale can
-- be cancelled (a return or an already cancelled invoice is left untouched).
-- with advanced.sql installed, trigger 4 also puts the goods back in stock.
-- =============================================================================

-- the _utf8mb4 introducer and COLLATE give the variable the tables' collation,
-- so this also works when the query is run on its own in workbench or
-- phpmyadmin (without them mysql 8 reports "illegal mix of collations")
SET @invoice_to_cancel = _utf8mb4'581587' COLLATE utf8mb4_unicode_ci;

-- 2a. the invoice before the cancellation
SELECT i.invoice_no, i.customer_id, i.invoice_date, i.invoice_type, i.status, i.cancelled_at,
       COUNT(l.line_no)                       AS line_count,
       ROUND(SUM(l.quantity * l.unit_price), 2) AS invoice_value
FROM invoices AS i
JOIN invoice_lines AS l ON l.invoice_no = i.invoice_no
WHERE i.invoice_no = @invoice_to_cancel
GROUP BY i.invoice_no, i.customer_id, i.invoice_date, i.invoice_type, i.status, i.cancelled_at;

START TRANSACTION;

UPDATE invoices
SET status       = 'Cancelled',
    cancelled_at = NOW()
WHERE invoice_no   = @invoice_to_cancel
  AND invoice_type = 'Sale'
  AND status       = 'Completed';

-- 1 = cancelled; 0 = not found, not a sale, or already cancelled
SELECT ROW_COUNT() AS invoices_cancelled;

COMMIT;

-- 2b. after: same invoice, same lines, new status (nothing was deleted)
SELECT i.invoice_no, i.customer_id, i.invoice_date, i.invoice_type, i.status, i.cancelled_at,
       COUNT(l.line_no)                       AS line_count,
       ROUND(SUM(l.quantity * l.unit_price), 2) AS invoice_value
FROM invoices AS i
JOIN invoice_lines AS l ON l.invoice_no = i.invoice_no
WHERE i.invoice_no = @invoice_to_cancel
GROUP BY i.invoice_no, i.customer_id, i.invoice_date, i.invoice_type, i.status, i.cancelled_at;


-- =============================================================================
-- query 3: regional sales breakdown (JOIN & GROUP BY)
-- total sales revenue and number of completed invoices per country, highest
-- revenue first. completed_invoices counts completed sale invoices; returns
-- (credit notes) reduce revenue but are not counted as invoices.
-- country comes from the customer (guest accounts carry their own country), so
-- the 12 customers who had invoices under two countries count under their main
-- one (cleaning correction c5).
-- =============================================================================

SELECT co.country_name                                                AS country,
       COUNT(CASE WHEN i.invoice_type = 'Sale' THEN 1 END)            AS completed_invoices,
       ROUND(SUM(CASE WHEN i.invoice_type = 'Sale'   THEN t.invoice_value ELSE 0 END), 2) AS gross_sales,
       ROUND(SUM(CASE WHEN i.invoice_type = 'Return' THEN t.invoice_value ELSE 0 END), 2) AS returns_value,
       ROUND(SUM(t.invoice_value), 2)                                 AS total_revenue
FROM (
        -- value of each invoice, summed on the invoice_lines primary key
        SELECT invoice_no, SUM(quantity * unit_price) AS invoice_value
        FROM invoice_lines
        GROUP BY invoice_no
     ) AS t
JOIN invoices  AS i  ON i.invoice_no   = t.invoice_no
JOIN customers AS c  ON c.customer_id  = i.customer_id
JOIN countries AS co ON co.country_id  = c.country_id
WHERE i.status = 'Completed'
GROUP BY co.country_id, co.country_name
ORDER BY total_revenue DESC;


-- =============================================================================
-- query 4: vip high-spender identification (nested subquery)
-- customers whose total spend is greater than the average total spend of all
-- customers. total spend = net value of their completed invoices (sales minus
-- returns). the 15 guest accounts are not real customers (each one pools the
-- anonymous orders of a whole country), so they are left out of both the list
-- and the average. customers with no purchases count as 0 in the average
-- (left join + coalesce).
-- =============================================================================

-- 4a. the threshold, shown for reference
SELECT ROUND(AVG(per_customer.total_spend), 2) AS average_customer_spend
FROM (
        SELECT c.customer_id, COALESCE(SUM(l.quantity * l.unit_price), 0) AS total_spend
        FROM customers AS c
        LEFT JOIN invoices      AS i ON i.customer_id = c.customer_id AND i.status = 'Completed'
        LEFT JOIN invoice_lines AS l ON l.invoice_no  = i.invoice_no
        WHERE c.is_guest = FALSE
        GROUP BY c.customer_id
     ) AS per_customer;

-- 4b. the vip list
SELECT c.customer_id,
       co.country_name             AS country,
       c.email,
       c.phone,
       s.invoice_count,
       s.first_purchase,
       s.last_purchase,
       ROUND(s.total_spend, 2)     AS total_spend
FROM customers AS c
JOIN countries AS co ON co.country_id = c.country_id
JOIN (
        -- total spend per customer
        SELECT i.customer_id,
               COUNT(CASE WHEN i.invoice_type = 'Sale' THEN 1 END) AS invoice_count,
               MIN(CASE WHEN i.invoice_type = 'Sale' THEN i.invoice_date END) AS first_purchase,
               MAX(CASE WHEN i.invoice_type = 'Sale' THEN i.invoice_date END) AS last_purchase,
               SUM(t.invoice_value)                                AS total_spend
        FROM invoices AS i
        JOIN (
                SELECT invoice_no, SUM(quantity * unit_price) AS invoice_value
                FROM invoice_lines
                GROUP BY invoice_no
             ) AS t ON t.invoice_no = i.invoice_no
        WHERE i.status = 'Completed'
        GROUP BY i.customer_id
     ) AS s ON s.customer_id = c.customer_id
WHERE c.is_guest = FALSE
  AND s.total_spend > (
        -- average total spend of all customers (nested subquery)
        SELECT AVG(per_customer.total_spend)
        FROM (
                SELECT c2.customer_id,
                       COALESCE(SUM(l2.quantity * l2.unit_price), 0) AS total_spend
                FROM customers AS c2
                LEFT JOIN invoices      AS i2 ON i2.customer_id = c2.customer_id
                                             AND i2.status = 'Completed'
                LEFT JOIN invoice_lines AS l2 ON l2.invoice_no = i2.invoice_no
                WHERE c2.is_guest = FALSE
                GROUP BY c2.customer_id
             ) AS per_customer
      )
ORDER BY s.total_spend DESC, c.customer_id;


-- =============================================================================
-- query 5: product performance & cross-selling (subquery / complex filtering)
-- products never bought by any customer from 'Germany', but bought by customers
-- from at least two other countries. "bought" = a line on a completed sale
-- invoice (returns and cancelled orders are not purchases).
-- - only real countries are counted: labels that do not name one country
--   ('Unspecified', 'European Community', 'Channel Islands', 'West Indies',
--   countries.is_country = FALSE) cannot count as a second country.
-- - only merchandise is considered (is_stock_item = TRUE): postage, carriage,
--   bank charges and vouchers are billable codes, not products to sell.
-- the result is the list of proven products to push into the german market.
-- =============================================================================

SELECT p.stock_code,
       p.description,
       COUNT(*)                                                              AS buyer_countries,
       GROUP_CONCAT(co.country_name ORDER BY co.country_name SEPARATOR ', ') AS bought_in
FROM (
        -- which countries bought each product: one row per (product, country)
        SELECT DISTINCT l.stock_code, c.country_id
        FROM invoices      AS i
        JOIN invoice_lines AS l ON l.invoice_no  = i.invoice_no
        JOIN customers     AS c ON c.customer_id = i.customer_id
        WHERE i.invoice_type = 'Sale'
          AND i.status       = 'Completed'
     ) AS pc
JOIN products  AS p  ON p.stock_code  = pc.stock_code
JOIN countries AS co ON co.country_id = pc.country_id
WHERE p.is_stock_item = TRUE
  AND co.is_country   = TRUE
  AND p.stock_code NOT IN (
        -- every product bought at least once by a customer from germany
        -- (stock_code is NOT NULL, so NOT IN is safe here)
        SELECT l2.stock_code
        FROM invoice_lines AS l2
        JOIN invoices      AS i2  ON i2.invoice_no  = l2.invoice_no
        JOIN customers     AS c2  ON c2.customer_id = i2.customer_id
        JOIN countries     AS co2 ON co2.country_id = c2.country_id
        WHERE co2.country_name = 'Germany'
          AND i2.invoice_type  = 'Sale'
          AND i2.status        = 'Completed'
      )
GROUP BY p.stock_code, p.description
HAVING COUNT(*) >= 2          -- at least two other (real) countries
ORDER BY buyer_countries DESC, p.stock_code;
