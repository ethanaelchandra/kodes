-- =============================================================================
--  kodes retail store | advanced.sql | phase 4: advanced features & automation
-- -----------------------------------------------------------------------------
--  run after schema.sql (and queries.sql). mysql 8.0.16+ / mariadb 10.4+
--
--  creates
--    trg_invoice_line_before_insert     checks a line before it is recorded
--    trg_invoice_line_after_insert      (required) every sale or return moves the stock
--    trg_invoice_line_before_update     recorded lines are read-only
--    trg_invoice_line_before_delete     recorded lines cannot be deleted
--    trg_invoice_after_update           cancelling an order puts its goods back
--    trg_stock_adjustment_after_insert  warehouse corrections move the stock
--    GetCustomerInvoiceHistory(id)      (required) every invoice of one customer
--
--  the demo at the end runs in one transaction and is rolled back, so the data
--  is left exactly as it was.
-- =============================================================================

USE kodes_retail;
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

DROP TRIGGER   IF EXISTS trg_invoice_line_before_insert;
DROP TRIGGER   IF EXISTS trg_invoice_line_after_insert;
DROP TRIGGER   IF EXISTS trg_invoice_line_before_update;
DROP TRIGGER   IF EXISTS trg_invoice_line_before_delete;
DROP TRIGGER   IF EXISTS trg_invoice_after_update;
DROP TRIGGER   IF EXISTS trg_stock_adjustment_after_insert;
DROP PROCEDURE IF EXISTS GetCustomerInvoiceHistory;
DROP PROCEDURE IF EXISTS demo_expect_error;

DELIMITER $$

-- -----------------------------------------------------------------------------
--  checks before a line is recorded. SIGNAL aborts the INSERT, so a refused
--  line is never saved and the stock is never touched.
--    * no new lines on a cancelled invoice
--    * a sale line needs a positive quantity, a credit-note line a negative one
--    * a sale cannot take a product's stock below zero
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_invoice_line_before_insert
BEFORE INSERT ON invoice_line
FOR EACH ROW
BEGIN
    DECLARE v_type    VARCHAR(12);
    DECLARE v_status  VARCHAR(10);
    DECLARE v_on_hand INT;
    DECLARE v_msg     VARCHAR(200);

    SET v_type   = (SELECT invoice_type FROM invoice WHERE invoice_no = NEW.invoice_no);
    SET v_status = (SELECT status       FROM invoice WHERE invoice_no = NEW.invoice_no);

    IF v_status = 'Cancelled' THEN
        SET v_msg = CONCAT('invoice ', NEW.invoice_no, ' is cancelled, so no lines can be added');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    IF v_type = 'SALE' AND NEW.quantity < 0 THEN
        SET v_msg = CONCAT('a sale line needs a positive quantity (', NEW.quantity, ' given)');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    IF v_type = 'CREDIT_NOTE' AND NEW.quantity > 0 THEN
        SET v_msg = CONCAT('a credit-note line needs a negative quantity (', NEW.quantity, ' given)');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    IF NEW.quantity > 0 THEN
        SET v_on_hand = (SELECT qty_on_hand FROM inventory WHERE stock_code = NEW.stock_code);
        IF v_on_hand IS NOT NULL AND v_on_hand < NEW.quantity THEN
            SET v_msg = CONCAT('not enough stock of ', NEW.stock_code, ': ', v_on_hand,
                               ' on hand, ', NEW.quantity, ' requested');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;
    END IF;
END $$

-- -----------------------------------------------------------------------------
--  required trigger: whenever a sale or a return is recorded, the product's
--  inventory level follows it.
--    sale line         quantity > 0  -> stock goes down by the quantity
--    credit-note line  quantity < 0  -> stock goes up (goods come back)
--  services and vouchers have no inventory row, so nothing changes for them.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_invoice_line_after_insert
AFTER INSERT ON invoice_line
FOR EACH ROW
BEGIN
    UPDATE inventory
    SET    qty_on_hand = qty_on_hand - NEW.quantity
    WHERE  stock_code  = NEW.stock_code;
END $$

-- -----------------------------------------------------------------------------
--  recorded lines are read-only: changing or deleting one would make the stock
--  and the audit trail wrong. corrections go through a cancellation or a
--  credit note instead.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_invoice_line_before_update
BEFORE UPDATE ON invoice_line
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'invoice lines are read-only: cancel the invoice or issue a credit note';
END $$

CREATE TRIGGER trg_invoice_line_before_delete
BEFORE DELETE ON invoice_line
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'invoice lines cannot be deleted: cancel the invoice or issue a credit note';
END $$

-- -----------------------------------------------------------------------------
--  cancelling an invoice (query 2) puts its goods back in stock. if a cancelled
--  invoice is ever re-opened, the goods are taken out again.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_invoice_after_update
AFTER UPDATE ON invoice
FOR EACH ROW
BEGIN
    IF NEW.status <> OLD.status THEN
        UPDATE inventory v
        JOIN  (SELECT stock_code, SUM(quantity) AS qty
               FROM   invoice_line
               WHERE  invoice_no = NEW.invoice_no
               GROUP BY stock_code) l ON l.stock_code = v.stock_code
        SET    v.qty_on_hand = v.qty_on_hand + IF(NEW.status = 'Cancelled', l.qty, -l.qty);
    END IF;
END $$

-- -----------------------------------------------------------------------------
--  a warehouse correction (damaged, lost, found, counted) moves the stock.
--  the CHECK on inventory still stops the stock from going below zero.
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_stock_adjustment_after_insert
AFTER INSERT ON stock_adjustment
FOR EACH ROW
BEGIN
    UPDATE inventory
    SET    qty_on_hand = qty_on_hand + NEW.quantity_change
    WHERE  stock_code  = NEW.stock_code;
END $$

-- -----------------------------------------------------------------------------
--  required stored procedure: every invoice of one customer (sales, credit
--  notes and cancelled orders) with its date, status and total value. an
--  unknown customer id raises an error instead of an empty list.
-- -----------------------------------------------------------------------------
CREATE PROCEDURE GetCustomerInvoiceHistory(IN p_customer_id INT UNSIGNED)
BEGIN
    DECLARE v_msg VARCHAR(200);

    IF NOT EXISTS (SELECT 1 FROM customer WHERE customer_id = p_customer_id) THEN
        SET v_msg = CONCAT('customer ', COALESCE(p_customer_id, 'NULL'), ' does not exist');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    SELECT i.invoice_no,
           i.invoice_date,
           i.invoice_type,
           i.status,
           co.country_name                                       AS country,
           COUNT(l.line_no)                                      AS line_count,
           COALESCE(SUM(l.quantity), 0)                          AS total_units,
           ROUND(COALESCE(SUM(l.quantity * l.unit_price), 0), 2) AS total_value
    FROM   invoice i
    JOIN   country co ON co.country_id = i.country_id
    LEFT JOIN invoice_line l ON l.invoice_no = i.invoice_no
    WHERE  i.customer_id = p_customer_id
    GROUP BY i.invoice_no, i.invoice_date, i.invoice_type, i.status, co.country_name
    ORDER BY i.invoice_date, i.invoice_no;
END $$

-- -----------------------------------------------------------------------------
--  demo helper (dropped at the end): runs one statement that should be refused
--  and reports the message, so every guard can be shown without stopping the
--  script.
-- -----------------------------------------------------------------------------
CREATE PROCEDURE demo_expect_error(IN p_test VARCHAR(100), IN p_sql TEXT)
BEGIN
    DECLARE v_msg TEXT DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;

    SET @demo_sql = p_sql;
    PREPARE demo_stmt FROM @demo_sql;
    EXECUTE demo_stmt;
    DEALLOCATE PREPARE demo_stmt;

    SELECT p_test                                            AS test,
           IF(v_msg IS NULL, 'accepted (unexpected)', 'refused') AS result,
           v_msg                                             AS message;
END $$

DELIMITER ;


-- =============================================================================
--  demo: one transaction, rolled back at the end
-- =============================================================================
START TRANSACTION;

-- d1. stock before
SELECT stock_code, qty_on_hand AS stock_before
FROM   inventory
WHERE  stock_code IN ('85123A', '22423')
ORDER BY stock_code;

-- d2. sale: invoice 581588, 12 x 85123A and 2 x 22423 for customer 12680 (france)
INSERT INTO invoice (invoice_no, invoice_type, invoice_date, customer_id, country_id)
SELECT '581588', 'SALE', NOW(), 12680, country_id FROM country WHERE country_name = 'France';

INSERT INTO invoice_line (invoice_no, line_no, stock_code, quantity, unit_price)
SELECT '581588', 1, stock_code, 12, unit_price FROM product WHERE stock_code = '85123A'
UNION ALL
SELECT '581588', 2, stock_code, 2, unit_price FROM product WHERE stock_code = '22423';

SELECT stock_code, qty_on_hand AS after_sale
FROM   inventory WHERE stock_code IN ('85123A', '22423') ORDER BY stock_code;

-- d3. return: credit note C581589, the customer sends back 3 x 85123A
INSERT INTO invoice (invoice_no, invoice_type, invoice_date, customer_id, country_id)
SELECT 'C581589', 'CREDIT_NOTE', NOW(), 12680, country_id FROM country WHERE country_name = 'France';

INSERT INTO invoice_line (invoice_no, line_no, stock_code, quantity, unit_price)
SELECT 'C581589', 1, stock_code, -3, unit_price FROM product WHERE stock_code = '85123A';

SELECT stock_code, qty_on_hand AS after_return
FROM   inventory WHERE stock_code IN ('85123A', '22423') ORDER BY stock_code;

-- d4. cancellation: a second order, 581590 for 5 x 22423, is cancelled
INSERT INTO invoice (invoice_no, invoice_type, invoice_date, customer_id, country_id)
SELECT '581590', 'SALE', NOW(), 12680, country_id FROM country WHERE country_name = 'France';

INSERT INTO invoice_line (invoice_no, line_no, stock_code, quantity, unit_price)
SELECT '581590', 1, stock_code, 5, unit_price FROM product WHERE stock_code = '22423';

SELECT stock_code, qty_on_hand AS after_second_order
FROM   inventory WHERE stock_code IN ('85123A', '22423') ORDER BY stock_code;

UPDATE invoice
SET    status = 'Cancelled', cancelled_at = NOW(), cancel_reason = 'demo: customer changed their mind'
WHERE  invoice_no = '581590';

SELECT stock_code, qty_on_hand AS after_cancellation
FROM   inventory WHERE stock_code IN ('85123A', '22423') ORDER BY stock_code;

-- d5. stock adjustment: 2 x 22423 found damaged in the warehouse
INSERT INTO stock_adjustment (stock_code, quantity_change, reason)
VALUES ('22423', -2, 'damaged');

SELECT stock_code, qty_on_hand AS after_adjustment
FROM   inventory WHERE stock_code IN ('85123A', '22423') ORDER BY stock_code;

-- d6. the stored procedure: customer 12680's full invoice history
CALL GetCustomerInvoiceHistory(12680);

-- d7. the guards: each statement below must be refused
CALL demo_expect_error('sale larger than the stock',
     'INSERT INTO invoice_line VALUES (''581588'', 3, ''22423'', 999999, 12.75)');
CALL demo_expect_error('line on a cancelled invoice',
     'INSERT INTO invoice_line VALUES (''581590'', 2, ''85123A'', 1, 2.95)');
CALL demo_expect_error('negative quantity on a sale',
     'INSERT INTO invoice_line VALUES (''581588'', 3, ''85123A'', -1, 2.95)');
CALL demo_expect_error('positive quantity on a credit note',
     'INSERT INTO invoice_line VALUES (''C581589'', 2, ''85123A'', 1, 2.95)');
CALL demo_expect_error('editing a recorded line',
     'UPDATE invoice_line SET quantity = 1 WHERE invoice_no = ''581587'' AND line_no = 1');
CALL demo_expect_error('deleting a recorded line',
     'DELETE FROM invoice_line WHERE invoice_no = ''581587'' AND line_no = 1');
CALL demo_expect_error('deleting an invoice that has lines',
     'DELETE FROM invoice WHERE invoice_no = ''581587''');
CALL demo_expect_error('adjustment taking stock below zero',
     'INSERT INTO stock_adjustment (stock_code, quantity_change, reason) VALUES (''23843'', -1, ''lost'')');
CALL demo_expect_error('lower-case stock code',
     'INSERT INTO product (stock_code, description) VALUES (''99999x'', ''TEST ITEM'')');
CALL demo_expect_error('negative list price',
     'INSERT INTO product (stock_code, description, unit_price) VALUES (''99999X'', ''TEST ITEM'', -1.00)');
CALL demo_expect_error('credit-note number on a sale',
     'INSERT INTO invoice (invoice_no, invoice_type, country_id) VALUES (''C999999'', ''SALE'', 1)');
CALL demo_expect_error('cancelling a credit note',
     'UPDATE invoice SET status = ''Cancelled'', cancelled_at = NOW() WHERE invoice_no = ''C581589''');
CALL demo_expect_error('malformed e-mail address',
     'INSERT INTO customer (country_id, email) VALUES (1, ''not-an-email'')');
CALL demo_expect_error('history of an unknown customer',
     'CALL GetCustomerInvoiceHistory(99999)');

ROLLBACK;

-- d8. after the rollback the stock is back where it started
SELECT stock_code, qty_on_hand AS stock_after_rollback
FROM   inventory
WHERE  stock_code IN ('85123A', '22423')
ORDER BY stock_code;

DROP PROCEDURE IF EXISTS demo_expect_error;
