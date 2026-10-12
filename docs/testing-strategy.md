# Testing strategy

What is tested, how, what I actually ran while preparing this portfolio, and what is not covered. Results below are from runs on my machine against the private repository on the date of writing; they are not from a CI system, because there is none.

## Approach

The test suite is built around one decision: **put business rules in pure functions and test those heavily**, keep database code thin, and verify the thin layer with a small smoke suite against a running instance.

| Layer | How it is tested | Why |
|---|---|---|
| Business rules (costing allocation, return limits, purchase-edit rules, FIFO initialization checks, diagnostics classification, adjustments, search normalization, import validation, RBAC mapping, security checks, report shaping) | Unit tests with Vitest. No database, no network. | Fast (about 1 second of test time), deterministic, and these are the rules where a mistake costs money. |
| Transactional data layer (Prisma transactions, row locks) | Exercised by the smoke tests and by manual and scripted runs against a throwaway database | Needs a real PostgreSQL for the locking behavior to mean anything. |
| HTTP surface | 3 smoke tests against a running instance: login and product read, import preview validation, report export | Confirms wiring, auth cookies and serialization end to end. |

## Suite inventory

| Test file | Tests | Focus |
|---|---:|---|
| `fifo` | 28 | Layer allocation across one to three layers, exact-boundary consumption, insufficient stock, oldest-first regardless of cost order, weighted-average and total cost, strategy factory |
| `returns` | 20 | Returnable quantity, partial and repeated returns, over-return rejection, sale-edit versus returns, supplier-return limits |
| `stock-adjustments` | 18 | Positive and negative correction rules, reversal blocked once a layer is partly consumed, import-driven stock deltas, reconciliation failure modes |
| `fifo-diagnostics` | 16 | Classification of each integrity problem; healthy baseline |
| `fifo-init` | 12 | Pre-flight and post-creation initialization validation |
| `business-rules` | 12 | Validation rules for products, purchases, sales and settings |
| `business` | 12 | Inventory value, daily sales and profit, stock movement, product deletion rules, post-FIFO stock lock |
| `product-search` | 12 | Pagination, in-stock filter, query composition, status messages |
| `purchase-edit` | 11 | Purchase update payloads and the consumed-layer rules |
| `imports` | 6 | CSV validation and preview |
| `rbac` | 6 | Role to permission mapping |
| `reports` | 5 | CSV escaping, daily sales export, date parameter parsing |
| `security` | 5 | When the second factor is required for user-management operations |
| `inventory-corrections` | 3 | Correction reason formatting |
| `product-transactions` | 1 | Transaction timeline ordering |
| **Total (unit)** | **167** | |
| `api-smoke` | 3 | Requires a running instance |

## Results of the runs I did

| Check | Result |
|---|---|
| Unit tests (`vitest run`, 15 files) | **167 passed, 0 failed** |
| API smoke tests against a local demo instance | **3 passed, 0 failed** |
| TypeScript typecheck (`tsc --noEmit`) | Clean |
| Lint (`next lint`) | No warnings or errors |
| All 12 migrations applied from scratch to an empty PostgreSQL 17 cluster (the Docker setup targets PostgreSQL 16; not rerun there) | Success |
| FIFO diagnostics after seeding and after the concurrency run | `healthy`, zero issues across all checks |

### Concurrency experiment

The most important property of the sales path is that two requests can never sell the same unit. I tested it with [`demo/concurrency-check.ps1`](../demo/concurrency-check.ps1) against the local demo instance:

- Product with 10 units in stock.
- 6 authenticated sessions each submit a sale of 3 units, released at the same instant.
- Maximum possible successes: 3 (9 units).

Observed on the single run I did: **3 sales accepted (HTTP 201), 3 rejected as insufficient stock (HTTP 409), final stock 1, which equals 10 minus 9**. Diagnostics reported zero integrity issues afterwards.

How much to trust this: it is one run on a development server, with 6 workers, which shows the behavior but does not prove the absence of races. It is a smoke-level confirmation that the locking works under real concurrency, not a formal verification. It is not part of an automated suite.

## What is not covered

Said plainly, because a coverage number would hide it:

- **No automated database-integration tests.** The transactional code (lock ordering, rollback behavior, idempotent return handling) is verified by running it, not by tests that start in CI. A Testcontainers-based suite that runs the FIFO scenarios and the concurrency experiment in a real PostgreSQL is the highest-value addition.
- **No browser end-to-end tests.** UI behavior (the bill form, search-as-you-type, responsive layout) was verified manually.
- **No CI.** Nothing runs the tests, typecheck or lint automatically on change.
- **No coverage measurement** and no mutation testing.
- **No load or performance tests.** Search performance on the real catalog was judged by use.
- **No tests for the legacy ETL.** It was a one-time tool protected by dry-run mode, pre-flight validation and in-transaction verification rather than by a test suite.

## If I were adding to it, in order

1. Database-backed integration suite in CI (FIFO scenarios, concurrency, return idempotency, purchase edits).
2. A route-enumerating test that fails if any API route is missing an auth guard.
3. A handful of browser tests for the critical flows: login, create sale, create purchase, return.
4. Property-based tests for the allocation function (total consumed always equals requested; no layer goes negative).
