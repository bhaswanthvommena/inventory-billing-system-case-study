# Known limitations

> **Context first.** This system was deliberately designed as very simple small-business inventory and billing software for a small business with a very small team. Many items below are **business-driven simplifications**, not oversights: the business did not require an audit trail or a customer database, and did not need login hardening. A general-purpose inventory and billing product would have all of them, and anyone building on this work can add them. See [design-context.md](design-context.md).

An engineering write-up that lists only strengths is not credible. These are the real limitations of the system, found by reading the code and running it, grouped by area, with how each could be fixed. Security gaps have their own table in [security-model.md](security-model.md) and are not repeated in full here.

Each item is tagged:

- **[Business decision]**: chosen on purpose to match the business's requirements. Right for this context; would be a gap elsewhere.
- **[Engineering gap]**: something I would improve regardless of context.

## Data model and integrity

| Limitation | Effect | Fix |
|---|---|---|
| **[Engineering gap] No database `CHECK` constraints.** Positive quantities, non-negative remaining quantity and similar rules are enforced in application code only. | A direct SQL edit or a future code path could write invalid rows; the diagnostics screen would detect but not prevent them. | Add `CHECK (remaining_qty >= 0)`, `CHECK (quantity > 0)` and similar in a new migration, after cleaning existing data. |
| **[Business decision] No audit columns or audit table; hard deletes.** The business did not require an audit trail; very few people can change data. | Cannot answer "who changed or deleted this?" Deleted records are gone. | Audit table plus `created_by` / `updated_by`; soft delete for business documents. Recommended for any multi-user deployment. |
| **[Engineering gap] Stock is stored twice** (`products.current_stock` and the sum of layers). | They can drift if a code path forgets one side. | Already mitigated by the post-initialization stock lock and the diagnostics and reconciliation tools; a database trigger or generated view would remove the duplication. |
| **[Engineering gap] Money precision is mixed.** Columns are `Decimal(12,2)`, but allocation and averaging arithmetic uses JavaScript numbers before rounding for storage. | Per-unit weighted-average costs that do not divide evenly (for example a total cost of 1,000 over 3 units) are rounded to two decimals when stored, so cost times quantity can differ from the true total by a few paise. | Use a decimal library or integer minor units in the costing code; keep the snapshot as a decimal computed from totals. |

## FIFO behavior

| Limitation | Effect | Fix |
|---|---|---|
| **[Engineering gap] FIFO order follows layer insertion time, not the purchase invoice date.** Back-dating or late entry of a purchase does not move its layer earlier. | Entering an older invoice late makes its units "newer" for costing purposes. | Order layers by an explicit business date plus a tie-breaker, and define what back-dating means for already-consumed layers. |
| **[Engineering gap, inherent to the migration] Opening layers use the current purchase price** at initialization time. | True historical cost of units already on the shelf is unknown, so the oldest layer per product is an approximation. | Inherent; could be refined with the last real purchase cost if the business supplied it. |
| **[Engineering gap] A customer return creates a new layer at the original line's average cost**, and does not alter the original sale's profit snapshot. | A fully returned sale still shows its original profit in sale-line history; net profit must be read together with returns. | Show returns as negative lines in profit reports, or record a profit adjustment when a return is created. |
| **[Engineering gap] The sales-form cost preview is an unlocked estimate.** | If another sale lands between preview and save, the saved cost can differ from what was previewed. | Acceptable by design (the saved value is authoritative), but the UI could state "estimated". |
| **[Engineering gap] The product page "Profit" headline** is the simple difference between current selling price and current purchase price. | It is an indicator, not the FIFO profit of any actual sale, and can be misread. | Label it, or show the cost of the next layer to be consumed. |
| **[Business decision] Historical legacy lines keep whatever cost the old system stored**, including zero where the old system stored zero. | Historical profit for those lines is overstated, by design: they reconcile with the old system's reports rather than inventing costs. | Mark such lines in reports. |

## Performance and scale

| Limitation | Effect | Fix |
|---|---|---|
| **[Business decision] All stock-changing writes serialize through one settings row.** | Throughput is bounded by one transaction at a time. Fine for one shop; not for high write rates or multiple branches. | Per-product locking with a narrower initialization guard. |
| **[Engineering gap] Search is a sequential scan** (`REGEXP_REPLACE` and `LIKE` on every row). | Fast with a few thousand products; scales linearly. | Stored normalized column with a trigram index. |

## Product scope (all **[Business decision]**)

The feature set is intentionally small, because the product was designed to be simple to install and operate. Compared with a full inventory and billing package:

- **No customer database.** Customer tracking was not a requirement. Name, phone and vehicle are typed on each bill and stored with that bill. A full product would have a separate customer table with history, credit and contact management.
- **Two roles only.** Administrators can do everything; staff accounts have read-only product and stock lookup. There is no role that can enter sales without seeing costs, because the business did not need one.
- **One shop, one currency, one costing method in use (FIFO).**
- **Few screens, flat navigation, minimal options.** Fewer choices means fewer mistakes for the people using it.
- **No notifications, scheduled reports or integrations**, which the business did not ask for.

## Engineering process (all **[Engineering gap]**)

- **No CI, no automated database-integration tests, no browser tests.** See [testing-strategy.md](testing-strategy.md).
- **Applied migration 0004 was edited after being applied**, leaving a checksum mismatch that produces a warning on every deploy. The schema is correct. See [database-design.md](database-design.md#migration-history-and-discipline).
- **The legacy ETL asserts a hard-coded expected next bill number.** That was correct for the cutover and makes the script unsafe to re-run today. It should be archived.
- **Backups, monitoring and alerting are not part of this codebase.** They depend on the hosting platform and manual dumps before major releases; restoring from backup has not been rehearsed in this repository.
- **Operational runbook is a single deployment document**, not a set of tested procedures.
