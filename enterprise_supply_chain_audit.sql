-- ============================================================
-- PROJECT: Enterprise Supply Chain Risk & Financial Forensic Audit System
-- Author:  [Your Name] | Inspired by Deloitte Advisory Practice
-- DBMS:    PostgreSQL 15+
-- Version: 1.0.0
-- ============================================================
-- SCENARIO:
--   A global manufacturing conglomerate engaged Deloitte to conduct
--   a forensic audit of its procurement-to-payment (P2P) cycle after
--   internal controls flagged unusual vendor activity. This system
--   models the full analytical layer used during that engagement.
-- ============================================================


-- ============================================================
-- SECTION 1: DATABASE SCHEMA & ARCHITECTURE
-- ============================================================

-- Drop tables in reverse dependency order for clean re-runs
DROP TABLE IF EXISTS Audit_Trail       CASCADE;
DROP TABLE IF EXISTS Risk_Scores       CASCADE;
DROP TABLE IF EXISTS Payments          CASCADE;
DROP TABLE IF EXISTS Invoices          CASCADE;
DROP TABLE IF EXISTS Inventory_Log     CASCADE;
DROP TABLE IF EXISTS Purchase_Orders   CASCADE;
DROP TABLE IF EXISTS Suppliers         CASCADE;


-- ------------------------------------------------------------
-- TABLE 1: Suppliers
-- Master vendor registry with geo-risk and compliance metadata
-- ------------------------------------------------------------
CREATE TABLE Suppliers (
    supplier_id         SERIAL          PRIMARY KEY,
    supplier_name       VARCHAR(150)    NOT NULL,
    country_code        CHAR(2)         NOT NULL,
    tax_id              VARCHAR(30)     UNIQUE NOT NULL,
    contact_email       VARCHAR(100),
    registration_date   DATE            NOT NULL DEFAULT CURRENT_DATE,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    tier                VARCHAR(10)     NOT NULL DEFAULT 'STANDARD'
                            CHECK (tier IN ('STRATEGIC','PREFERRED','STANDARD','PROBATION')),
    annual_spend_limit  NUMERIC(15,2)   NOT NULL CHECK (annual_spend_limit > 0),
    high_risk_flag      BOOLEAN         NOT NULL DEFAULT FALSE,

    CONSTRAINT chk_country_code CHECK (country_code ~ '^[A-Z]{2}$')
);

COMMENT ON TABLE  Suppliers IS 'Master vendor registry. High-risk flags are set by the sanctions screening job nightly.';
COMMENT ON COLUMN Suppliers.high_risk_flag IS 'TRUE if supplier is in OFAC/FATF high-risk jurisdiction or failed KYC checks.';


-- ------------------------------------------------------------
-- TABLE 2: Purchase_Orders
-- Authorized procurement commitments raised by internal buyers
-- ------------------------------------------------------------
CREATE TABLE Purchase_Orders (
    po_id               SERIAL          PRIMARY KEY,
    supplier_id         INT             NOT NULL REFERENCES Suppliers(supplier_id) ON DELETE RESTRICT,
    buyer_employee_id   VARCHAR(20)     NOT NULL,
    po_date             TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    delivery_due_date   DATE,
    total_po_amount     NUMERIC(15,2)   NOT NULL CHECK (total_po_amount > 0),
    currency            CHAR(3)         NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
    status              VARCHAR(20)     NOT NULL DEFAULT 'OPEN'
                            CHECK (status IN ('DRAFT','OPEN','PARTIALLY_INVOICED','CLOSED','CANCELLED')),
    department          VARCHAR(60)     NOT NULL,
    notes               TEXT,

    CONSTRAINT chk_delivery_after_po CHECK (delivery_due_date IS NULL OR delivery_due_date >= po_date::DATE)
);

COMMENT ON TABLE Purchase_Orders IS 'Every payment must trace back to an approved PO — three-way match requirement.';


-- ------------------------------------------------------------
-- TABLE 3: Invoices
-- Vendor-submitted payment claims against a Purchase Order
-- ------------------------------------------------------------
CREATE TABLE Invoices (
    invoice_id          SERIAL          PRIMARY KEY,
    po_id               INT             NOT NULL REFERENCES Purchase_Orders(po_id) ON DELETE RESTRICT,
    supplier_id         INT             NOT NULL REFERENCES Suppliers(supplier_id),
    invoice_number      VARCHAR(50)     NOT NULL,
    invoice_date        TIMESTAMP       NOT NULL,
    received_date       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    invoice_amount      NUMERIC(15,2)   NOT NULL CHECK (invoice_amount > 0),
    currency            CHAR(3)         NOT NULL DEFAULT 'USD',
    status              VARCHAR(20)     NOT NULL DEFAULT 'PENDING'
                            CHECK (status IN ('PENDING','APPROVED','REJECTED','PAID','DUPLICATE_FLAGGED')),
    description         TEXT,
    gl_account_code     VARCHAR(20),

    CONSTRAINT uq_invoice_number_supplier UNIQUE (invoice_number, supplier_id)
);

COMMENT ON COLUMN Invoices.invoice_amount IS 'FORENSIC ALERT: Amount exceeding linked PO total_po_amount signals overbilling.';


-- ------------------------------------------------------------
-- TABLE 4: Payments
-- Actual disbursements made against approved invoices
-- ------------------------------------------------------------
CREATE TABLE Payments (
    payment_id          SERIAL          PRIMARY KEY,
    invoice_id          INT             NOT NULL REFERENCES Invoices(invoice_id) ON DELETE RESTRICT,
    payment_date        TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    amount_paid         NUMERIC(15,2)   NOT NULL CHECK (amount_paid > 0),
    payment_method      VARCHAR(30)     NOT NULL
                            CHECK (payment_method IN ('ACH','WIRE','CHECK','CARD','CRYPTO')),
    bank_account_ref    VARCHAR(50),
    initiated_by        VARCHAR(50)     NOT NULL,
    approved_by         VARCHAR(50),
    reconciled          BOOLEAN         NOT NULL DEFAULT FALSE,

    CONSTRAINT chk_approved_not_self CHECK (initiated_by <> approved_by)
);

COMMENT ON TABLE  Payments IS 'Dual-control enforced: initiator and approver must be different employees.';
COMMENT ON COLUMN Payments.bank_account_ref IS 'Hashed/masked account number. Changes between payments to same supplier are a red flag.';


-- ------------------------------------------------------------
-- TABLE 5: Inventory_Log
-- Goods-received notes (GRN) — the physical leg of three-way match
-- ------------------------------------------------------------
CREATE TABLE Inventory_Log (
    log_id              SERIAL          PRIMARY KEY,
    po_id               INT             NOT NULL REFERENCES Purchase_Orders(po_id),
    received_date       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    item_description    VARCHAR(200)    NOT NULL,
    quantity_ordered    NUMERIC(12,3)   NOT NULL CHECK (quantity_ordered > 0),
    quantity_received   NUMERIC(12,3)   NOT NULL CHECK (quantity_received >= 0),
    unit_cost           NUMERIC(15,4)   NOT NULL CHECK (unit_cost >= 0),
    warehouse_location  VARCHAR(50),
    received_by         VARCHAR(50)     NOT NULL,
    discrepancy_flag    BOOLEAN         NOT NULL DEFAULT FALSE,

    CONSTRAINT chk_qty_received_not_exceed CHECK (quantity_received <= quantity_ordered * 1.05) -- 5% tolerance
);

COMMENT ON COLUMN Inventory_Log.discrepancy_flag IS 'Set TRUE when quantity_received deviates >5% from quantity_ordered.';


-- ------------------------------------------------------------
-- TABLE 6: Risk_Scores
-- Computed vendor risk ratings refreshed by analytical batch job
-- ------------------------------------------------------------
CREATE TABLE Risk_Scores (
    score_id            SERIAL          PRIMARY KEY,
    supplier_id         INT             NOT NULL REFERENCES Suppliers(supplier_id),
    score_date          DATE            NOT NULL DEFAULT CURRENT_DATE,
    overall_score       NUMERIC(5,2)    NOT NULL CHECK (overall_score BETWEEN 0 AND 100),
    geo_political_risk  NUMERIC(5,2)    CHECK (geo_political_risk BETWEEN 0 AND 100),
    financial_risk      NUMERIC(5,2)    CHECK (financial_risk BETWEEN 0 AND 100),
    compliance_risk     NUMERIC(5,2)    CHECK (compliance_risk BETWEEN 0 AND 100),
    concentration_risk  NUMERIC(5,2)    CHECK (concentration_risk BETWEEN 0 AND 100),
    risk_band           VARCHAR(10)     NOT NULL
                            CHECK (risk_band IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    computed_by         VARCHAR(50)     NOT NULL DEFAULT 'RISK_ENGINE_v2',
    notes               TEXT,

    CONSTRAINT uq_supplier_score_date UNIQUE (supplier_id, score_date)
);


-- ------------------------------------------------------------
-- TABLE 7: Audit_Trail
-- Immutable system-of-record for all data changes & flags
-- This table is APPEND-ONLY — no UPDATEs or DELETEs permitted
-- ------------------------------------------------------------
CREATE TABLE Audit_Trail (
    audit_id            BIGSERIAL       PRIMARY KEY,
    event_timestamp     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    table_name          VARCHAR(60)     NOT NULL,
    record_id           INT             NOT NULL,
    event_type          VARCHAR(20)     NOT NULL
                            CHECK (event_type IN ('INSERT','UPDATE','DELETE','FLAG','ALERT','REVIEW')),
    changed_by          VARCHAR(50)     NOT NULL,
    old_value           JSONB,
    new_value           JSONB,
    flag_reason         VARCHAR(200),
    severity            VARCHAR(10)     DEFAULT 'INFO'
                            CHECK (severity IN ('INFO','WARNING','HIGH','CRITICAL')),
    reviewed            BOOLEAN         NOT NULL DEFAULT FALSE,
    reviewer_id         VARCHAR(50)
);

COMMENT ON TABLE Audit_Trail IS 'Forensic-grade immutable log. Enforce append-only via row-level security in production.';


-- ============================================================
-- PERFORMANCE INDEXES
-- ============================================================

-- High-traffic FK lookups
CREATE INDEX idx_po_supplier          ON Purchase_Orders(supplier_id);
CREATE INDEX idx_invoices_po          ON Invoices(po_id);
CREATE INDEX idx_invoices_supplier    ON Invoices(supplier_id);
CREATE INDEX idx_payments_invoice     ON Payments(invoice_id);
CREATE INDEX idx_inventory_po         ON Inventory_Log(po_id);
CREATE INDEX idx_risk_supplier_date   ON Risk_Scores(supplier_id, score_date DESC);

-- Forensic query patterns
CREATE INDEX idx_invoices_date_amount ON Invoices(invoice_date, invoice_amount);
CREATE INDEX idx_payments_date        ON Payments(payment_date);
CREATE INDEX idx_audit_table_record   ON Audit_Trail(table_name, record_id);
CREATE INDEX idx_audit_severity       ON Audit_Trail(severity) WHERE severity IN ('HIGH','CRITICAL');

-- Composite index for three-way match queries
CREATE INDEX idx_invoices_status_po   ON Invoices(status, po_id);


-- ============================================================
-- SECTION 2: SYNTHETIC DATA (WITH EMBEDDED FORENSIC ANOMALIES)
-- ============================================================
-- ANOMALIES BAKED IN:
--   [A1] Supplier 5 (Meridian Gulf LLC) — high-risk country code 'IR'
--   [A2] Supplier 7 (Vantage Shell Co.) — split-PO structuring below approval threshold
--   [A3] Invoice 8 & 9 — duplicate invoice amounts from same supplier within 90 minutes
--   [A4] Invoice 11 — amount exceeds its linked PO total (overbilling)
--   [A5] Payment 6 & 7 — same invoice paid twice (double-payment)
--   [A6] Supplier 3 — bank account ref changes between Payment 3 and Payment 4
-- ============================================================

-- ---- Suppliers ----
INSERT INTO Suppliers (supplier_name, country_code, tax_id, contact_email, registration_date, tier, annual_spend_limit, high_risk_flag) VALUES
('Apex Industrial Supplies Ltd.',  'US', 'US-47291-EIN', 'ap@apexind.com',       '2019-03-15', 'STRATEGIC',  5000000.00, FALSE),
('BlueStar Components GmbH',       'DE', 'DE-811234567', 'finance@bluestar.de',   '2020-07-01', 'PREFERRED',  2500000.00, FALSE),
('Nexus Logistics Pte. Ltd.',      'SG', 'SG-201923451', 'ar@nexuslog.sg',        '2021-01-20', 'PREFERRED',  1800000.00, FALSE),
('OmniParts Co.',                  'IN', 'IN-GSTIN9988', 'billing@omniparts.in',  '2018-11-05', 'STANDARD',    750000.00, FALSE),
('Meridian Gulf LLC',              'IR', 'IR-000447821', 'contact@meridgulf.net', '2022-06-30', 'PROBATION',   300000.00, TRUE),  -- [A1] OFAC-watch jurisdiction
('Dynamo Tech Korea',              'KR', 'KR-2109-8874', 'acc@dynamotech.kr',     '2020-03-12', 'PREFERRED',  1200000.00, FALSE),
('Vantage Shell Co.',              'PA', 'PA-77654321X', 'ops@vantageshell.com',  '2023-02-14', 'STANDARD',    500000.00, FALSE),  -- [A2] Shell company suspect
('Pacific Raw Materials Inc.',     'AU', 'AU-ABN199234', 'invoices@pacraw.au',    '2017-09-09', 'STRATEGIC',  4000000.00, FALSE),
('EuroTrade Supplies S.A.',        'FR', 'FR-89234567',  'finance@eurotrade.fr',  '2019-05-22', 'PREFERRED',  2000000.00, FALSE),
('Global Freight Partners LLC',    'AE', 'AE-0045-9912', 'gfp@gfp-ae.com',       '2021-08-17', 'STANDARD',    900000.00, FALSE);


-- ---- Purchase_Orders ----
INSERT INTO Purchase_Orders (supplier_id, buyer_employee_id, po_date, delivery_due_date, total_po_amount, currency, status, department) VALUES
(1,  'EMP-1042', '2024-01-10 09:00:00', '2024-02-10', 485000.00, 'USD', 'CLOSED',             'Manufacturing'),
(2,  'EMP-2211', '2024-01-15 11:30:00', '2024-03-01', 210000.00, 'USD', 'CLOSED',             'Engineering'),
(3,  'EMP-1042', '2024-02-01 08:45:00', '2024-03-15', 95000.00,  'USD', 'PARTIALLY_INVOICED', 'Logistics'),
(4,  'EMP-3301', '2024-02-12 14:00:00', '2024-04-01', 58000.00,  'USD', 'OPEN',               'Procurement'),
(5,  'EMP-2211', '2024-03-01 10:15:00', '2024-04-15', 47500.00,  'USD', 'OPEN',               'Operations'),   -- [A1] PO to high-risk supplier
(7,  'EMP-4455', '2024-03-05 09:00:00', '2024-04-20', 24900.00,  'USD', 'OPEN',               'IT'),           -- [A2] Just below $25K approval threshold
(7,  'EMP-4455', '2024-03-05 09:45:00', '2024-04-20', 24800.00,  'USD', 'OPEN',               'IT'),           -- [A2] Split PO same day, same buyer
(6,  'EMP-1099', '2024-03-10 13:00:00', '2024-05-01', 320000.00, 'USD', 'PARTIALLY_INVOICED', 'Manufacturing'),
(8,  'EMP-2211', '2024-03-18 08:00:00', '2024-05-20', 780000.00, 'USD', 'PARTIALLY_INVOICED', 'Procurement'),
(9,  'EMP-3301', '2024-04-02 11:00:00', '2024-06-01', 155000.00, 'USD', 'OPEN',               'Engineering'),
(1,  'EMP-1042', '2024-04-10 09:30:00', '2024-06-30', 120000.00, 'USD', 'OPEN',               'Manufacturing'),
(10, 'EMP-2211', '2024-04-15 14:30:00', '2024-07-01', 67500.00,  'USD', 'OPEN',               'Logistics');


-- ---- Invoices ----
INSERT INTO Invoices (po_id, supplier_id, invoice_number, invoice_date, received_date, invoice_amount, currency, status, description, gl_account_code) VALUES
(1,  1,  'APEX-2024-001',  '2024-01-25 10:00:00', '2024-01-26 08:30:00', 485000.00, 'USD', 'PAID',             'Full delivery — industrial components batch Q1',         '5100-MFG'),
(2,  2,  'BS-INV-0441',    '2024-02-01 09:00:00', '2024-02-02 11:00:00', 210000.00, 'USD', 'PAID',             'Engineering parts shipment Feb 2024',                    '5200-ENG'),
(3,  3,  'NX-2024-0089',   '2024-02-20 14:00:00', '2024-02-21 09:00:00', 47500.00,  'USD', 'PAID',             'Freight and logistics services Q1',                      '6300-LOG'),
(3,  3,  'NX-2024-0090',   '2024-03-10 11:00:00', '2024-03-11 08:45:00', 47500.00,  'USD', 'APPROVED',         'Logistics services — second tranche',                    '6300-LOG'),
(4,  4,  'OP-INV-2024-33', '2024-03-01 08:00:00', '2024-03-02 09:00:00', 57800.00,  'USD', 'APPROVED',         'OmniParts standard components order',                    '5100-MFG'),
(5,  5,  'MG-0012',        '2024-03-15 10:30:00', '2024-03-16 08:00:00', 47500.00,  'USD', 'PENDING',          'Gulf region specialty materials',                        '5400-OPS'),  -- [A1]
(8,  6,  'DYN-KR-20240310','2024-03-28 09:00:00', '2024-03-29 10:15:00', 160000.00, 'USD', 'APPROVED',         'Dynamo Tech — semiconductor components batch 1',         '5100-MFG'),
(9,  8,  'PAC-2024-0221',  '2024-04-01 11:00:00', '2024-04-02 09:30:00', 390000.00, 'USD', 'APPROVED',         'Raw materials — iron ore concentrate, first tranche',    '5000-RAW'),
(9,  8,  'PAC-2024-0221',  '2024-04-01 12:28:00', '2024-04-02 10:05:00', 390000.00, 'USD', 'DUPLICATE_FLAGGED','Raw materials — iron ore concentrate, first tranche',    '5000-RAW'), -- [A3] Duplicate: same invoice# + amount, <90 min apart
(11, 1,  'APEX-2024-009',  '2024-04-12 09:00:00', '2024-04-13 08:00:00', 118500.00, 'USD', 'APPROVED',         'Q2 manufacturing components',                            '5100-MFG'),
(11, 1,  'APEX-2024-010',  '2024-04-14 10:00:00', '2024-04-15 09:00:00', 135000.00, 'USD', 'PENDING',          'Q2 supplemental parts order',                            '5100-MFG'), -- [A4] Inv 10 + Inv 11 = $253,500 vs PO $120,000 — OVERBILLING
(12, 10, 'GFP-1104',       '2024-04-20 13:00:00', '2024-04-21 08:30:00', 67500.00,  'USD', 'APPROVED',         'Global Freight Q2 shipping services',                    '6300-LOG');


-- ---- Payments ----
INSERT INTO Payments (invoice_id, payment_date, amount_paid, payment_method, bank_account_ref, initiated_by, approved_by, reconciled) VALUES
(1,  '2024-02-05 10:30:00', 485000.00, 'WIRE',  'ACCT-APEX-7712',  'EMP-2055', 'EMP-3301', TRUE),
(2,  '2024-02-15 09:00:00', 210000.00, 'ACH',   'ACCT-BLST-4421',  'EMP-1042', 'EMP-2211', TRUE),
(3,  '2024-03-01 11:00:00', 47500.00,  'ACH',   'ACCT-NX-0089',    'EMP-2055', 'EMP-4455', TRUE),
(4,  '2024-04-01 14:00:00', 47500.00,  'ACH',   'ACCT-NX-8844',    'EMP-2055', 'EMP-1099', FALSE), -- [A6] Bank account ref changed vs Payment 3
(5,  '2024-04-10 09:30:00', 57800.00,  'CHECK', 'ACCT-OP-1122',    'EMP-3301', 'EMP-2211', FALSE),
(8,  '2024-04-20 10:00:00', 390000.00, 'WIRE',  'ACCT-PAC-5533',   'EMP-1042', 'EMP-3301', FALSE),
(8,  '2024-04-20 11:45:00', 390000.00, 'WIRE',  'ACCT-PAC-5533',   'EMP-4455', 'EMP-1099', FALSE), -- [A5] Double payment: same invoice within 2 hours
(7,  '2024-04-22 09:00:00', 160000.00, 'WIRE',  'ACCT-DYN-9901',   'EMP-2055', 'EMP-3301', FALSE),
(10, '2024-04-25 10:00:00', 118500.00, 'ACH',   'ACCT-APEX-7712',  'EMP-1042', 'EMP-2211', FALSE),
(12, '2024-04-28 13:30:00', 67500.00,  'ACH',   'ACCT-GFP-6600',   'EMP-3301', 'EMP-4455', FALSE);


-- ---- Inventory_Log ----
INSERT INTO Inventory_Log (po_id, received_date, item_description, quantity_ordered, quantity_received, unit_cost, warehouse_location, received_by, discrepancy_flag) VALUES
(1,  '2024-02-08 08:00:00', 'Industrial Grade Steel Bolts M12',     5000.000, 4990.000,  48.50,  'WH-A1', 'RECV-101', FALSE),
(1,  '2024-02-08 08:00:00', 'Heavy-duty Welding Rods 6013',         2000.000, 2000.000,  15.25,  'WH-A1', 'RECV-101', FALSE),
(2,  '2024-02-28 10:30:00', 'PCB Motherboard Assembly v4.2',          200.000,  195.000, 850.00,  'WH-B3', 'RECV-204', TRUE),  -- 5 units short
(3,  '2024-03-12 09:00:00', 'Freight Container Service 20FT',         10.000,   10.000, 4750.00, 'WH-EXT','RECV-307', FALSE),
(4,  '2024-03-28 14:00:00', 'Precision Machined Gear Sets',          400.000,  400.000, 144.50,  'WH-C2', 'RECV-101', FALSE),
(8,  '2024-04-15 08:30:00', 'Samsung MCU Chip K4B4G1646E',         12000.000,11850.000,  13.34,  'WH-B3', 'RECV-204', TRUE),  -- 150 chips short
(9,  '2024-05-01 07:00:00', 'Iron Ore Concentrate 62% Fe',           800.000,  800.000, 487.50,  'WH-D1', 'RECV-415', FALSE),
(11, '2024-05-10 09:00:00', 'CNC Machined Aluminium Brackets',       600.000,  580.000, 197.50,  'WH-A1', 'RECV-101', TRUE),  -- [A4] Goods received but PO already over-invoiced
(12, '2024-05-05 13:00:00', 'Sea Freight — FCL 40HQ Container',        5.000,    5.000,13500.00, 'WH-EXT','RECV-307', FALSE),
(6,  '2024-04-20 11:00:00', 'Gulf Specialty Alloy — Grade 304',      100.000,   98.000, 475.00,  'WH-A2', 'RECV-101', FALSE);


-- ---- Risk_Scores ----
INSERT INTO Risk_Scores (supplier_id, score_date, overall_score, geo_political_risk, financial_risk, compliance_risk, concentration_risk, risk_band, notes) VALUES
(1,  '2024-04-30', 18.50, 5.00,  22.00, 12.00, 35.00, 'LOW',      'Long-standing strategic partner; clean audit history'),
(2,  '2024-04-30', 21.00, 8.00,  18.00, 15.00, 43.00, 'LOW',      'EU-regulated; strong financial covenants'),
(3,  '2024-04-30', 38.00, 15.00, 35.00, 42.00, 60.00, 'MEDIUM',   'Bank account change detected — pending verification'),
(4,  '2024-04-30', 31.00, 10.00, 28.00, 25.00, 61.00, 'MEDIUM',   'Delivery discrepancies in 2 of last 5 POs'),
(5,  '2024-04-30', 91.00, 98.00, 85.00, 95.00, 72.00, 'CRITICAL', 'OFAC watch-list jurisdiction; KYC failed; escalate immediately'),
(6,  '2024-04-30', 24.00, 12.00, 20.00, 18.00, 47.00, 'LOW',      'Preferred Korean partner; strong delivery record'),
(7,  '2024-04-30', 72.00, 55.00, 78.00, 82.00, 40.00, 'HIGH',     'Panama jurisdiction; PO structuring pattern detected; shell entity suspected'),
(8,  '2024-04-30', 19.00, 8.00,  15.00, 12.00, 42.00, 'LOW',      'Tier-1 Australian supplier; audited externally'),
(9,  '2024-04-30', 26.00, 10.00, 22.00, 20.00, 53.00, 'MEDIUM',   'Within normal parameters; monitor freight cost volatility'),
(10, '2024-04-30', 44.00, 35.00, 40.00, 38.00, 65.00, 'MEDIUM',   'UAE base; elevated geo-political score due to regional tensions');


-- ---- Audit_Trail ----
INSERT INTO Audit_Trail (event_timestamp, table_name, record_id, event_type, changed_by, new_value, flag_reason, severity) VALUES
('2024-03-16 08:05:00', 'Invoices',       6,  'FLAG',   'RISK_ENGINE_v2', '{"status":"PENDING","supplier_id":5}',     'Invoice from OFAC-jurisdiction supplier IR — mandatory compliance hold',       'CRITICAL'),
('2024-04-02 10:06:00', 'Invoices',       9,  'FLAG',   'DEDUP_JOB_v3',   '{"invoice_number":"PAC-2024-0221"}',       'Duplicate invoice number + amount from same supplier within 90 minutes',      'HIGH'),
('2024-04-01 15:00:00', 'Payments',       4,  'ALERT',  'FRAUD_MONITOR',  '{"old_acct":"ACCT-NX-0089","new_acct":"ACCT-NX-8844"}', 'Supplier bank account changed between consecutive payments — verify', 'HIGH'),
('2024-04-20 11:50:00', 'Payments',       7,  'FLAG',   'DEDUP_JOB_v3',   '{"invoice_id":8,"amount":390000.00}',      'Double-payment: invoice_id=8 paid twice within 105 minutes',                 'CRITICAL'),
('2024-04-15 09:05:00', 'Invoices',       11, 'ALERT',  'THREE_WAY_MATCH','{"po_total":120000,"invoiced_to_date":253500}', 'Cumulative invoice amount exceeds PO value by $133,500 — overbilling',  'CRITICAL'),
('2024-03-05 10:00:00', 'Purchase_Orders',7,  'FLAG',   'RISK_ENGINE_v2', '{"po_ids":[6,7],"buyer":"EMP-4455","supplier_id":7}', 'PO structuring: two POs to same shell vendor same day below $25K threshold', 'HIGH'),
('2024-04-30 23:00:00', 'Risk_Scores',    5,  'INSERT', 'RISK_ENGINE_v2', '{"overall_score":91.0,"risk_band":"CRITICAL"}', 'Automated risk score refresh — supplier 5 escalated to CRITICAL',         'CRITICAL'),
('2024-04-01 14:05:00', 'Invoices',       4,  'UPDATE', 'EMP-2055',       '{"status":"APPROVED"}',                    NULL,                                                                          'INFO'),
('2024-04-22 08:30:00', 'Invoices',       8,  'REVIEW', 'EMP-AUDIT-01',   '{"reviewed":true}',                        'Manual review of double-payment — recovery initiated',                        'HIGH'),
('2024-04-25 09:00:00', 'Suppliers',      7,  'FLAG',   'KYC_SYSTEM',     '{"tax_id":"PA-77654321X","tier":"STANDARD"}','Beneficial ownership verification failed for Panama entity',                'CRITICAL');


-- ============================================================
-- SECTION 3: ADVANCED ANALYTICAL QUERIES
-- ============================================================


-- ============================================================
-- QUERY 1: FULL FORENSIC AUDIT TRAIL RECONSTRUCTION
-- Purpose : Reconstruct the complete P2P lifecycle for every
--           payment, joining 5 tables to surface all risk signals
--           in a single row. A Deloitte forensic analyst would
--           run this first to triage the entire population.
-- ============================================================
SELECT
    p.payment_id,
    p.payment_date,
    s.supplier_id,
    s.supplier_name,
    s.country_code,
    s.tier                                          AS supplier_tier,
    s.high_risk_flag,
    rs.risk_band,
    rs.overall_score                                AS supplier_risk_score,
    po.po_id,
    po.buyer_employee_id,
    po.total_po_amount                              AS po_authorized_amount,
    po.department,
    i.invoice_id,
    i.invoice_number,
    i.invoice_amount,
    p.amount_paid,
    p.payment_method,
    p.bank_account_ref,
    p.initiated_by,
    p.approved_by,
    p.reconciled,

    -- Overbilling signal: invoice amount vs authorized PO
    ROUND(((i.invoice_amount - po.total_po_amount) / po.total_po_amount) * 100, 2)
                                                    AS pct_over_po_limit,

    -- Segregation-of-duties check
    CASE WHEN p.initiated_by = p.approved_by
         THEN 'SOD_VIOLATION'
         ELSE 'OK'
    END                                             AS sod_check,

    -- Consolidated risk label
    CASE
        WHEN s.high_risk_flag = TRUE                        THEN 'GEOPOLITICAL_RISK'
        WHEN i.invoice_amount > po.total_po_amount          THEN 'OVERBILLING'
        WHEN i.status = 'DUPLICATE_FLAGGED'                 THEN 'DUPLICATE_INVOICE'
        WHEN rs.risk_band IN ('HIGH','CRITICAL')            THEN 'VENDOR_RISK'
        ELSE 'CLEAR'
    END                                             AS forensic_flag,

    -- Count of audit events for this payment
    (SELECT COUNT(*) FROM Audit_Trail at2
     WHERE at2.table_name = 'Payments' AND at2.record_id = p.payment_id)
                                                    AS audit_event_count

FROM Payments             p
JOIN Invoices             i   ON p.invoice_id    = i.invoice_id
JOIN Purchase_Orders      po  ON i.po_id         = po.po_id
JOIN Suppliers            s   ON po.supplier_id  = s.supplier_id
LEFT JOIN Risk_Scores     rs  ON s.supplier_id   = rs.supplier_id
                             AND rs.score_date   = (
                                 SELECT MAX(score_date)
                                 FROM Risk_Scores rs2
                                 WHERE rs2.supplier_id = s.supplier_id
                             )
ORDER BY
    CASE rs.risk_band
        WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2
        WHEN 'MEDIUM'   THEN 3 ELSE 4
    END,
    p.payment_date DESC;


-- ============================================================
-- QUERY 2: DUPLICATE PAYMENT & RAPID CONSECUTIVE PAYMENT DETECTION
-- Purpose : Use LAG() window function to compute the time gap
--           between consecutive payments per invoice. Flags any
--           payment made within 24 hours of a prior payment for
--           the same invoice — a primary double-payment indicator.
-- ============================================================
WITH payment_timeline AS (
    SELECT
        p.payment_id,
        p.invoice_id,
        i.invoice_number,
        s.supplier_name,
        p.payment_date,
        p.amount_paid,
        p.initiated_by,
        p.approved_by,

        -- Prior payment timestamp for the same invoice
        LAG(p.payment_date) OVER (
            PARTITION BY p.invoice_id
            ORDER BY p.payment_date
        )                                           AS prev_payment_date,

        -- Prior payment amount for the same invoice
        LAG(p.amount_paid) OVER (
            PARTITION BY p.invoice_id
            ORDER BY p.payment_date
        )                                           AS prev_payment_amount,

        -- Running total paid per invoice
        SUM(p.amount_paid) OVER (
            PARTITION BY p.invoice_id
            ORDER BY p.payment_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                           AS cumulative_paid,

        -- Row number to identify repeat payments
        ROW_NUMBER() OVER (
            PARTITION BY p.invoice_id
            ORDER BY p.payment_date
        )                                           AS payment_sequence

    FROM Payments   p
    JOIN Invoices   i ON p.invoice_id  = i.invoice_id
    JOIN Purchase_Orders po ON i.po_id = po.po_id
    JOIN Suppliers  s ON po.supplier_id= s.supplier_id
),
flagged_payments AS (
    SELECT
        *,
        -- Time gap in hours between this payment and the prior one
        ROUND(
            EXTRACT(EPOCH FROM (payment_date - prev_payment_date)) / 3600.0,
            2
        )                                           AS hours_since_prev_payment,

        -- Flag if this is a repeat payment within 24 hours
        CASE
            WHEN prev_payment_date IS NOT NULL
             AND EXTRACT(EPOCH FROM (payment_date - prev_payment_date)) < 86400
             AND amount_paid = prev_payment_amount  THEN 'DUPLICATE_PAYMENT'
            WHEN prev_payment_date IS NOT NULL
             AND EXTRACT(EPOCH FROM (payment_date - prev_payment_date)) < 86400
                                                    THEN 'RAPID_REPEAT_PAYMENT'
            WHEN payment_sequence > 1               THEN 'MULTIPLE_PAYMENTS'
            ELSE 'NORMAL'
        END                                         AS payment_anomaly_type

    FROM payment_timeline
)
SELECT
    payment_id,
    invoice_id,
    invoice_number,
    supplier_name,
    payment_date,
    amount_paid,
    prev_payment_date,
    prev_payment_amount,
    hours_since_prev_payment,
    cumulative_paid,
    payment_sequence,
    payment_anomaly_type,
    initiated_by,
    approved_by
FROM flagged_payments
WHERE payment_anomaly_type <> 'NORMAL'
   OR payment_sequence      > 1
ORDER BY invoice_id, payment_date;


-- ============================================================
-- QUERY 3: PO STRUCTURING ANALYSIS (BENFORD'S LAW PROXY)
-- Purpose : Detect "invoice/PO structuring" — a fraud technique
--           where amounts are deliberately kept below approval
--           thresholds. Uses DENSE_RANK to rank suppliers by
--           transaction frequency at suspicious amount bands,
--           combined with same-day PO clustering detection.
-- ============================================================
WITH approval_thresholds AS (
    -- Define your organization's approval tier limits
    SELECT 10000  AS tier_1_max   -- Manager approval
    UNION ALL
    SELECT 25000  AS tier_2_max   -- Director approval
    UNION ALL
    SELECT 100000 AS tier_3_max   -- VP approval
),
po_with_bands AS (
    SELECT
        po.po_id,
        po.supplier_id,
        s.supplier_name,
        s.country_code,
        po.buyer_employee_id,
        po.po_date,
        po.total_po_amount,
        po.department,

        -- Assign threshold band
        CASE
            WHEN po.total_po_amount < 10000  THEN 'BAND_1_UNDER_10K'
            WHEN po.total_po_amount < 25000  THEN 'BAND_2_UNDER_25K'   -- Most sensitive
            WHEN po.total_po_amount < 100000 THEN 'BAND_3_UNDER_100K'
            ELSE                                  'BAND_4_OVER_100K'
        END                                         AS threshold_band,

        -- Count POs from same buyer to same supplier on the same calendar day
        COUNT(po.po_id) OVER (
            PARTITION BY po.supplier_id, po.buyer_employee_id, po.po_date::DATE
        )                                           AS same_day_po_count,

        -- Cumulative spend to same supplier per buyer in rolling 30 days
        SUM(po.total_po_amount) OVER (
            PARTITION BY po.supplier_id, po.buyer_employee_id
            ORDER BY po.po_date
            RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW
        )                                           AS rolling_30d_spend

    FROM Purchase_Orders po
    JOIN Suppliers s ON po.supplier_id = s.supplier_id
    WHERE po.status <> 'CANCELLED'
),
ranked_structuring AS (
    SELECT
        *,
        -- Rank suppliers by number of sub-threshold POs (highest = most suspicious)
        DENSE_RANK() OVER (
            ORDER BY
                SUM(CASE WHEN threshold_band = 'BAND_2_UNDER_25K' THEN 1 ELSE 0 END)
                    OVER (PARTITION BY supplier_id) DESC
        )                                           AS structuring_risk_rank

    FROM po_with_bands
)
SELECT
    supplier_id,
    supplier_name,
    country_code,
    buyer_employee_id,
    po_id,
    po_date,
    total_po_amount,
    threshold_band,
    same_day_po_count,
    ROUND(rolling_30d_spend, 2)                     AS rolling_30d_spend_usd,
    structuring_risk_rank,

    CASE
        WHEN same_day_po_count   >= 2
         AND threshold_band       = 'BAND_2_UNDER_25K'  THEN 'HIGH — SAME-DAY STRUCTURING'
        WHEN rolling_30d_spend   > 100000
         AND threshold_band      IN ('BAND_1_UNDER_10K',
                                     'BAND_2_UNDER_25K') THEN 'MEDIUM — VOLUME STRUCTURING'
        WHEN structuring_risk_rank <= 3               THEN 'MEDIUM — PATTERN RISK'
        ELSE 'LOW'
    END                                             AS structuring_alert

FROM ranked_structuring
ORDER BY structuring_risk_rank, same_day_po_count DESC, po_date;


-- ============================================================
-- QUERY 4: THREE-WAY MATCH EXCEPTION REPORT
-- Purpose : The P2P three-way match control validates that
--           (1) a valid PO exists, (2) goods were actually
--           received (GRN), and (3) the invoice matches both.
--           This query surfaces all exceptions across that
--           control framework, weighted by financial exposure.
-- ============================================================
WITH invoice_totals AS (
    -- Sum all invoices per PO to detect cumulative overbilling
    SELECT
        po_id,
        COUNT(*)                                    AS invoice_count,
        SUM(invoice_amount)                         AS total_invoiced,
        SUM(CASE WHEN status = 'DUPLICATE_FLAGGED'
                 THEN 1 ELSE 0 END)                 AS duplicate_count,
        SUM(CASE WHEN status = 'PENDING'
                 THEN invoice_amount ELSE 0 END)    AS pending_amount
    FROM Invoices
    GROUP BY po_id
),
grn_totals AS (
    -- Sum goods received value per PO
    SELECT
        po_id,
        SUM(quantity_received * unit_cost)          AS grn_value,
        SUM(quantity_ordered  * unit_cost)          AS ordered_value,
        MAX(CASE WHEN discrepancy_flag THEN 1 ELSE 0 END) AS has_grn_discrepancy
    FROM Inventory_Log
    GROUP BY po_id
),
three_way_match AS (
    SELECT
        po.po_id,
        s.supplier_name,
        s.high_risk_flag,
        po.buyer_employee_id,
        po.total_po_amount,
        po.department,
        po.status                                   AS po_status,

        COALESCE(it.total_invoiced,    0)           AS total_invoiced,
        COALESCE(it.invoice_count,     0)           AS invoice_count,
        COALESCE(it.duplicate_count,   0)           AS duplicate_invoice_count,
        COALESCE(it.pending_amount,    0)           AS pending_approval_amount,
        COALESCE(g.grn_value,          0)           AS goods_received_value,
        COALESCE(g.ordered_value,      0)           AS goods_ordered_value,
        COALESCE(g.has_grn_discrepancy,0)           AS has_grn_discrepancy,

        -- Financial exposure calculations
        COALESCE(it.total_invoiced, 0) - po.total_po_amount
                                                    AS overbill_exposure,
        COALESCE(g.ordered_value, 0) - COALESCE(g.grn_value, 0)
                                                    AS grn_shortfall_value

    FROM Purchase_Orders  po
    JOIN Suppliers         s  ON po.supplier_id = s.supplier_id
    LEFT JOIN invoice_totals  it ON po.po_id    = it.po_id
    LEFT JOIN grn_totals      g  ON po.po_id    = g.po_id
)
SELECT
    po_id,
    supplier_name,
    department,
    po_status,
    total_po_amount,
    total_invoiced,
    goods_received_value,
    ROUND(overbill_exposure,    2)                  AS overbill_exposure_usd,
    ROUND(grn_shortfall_value,  2)                  AS grn_shortfall_usd,
    duplicate_invoice_count,
    has_grn_discrepancy,
    high_risk_flag,

    -- Composite match status
    CASE
        WHEN overbill_exposure     > 0              THEN 'FAIL — OVERBILLED'
        WHEN duplicate_invoice_count > 0            THEN 'FAIL — DUPLICATE INV'
        WHEN goods_received_value  = 0
         AND total_invoiced        > 0              THEN 'FAIL — NO GRN ON FILE'
        WHEN has_grn_discrepancy   = 1              THEN 'WARN — GRN DISCREPANCY'
        WHEN total_invoiced        = 0              THEN 'WARN — NO INVOICE YET'
        ELSE                                             'PASS'
    END                                             AS three_way_match_status,

    -- Financial exposure tier
    CASE
        WHEN ABS(overbill_exposure) > 100000        THEN 'TIER_1_MATERIAL'
        WHEN ABS(overbill_exposure) > 10000         THEN 'TIER_2_SIGNIFICANT'
        WHEN ABS(overbill_exposure) > 0             THEN 'TIER_3_MINOR'
        ELSE                                             'NO_EXPOSURE'
    END                                             AS exposure_tier

FROM three_way_match
ORDER BY
    CASE three_way_match_status
        WHEN 'FAIL — OVERBILLED'      THEN 1
        WHEN 'FAIL — DUPLICATE INV'   THEN 2
        WHEN 'FAIL — NO GRN ON FILE'  THEN 3
        WHEN 'WARN — GRN DISCREPANCY' THEN 4
        ELSE 5
    END,
    ABS(overbill_exposure) DESC;


-- ============================================================
-- QUERY 5: VENDOR RISK HEAT MAP WITH DYNAMIC SCORING
-- Purpose : Build a comprehensive risk dashboard score for every
--           active supplier, combining geo-political risk, spend
--           concentration, invoice anomalies, and payment behavior.
--           Demonstrates multi-CTE chaining for layered logic.
-- ============================================================
WITH supplier_spend AS (
    -- Aggregate actual spend per supplier
    SELECT
        s.supplier_id,
        s.supplier_name,
        s.country_code,
        s.tier,
        s.high_risk_flag,
        s.annual_spend_limit,
        COUNT(DISTINCT po.po_id)                    AS total_pos,
        SUM(po.total_po_amount)                     AS total_committed,
        COUNT(DISTINCT i.invoice_id)                AS total_invoices,
        SUM(i.invoice_amount)                       AS total_invoiced,
        SUM(p.amount_paid)                          AS total_paid

    FROM Suppliers         s
    LEFT JOIN Purchase_Orders po ON s.supplier_id = po.supplier_id
    LEFT JOIN Invoices         i  ON po.po_id      = i.po_id
    LEFT JOIN Payments         p  ON i.invoice_id  = p.invoice_id
    WHERE s.is_active = TRUE
    GROUP BY s.supplier_id, s.supplier_name, s.country_code,
             s.tier, s.high_risk_flag, s.annual_spend_limit
),
invoice_anomalies AS (
    -- Count anomalies per supplier
    SELECT
        s.supplier_id,
        COUNT(CASE WHEN i.status = 'DUPLICATE_FLAGGED' THEN 1 END) AS duplicate_invoices,
        COUNT(CASE WHEN i.invoice_amount > po.total_po_amount THEN 1 END) AS overbilled_pos,
        COUNT(CASE WHEN at2.severity = 'CRITICAL' THEN 1 END)       AS critical_audit_events
    FROM Suppliers       s
    LEFT JOIN Purchase_Orders po ON s.supplier_id = po.supplier_id
    LEFT JOIN Invoices         i  ON po.po_id      = i.po_id
    LEFT JOIN Audit_Trail   at2   ON at2.table_name = 'Invoices'
                                 AND at2.record_id  = i.invoice_id
    GROUP BY s.supplier_id
),
latest_risk AS (
    -- Pull latest automated risk score
    SELECT DISTINCT ON (supplier_id)
        supplier_id,
        overall_score,
        geo_political_risk,
        financial_risk,
        compliance_risk,
        risk_band
    FROM Risk_Scores
    ORDER BY supplier_id, score_date DESC
),
composite_scoring AS (
    SELECT
        ss.supplier_id,
        ss.supplier_name,
        ss.country_code,
        ss.tier,
        ss.high_risk_flag,
        ss.annual_spend_limit,
        ss.total_committed,
        ss.total_paid,
        ss.total_invoices,
        ia.duplicate_invoices,
        ia.overbilled_pos,
        ia.critical_audit_events,
        lr.overall_score                            AS system_risk_score,
        lr.risk_band,

        -- Spend utilisation vs limit
        ROUND((COALESCE(ss.total_committed,0) / ss.annual_spend_limit) * 100, 1)
                                                    AS spend_utilisation_pct,

        -- Weighted composite risk score (0–100)
        ROUND(
            COALESCE(lr.overall_score,        0) * 0.40 +   -- System score (40%)
            (CASE WHEN ss.high_risk_flag THEN 30 ELSE 0 END) + -- Geo flag (30 pts hard)
            LEAST(ia.duplicate_invoices  * 8,  25)         + -- Duplicate invoices (up to 25)
            LEAST(ia.overbilled_pos      * 10, 20)         + -- Overbilling instances (up to 20)
            LEAST(ia.critical_audit_events*5,  15)           -- Critical audit events (up to 15)
        , 2)                                        AS composite_risk_score

    FROM supplier_spend      ss
    LEFT JOIN invoice_anomalies ia ON ss.supplier_id = ia.supplier_id
    LEFT JOIN latest_risk       lr ON ss.supplier_id = lr.supplier_id
)
SELECT
    supplier_id,
    supplier_name,
    country_code,
    tier,
    high_risk_flag,
    risk_band                                       AS system_risk_band,
    system_risk_score,
    composite_risk_score,
    spend_utilisation_pct,
    total_committed,
    total_paid,
    annual_spend_limit,
    duplicate_invoices,
    overbilled_pos,
    critical_audit_events,

    -- Final risk classification based on composite score
    CASE
        WHEN composite_risk_score >= 75 THEN 'CRITICAL — IMMEDIATE ACTION'
        WHEN composite_risk_score >= 50 THEN 'HIGH — ESCALATE TO MANAGER'
        WHEN composite_risk_score >= 30 THEN 'MEDIUM — ENHANCED MONITORING'
        ELSE                                 'LOW — STANDARD CONTROLS'
    END                                             AS deloitte_risk_verdict,

    -- Recommended action
    CASE
        WHEN high_risk_flag = TRUE          THEN 'Suspend payments; escalate to Legal & Compliance'
        WHEN overbilled_pos  > 0            THEN 'Initiate invoice dispute; hold further payments'
        WHEN duplicate_invoices > 0         THEN 'Recovery review; update AP controls'
        WHEN spend_utilisation_pct > 90     THEN 'Spend limit review required'
        ELSE                                     'Continue monitoring'
    END                                             AS recommended_action

FROM composite_scoring
ORDER BY composite_risk_score DESC;


-- ============================================================
-- QUERY 6: CRITICAL AUDIT TRAIL SUMMARY — OPEN ITEMS TRACKER
-- Purpose : Surface all unreviewed HIGH/CRITICAL audit events,
--           enriched with supplier context and days outstanding.
--           This mimics the "open findings" register in a
--           Deloitte Management Audit Report.
-- ============================================================
WITH open_findings AS (
    SELECT
        at2.audit_id,
        at2.event_timestamp,
        at2.table_name,
        at2.record_id,
        at2.event_type,
        at2.flag_reason,
        at2.severity,
        at2.changed_by,
        at2.reviewed,

        -- Days since the finding was raised
        EXTRACT(DAY FROM NOW() - at2.event_timestamp)
                                                    AS days_outstanding,

        -- Try to retrieve supplier context via table linkage
        CASE at2.table_name
            WHEN 'Suppliers'       THEN s1.supplier_name
            WHEN 'Purchase_Orders' THEN s2.supplier_name
            WHEN 'Invoices'        THEN s3.supplier_name
            WHEN 'Payments'        THEN s4.supplier_name
            ELSE 'N/A'
        END                                         AS linked_supplier,

        CASE at2.table_name
            WHEN 'Suppliers'       THEN s1.country_code
            WHEN 'Purchase_Orders' THEN s2.country_code
            WHEN 'Invoices'        THEN s3.country_code
            WHEN 'Payments'        THEN s4.country_code
            ELSE 'N/A'
        END                                         AS supplier_country,

        -- Escalation priority based on age + severity
        DENSE_RANK() OVER (
            ORDER BY
                CASE at2.severity
                    WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 ELSE 3
                END,
                at2.event_timestamp ASC   -- Oldest findings ranked first
        )                                           AS escalation_priority_rank

    FROM Audit_Trail at2

    -- Left-join each possible source table to resolve supplier context
    LEFT JOIN Suppliers         s1 ON at2.table_name = 'Suppliers'
                                  AND at2.record_id  = s1.supplier_id
    LEFT JOIN Purchase_Orders   po ON at2.table_name = 'Purchase_Orders'
                                  AND at2.record_id  = po.po_id
    LEFT JOIN Suppliers         s2 ON po.supplier_id = s2.supplier_id
    LEFT JOIN Invoices           i  ON at2.table_name = 'Invoices'
                                  AND at2.record_id  = i.invoice_id
    LEFT JOIN Purchase_Orders  po2  ON i.po_id        = po2.po_id
    LEFT JOIN Suppliers         s3  ON po2.supplier_id = s3.supplier_id
    LEFT JOIN Payments          py  ON at2.table_name = 'Payments'
                                  AND at2.record_id  = py.payment_id
    LEFT JOIN Invoices          i2  ON py.invoice_id  = i2.invoice_id
    LEFT JOIN Purchase_Orders  po3  ON i2.po_id       = po3.po_id
    LEFT JOIN Suppliers         s4  ON po3.supplier_id= s4.supplier_id

    WHERE at2.severity IN ('HIGH','CRITICAL')
      AND at2.reviewed = FALSE
)
SELECT
    escalation_priority_rank                        AS priority,
    audit_id,
    TO_CHAR(event_timestamp, 'YYYY-MM-DD HH24:MI') AS flagged_at,
    days_outstanding,
    severity,
    table_name                                      AS source_table,
    record_id,
    event_type,
    linked_supplier,
    supplier_country,
    flag_reason,
    changed_by                                      AS flagged_by,

    -- SLA breach indicator (CRITICAL >3 days, HIGH >7 days)
    CASE
        WHEN severity = 'CRITICAL' AND days_outstanding > 3  THEN 'SLA_BREACHED'
        WHEN severity = 'HIGH'     AND days_outstanding > 7  THEN 'SLA_BREACHED'
        ELSE                                                       'WITHIN_SLA'
    END                                             AS sla_status

FROM open_findings
ORDER BY
    escalation_priority_rank,
    days_outstanding DESC;


-- ============================================================
-- SECTION 4: PERFORMANCE OPTIMIZATION NOTES
-- ============================================================
-- The following index strategy is recommended for production
-- deployment. Analyze with EXPLAIN ANALYZE after loading real
-- data volumes (>100K rows per table).
-- ============================================================

/*
INDEXING STRATEGY SUMMARY
==========================

TABLE: Invoices
  -- Most frequently joined and filtered table in all audit queries
  CREATE INDEX CONCURRENTLY idx_inv_supplier_status
      ON Invoices(supplier_id, status);
  -- Covers: forensic trail join + status filters in audit queries

  CREATE INDEX CONCURRENTLY idx_inv_date_amount
      ON Invoices(invoice_date, invoice_amount);
  -- Covers: duplicate detection window (Query 2) — time + amount filter

TABLE: Payments
  CREATE INDEX CONCURRENTLY idx_pay_invoice_date
      ON Payments(invoice_id, payment_date);
  -- Covers: LAG/LEAD window partitioned by invoice_id (Query 2)

TABLE: Purchase_Orders
  CREATE INDEX CONCURRENTLY idx_po_supplier_buyer_date
      ON Purchase_Orders(supplier_id, buyer_employee_id, po_date);
  -- Composite index for structuring detection (Query 3)
  -- Avoids full table scan when partitioning by supplier+buyer+day

TABLE: Audit_Trail
  CREATE INDEX CONCURRENTLY idx_audit_severity_reviewed
      ON Audit_Trail(severity, reviewed)
      WHERE severity IN ('HIGH','CRITICAL') AND reviewed = FALSE;
  -- Partial index — dramatically speeds up open-findings query (Query 6)
  -- Partial indexes are powerful when a large % of rows are reviewed=TRUE

TABLE: Risk_Scores
  CREATE INDEX CONCURRENTLY idx_risk_supplier_date
      ON Risk_Scores(supplier_id, score_date DESC);
  -- Supports DISTINCT ON(supplier_id) ORDER BY score_date DESC in CTE

GENERAL RECOMMENDATIONS
=======================
1. PARTITION Audit_Trail by event_timestamp (monthly) once it exceeds
   5M rows — it is an append-only log and partitions pruning is free.

2. CREATE MATERIALIZED VIEW mv_supplier_risk_dashboard AS [Query 5]
   WITH DATA;
   REFRESH MATERIALIZED VIEW CONCURRENTLY mv_supplier_risk_dashboard;
   -- Refresh nightly via pg_cron; front-end dashboards query the MV
   -- instead of running the multi-CTE live, reducing latency ~95%.

3. Use pg_stat_statements to identify slow queries after production
   ingestion and tune with EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON).

4. CLUSTER Invoices ON idx_inv_date_amount after initial bulk load —
   physically reorders heap pages to match the index, improving
   sequential scan performance on date-range audit queries.
*/
