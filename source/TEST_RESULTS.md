# Validation results

Checked on 24 October 2026 using Python 3.12.14.

## Completed

- `python -m unittest discover -v`: **15 tests passed**.
- Full default dataset generation: **business invariants passed**.
- `python load_mysql.py --data data --dry-run`: **all CSV-backed tables passed
  offline header, value-conversion, and row-count checks**.
- Independent ledger replay checked that transfers balance and wallet balances
  never become negative in the test simulation.
- Reproducibility checked by comparing two independent exports with the same
  seed and configuration.
- Timeout resolution, held funds, retry ordering, business-rule failure codes,
  event duplicates, and late/missing event transport were exercised.
- Loader tests cover timezone conversion, exact integer amounts, unsafe SQL
  identifiers, malformed CSV rows, nonempty-table protection, and transaction
  rollback through an injected failure using test doubles.

## Full dataset counts

| Item | Count |
|---|---:|
| Customers | 5,000 |
| Logical payment requests | 100,000 |
| Attempts including retries | 100,766 |
| Successful attempts | 84,053 |
| Definitively failed attempts | 16,615 |
| Pending attempts at cutoff | 98 |
| Canonical source events | 203,748 |
| Received event-delivery rows, including duplicates | 205,362 |
| Distinct received source events | 203,280 |
| Wallet ledger entries | 168,106 |
| Simulated infrastructure incidents | 15 |

The failed logical-payment count is 15,849, which differs from the failed
attempt count because retries can recover a payment. Total opening and closing
wallet money both equal **113,707,998 cents**. Held money at cutoff is
**234,739 cents**, already included in closing ledger balances.

These are simulation outputs and are not statistics about Somalia or a real
provider. They are an answer key for checking your implementation, not input
features for your pipeline.

## Remaining integration check

No MySQL server is available in the execution workspace. The schema and loader
have **not been run against a live MySQL server**. The offline tests do not
establish server compatibility, account permissions, or successful database
creation. Run the loader against your exercise MySQL instance, then verify the
reported counts. MySQL Connector/Python, Power BI, and AWS deployment were not
installed or executed as part of this deliverable.

The 80-hour project includes building and testing your own extraction,
transformation, and reporting pipeline. Those downstream components have not
been implemented for you.
