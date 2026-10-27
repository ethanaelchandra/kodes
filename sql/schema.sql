-- =============================================================================
-- kodes retail | phase 2: database implementation (ddl)
-- file    : schema.sql
-- target  : mysql 8.0.16+ (check constraints are enforced from 8.0.16)
--           also runs on mariadb 10.4+ (xampp): utf8mb4_unicode_ci exists in both
-- run     : mysql -u root -p < sql/schema.sql
-- note    : this script drops and recreates the kodes_retail database
-- =============================================================================

DROP DATABASE IF EXISTS kodes_retail;
CREATE DATABASE kodes_retail
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
USE kodes_retail;

-- -----------------------------------------------------------------------------
-- countries: lookup table, one row per country label.
-- replaces the free-text Country column so a country is stored (and renamed) once.
-- -----------------------------------------------------------------------------
CREATE TABLE countries (
    country_id    SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    country_name  VARCHAR(60)       NOT NULL,

    CONSTRAINT pk_countries      PRIMARY KEY (country_id),
    CONSTRAINT uq_countries_name UNIQUE (country_name),
    CONSTRAINT chk_countries_name CHECK (CHAR_LENGTH(TRIM(country_name)) > 0)
) ENGINE = InnoDB;

-- -----------------------------------------------------------------------------
-- customers: CustomerID -> Country (3nf: country moved out of the invoice).
-- customer_id keeps the original ids (12346-18287). ids 1-15 are guest accounts
-- (one per country) for sales recorded without a customer id. new customers
-- continue from the auto_increment counter (18288+).
-- email/phone are new attributes for contact info (unknown for imported rows).
-- -----------------------------------------------------------------------------
CREATE TABLE customers (
    customer_id  INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    country_id   SMALLINT UNSIGNED NOT NULL,
    is_guest     BOOLEAN           NOT NULL DEFAULT FALSE,
    email        VARCHAR(255)      NULL,
    phone        VARCHAR(20)       NULL,

    CONSTRAINT pk_customers       PRIMARY KEY (customer_id),
    CONSTRAINT uq_customers_email UNIQUE (email),
    CONSTRAINT fk_customers_country FOREIGN KEY (country_id)
        REFERENCES countries (country_id)
        ON UPDATE CASCADE      -- a re-numbered country follows automatically
        ON DELETE RESTRICT,    -- cannot delete a country that still has customers
    CONSTRAINT chk_customers_email CHECK (email IS NULL OR email LIKE '%_@_%._%'),
    CONSTRAINT chk_customers_phone CHECK (phone IS NULL OR phone REGEXP '^[+]?[0-9 ()-]{6,20}$')
) ENGINE = InnoDB;

-- -----------------------------------------------------------------------------
-- products: StockCode -> Description (3nf: description moved out of the line).
-- unit_price is the current list price (what query 1 updates). the price paid
-- on each sale stays in invoice_lines.unit_price, because the same product was
-- sold at many different prices (StockCode does not determine Price).
-- is_stock_item = FALSE for postage, carriage, manual, discount, samples,
-- bank charges, pads and gift vouchers: billable codes with no physical stock.
-- -----------------------------------------------------------------------------
CREATE TABLE products (
    stock_code     VARCHAR(20)   NOT NULL,
    description    VARCHAR(255)  NOT NULL,
    unit_price     DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    is_stock_item  BOOLEAN       NOT NULL DEFAULT TRUE,

    CONSTRAINT pk_products             PRIMARY KEY (stock_code),
    CONSTRAINT chk_products_price      CHECK (unit_price >= 0),
    CONSTRAINT chk_products_description CHECK (CHAR_LENGTH(TRIM(description)) > 0)
) ENGINE = InnoDB;

-- -----------------------------------------------------------------------------
-- inventory: new table (1:0..1 with products) holding stock levels for physical
-- items only. kept apart from products so the busy stock counter is updated
-- without touching the catalogue, and so a warehouse column can be added later.
-- maintained automatically by the triggers in advanced.sql.
-- -----------------------------------------------------------------------------
CREATE TABLE inventory (
    stock_code        VARCHAR(20) NOT NULL,
    quantity_on_hand  INT         NOT NULL DEFAULT 0,
    reorder_level     INT         NOT NULL DEFAULT 0,
    last_updated      DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                  ON UPDATE CURRENT_TIMESTAMP,

    CONSTRAINT pk_inventory PRIMARY KEY (stock_code),
    CONSTRAINT fk_inventory_product FOREIGN KEY (stock_code)
        REFERENCES products (stock_code)
        ON UPDATE CASCADE      -- renamed stock code follows automatically
        ON DELETE CASCADE,     -- a stock row means nothing without its product
    CONSTRAINT chk_inventory_qty     CHECK (quantity_on_hand >= 0),  -- no overselling
    CONSTRAINT chk_inventory_reorder CHECK (reorder_level >= 0)
) ENGINE = InnoDB;

-- -----------------------------------------------------------------------------
-- invoices: Invoice -> InvoiceDate, CustomerID (2nf: header split from lines).
-- invoice_type: 'Sale' for normal invoices, 'Return' for the source's
--   C-prefixed credit notes (negative quantities).
-- status: 'Completed' or 'Cancelled'. cancelling never deletes the invoice or
--   its lines (audit trail); cancelled_at records when it happened.
-- type/status use a binary collation so only the exact spellings are accepted.
-- -----------------------------------------------------------------------------
CREATE TABLE invoices (
    invoice_no    VARCHAR(10)  NOT NULL,
    customer_id   INT UNSIGNED NOT NULL,
    invoice_date  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    invoice_type  VARCHAR(10)  COLLATE utf8mb4_bin NOT NULL DEFAULT 'Sale',
    status        VARCHAR(10)  COLLATE utf8mb4_bin NOT NULL DEFAULT 'Completed',
    cancelled_at  DATETIME     NULL,

    CONSTRAINT pk_invoices PRIMARY KEY (invoice_no),
    CONSTRAINT fk_invoices_customer FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id)
        ON UPDATE CASCADE      -- merged/re-numbered customer follows automatically
        ON DELETE RESTRICT,    -- sales history protects the customer row
    CONSTRAINT chk_invoices_type   CHECK (invoice_type IN ('Sale', 'Return')),
    CONSTRAINT chk_invoices_status CHECK (status IN ('Completed', 'Cancelled')),
    -- cancelled_at is filled exactly when the invoice is cancelled
    CONSTRAINT chk_invoices_cancelled_at CHECK ((status = 'Cancelled') = (cancelled_at IS NOT NULL)),
    CONSTRAINT chk_invoices_cancel_order CHECK (cancelled_at IS NULL OR cancelled_at >= invoice_date)
) ENGINE = InnoDB;

CREATE INDEX idx_invoices_date ON invoices (invoice_date);

-- -----------------------------------------------------------------------------
-- invoice_lines: (invoice_no, line_no) -> stock_code, quantity, unit_price.
-- line_no is needed because the same product can appear on one invoice more
-- than once at different prices, so (invoice_no, stock_code) is not unique.
-- quantity > 0 is a sale, quantity < 0 is a return (credit note line).
-- unit_price has 3 decimals because the source has prices like 0.001.
-- -----------------------------------------------------------------------------
CREATE TABLE invoice_lines (
    invoice_no  VARCHAR(10)       NOT NULL,
    line_no     SMALLINT UNSIGNED NOT NULL,
    stock_code  VARCHAR(20)       NOT NULL,
    quantity    INT               NOT NULL,
    unit_price  DECIMAL(10,3)     NOT NULL,

    CONSTRAINT pk_invoice_lines PRIMARY KEY (invoice_no, line_no),
    CONSTRAINT fk_lines_invoice FOREIGN KEY (invoice_no)
        REFERENCES invoices (invoice_no)
        ON UPDATE CASCADE      -- lines follow a corrected invoice number
        ON DELETE CASCADE,     -- lines cannot exist without their invoice
    CONSTRAINT fk_lines_product FOREIGN KEY (stock_code)
        REFERENCES products (stock_code)
        ON UPDATE CASCADE      -- lines follow a renamed stock code
        ON DELETE RESTRICT,    -- a product with sales history cannot be deleted
    CONSTRAINT chk_lines_line_no  CHECK (line_no >= 1),
    CONSTRAINT chk_lines_quantity CHECK (quantity <> 0),
    CONSTRAINT chk_lines_price    CHECK (unit_price >= 0)
) ENGINE = InnoDB;
