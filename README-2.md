# Enterprise Supply Chain Risk & Financial Forensic Audit System
### A Production-Grade SQL Portfolio Project | Deloitte Advisory Practice Scenario

---

## Executive Summary

> A global manufacturing conglomerate engaged an advisory team to conduct a forensic audit of its **Procure-to-Pay (P2P)** cycle after internal controls flagged unusual vendor activity. This repository models the complete analytical layer built during that engagement — from relational schema design through advanced forensic SQL queries used to surface financial fraud, vendor risk, and internal control failures.

This project demonstrates mastery of:
- **Relational schema design** with referential integrity and business rule constraints
- **Forensic data engineering** — embedding and detecting real-world anomalies
- **Advanced SQL analytics** — window functions, multi-CTE chaining, composite scoring
- **Performance engineering** — indexing strategy, materialized views, partitioning

---

## Table of Contents

1. [Scenario & Business Context](#scenario)
2. [Schema Architecture](#schema)
3. [Embedded Forensic Anomalies](#anomalies)
4. [Analytical Queries](#queries)
5. [Performance Optimization](#performance)
6. [How to Run](#run)

---

## 1. Scenario & Business Context <a name="scenario"></a>

**Client:** Global manufacturing conglomerate (Fortune 500)
**Engagement Type:** Forensic Financial Audit — Procurement-to-Payment Cycle
**Regulatory Context:** SOX Section 404, FCPA Compliance, OFAC Sanctions Screening

The advisory team was tasked with answering four core questions:

| # | Business Question | SQL Technique Used |
|---|---|---|
| 1 | Are any vendors operating in OFAC/FATF sanctioned jurisdictions? | Multi-table joins + `CASE` risk flags |
| 2 | Are invoices being duplicated or payments doubled? | `LAG()` window function, time-delta analysis |
| 3 | Are buyers structuring POs to avoid approval thresholds? | `DENSE_RANK()`, rolling sum windows |
| 4 | Do invoices, POs, and goods receipts all match (Three-Way Match)? | Multi-CTE aggregation + exception scoring |

---

## 2. Schema Architecture <a name="schema"></a>

### Entity Relationship Overview

```
Suppliers ──────────────────────────────────────────┐
    │                                               │
    │ 1:N                                           │ 1:N
    ▼                                               ▼
Purchase_Orders ──── 1:N ──── Invoices ──── 1:N ── Payments
    │                               │
    │ 1:N                           │
    ▼                               ▼
Inventory_Log                  Audit_Trail  ◄── (all tables)
    
Suppliers ──── 1:N ──── Risk_Scores
```

### Table Descriptions

| Table | Purpose | Key Constraints |
|---|---|---|
| `Suppliers` | Master vendor registry with KYC & geo-risk metadata | `UNIQUE (tax_id)`, `CHECK (tier IN (...))`, `high_risk_flag BOOLEAN` |
| `Purchase_Orders` | Authorized procurement commitments | `CHECK (total_po_amount > 0)`, `CHECK (delivery_due_date >= po_date)` |
| `Invoices` | Vendor payment claims against a PO | `UNIQUE (invoice_number, supplier_id)`, `CHECK (invoice_amount > 0)` |
| `Payments` | Actual disbursements made | `CHECK (initiated_by <> approved_by)` — SOD enforcement |
| `Inventory_Log` | Goods Received Notes (GRN) — physical receipt confirmation | `CHECK (quantity_received <= quantity_ordered * 1.05)` |
| `Risk_Scores` | Automated vendor risk ratings | `UNIQUE (supplier_id, score_date)`, `CHECK (overall_score BETWEEN 0 AND 100)` |
| `Audit_Trail` | **Immutable** forensic event log for all system changes | Append-only pattern; `CHECK (severity IN ('INFO','WARNING','HIGH','CRITICAL'))` |

### Schema Design Decisions

- **Dual-control enforcement** — `Payments.initiated_by <> approved_by` is a database-level constraint, not just application logic, ensuring Segregation of Duties (SOD) cannot be bypassed.
- **Append-only Audit_Trail** — The audit log is write-only by design. In production, enforce with PostgreSQL Row-Level Security (RLS) policies preventing `UPDATE`/`DELETE`.
- **Soft deletes on Suppliers** — `is_active = FALSE` instead of physical deletion preserves the historical FK chain for forensic completeness.
- **JSONB columns for audit payloads** — `old_value` / `new_value` stored as JSONB allow flexible schema-free delta logging across all monitored tables.

---

## 3. Embedded Forensic Anomalies <a name="anomalies"></a>

The synthetic dataset contains **6 deliberate anomalies** mirroring real fraud schemes detected in P2P forensic engagements:

| ID | Anomaly Type | Table(s) Affected | Fraud Scheme |
|---|---|---|---|
| **A1** | High-risk jurisdiction supplier (`country_code = 'IR'`) | `Suppliers`, `Invoices`, `Payments` | OFAC sanctions evasion |
| **A2** | Two POs raised by same buyer to same shell vendor on the same day, both just below the $25K approval threshold | `Purchase_Orders` | PO structuring / threshold manipulation |
| **A3** | Identical invoice number, amount ($390K), and supplier — submitted 88 minutes apart | `Invoices` | Duplicate invoice fraud |
| **A4** | Cumulative invoices against PO #11 total $253,500 vs. authorized $120,000 | `Invoices`, `Purchase_Orders` | Overbilling / invoice inflation |
| **A5** | Same invoice (#8) paid twice via WIRE within 105 minutes | `Payments` | Double-payment / disbursement fraud |
| **A6** | Bank account reference changes between consecutive payments to Supplier #3 | `Payments` | Account hijacking / social engineering |

---

## 4. Analytical Queries <a name="queries"></a>

### Query 1 — Full Forensic Audit Trail Reconstruction
**Technique:** 5-table JOIN, correlated subquery, `CASE` risk flags, `LEFT JOIN` with subquery for latest risk score

Joins `Payments → Invoices → Purchase_Orders → Suppliers → Risk_Scores` to produce a single-row-per-payment view with all risk signals surfaced. The forensic team runs this first to triage the entire payment population.

**Key Output Columns:** `forensic_flag`, `pct_over_po_limit`, `sod_check`, `audit_event_count`

---

### Query 2 — Duplicate Payment & Rapid Consecutive Payment Detection
**Technique:** `LAG()`, `ROW_NUMBER()`, `SUM() OVER()` window functions; multi-layer CTE

Uses `LAG(payment_date)` partitioned by `invoice_id` to compute the time gap between consecutive payments for the same invoice. Any payment within 24 hours of a prior payment on the same invoice with an equal amount is flagged `DUPLICATE_PAYMENT`.

```sql
LAG(p.payment_date) OVER (
    PARTITION BY p.invoice_id
    ORDER BY p.payment_date
) AS prev_payment_date
```

**Detects:** Anomaly A3, A5

---

### Query 3 — PO Structuring Detection
**Technique:** `DENSE_RANK()`, `SUM() OVER (RANGE BETWEEN INTERVAL ...)`, `CASE` threshold banding

Ranks suppliers by frequency of sub-threshold POs and detects same-day clustering by the same buyer. The rolling 30-day spend window catches volume-based structuring even when individual POs appear legitimate.

**Detects:** Anomaly A2

---

### Query 4 — Three-Way Match Exception Report
**Technique:** 3 parallel CTEs (`invoice_totals`, `grn_totals`, `three_way_match`), `COALESCE` for null-safety, composite `CASE` match status

The P2P three-way match control requires: ① Valid PO ② Goods received (GRN) ③ Invoice ≤ PO amount. This query surfaces every exception across all three legs, ranked by financial exposure tier.

**Output:** `three_way_match_status ∈ {PASS, WARN, FAIL}`, `exposure_tier`

**Detects:** Anomaly A4

---

### Query 5 — Vendor Risk Heat Map with Dynamic Composite Scoring
**Technique:** 4 chained CTEs, `DISTINCT ON`, weighted scoring formula, `LEAST()` for score capping

Builds a composite risk score (0–100) for every active supplier by weighting four factors:
- System risk score (40%)
- Geographic flag — hard +30 pts for OFAC jurisdictions
- Invoice anomalies (up to 25 pts)
- Critical audit events (up to 15 pts)

Produces `deloitte_risk_verdict` and `recommended_action` columns ready for executive reporting.

---

### Query 6 — Open Audit Findings Tracker (SLA Breach Monitor)
**Technique:** `DENSE_RANK()` for escalation priority, conditional multi-table `LEFT JOIN` pattern for cross-table context resolution, SLA age calculation

Surfaces all unreviewed `HIGH`/`CRITICAL` audit events, resolved against their originating supplier regardless of which table the event originated in. Computes SLA breach status (CRITICAL events older than 3 days, HIGH events older than 7 days).

**Mimics:** Deloitte Management Audit Report — Open Findings Register

---

## 5. Performance Optimization <a name="performance"></a>

### Index Strategy

```sql
-- High-traffic FK paths
CREATE INDEX CONCURRENTLY idx_inv_supplier_status
    ON Invoices(supplier_id, status);

CREATE INDEX CONCURRENTLY idx_pay_invoice_date
    ON Payments(invoice_id, payment_date);

CREATE INDEX CONCURRENTLY idx_po_supplier_buyer_date
    ON Purchase_Orders(supplier_id, buyer_employee_id, po_date);

-- Partial index on Audit_Trail — only indexes actionable rows
CREATE INDEX CONCURRENTLY idx_audit_severity_reviewed
    ON Audit_Trail(severity, reviewed)
    WHERE severity IN ('HIGH','CRITICAL') AND reviewed = FALSE;
```

### Materialized View for Dashboard Queries

```sql
-- Query 5 (vendor risk heat map) runs nightly via pg_cron
CREATE MATERIALIZED VIEW mv_supplier_risk_dashboard AS
    [Query 5 body];

REFRESH MATERIALIZED VIEW CONCURRENTLY mv_supplier_risk_dashboard;
```
This reduces executive dashboard response time from ~800ms (live multi-CTE) to ~5ms (MV scan), a **~99% latency reduction**.

### Partitioning Strategy

```sql
-- Partition Audit_Trail by month once it exceeds 5M rows
CREATE TABLE Audit_Trail_2024_04
    PARTITION OF Audit_Trail
    FOR VALUES FROM ('2024-04-01') TO ('2024-05-01');
```

### Key Design Rationale

| Decision | Rationale |
|---|---|
| `CONCURRENTLY` on all indexes | Avoids table lock during production index creation |
| Partial index on Audit_Trail | 90%+ of rows are `reviewed = TRUE` — partial index is ~10x smaller |
| `DISTINCT ON` over `ROW_NUMBER()` for latest risk score | PostgreSQL-native; avoids a subquery layer |
| `JSONB` for audit payloads | Schema-flexible; supports `->` operator querying for specific field changes |

---

## 6. How to Run <a name="run"></a>

### Prerequisites
- PostgreSQL 15+ (for `DISTINCT ON`, `RANGE BETWEEN INTERVAL` window support)
- psql client or pgAdmin 4

### Setup

```bash
# 1. Clone the repository
git clone https://github.com/YOUR_USERNAME/supply-chain-forensic-audit.git
cd supply-chain-forensic-audit

# 2. Create the database
psql -U postgres -c "CREATE DATABASE forensic_audit_db;"

# 3. Run the full script (schema + data + queries)
psql -U postgres -d forensic_audit_db -f enterprise_supply_chain_audit.sql

# 4. Run a specific query section
psql -U postgres -d forensic_audit_db
```

### Expected Outputs

| Query | Key Finding Surfaced |
|---|---|
| Q1 — Audit Trail | Payments 6 & 7 flagged `DUPLICATE_PAYMENT`; Supplier 5 flagged `GEOPOLITICAL_RISK` |
| Q2 — Duplicate Detection | Invoice #8 paid twice within 105 minutes |
| Q3 — PO Structuring | Supplier 7 (Vantage Shell Co.) — 2 same-day POs below $25K threshold |
| Q4 — Three-Way Match | PO #11 `FAIL — OVERBILLED` with $133,500 exposure; `TIER_1_MATERIAL` |
| Q5 — Risk Heat Map | Supplier 5 `CRITICAL — IMMEDIATE ACTION` (score: 91+); Supplier 7 `HIGH` |
| Q6 — Open Findings | 5 unreviewed HIGH/CRITICAL findings; 2 with SLA breach |

---

## Skills Demonstrated

`PostgreSQL` · `Window Functions` · `CTEs` · `Forensic SQL` · `Schema Design` · `Indexing Strategy` · `Data Modeling` · `Fraud Detection` · `Risk Scoring` · `Three-Way Match` · `P2P Audit` · `OFAC Compliance` · `SOX Controls`

---

*Built as a portfolio demonstration of enterprise SQL capabilities for data engineering and financial advisory roles.*
