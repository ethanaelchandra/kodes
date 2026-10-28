unf

| Invoice | InvoiceDate | Customer ID | Country | StockCode | Description | Quantity | Price |
|---|---|---|---|---|---|---|---|
| 554159 | 2011-05-23 11:48:00 | 12464 | Belgium | POST | POSTAGE | 2 | 15.0 |
|  |  |  |  | 22467 | GUMBALL COAT RACK | 6 | 2.55 |
|  |  |  |  | 22847 | BREAD BIN DINER STYLE IVORY | 3 | 16.95 |
|  |  |  |  | 22846 | BREAD BIN DINER STYLE RED | 3 | 16.95 |
| 564481 | 2011-08-25 13:33:00 | 12464 | Belgium | POST | POSTAGE | 3 | 15.0 |
|  |  |  |  | 22624 | IVORY KITCHEN SCALES | 3 | 8.5 |
|  |  |  |  | 22847 | BREAD BIN DINER STYLE IVORY | 4 | 14.95 |
|  |  |  |  | 22846 | BREAD BIN DINER STYLE RED | 4 | 14.95 |
| 492581 | 2009-12-17 15:02:00 | 15270 | United Kingdom | 85123A | WHITE HANGING HEART T-LIGHT HOLDER | 12 | 2.95 |
|  |  |  |  | 85123A | WHITE HANGING HEART T-LIGHT HOLDER | 32 | 2.55 |
|  |  |  |  | 22188 | BLACK HEART CARD HOLDER | 10 | 3.95 |
|  |  |  |  | 22189 | CREAM HEART CARD HOLDER | 24 | 3.95 |

1nf

| Invoice | LineNo | StockCode | Description | Quantity | InvoiceDate | Price | Customer ID | Country |
|---|---|---|---|---|---|---|---|---|
| 554159 | 1 | POST | POSTAGE | 2 | 2011-05-23 11:48:00 | 15.0 | 12464 | Belgium |
| 554159 | 2 | 22467 | GUMBALL COAT RACK | 6 | 2011-05-23 11:48:00 | 2.55 | 12464 | Belgium |
| 554159 | 3 | 22847 | BREAD BIN DINER STYLE IVORY | 3 | 2011-05-23 11:48:00 | 16.95 | 12464 | Belgium |
| 554159 | 4 | 22846 | BREAD BIN DINER STYLE RED | 3 | 2011-05-23 11:48:00 | 16.95 | 12464 | Belgium |
| 564481 | 1 | POST | POSTAGE | 3 | 2011-08-25 13:33:00 | 15.0 | 12464 | Belgium |
| 564481 | 2 | 22624 | IVORY KITCHEN SCALES | 3 | 2011-08-25 13:33:00 | 8.5 | 12464 | Belgium |
| 564481 | 3 | 22847 | BREAD BIN DINER STYLE IVORY | 4 | 2011-08-25 13:33:00 | 14.95 | 12464 | Belgium |
| 564481 | 4 | 22846 | BREAD BIN DINER STYLE RED | 4 | 2011-08-25 13:33:00 | 14.95 | 12464 | Belgium |
| 492581 | 1 | 85123A | WHITE HANGING HEART T-LIGHT HOLDER | 12 | 2009-12-17 15:02:00 | 2.95 | 15270 | United Kingdom |
| 492581 | 2 | 85123A | WHITE HANGING HEART T-LIGHT HOLDER | 32 | 2009-12-17 15:02:00 | 2.55 | 15270 | United Kingdom |
| 492581 | 3 | 22188 | BLACK HEART CARD HOLDER | 10 | 2009-12-17 15:02:00 | 3.95 | 15270 | United Kingdom |
| 492581 | 4 | 22189 | CREAM HEART CARD HOLDER | 24 | 2009-12-17 15:02:00 | 3.95 | 15270 | United Kingdom |

2nf invoice

| Invoice | InvoiceDate | Customer ID | Country |
|---|---|---|---|
| 554159 | 2011-05-23 11:48:00 | 12464 | Belgium |
| 564481 | 2011-08-25 13:33:00 | 12464 | Belgium |
| 492581 | 2009-12-17 15:02:00 | 15270 | United Kingdom |

2nf invoice_line

| Invoice | LineNo | StockCode | Description | Quantity | Price |
|---|---|---|---|---|---|
| 554159 | 1 | POST | POSTAGE | 2 | 15.0 |
| 554159 | 2 | 22467 | GUMBALL COAT RACK | 6 | 2.55 |
| 554159 | 3 | 22847 | BREAD BIN DINER STYLE IVORY | 3 | 16.95 |
| 554159 | 4 | 22846 | BREAD BIN DINER STYLE RED | 3 | 16.95 |
| 564481 | 1 | POST | POSTAGE | 3 | 15.0 |
| 564481 | 2 | 22624 | IVORY KITCHEN SCALES | 3 | 8.5 |
| 564481 | 3 | 22847 | BREAD BIN DINER STYLE IVORY | 4 | 14.95 |
| 564481 | 4 | 22846 | BREAD BIN DINER STYLE RED | 4 | 14.95 |
| 492581 | 1 | 85123A | WHITE HANGING HEART T-LIGHT HOLDER | 12 | 2.95 |
| 492581 | 2 | 85123A | WHITE HANGING HEART T-LIGHT HOLDER | 32 | 2.55 |
| 492581 | 3 | 22188 | BLACK HEART CARD HOLDER | 10 | 3.95 |
| 492581 | 4 | 22189 | CREAM HEART CARD HOLDER | 24 | 3.95 |

3nf customer

| Customer ID | Country |
|---|---|
| 12464 | Belgium |
| 15270 | United Kingdom |

3nf product

| StockCode | Description |
|---|---|
| POST | POSTAGE |
| 22467 | GUMBALL COAT RACK |
| 22847 | BREAD BIN DINER STYLE IVORY |
| 22846 | BREAD BIN DINER STYLE RED |
| 22624 | IVORY KITCHEN SCALES |
| 85123A | WHITE HANGING HEART T-LIGHT HOLDER |
| 22188 | BLACK HEART CARD HOLDER |
| 22189 | CREAM HEART CARD HOLDER |

3nf invoice

| Invoice | InvoiceDate | Customer ID |
|---|---|---|
| 554159 | 2011-05-23 11:48:00 | 12464 |
| 564481 | 2011-08-25 13:33:00 | 12464 |
| 492581 | 2009-12-17 15:02:00 | 15270 |

3nf invoice_line

| Invoice | LineNo | StockCode | Quantity | Price |
|---|---|---|---|---|
| 554159 | 1 | POST | 2 | 15.0 |
| 554159 | 2 | 22467 | 6 | 2.55 |
| 554159 | 3 | 22847 | 3 | 16.95 |
| 554159 | 4 | 22846 | 3 | 16.95 |
| 564481 | 1 | POST | 3 | 15.0 |
| 564481 | 2 | 22624 | 3 | 8.5 |
| 564481 | 3 | 22847 | 4 | 14.95 |
| 564481 | 4 | 22846 | 4 | 14.95 |
| 492581 | 1 | 85123A | 12 | 2.95 |
| 492581 | 2 | 85123A | 32 | 2.55 |
| 492581 | 3 | 22188 | 10 | 3.95 |
| 492581 | 4 | 22189 | 24 | 3.95 |
