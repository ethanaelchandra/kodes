-- =============================================================================
--  kodes retail store | schema.sql | phase 2: database implementation (ddl)
-- -----------------------------------------------------------------------------
--  builds database kodes_retail (7 tables in 3nf) and imports the full
--  online_retail_data.csv (1,067,371 rows). runs on mysql 8.0.16+ and on
--  mariadb 10.4+ (xampp).
--
--  before running:
--   1. put online_retail_data.csv somewhere the database can read and change
--      the path in step 3 (look for "csv path").
--   2. local infile must be on, once, as root:  SET GLOBAL local_infile = 1;
--   3. run it from the command line so the import is not cut off by a timeout:
--        xampp shell : mysql -u root --local-infile=1 < schema.sql
--        mysql 8     : mysql -u root -p --local-infile=1 < schema.sql
--      workbench works too with OPT_LOCAL_INFILE=1 under connection > advanced.
--  a full run takes about 1 to 3 minutes.
-- =============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

DROP DATABASE IF EXISTS kodes_retail;
CREATE DATABASE kodes_retail CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE kodes_retail;


-- =============================================================================
--  step 1  tables
-- =============================================================================

CREATE TABLE country (
    country_id    SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    country_name  VARCHAR(60)       NOT NULL,
    iso_code      CHAR(2)           NULL,
    CONSTRAINT pk_country      PRIMARY KEY (country_id),
    CONSTRAINT uq_country_name UNIQUE (country_name),
    CONSTRAINT uq_country_iso  UNIQUE (iso_code),
    CONSTRAINT ck_country_name CHECK (CHAR_LENGTH(TRIM(country_name)) > 0),
    CONSTRAINT ck_country_iso  CHECK (iso_code IS NULL OR iso_code COLLATE utf8mb4_bin REGEXP '^[A-Z]{2}$')
) ENGINE = InnoDB;

CREATE TABLE customer (
    customer_id    INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    country_id     SMALLINT UNSIGNED NOT NULL,
    customer_name  VARCHAR(100)      NULL,
    email          VARCHAR(254)      NULL,
    phone          VARCHAR(20)       NULL,
    CONSTRAINT pk_customer         PRIMARY KEY (customer_id),
    CONSTRAINT uq_customer_email   UNIQUE (email),
    CONSTRAINT fk_customer_country FOREIGN KEY (country_id) REFERENCES country (country_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ck_customer_email   CHECK (email IS NULL OR email LIKE '_%@_%._%'),
    CONSTRAINT ck_customer_phone   CHECK (phone IS NULL OR phone REGEXP '^[+]?[0-9 ()-]{6,20}$')
) ENGINE = InnoDB;

CREATE TABLE product (
    stock_code    VARCHAR(20)   NOT NULL,
    description   VARCHAR(100)  NOT NULL,
    unit_price    DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    product_type  VARCHAR(10)   NOT NULL DEFAULT 'GOODS',
    CONSTRAINT pk_product        PRIMARY KEY (stock_code),
    CONSTRAINT ck_product_code   CHECK (CHAR_LENGTH(stock_code) > 0
                                        AND stock_code COLLATE utf8mb4_bin = UPPER(TRIM(stock_code))),
    CONSTRAINT ck_product_desc   CHECK (CHAR_LENGTH(TRIM(description)) > 0),
    CONSTRAINT ck_product_price  CHECK (unit_price >= 0),
    CONSTRAINT ck_product_type   CHECK (product_type COLLATE utf8mb4_bin IN ('GOODS', 'SERVICE', 'VOUCHER'))
) ENGINE = InnoDB;

CREATE TABLE inventory (
    stock_code     VARCHAR(20) NOT NULL,
    qty_on_hand    INT         NOT NULL DEFAULT 0,
    reorder_level  INT         NOT NULL DEFAULT 0,
    last_updated   DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_inventory         PRIMARY KEY (stock_code),
    CONSTRAINT fk_inventory_product FOREIGN KEY (stock_code) REFERENCES product (stock_code)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT ck_inventory_qty     CHECK (qty_on_hand >= 0),
    CONSTRAINT ck_inventory_reorder CHECK (reorder_level >= 0)
) ENGINE = InnoDB;

CREATE TABLE invoice (
    invoice_no     VARCHAR(10)       NOT NULL,
    invoice_type   VARCHAR(12)       NOT NULL DEFAULT 'SALE',
    invoice_date   DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    customer_id    INT UNSIGNED      NULL,
    country_id     SMALLINT UNSIGNED NOT NULL,
    status         VARCHAR(10)       NOT NULL DEFAULT 'Completed',
    cancelled_at   DATETIME          NULL,
    cancel_reason  VARCHAR(255)      NULL,
    CONSTRAINT pk_invoice          PRIMARY KEY (invoice_no),
    CONSTRAINT fk_invoice_customer FOREIGN KEY (customer_id) REFERENCES customer (customer_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT fk_invoice_country  FOREIGN KEY (country_id) REFERENCES country (country_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ck_invoice_type     CHECK (invoice_type COLLATE utf8mb4_bin IN ('SALE', 'CREDIT_NOTE', 'ADJUSTMENT')),
    CONSTRAINT ck_invoice_no_type  CHECK (
           (invoice_type = 'SALE'        AND invoice_no COLLATE utf8mb4_bin REGEXP '^[0-9]{6}$')
        OR (invoice_type = 'CREDIT_NOTE' AND invoice_no COLLATE utf8mb4_bin REGEXP '^C[0-9]{6}$')
        OR (invoice_type = 'ADJUSTMENT'  AND invoice_no COLLATE utf8mb4_bin REGEXP '^A[0-9]{6}$')),
    CONSTRAINT ck_invoice_status   CHECK (status COLLATE utf8mb4_bin IN ('Completed', 'Cancelled')),
    CONSTRAINT ck_invoice_cancel   CHECK (
           (status = 'Completed' AND cancelled_at IS NULL AND cancel_reason IS NULL)
        OR (status = 'Cancelled' AND cancelled_at IS NOT NULL AND invoice_type = 'SALE'))
) ENGINE = InnoDB;

CREATE TABLE invoice_line (
    invoice_no  VARCHAR(10)       NOT NULL,
    line_no     SMALLINT UNSIGNED NOT NULL,
    stock_code  VARCHAR(20)       NOT NULL,
    quantity    INT               NOT NULL,
    unit_price  DECIMAL(10,3)     NOT NULL,
    CONSTRAINT pk_invoice_line   PRIMARY KEY (invoice_no, line_no),
    CONSTRAINT fk_line_invoice   FOREIGN KEY (invoice_no) REFERENCES invoice (invoice_no)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_line_product   FOREIGN KEY (stock_code) REFERENCES product (stock_code)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ck_line_no        CHECK (line_no >= 1),
    CONSTRAINT ck_line_quantity  CHECK (quantity <> 0),
    CONSTRAINT ck_line_price     CHECK (unit_price >= 0)
) ENGINE = InnoDB;

CREATE TABLE stock_adjustment (
    adjustment_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    stock_code       VARCHAR(20)  NOT NULL,
    quantity_change  INT          NOT NULL,
    reason           VARCHAR(100) NULL,
    adjusted_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_stock_adjustment   PRIMARY KEY (adjustment_id),
    CONSTRAINT fk_adjustment_product FOREIGN KEY (stock_code) REFERENCES product (stock_code)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ck_adjustment_qty     CHECK (quantity_change <> 0)
) ENGINE = InnoDB;

CREATE INDEX idx_invoice_date        ON invoice (invoice_date);
CREATE INDEX idx_invoice_type_status ON invoice (invoice_type, status);
CREATE INDEX idx_product_type_price  ON product (product_type, unit_price);
CREATE INDEX idx_adjustment_date     ON stock_adjustment (adjusted_at);


-- =============================================================================
--  step 2  country names: the csv's labels mapped to standard names + iso codes
-- =============================================================================

CREATE TABLE stg_country_map (
    raw_label     VARCHAR(60) NOT NULL PRIMARY KEY,
    country_name  VARCHAR(60) NOT NULL,
    iso_code      CHAR(2)     NULL
) ENGINE = InnoDB;

INSERT INTO stg_country_map (raw_label, country_name, iso_code) VALUES
    ('Australia', 'Australia', 'AU'),             ('Austria', 'Austria', 'AT'),
    ('Bahrain', 'Bahrain', 'BH'),                 ('Belgium', 'Belgium', 'BE'),
    ('Bermuda', 'Bermuda', 'BM'),                 ('Brazil', 'Brazil', 'BR'),
    ('Canada', 'Canada', 'CA'),                   ('Channel Islands', 'Channel Islands', NULL),
    ('Cyprus', 'Cyprus', 'CY'),                   ('Czech Republic', 'Czech Republic', 'CZ'),
    ('Denmark', 'Denmark', 'DK'),                 ('EIRE', 'Ireland', 'IE'),
    ('European Community', 'European Community', NULL),
    ('Finland', 'Finland', 'FI'),                 ('France', 'France', 'FR'),
    ('Germany', 'Germany', 'DE'),                 ('Greece', 'Greece', 'GR'),
    ('Hong Kong', 'Hong Kong', 'HK'),             ('Iceland', 'Iceland', 'IS'),
    ('Israel', 'Israel', 'IL'),                   ('Italy', 'Italy', 'IT'),
    ('Japan', 'Japan', 'JP'),                     ('Korea', 'South Korea', 'KR'),
    ('Lebanon', 'Lebanon', 'LB'),                 ('Lithuania', 'Lithuania', 'LT'),
    ('Malta', 'Malta', 'MT'),                     ('Netherlands', 'Netherlands', 'NL'),
    ('Nigeria', 'Nigeria', 'NG'),                 ('Norway', 'Norway', 'NO'),
    ('Poland', 'Poland', 'PL'),                   ('Portugal', 'Portugal', 'PT'),
    ('RSA', 'South Africa', 'ZA'),                ('Saudi Arabia', 'Saudi Arabia', 'SA'),
    ('Singapore', 'Singapore', 'SG'),             ('Spain', 'Spain', 'ES'),
    ('Sweden', 'Sweden', 'SE'),                   ('Switzerland', 'Switzerland', 'CH'),
    ('Thailand', 'Thailand', 'TH'),               ('United Arab Emirates', 'United Arab Emirates', 'AE'),
    ('United Kingdom', 'United Kingdom', 'GB'),   ('Unspecified', 'Unspecified', NULL),
    ('USA', 'United States', 'US'),               ('West Indies', 'West Indies', NULL);


-- =============================================================================
--  step 3  load the raw csv into a staging table, every field as text
-- =============================================================================

CREATE TABLE stg_raw (
    src_row       INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    invoice       VARCHAR(20),
    stock_code    VARCHAR(40),
    description   VARCHAR(255),
    quantity      VARCHAR(20),
    invoice_date  VARCHAR(30),
    price         VARCHAR(20),
    customer_id   VARCHAR(20),
    country       VARCHAR(60)
) ENGINE = InnoDB;

-- csv path: change it to where the file is on your machine (forward slashes).
-- if your client refuses LOCAL (phpmyadmin often does), run this file from the
-- command line as shown at the top instead.
LOAD DATA LOCAL INFILE 'C:/kodes/online_retail_data.csv'
INTO TABLE stg_raw
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(invoice, stock_code, description, quantity, invoice_date, price, customer_id, country);

SELECT COUNT(*) AS csv_rows_loaded FROM stg_raw;


-- =============================================================================
--  step 4  clean and type every field
--   codes trimmed and upper-cased (85123a = 85123A), descriptions trimmed with
--   runs of spaces collapsed, '13085.0' -> 13085, blanks -> NULL, country
--   labels mapped to standard names
-- =============================================================================

CREATE TABLE stg_typed ENGINE = InnoDB AS
SELECT r.src_row,
       TRIM(r.invoice)                                                       AS invoice_no,
       UPPER(TRIM(r.stock_code))                                             AS stock_code,
       NULLIF(TRIM(REGEXP_REPLACE(r.description, '[[:space:]]+', ' ')), '') AS description,
       CAST(r.quantity AS SIGNED)                                            AS quantity,
       CAST(r.invoice_date AS DATETIME)                                      AS invoice_date,
       CAST(r.price AS DECIMAL(12,3))                                        AS price,
       CAST(CAST(NULLIF(TRIM(r.customer_id), '') AS DECIMAL(12,1)) AS UNSIGNED) AS customer_id,
       COALESCE(m.country_name, TRIM(TRAILING '\r' FROM r.country))        AS country
FROM stg_raw r
LEFT JOIN stg_country_map m ON m.raw_label = TRIM(TRAILING '\r' FROM r.country);
ALTER TABLE stg_typed ADD PRIMARY KEY (src_row);

SELECT COUNT(*) AS rows_typed FROM stg_typed;


-- =============================================================================
--  step 5  remove rows that are not business data
--   a. the file is two yearly exports appended. the second starts where the
--      dates jump backwards, and it repeats every invoice of 1-9 dec 2010.
--      each invoice is kept from the first export it appears in.
--   b. TEST001 / TEST002 are test transactions.
-- =============================================================================

SELECT MIN(src_row) INTO @second_export_start
FROM (SELECT src_row, invoice_date,
             LAG(invoice_date) OVER (ORDER BY src_row) AS prev_date
      FROM stg_typed) t
WHERE invoice_date < prev_date;

CREATE TABLE stg_rows ENGINE = InnoDB AS
SELECT src_row, invoice_no, stock_code, description, quantity, invoice_date, price, customer_id, country
FROM (SELECT s.*,
             IF(s.src_row >= @second_export_start, 2, 1) AS src_part,
             MIN(IF(s.src_row >= @second_export_start, 2, 1)) OVER (PARTITION BY s.invoice_no) AS first_part
      FROM stg_typed s) t
WHERE src_part = first_part
  AND stock_code NOT IN ('TEST001', 'TEST002');
ALTER TABLE stg_rows ADD PRIMARY KEY (src_row), ADD INDEX ix_rows_invoice (invoice_no), ADD INDEX ix_rows_code (stock_code);

SELECT @second_export_start AS second_export_first_row,
       (SELECT COUNT(*) FROM stg_typed) - (SELECT COUNT(*) FROM stg_rows) AS rows_removed;


-- =============================================================================
--  step 6  classify every document
--   C......                                     -> CREDIT_NOTE
--   A......                                     -> ADJUSTMENT (bad debt)
--   numeric, every line priced 0, no customer   -> STOCK_ADJ (warehouse notes,
--                                                  stored in stock_adjustment)
--   anything else                               -> SALE
-- =============================================================================

CREATE TABLE stg_doc ENGINE = InnoDB AS
SELECT invoice_no,
       CASE
           WHEN invoice_no LIKE 'C%' THEN 'CREDIT_NOTE'
           WHEN invoice_no LIKE 'A%' THEN 'ADJUSTMENT'
           WHEN SUM(price <> 0) = 0 AND MAX(customer_id) IS NULL THEN 'STOCK_ADJ'
           ELSE 'SALE'
       END               AS doc_type,
       MIN(invoice_date) AS invoice_date,
       MAX(customer_id)  AS customer_id,
       MAX(country)      AS country
FROM stg_rows
GROUP BY invoice_no;
ALTER TABLE stg_doc ADD PRIMARY KEY (invoice_no);

SELECT doc_type, COUNT(*) AS documents FROM stg_doc GROUP BY doc_type ORDER BY doc_type;


-- =============================================================================
--  step 7  fill the 3nf tables
-- =============================================================================

-- 7.1 country (every country that appears on a sale, credit note or adjustment)
INSERT INTO country (country_name, iso_code)
SELECT d.country, MAX(m.iso_code)
FROM (SELECT DISTINCT country FROM stg_doc WHERE doc_type <> 'STOCK_ADJ') d
LEFT JOIN stg_country_map m ON m.country_name = d.country
GROUP BY d.country
ORDER BY d.country;

-- 7.2 customer: registered country = the country of the customer's latest invoice
INSERT INTO customer (customer_id, country_id)
SELECT r.customer_id, c.country_id
FROM (SELECT customer_id, country,
             ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY invoice_date DESC, invoice_no DESC) AS rn
      FROM stg_doc
      WHERE customer_id IS NOT NULL) r
JOIN country c ON c.country_name = r.country
WHERE r.rn = 1;

-- 7.3 product
--   name  = the description used most often on priced lines; if a code never had
--           a priced line, its most used upper-case product name; otherwise a
--           placeholder. warehouse notes ("damaged", "?") are never chosen.
--   price = current list price: the price charged most often in the product's
--           last 90 days of sales, registered customers first (guests pay about
--           twice as much); 0.00 if the product was never sold.
CREATE TABLE stg_name ENGINE = InnoDB AS
SELECT stock_code, description
FROM (SELECT stock_code, description,
             ROW_NUMBER() OVER (PARTITION BY stock_code
                                ORDER BY priced DESC, cnt DESC, last_used DESC, description) AS rn
      FROM (SELECT stock_code, description,
                   MAX(price > 0)    AS priced,
                   COUNT(*)          AS cnt,
                   MAX(invoice_date) AS last_used
            FROM stg_rows
            WHERE description IS NOT NULL
            GROUP BY stock_code, description) d
      WHERE priced = 1
         OR (description COLLATE utf8mb4_bin = UPPER(description) AND description REGEXP '[A-Z]{3}')) x
WHERE rn = 1;
ALTER TABLE stg_name ADD PRIMARY KEY (stock_code);

CREATE TABLE stg_price ENGINE = InnoDB AS
WITH sale_lines AS (
    SELECT r.stock_code, r.price, r.invoice_date, r.customer_id
    FROM stg_rows r
    JOIN stg_doc d ON d.invoice_no = r.invoice_no AND d.doc_type = 'SALE'
    WHERE r.price > 0 AND r.quantity > 0
),
recent AS (
    SELECT s.*
    FROM sale_lines s
    JOIN (SELECT stock_code, MAX(invoice_date) AS last_date FROM sale_lines GROUP BY stock_code) l
      ON l.stock_code = s.stock_code
    WHERE s.invoice_date >= l.last_date - INTERVAL 90 DAY
),
ranked AS (
    SELECT stock_code, price,
           ROW_NUMBER() OVER (PARTITION BY stock_code
                              ORDER BY SUM(customer_id IS NOT NULL) DESC, COUNT(*) DESC,
                                       MAX(invoice_date) DESC, price DESC) AS rn
    FROM recent
    GROUP BY stock_code, price
)
SELECT stock_code, price FROM ranked WHERE rn = 1;
ALTER TABLE stg_price ADD PRIMARY KEY (stock_code);

--   type  = SERVICE for charges, fees, discounts and manual or bad-debt lines,
--           VOUCHER for gift vouchers, GOODS for everything else. services have
--           no list price (their amount is set on each invoice line), so 0.00.
INSERT INTO product (stock_code, description, unit_price, product_type)
SELECT c.stock_code,
       LEFT(COALESCE(n.description, CONCAT('UNNAMED ITEM ', c.stock_code)), 100),
       IF(c.product_type = 'SERVICE', 0.00, ROUND(COALESCE(p.price, 0), 2)),
       c.product_type
FROM (SELECT DISTINCT stock_code,
             CASE
                 WHEN stock_code IN ('POST', 'DOT', 'C2', 'C3', 'M', 'D', 'S', 'B', 'BANK CHARGES',
                                     'AMAZONFEE', 'CRUK', 'ADJUST', 'ADJUST2') THEN 'SERVICE'
                 WHEN stock_code LIKE 'GIFT%' THEN 'VOUCHER'
                 ELSE 'GOODS'
             END AS product_type
      FROM stg_rows) c
LEFT JOIN stg_name  n ON n.stock_code = c.stock_code
LEFT JOIN stg_price p ON p.stock_code = c.stock_code;

-- 7.4 inventory (goods only). the csv holds no stock levels, so the opening
--     stock is estimated as the net units sold in the last 90 days of history
--     (about one quarter of cover); reorder level = one average week of that.
CREATE TABLE stg_stock ENGINE = InnoDB AS
SELECT r.stock_code, GREATEST(SUM(r.quantity), 0) AS units_90d
FROM stg_rows r
JOIN stg_doc d ON d.invoice_no = r.invoice_no AND d.doc_type IN ('SALE', 'CREDIT_NOTE')
WHERE r.invoice_date >= (SELECT MAX(invoice_date) FROM stg_rows) - INTERVAL 90 DAY
GROUP BY r.stock_code;
ALTER TABLE stg_stock ADD PRIMARY KEY (stock_code);

INSERT INTO inventory (stock_code, qty_on_hand, reorder_level)
SELECT p.stock_code, COALESCE(s.units_90d, 0), CEIL(COALESCE(s.units_90d, 0) / 13)
FROM product p
LEFT JOIN stg_stock s ON s.stock_code = p.stock_code
WHERE p.product_type = 'GOODS';

-- 7.5 invoice (83 invoices carry two timestamps a minute or more apart: the first is kept)
INSERT INTO invoice (invoice_no, invoice_type, invoice_date, customer_id, country_id, status)
SELECT d.invoice_no, d.doc_type, d.invoice_date, d.customer_id, c.country_id, 'Completed'
FROM stg_doc d
JOIN country c ON c.country_name = d.country
WHERE d.doc_type <> 'STOCK_ADJ';

-- 7.6 invoice_line (line_no = the line's order in the source file)
--     every price is stored >= 0: on the bad-debt lines the minus sign moves from
--     the price to the quantity, so quantity x price keeps its value.
--     the one credit-note line with a positive quantity (C496350) is stored as a
--     return (negative), like every other credit-note line.
INSERT INTO invoice_line (invoice_no, line_no, stock_code, quantity, unit_price)
SELECT r.invoice_no,
       ROW_NUMBER() OVER (PARTITION BY r.invoice_no ORDER BY r.src_row),
       r.stock_code,
       CASE
           WHEN r.price < 0 THEN -r.quantity
           WHEN d.doc_type = 'CREDIT_NOTE' AND r.quantity > 0 THEN -r.quantity
           ELSE r.quantity
       END,
       ABS(r.price)
FROM stg_rows r
JOIN stg_doc d ON d.invoice_no = r.invoice_no
WHERE d.doc_type <> 'STOCK_ADJ';

-- 7.7 stock_adjustment: the warehouse-note documents. reason = the note, or NULL
--     when the field was blank or just repeated the product name.
INSERT INTO stock_adjustment (stock_code, quantity_change, reason, adjusted_at)
SELECT r.stock_code,
       r.quantity,
       CASE WHEN r.description IS NULL OR r.description = p.description THEN NULL
            ELSE LEFT(r.description, 100) END,
       r.invoice_date
FROM stg_rows r
JOIN stg_doc d ON d.invoice_no = r.invoice_no AND d.doc_type = 'STOCK_ADJ'
JOIN product p ON p.stock_code = r.stock_code
ORDER BY r.src_row;


-- =============================================================================
--  step 8  reconcile, then drop the staging tables
-- =============================================================================

SET @csv_rows  = (SELECT COUNT(*) FROM stg_raw);
SET @test_rows = (SELECT COUNT(*) FROM stg_typed WHERE stock_code IN ('TEST001', 'TEST002'));
SET @kept_rows = (SELECT COUNT(*) FROM stg_rows);

SELECT 'csv rows'                         AS item, @csv_rows AS n
UNION ALL SELECT 'repeated dec-2010 rows removed', @csv_rows - @test_rows - @kept_rows
UNION ALL SELECT 'test rows removed',              @test_rows
UNION ALL SELECT 'invoice lines',                  (SELECT COUNT(*) FROM invoice_line)
UNION ALL SELECT 'stock adjustments',              (SELECT COUNT(*) FROM stock_adjustment)
UNION ALL SELECT 'unmapped country labels',        (SELECT COUNT(DISTINCT r.country) FROM stg_raw r
                                                    LEFT JOIN stg_country_map m ON m.raw_label = TRIM(TRAILING '\r' FROM r.country)
                                                    WHERE m.raw_label IS NULL);

SELECT ROUND(SUM(r.quantity * r.price), 2)                            AS source_net_value,
       (SELECT ROUND(SUM(quantity * unit_price), 2) FROM invoice_line) AS database_net_value
FROM stg_rows r
JOIN stg_doc d ON d.invoice_no = r.invoice_no AND d.doc_type <> 'STOCK_ADJ';

SELECT 'country' AS table_name, COUNT(*) AS row_count FROM country
UNION ALL SELECT 'customer',         COUNT(*) FROM customer
UNION ALL SELECT 'product',          COUNT(*) FROM product
UNION ALL SELECT 'inventory',        COUNT(*) FROM inventory
UNION ALL SELECT 'invoice',          COUNT(*) FROM invoice
UNION ALL SELECT 'invoice_line',     COUNT(*) FROM invoice_line
UNION ALL SELECT 'stock_adjustment', COUNT(*) FROM stock_adjustment;

DROP TABLE stg_stock, stg_price, stg_name, stg_doc, stg_rows, stg_typed, stg_raw, stg_country_map;
