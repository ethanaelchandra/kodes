-- =============================================================================
--  kodes retail store | queries.sql | phase 3: data transactions & queries (dml)
-- -----------------------------------------------------------------------------
--  run after schema.sql (or after restoring the backup). mysql 8.0 / mariadb 10.4+
--  queries 1 and 2 change data and run inside transactions; 3 to 5 only read.
--  money is in the store's currency unit: the csv's prices are pounds, the
--  brief writes them as "$".
-- =============================================================================

USE kodes_retail;
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

-- workbench's safe-update mode blocks updates filtered on non-key columns
SET @old_safe_updates = @@SQL_SAFE_UPDATES;
SET SQL_SAFE_UPDATES = 0;


-- =============================================================================
--  query 1  price adjustment campaign (UPDATE)
--  +8% on the list price of every product that costs less than 5.00.
--  * only goods: services and vouchers are not products on sale, and a voucher's
--    price is its face value.
--  * 0.00 means "no known price" and is left alone.
--  * the price charged on past sales lives on invoice_line, so history and past
--    revenue do not change.
--  run once: every run adds another 8%.
-- =============================================================================

SELECT COUNT(*)        AS products_to_raise,
       MIN(unit_price) AS lowest_price,
       MAX(unit_price) AS highest_price
FROM   product
WHERE  product_type = 'GOODS'
  AND  unit_price > 0
  AND  unit_price < 5.00;

SELECT stock_code, description, unit_price AS price_before
FROM   product
WHERE  stock_code IN ('85123A', '21212', '22697', '84879', '22423')
ORDER BY stock_code;

START TRANSACTION;

UPDATE product
SET    unit_price = ROUND(unit_price * 1.08, 2)
WHERE  product_type = 'GOODS'
  AND  unit_price > 0
  AND  unit_price < 5.00;

SELECT ROW_COUNT() AS prices_changed;

COMMIT;

SELECT stock_code, description, unit_price AS price_after
FROM   product
WHERE  stock_code IN ('85123A', '21212', '22697', '84879', '22423')
ORDER BY stock_code;


-- =============================================================================
--  query 2  order cancellation processing (UPDATE, no DELETE)
--  the customer of @cancel_invoice cancels the order. the invoice and all its
--  lines stay for the audit trail; only the status changes, with when and why.
--  only a completed sale can be cancelled, so running it twice changes nothing.
--  once advanced.sql is installed, a trigger also puts the goods back in stock.
-- =============================================================================

SET @cancel_invoice = '581587';

SELECT invoice_no, invoice_type, invoice_date, customer_id, status
FROM   invoice
WHERE  invoice_no = @cancel_invoice;

START TRANSACTION;

UPDATE invoice
SET    status        = 'Cancelled',
       cancelled_at  = NOW(),
       cancel_reason = 'cancelled at customer request'
WHERE  invoice_no   = @cancel_invoice
  AND  invoice_type = 'SALE'
  AND  status       = 'Completed';

SELECT ROW_COUNT() AS invoices_cancelled;

COMMIT;

SELECT i.invoice_no,
       i.status,
       i.cancelled_at,
       i.cancel_reason,
       COUNT(l.line_no)                         AS lines_kept,
       ROUND(SUM(l.quantity * l.unit_price), 2) AS invoice_value
FROM   invoice i
JOIN   invoice_line l ON l.invoice_no = i.invoice_no
WHERE  i.invoice_no = @cancel_invoice
GROUP BY i.invoice_no, i.status, i.cancelled_at, i.cancel_reason;


-- =============================================================================
--  query 3  regional sales breakdown (JOIN & GROUP BY)
--  sales revenue and completed invoices per country, highest revenue first.
--  revenue = quantity x price charged on completed SALE invoices; cancelled
--  orders and credit notes are not sales. returns and the net figure are shown
--  beside it.
-- =============================================================================

SELECT co.country_name                                                AS country,
       COUNT(DISTINCT CASE WHEN i.invoice_type = 'SALE'
                           THEN i.invoice_no END)                     AS completed_invoices,
       ROUND(SUM(CASE WHEN i.invoice_type = 'SALE'
                      THEN l.quantity * l.unit_price ELSE 0 END), 2)  AS total_revenue,
       ROUND(SUM(CASE WHEN i.invoice_type = 'CREDIT_NOTE'
                      THEN l.quantity * l.unit_price ELSE 0 END), 2)  AS returns_value,
       ROUND(SUM(l.quantity * l.unit_price), 2)                       AS net_revenue
FROM   invoice i
JOIN   invoice_line l ON l.invoice_no = i.invoice_no
JOIN   country co     ON co.country_id = i.country_id
WHERE  i.status = 'Completed'
  AND  i.invoice_type IN ('SALE', 'CREDIT_NOTE')
GROUP BY co.country_id, co.country_name
ORDER BY total_revenue DESC, country;


-- =============================================================================
--  query 4  vip high-spender identification (nested query / subquery)
--  customers whose total spend is above the average total spend of all
--  customers. total spend = completed sales minus completed credit notes
--  (what the customer paid after returns). the average covers every
--  customer in the table; one with no completed purchase counts as 0.
-- =============================================================================

SELECT c.customer_id,
       c.customer_name,
       c.email,
       c.phone,
       co.country_name           AS country,
       s.sale_invoices,
       ROUND(s.total_spend, 2)   AS total_spend
FROM   customer c
JOIN   country co ON co.country_id = c.country_id
JOIN  (SELECT i.customer_id,
              COUNT(DISTINCT CASE WHEN i.invoice_type = 'SALE' THEN i.invoice_no END) AS sale_invoices,
              SUM(l.quantity * l.unit_price)                                          AS total_spend
       FROM   invoice i
       JOIN   invoice_line l ON l.invoice_no = i.invoice_no
       WHERE  i.customer_id IS NOT NULL
         AND  i.status = 'Completed'
         AND  i.invoice_type IN ('SALE', 'CREDIT_NOTE')
       GROUP BY i.customer_id) s ON s.customer_id = c.customer_id
WHERE  s.total_spend > (
           SELECT AVG(per_customer.spend)
           FROM  (SELECT c2.customer_id,
                         COALESCE(SUM(l2.quantity * l2.unit_price), 0) AS spend
                  FROM   customer c2
                  LEFT JOIN invoice i2
                         ON  i2.customer_id  = c2.customer_id
                         AND i2.status       = 'Completed'
                         AND i2.invoice_type IN ('SALE', 'CREDIT_NOTE')
                  LEFT JOIN invoice_line l2 ON l2.invoice_no = i2.invoice_no
                  GROUP BY c2.customer_id) AS per_customer)
ORDER BY s.total_spend DESC, c.customer_id;

-- the average the list is compared with
SELECT ROUND(AVG(per_customer.spend), 2) AS average_total_spend,
       COUNT(*)                          AS customers
FROM  (SELECT c2.customer_id,
              COALESCE(SUM(l2.quantity * l2.unit_price), 0) AS spend
       FROM   customer c2
       LEFT JOIN invoice i2
              ON  i2.customer_id  = c2.customer_id
              AND i2.status       = 'Completed'
              AND i2.invoice_type IN ('SALE', 'CREDIT_NOTE')
       LEFT JOIN invoice_line l2 ON l2.invoice_no = i2.invoice_no
       GROUP BY c2.customer_id) AS per_customer;


-- =============================================================================
--  query 5  product performance & cross-selling (subquery / complex filtering)
--  goods never bought from germany but bought from at least two other countries.
--  a purchase = a line with quantity > 0 on a completed SALE invoice, and its
--  country is the one recorded on the invoice, which also covers buyers with no
--  customer account. stock_code is never NULL, so NOT IN is safe here.
-- =============================================================================

SELECT p.stock_code,
       p.description,
       COUNT(DISTINCT i.country_id)                                        AS buying_countries,
       GROUP_CONCAT(DISTINCT co.country_name ORDER BY co.country_name SEPARATOR ', ') AS countries
FROM   product p
JOIN   invoice_line l ON l.stock_code = p.stock_code
JOIN   invoice i      ON i.invoice_no = l.invoice_no
JOIN   country co     ON co.country_id = i.country_id
WHERE  p.product_type = 'GOODS'
  AND  i.invoice_type = 'SALE'
  AND  i.status       = 'Completed'
  AND  l.quantity     > 0
  AND  p.stock_code NOT IN (
           SELECT l2.stock_code
           FROM   invoice_line l2
           JOIN   invoice i2  ON i2.invoice_no = l2.invoice_no
           JOIN   country c2  ON c2.country_id = i2.country_id
           WHERE  c2.country_name = 'Germany'
             AND  i2.invoice_type = 'SALE'
             AND  i2.status       = 'Completed'
             AND  l2.quantity     > 0)
GROUP BY p.stock_code, p.description
HAVING COUNT(DISTINCT i.country_id) >= 2
ORDER BY buying_countries DESC, p.stock_code;


SET SQL_SAFE_UPDATES = @old_safe_updates;
