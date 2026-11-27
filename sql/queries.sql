-- =============================================================================
-- KoDes Retail | Phase 3: Data transactions & queries (DML)
-- File    : queries.sql
-- Needs   : schema.sql + load_data.sql. Running advanced.sql first is better:
--           then the cancellation in query 2 also puts its goods back in stock
--           (run_all.sh runs advanced.sql first for that reason).
-- Run     : mysql --default-character-set=utf8mb4 -u root -p kodes_retail < sql/queries.sql
-- Notes   : - Revenue = quantity * unit_price of the line (price at time of sale).
--           - Only 'Completed' invoices count; 'Cancelled' ones stay in the
--             database for audit but are excluded from every figure.
--           - 'Return' invoices (source C-prefixed credit notes) have negative
--             quantities, so adding them to sales gives net revenue.
--           - Per-invoice totals are aggregated first (derived table on the
--             invoice_lines primary key), which keeps each report at about
--             1 second on the full 1,026,947-line dataset.
--           - Query 1 and query 2 change data on purpose.
-- =============================================================================

USE kodes_retail;
-- Literals and @variables use the same collation as the tables
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;


-- =============================================================================
-- Query 1: Price adjustment campaign (UPDATE)
-- Raise the list price (products.unit_price) by 8% for every product that
-- currently costs less than 5.00, rounded to the cent. Historical invoice lines
-- keep the price that was actually paid, because they store their own
-- unit_price, so the campaign never rewrites past sales.
-- =============================================================================

-- 1a. Preview: how many products will be repriced
SELECT COUNT(*)        AS products_below_5,
       MIN(unit_price) AS lowest_price,
       MAX(unit_price) AS highest_price
FROM products
WHERE unit_price < 5.00;

START TRANSACTION;

-- 1b. Keep the old prices so the change can be checked afterwards
CREATE TEMPORARY TABLE q1_old_prices AS
SELECT stock_code, unit_price AS old_price
FROM products
WHERE unit_price < 5.00;

-- 1c. The price change itself
UPDATE products
SET unit_price = ROUND(unit_price * 1.08, 2)
WHERE unit_price < 5.00;

-- Rows actually changed: a price of 0.00, or of a few cents, rounds back to the
-- same value, because 8% of it is less than half a cent
SELECT ROW_COUNT() AS products_repriced;

COMMIT;

-- 1d. Before vs after for a sample of products
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
-- Query 2: Order cancellation processing (UPDATE, soft cancel)
-- A customer asks to cancel invoice 581587. The invoice is not deleted: its
-- status becomes 'Cancelled' and cancelled_at records when. The header and all
-- its lines stay in the database as the audit record. Only a completed sale can
-- be cancelled (a return or an already cancelled invoice is left untouched).
-- With advanced.sql installed, trigger 4 also puts the goods back in stock.
-- =============================================================================

-- The _utf8mb4 introducer and COLLATE give the variable the tables' collation,
-- so this also works when the query is run on its own in Workbench or
-- phpMyAdmin (without them MySQL 8 reports "illegal mix of collations")
SET @invoice_to_cancel = _utf8mb4'581587' COLLATE utf8mb4_unicode_ci;

-- 2a. The invoice before the cancellation
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

-- 2b. After: same invoice, same lines, new status (nothing was deleted)
SELECT i.invoice_no, i.customer_id, i.invoice_date, i.invoice_type, i.status, i.cancelled_at,
       COUNT(l.line_no)                       AS line_count,
       ROUND(SUM(l.quantity * l.unit_price), 2) AS invoice_value
FROM invoices AS i
JOIN invoice_lines AS l ON l.invoice_no = i.invoice_no
WHERE i.invoice_no = @invoice_to_cancel
GROUP BY i.invoice_no, i.customer_id, i.invoice_date, i.invoice_type, i.status, i.cancelled_at;


-- =============================================================================
-- Query 3: Regional sales breakdown (JOIN & GROUP BY)
-- Total sales revenue and number of completed invoices per country, highest
-- revenue first. completed_invoices counts completed sale invoices; returns
-- (credit notes) reduce revenue but are not counted as invoices.
-- Country comes from the customer (guest accounts carry their own country), so
-- the 12 customers who had invoices under two countries count under their main
-- one (cleaning correction C5).
-- =============================================================================

SELECT co.country_name                                                AS country,
       COUNT(CASE WHEN i.invoice_type = 'Sale' THEN 1 END)            AS completed_invoices,
       ROUND(SUM(CASE WHEN i.invoice_type = 'Sale'   THEN t.invoice_value ELSE 0 END), 2) AS gross_sales,
       ROUND(SUM(CASE WHEN i.invoice_type = 'Return' THEN t.invoice_value ELSE 0 END), 2) AS returns_value,
       ROUND(SUM(t.invoice_value), 2)                                 AS total_revenue
FROM (
        -- Value of each invoice, summed on the invoice_lines primary key
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
-- Query 4: VIP high-spender identification (nested subquery)
-- Customers whose total spend is greater than the average total spend of all
-- customers. Total spend = net value of their completed invoices (sales minus
-- returns). The 15 guest accounts are not real customers (each one pools the
-- anonymous orders of a whole country), so they are left out of both the list
-- and the average. Customers with no purchases count as 0 in the average
-- (left join + coalesce).
-- =============================================================================

-- 4a. The threshold, shown for reference
SELECT ROUND(AVG(per_customer.total_spend), 2) AS average_customer_spend
FROM (
        SELECT c.customer_id, COALESCE(SUM(l.quantity * l.unit_price), 0) AS total_spend
        FROM customers AS c
        LEFT JOIN invoices      AS i ON i.customer_id = c.customer_id AND i.status = 'Completed'
        LEFT JOIN invoice_lines AS l ON l.invoice_no  = i.invoice_no
        WHERE c.is_guest = FALSE
        GROUP BY c.customer_id
     ) AS per_customer;

-- 4b. The VIP list
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
        -- Total spend per customer
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
        -- Average total spend of all customers (nested subquery)
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
-- Query 5: Product performance & cross-selling (subquery / complex filtering)
-- Products never bought by any customer from 'Germany', but bought by customers
-- from at least two other countries. "Bought" = a line on a completed sale
-- invoice (returns and cancelled orders are not purchases).
-- - Only real countries are counted: labels that do not name one country
--   ('Unspecified', 'European Community', 'Channel Islands', 'West Indies',
--   countries.is_country = FALSE) cannot count as a second country.
-- - Only merchandise is considered (is_stock_item = TRUE): postage, carriage,
--   bank charges and vouchers are billable codes, not products to sell.
-- The result is the list of proven products to push into the German market.
-- =============================================================================

SELECT p.stock_code,
       p.description,
       COUNT(*)                                                              AS buyer_countries,
       GROUP_CONCAT(co.country_name ORDER BY co.country_name SEPARATOR ', ') AS bought_in
FROM (
        -- Which countries bought each product: one row per (product, country)
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
        -- Every product bought at least once by a customer from Germany
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
HAVING COUNT(*) >= 2          -- At least two other (real) countries
ORDER BY buyer_countries DESC, p.stock_code;
