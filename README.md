# SIM_WALLET: from a damaged payments feed to trusted reporting

An end-to-end data engineering and analytics project on a **synthetic Somali mobile-money provider**.
Raw payment data with deliberately broken event delivery (duplicates, late arrivals, lost events) is turned into
tested, reconciled reporting and a management memo with three investigation priorities.

▶️ **Video walkthrough (Somali):** [YouTube](https://youtu.be/WrxIkwnhkRs?si=Jr2eumFOBmHmNFrE)
📄 **Power BI report (PDF):** [docs/reports.pdf](docs/reports.pdf)

> All people, balances, payments and incidents are synthetic. The provider `SIM_WALLET` is fictional.

---

## Architecture

![High-level architecture](docs/high%20level%20architecture.png)

| Stage | Tool | What happens |
|---|---|---|
| Data generation | Python | Seeded synthetic data: 5,000 customers, 100,000 payments over 90 days |
| Source system | MySQL 8.4 | `somali_wallet_source`: 9 tables + metadata |
| Ingestion / landing | Python → Databricks Volume | Tables extracted from MySQL to JSONL files |
| Bronze | Databricks (Delta) | Raw JSON kept exactly as received, plus `source_file` and `loaded_at` |
| Silver | dbt | Trimmed, typed, UTC timestamps; events deduplicated to one row per `event_id`; late arrivals flagged |
| Intermediate | dbt | `int_attempt_outcomes`: each attempt's outcome decided from evidence |
| Gold | dbt | Star schema (3 facts, 4 dimensions) + 6 report tables |
| Serving | Power BI | 2-page dashboard + management memo |

**Why dbt:** transformations are version-controlled SQL, built in dependency order, with tests that run on every build.

---

## The business problem

A Head of Payment Operations asked:

> How many payments completed, which confirmed failures deserve attention, and which transfers still need
> investigation? Before I act, show that duplicate events, late arrivals or missing confirmations have not
> distorted the report.

The brief contains seven questions (outcomes, failure reasons, city/channel comparison, incidents, retry recovery,
unresolved transfers, ledger reconciliation) and asks for a dashboard plus a one-page memo with three priorities.

---

## The hard part: a damaged event feed

The `event_deliveries` table is an analytics log where:

- about **1%** of events arrive **twice** (same `event_id`, new `delivery_id`)
- about **2%** arrive **1 to 36 hours late** (98% arrive within 10 seconds)
- about **0.2%** are **lost**

How the pipeline handles it:

1. **Duplicates:** `silver.events` keeps one row per `event_id` (first arrival).
2. **Late arrivals:** history is ordered by when an event *happened* (`event_at`), not when it *arrived*, so a late event never overwrites a newer state. Events later than 10 minutes are flagged.
3. **Lost events:** `int_attempt_outcomes` decides each attempt's outcome from evidence, in order of strength:
   **event → ledger postings → a later retry**. Attempts with no evidence stay `UNKNOWN`; nothing is guessed.

---

## Data model (gold)

| Table | Grain | Used for |
|---|---|---|
| `fct_payments` | one payment | outcomes, retry recovery, city/channel |
| `fct_payment_attempts` | one attempt | failure reasons, incidents, unresolved attempts |
| `fct_wallet_balances` | one wallet at the cutoff | balances and reconciliation |
| `dim_wallet`, `dim_reason`, `dim_incident`, `dim_date` | descriptions | slicing and categorisation |
| `rpt_investigation_queue` | one unresolved attempt | ranked work list with evidence, next check and owner |
| `rpt_reconciliation_summary` / `_exceptions` | one check / one problem | proof that money totals agree |
| `rpt_incident_comparison` | one incident | incident window vs comparable normal periods |
| `rpt_city_channel_summary` | city × channel | rates with their counts, small-group flags |

**Quality gates:** 197 dbt data tests and 3 unit tests (row and column counts against bronze, uniqueness,
accepted values, relationships, grain checks, and the unit-tested outcome rules).

---

## Dashboard

Full report including the memo page: [docs/reports.pdf](docs/reports.pdf)

---

## Key results

*Payments requested 1 Jul – 28 Sep 2026; outcomes as of 29 Sep 2026 00:00 Mogadishu time.*

- **100,000 payments:** 84.05% succeeded, 15.81% confirmed failed, 98 pending, 36 without final evidence.
- **766 retries** explain exactly the gap between failed attempts (16,579) and failed payments (15,813).
- **185 successes** were confirmed from the ledger after the success event was lost.
- **Reconciliation: 7/7 checks pass.** Successful volume ($2,294,010.71) equals the debit side of the wallet ledger, and total money is conserved.

### Management memo: three priorities

| # | Finding | Owner |
|---|---|---|
| 1 | Technical failure rate is **19% during payment-switch incidents vs 1%** in comparable normal periods (13 of 15 incidents) | Payment Engineering |
| 2 | **98 transfers pending** after a response timeout, the oldest for about 90 days, with **$2,347.40** of customer funds held | Payment Operations |
| 3 | About **37%** of payments hit by a technical failure never succeed; `PROCESSING_EXPIRED` is the largest reason | Payment Engineering |

**Limitations:** synthetic data; incident results show association, not cause; held balances are not losses;
origin city is the sender's home city, not a measured location.

---

## Repository structure

```
sim_wallet/
├── README.md
├── docs/                       architecture, report PDF and .pbix, memo priorities
├── source/                     data generator, MySQL schema and loader, business brief, data dictionary
└── dbt_databricks/sim_wallet/  dbt project: models (silver, intermediate, gold), tests, macros
```

## How to run the dbt project

Requirements: Python 3.11+, a Databricks SQL warehouse, and the bronze tables loaded.

```bash
pip install dbt-databricks
cd dbt_databricks/sim_wallet
dbt deps
dbt build
```

Configure the Databricks connection in your own `~/.dbt/profiles.yml` (profile name `sim_wallet`).
Credentials are never stored in this repository.

---

## Credits

The ingestion, dbt models and tests, Power BI report, analysis and memo are my own work.
