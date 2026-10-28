-- =============================================================================
-- kodes retail | phase 4: advanced features & automation
-- file    : advanced.sql
-- needs   : schema.sql + load_data.sql (queries.sql optional)
-- run     : mysql --default-character-set=utf8mb4 -u root -p kodes_retail < sql/advanced.sql
-- creates : 4 triggers that keep inventory.quantity_on_hand in step with every
--           sale, return, correction and cancellation, and the stored procedure
--           GetCustomerInvoiceHistory(customer_id).
-- notes   : - the triggers are created after the historical import, so the
--             opening stock already reflects history; only new transactions
--             move it from here on.
--           - postage, fees and vouchers have no inventory row, so their lines
--             simply do not touch stock.
--           - an invoice that still has lines cannot be deleted (ON DELETE
--             RESTRICT on invoice_lines): orders are cancelled instead, and
--             trigger 4 returns their goods to stock.
-- =============================================================================

USE kodes_retail;
-- literals and variables use the same collation as the tables
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

DROP TRIGGER   IF EXISTS trg_invoice_lines_after_insert;
DROP TRIGGER   IF EXISTS trg_invoice_lines_after_update;
DROP TRIGGER   IF EXISTS trg_invoice_lines_after_delete;
DROP TRIGGER   IF EXISTS trg_invoices_after_status_change;
DROP PROCEDURE IF EXISTS GetCustomerInvoiceHistory;

DELIMITER $$

-- =============================================================================
-- trigger 1 (the required one): recording a sale or return line updates stock.
--   sale line   (quantity > 0) -> stock goes down
--   return line (quantity < 0) -> stock goes up
-- it also rejects a line whose sign does not match the invoice type, and a sale
-- that would take stock below zero (no overselling).
-- =============================================================================
CREATE TRIGGER trg_invoice_lines_after_insert
AFTER INSERT ON invoice_lines
FOR EACH ROW
BEGIN
    DECLARE v_type   VARCHAR(10);
    DECLARE v_status VARCHAR(10);
    DECLARE v_stock  INT;
    DECLARE v_msg    VARCHAR(255);

    SELECT invoice_type, status
      INTO v_type, v_status
    FROM invoices
    WHERE invoice_no = NEW.invoice_no;

    -- a sale line must be positive, a return line negative
    IF (v_type = 'Sale' AND NEW.quantity < 0) OR (v_type = 'Return' AND NEW.quantity > 0) THEN
        SET v_msg = CONCAT('quantity ', NEW.quantity, ' does not match ',
                           LOWER(v_type), ' invoice ', NEW.invoice_no);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    -- only completed invoices move stock; NULL = item without an inventory row
    IF v_status = 'Completed' THEN
        SET v_stock = (SELECT quantity_on_hand FROM inventory WHERE stock_code = NEW.stock_code);

        IF v_stock IS NOT NULL THEN
            IF v_stock - NEW.quantity < 0 THEN
                SET v_msg = CONCAT('not enough stock for ', NEW.stock_code, ': ',
                                   v_stock, ' on hand, ', NEW.quantity, ' requested');
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
            END IF;

            UPDATE inventory
            SET quantity_on_hand = quantity_on_hand - NEW.quantity
            WHERE stock_code = NEW.stock_code;
        END IF;
    END IF;
END $$

-- =============================================================================
-- trigger 2: a corrected line (new quantity or product) moves the difference.
-- the corrected quantity must still match the invoice type; then the old
-- movement is undone and the new one applied. the CHECK constraint on
-- inventory still blocks any result below zero.
-- =============================================================================
CREATE TRIGGER trg_invoice_lines_after_update
AFTER UPDATE ON invoice_lines
FOR EACH ROW
BEGIN
    DECLARE v_type VARCHAR(10);
    DECLARE v_msg  VARCHAR(255);

    SET v_type = (SELECT invoice_type FROM invoices WHERE invoice_no = NEW.invoice_no);
    IF (v_type = 'Sale' AND NEW.quantity < 0) OR (v_type = 'Return' AND NEW.quantity > 0) THEN
        SET v_msg = CONCAT('quantity ', NEW.quantity, ' does not match ',
                           LOWER(v_type), ' invoice ', NEW.invoice_no);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    IF (SELECT status FROM invoices WHERE invoice_no = OLD.invoice_no) = 'Completed' THEN
        UPDATE inventory
        SET quantity_on_hand = quantity_on_hand + OLD.quantity
        WHERE stock_code = OLD.stock_code;
    END IF;

    IF (SELECT status FROM invoices WHERE invoice_no = NEW.invoice_no) = 'Completed' THEN
        UPDATE inventory
        SET quantity_on_hand = quantity_on_hand - NEW.quantity
        WHERE stock_code = NEW.stock_code;
    END IF;
END $$

-- =============================================================================
-- trigger 3: a line deleted from a completed invoice gives its movement back.
-- =============================================================================
CREATE TRIGGER trg_invoice_lines_after_delete
AFTER DELETE ON invoice_lines
FOR EACH ROW
BEGIN
    IF (SELECT status FROM invoices WHERE invoice_no = OLD.invoice_no) = 'Completed' THEN
        UPDATE inventory
        SET quantity_on_hand = quantity_on_hand + OLD.quantity
        WHERE stock_code = OLD.stock_code;
    END IF;
END $$

-- =============================================================================
-- trigger 4: links query 2 to the stock. cancelling a completed invoice puts
-- its goods back on the shelf (cancelling a return takes them out again);
-- re-activating a cancelled invoice reverses that.
-- =============================================================================
CREATE TRIGGER trg_invoices_after_status_change
AFTER UPDATE ON invoices
FOR EACH ROW
BEGIN
    IF OLD.status = 'Completed' AND NEW.status = 'Cancelled' THEN
        UPDATE inventory AS v
        JOIN (SELECT stock_code, SUM(quantity) AS qty
              FROM invoice_lines
              WHERE invoice_no = NEW.invoice_no
              GROUP BY stock_code) AS l
          ON l.stock_code = v.stock_code
        SET v.quantity_on_hand = v.quantity_on_hand + l.qty;

    ELSEIF OLD.status = 'Cancelled' AND NEW.status = 'Completed' THEN
        UPDATE inventory AS v
        JOIN (SELECT stock_code, SUM(quantity) AS qty
              FROM invoice_lines
              WHERE invoice_no = NEW.invoice_no
              GROUP BY stock_code) AS l
          ON l.stock_code = v.stock_code
        SET v.quantity_on_hand = v.quantity_on_hand - l.qty;
    END IF;
END $$

-- =============================================================================
-- stored procedure: GetCustomerInvoiceHistory
-- input : a customer id
-- output: every invoice of that customer (sales, returns, cancelled ones too)
--         with its date, type, status, number of lines, units and total value,
--         oldest first. an unknown customer id raises an error instead of
--         silently returning nothing.
-- =============================================================================
CREATE PROCEDURE GetCustomerInvoiceHistory(IN p_customer_id INT UNSIGNED)
READS SQL DATA
BEGIN
    DECLARE v_msg VARCHAR(255);

    IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id) THEN
        SET v_msg = CONCAT('customer ', COALESCE(p_customer_id, 'NULL'), ' does not exist');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    SELECT i.invoice_no,
           i.invoice_date,
           i.invoice_type,
           i.status,
           COUNT(l.line_no)                                      AS line_count,
           COALESCE(SUM(l.quantity), 0)                          AS total_quantity,
           ROUND(COALESCE(SUM(l.quantity * l.unit_price), 0), 2) AS total_value
    FROM invoices AS i
    LEFT JOIN invoice_lines AS l ON l.invoice_no = i.invoice_no
    WHERE i.customer_id = p_customer_id
    GROUP BY i.invoice_no, i.invoice_date, i.invoice_type, i.status
    ORDER BY i.invoice_date, i.invoice_no;
END $$

DELIMITER ;


-- =============================================================================
-- demo / tests
-- everything that changes data runs inside one transaction that is rolled back
-- at the end, so this section can be re-run and leaves the database unchanged.
-- demo_try is a throw-away helper that runs a statement and reports whether it
-- was accepted or rejected (with the error message) instead of stopping.
-- =============================================================================

DROP PROCEDURE IF EXISTS demo_try;
DELIMITER $$
CREATE PROCEDURE demo_try(IN p_test VARCHAR(100), IN p_sql TEXT)
BEGIN
    DECLARE v_error TEXT DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        GET DIAGNOSTICS CONDITION 1 v_error = MESSAGE_TEXT;

    SET @demo_sql = p_sql;
    PREPARE demo_stmt FROM @demo_sql;
    EXECUTE demo_stmt;
    DEALLOCATE PREPARE demo_stmt;

    SELECT p_test AS test,
           IF(v_error IS NULL, 'accepted', CONCAT('rejected: ', v_error)) AS result;
END $$
DELIMITER ;

-- test 1: the procedure for an existing customer (12346: one big sale and its return)
CALL GetCustomerInvoiceHistory(12346);

START TRANSACTION;

-- stock before the demo
SELECT 'before' AS moment, stock_code, quantity_on_hand
FROM inventory WHERE stock_code IN ('85123A', '84879') ORDER BY stock_code;

-- test 2: a new sale of 10 x 85123A and 24 x 84879 -> stock goes down
INSERT INTO invoices (invoice_no, customer_id, invoice_type) VALUES ('600001', 12346, 'Sale');
INSERT INTO invoice_lines (invoice_no, line_no, stock_code, quantity, unit_price) VALUES
    ('600001', 1, '85123A', 10, 3.19),
    ('600001', 2, '84879',  24, 1.83),
    ('600001', 3, 'POST',    1, 18.00);   -- postage: no inventory row, stock untouched

SELECT 'after sale' AS moment, stock_code, quantity_on_hand
FROM inventory WHERE stock_code IN ('85123A', '84879') ORDER BY stock_code;

-- test 3: the customer returns 2 x 85123A on a credit note -> stock goes up
INSERT INTO invoices (invoice_no, customer_id, invoice_type) VALUES ('C600002', 12346, 'Return');
INSERT INTO invoice_lines (invoice_no, line_no, stock_code, quantity, unit_price) VALUES
    ('C600002', 1, '85123A', -2, 3.19);

SELECT 'after return' AS moment, stock_code, quantity_on_hand
FROM inventory WHERE stock_code IN ('85123A', '84879') ORDER BY stock_code;

-- test 4: a line correction (24 -> 12 units of 84879) moves only the difference
UPDATE invoice_lines SET quantity = 12 WHERE invoice_no = '600001' AND line_no = 2;

SELECT 'after correction' AS moment, stock_code, quantity_on_hand
FROM inventory WHERE stock_code IN ('85123A', '84879') ORDER BY stock_code;

-- test 5: the sale is cancelled (query 2 style) -> its goods go back on the shelf
UPDATE invoices SET status = 'Cancelled', cancelled_at = NOW() WHERE invoice_no = '600001';

SELECT 'after cancel' AS moment, stock_code, quantity_on_hand
FROM inventory WHERE stock_code IN ('85123A', '84879') ORDER BY stock_code;

-- test 6: the new documents appear in the customer's history
CALL GetCustomerInvoiceHistory(12346);

-- test 7: guard rails
INSERT INTO invoices (invoice_no, customer_id, invoice_type) VALUES ('600003', 12346, 'Sale');
CALL demo_try('oversell 5 x 23843 (0 in stock)',
    "INSERT INTO invoice_lines VALUES ('600003', 1, '23843', 5, 2.08)");
CALL demo_try('negative quantity on a sale invoice',
    "INSERT INTO invoice_lines VALUES ('600003', 2, '85123A', -1, 3.19)");
CALL demo_try('zero quantity (check constraint)',
    "INSERT INTO invoice_lines VALUES ('600003', 3, '85123A', 0, 3.19)");
CALL demo_try('valid sale of 1 x 85123A',
    "INSERT INTO invoice_lines VALUES ('600003', 4, '85123A', 1, 3.19)");
CALL demo_try('sale line corrected to a negative quantity',
    "UPDATE invoice_lines SET quantity = -5 WHERE invoice_no = '600003' AND line_no = 4");
CALL demo_try('delete an invoice that still has lines',
    "DELETE FROM invoices WHERE invoice_no = '600001'");
CALL demo_try('history of an unknown customer',
    "CALL GetCustomerInvoiceHistory(99999)");

ROLLBACK;

-- stock is back to its original values after the rollback
SELECT 'after rollback' AS moment, stock_code, quantity_on_hand
FROM inventory WHERE stock_code IN ('85123A', '84879') ORDER BY stock_code;

DROP PROCEDURE IF EXISTS demo_try;

-- list what this script installed
SELECT trigger_name, action_timing, event_manipulation, event_object_table
FROM information_schema.triggers
WHERE trigger_schema = 'kodes_retail'
ORDER BY event_object_table, trigger_name;

SELECT routine_name, routine_type
FROM information_schema.routines
WHERE routine_schema = 'kodes_retail';
