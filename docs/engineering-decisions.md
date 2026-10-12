# Engineering decisions

Short architecture decision records for the choices that shaped the system. Each lists the context, the decision, the alternatives I weighed, and the consequences, including the ones I would revisit. They describe decisions as made at the time; where hindsight changes my view, it says so.

Contents:

1. [A single Next.js monolith](#adr-1-a-single-nextjs-monolith)
2. [PostgreSQL with Prisma](#adr-2-postgresql-with-prisma)
3. [FIFO inventory layers, not a single purchase price](#adr-3-fifo-inventory-layers-not-a-single-purchase-price)
4. [Serialize stock mutations through a singleton row lock](#adr-4-serialize-stock-mutations-through-a-singleton-row-lock)
5. [Snapshot cost on the sale line](#adr-5-snapshot-cost-on-the-sale-line)
6. [Two-phase FIFO rollout with a freeze after initialization](#adr-6-two-phase-fifo-rollout-with-a-freeze-after-initialization)
7. [Pure functions for business rules](#adr-7-pure-functions-for-business-rules)
8. [Stateless JWT sessions with the role read from the database](#adr-8-stateless-jwt-sessions-with-the-role-read-from-the-database)
9. [Migrate with a verified, transactional, idempotent ETL](#adr-9-migrate-with-a-verified-transactional-idempotent-etl)
10. [Design for the simplest possible operation](#adr-10-design-for-the-simplest-possible-operation)
11. [Deferred decisions](#deferred-decisions)

---

## ADR 1: A single Next.js monolith

**Context.** One developer, one small business, a few concurrent users, and a requirement that staff can look up stock from a phone. No need for independent scaling of components.

**Decision.** One Next.js 15 (App Router) application with TypeScript: server-rendered pages, JSON route handlers, a feature-organized data layer, and Prisma to PostgreSQL. No separate API service.

**Alternatives considered.** A separate API (Express or Nest) plus an SPA; a desktop client to resemble the old system.

**Consequences.**

- One deployable, one language, shared Zod schemas between client forms and server validation, and trivial local setup.
- Server components reduce the amount of client JavaScript that phones must load.
- Cost: no hard boundary between layers, so discipline matters. Authorization is enforced per route by explicit guard calls rather than by structure (see [security-model.md](security-model.md)). I would add default-deny middleware.

## ADR 2: PostgreSQL with Prisma

**Context.** Financial and stock data with relational integrity needs; the legacy data was relational.

**Decision.** PostgreSQL as the system of record, accessed with Prisma 6 for schema, migrations and typed queries. Raw SQL only where Prisma cannot express a requirement, which is row locking (`SELECT ... FOR UPDATE`) and a few search and diagnostic queries.

**Alternatives considered.** Another SQL Server (continuity with the legacy system); a document store; Drizzle or plain SQL.

**Consequences.**

- Transactions, row-level locks and partial indexes were all available when needed.
- Typed queries caught a class of errors at compile time.
- Prisma's migration model needs discipline: see the migration lessons in [database-design.md](database-design.md#migration-history-and-discipline).
- Costs of not using database constraints: several invariants live in application code only. See [known-limitations.md](known-limitations.md).

## ADR 3: FIFO inventory layers, not a single purchase price

**Context.** The legacy system calculated profit from one purchase price per product, which misstates profit whenever cost changes. The business wanted profit that reflects what was actually paid for the units sold.

**Decision.** Model stock as **layers** (one per purchase line, opening balance, customer return or positive adjustment) and consume them oldest-first, recording the per-layer trail. Costing is behind a `CostingStrategy` interface.

**Alternatives considered.**

| Option | Why not |
|---|---|
| Keep the single current purchase price | The status quo; wrong profit when cost varies |
| Moving weighted-average cost per product | Simpler (one number per product, no layers), but gives a blended cost that no physical unit ever had, and cannot answer "which purchase did this sale come from?" Reasonable choice; I would offer it as a second strategy. |
| LIFO | Does not match how this stock physically moves (oldest units are sold first) |
| Specific identification | Needs serial/batch tracking at the counter; far too heavy for accessory SKUs |

**Consequences.**

- Profit per bill is explainable and traceable down to the purchase that supplied the units. See [fifo-costing-worked-example.md](fifo-costing-worked-example.md).
- Edits to purchase history are constrained (cannot change what has been consumed).
- More moving parts: layers must stay consistent with the denormalized stock counter, which needed a diagnostics and reconciliation tool.
- Known imperfection: FIFO order follows when a layer was *entered*, not the invoice date.

## ADR 4: Serialize stock mutations through a singleton row lock

**Context.** Several different operations change stock: sales, purchases, returns, adjustments, imports and, once, FIFO initialization. Two sales of the same product must not consume the same unit, and nothing may change stock while FIFO is being initialized.

**Decision.** Every stock-changing transaction first locks the single `settings` row with `SELECT ... FOR UPDATE`; initialization holds that lock for its entire transaction. Within a sale, the relevant layer rows are additionally locked `FOR UPDATE` in `created_at` order.

**Alternatives considered.**

- Optimistic concurrency with a version column and retries: more code in every write path, with retries that are hard to reason about when allocations span several layers.
- Per-product advisory locks: finer grained, but more complicated and no real benefit at this scale.
- `SERIALIZABLE` isolation everywhere: simple to state, but retry handling is still needed and it affects every query.

**Consequences.**

- Easy to reason about: stock mutations are effectively one at a time. The concurrency experiment in [testing-strategy.md](testing-strategy.md) shows correct behavior under simultaneous requests.
- Throughput ceiling: all stock writes queue through one row. Acceptable for one shop. It would be the first thing to replace (per-product locks) if the write rate grew by an order of magnitude.
- In the write paths I reviewed, locks are taken in the same order (settings row first, then layers by creation time), which avoids lock-order deadlocks between operations.

## ADR 5: Snapshot cost on the sale line

**Context.** Historical profit must not change when master data or later purchases change.

**Decision.** Each sale line stores its cost and profit as computed at sale time, and the legacy import preserved the legacy snapshots as they were.

**Consequences.** Reports are simple and stable, and they reconcile with the old system for history. The cost is that corrections (for example a customer return) do not retroactively alter the original line's profit; returns are tracked as their own records. That is a deliberate trade-off, listed in [known-limitations.md](known-limitations.md).

## ADR 6: Two-phase FIFO rollout with a freeze after initialization

**Context.** FIFO was added to a live system with years of history and no layers. A big-bang switch would have meant no way to verify before behavior changed.

**Decision.**

1. Ship the code and schema with the engine switched off. Behavior is unchanged: cost snapshots still come from the current purchase price.
2. An admin runs a one-time **initialization** in a single locked transaction, with pre-flight and post-flight validation, that creates opening layers from current stock and flips the flag.
3. After that, direct stock edits are rejected; stock moves only through operations that maintain layers.
4. A diagnostics screen and a safe reconciliation tool exist for ongoing integrity checks.

**Consequences.** Deploy risk was separated from behavior risk, and a failed initialization changes nothing. The compromise is that opening layers carry the then-current purchase price rather than true historical cost.

## ADR 7: Pure functions for business rules

**Decision.** Allocation, return limits, purchase-edit rules, initialization validation and diagnostics classification are implemented as pure functions that take plain data and return results or typed errors. The data layer loads rows, calls them, and persists the outcome inside a transaction.

**Consequences.** 167 unit tests run in about a second with no database. The boundary between "rule" and "persistence" is clear. The cost is that tests do not cover the persistence glue; see the gaps in [testing-strategy.md](testing-strategy.md).

## ADR 8: Stateless JWT sessions with the role read from the database

**Decision.** An HS256 JWT in an `httpOnly` cookie identifies the user; the user and role are loaded from the database on each request.

**Alternatives considered.** Server-side sessions; an auth provider.

**Consequences.** Role changes and deletions take effect immediately and there is no session table to maintain. Individual tokens cannot be revoked before expiry, and there is no login throttling. Both are accepted simplifications for a very small, trusted user base (see [design-context.md](design-context.md)). In a system with more users or wider exposure I would choose server-side sessions or a managed auth provider with MFA.

## ADR 9: Migrate with a verified, transactional, idempotent ETL

**Decision.** A TypeScript ETL with a dry-run mode, pre-flight validation, a single-transaction import keyed on legacy ids, and verification inside the transaction. See [legacy-migration.md](legacy-migration.md).

**Alternatives considered.** A vendor migration tool or CSV export and import (no pre-flight, no in-transaction verification, harder to repeat); incremental sync (unnecessary for a one-time cutover).

**Consequences.** The migration was repeatable and rolled back cleanly on any mismatch. The acceptance checks were counts and stock totals; I would add value-level reconciliation next time.

## ADR 10: Design for the simplest possible operation

**Context.** A small, single-location business with a very small team: a couple of administrators and a few read-only staff accounts. The old system was a desktop program used for about 15 years. The business needed software that is simple to install and operate, did not require customer tracking, and did not require an audit trail. See [design-context.md](design-context.md).

**Decision.** Treat "easy to install, easy to operate, hard to misuse" as the primary requirement and let it override features that a general-purpose inventory and billing product would have:

- no customer database (customer details are typed per bill);
- no audit trail;
- no login rate limiting, complex password rules or multi-factor login;
- two roles only, one of them read-only;
- a small number of screens with flat navigation.

**Alternatives considered.** A fuller product with customer management, audit logging and hardened authentication. That is what I would build for a multi-user business, but for this one it would have added screens, options and failure modes for people who wanted fewer of each.

**Consequences.** The system fits its users, and the code stayed small enough for one developer to reason about completely. The cost is a documented list of limitations ([known-limitations.md](known-limitations.md), [security-model.md](security-model.md)). They are all solvable by anyone adapting the design to a different setting, and each has a suggested fix.

## Deferred decisions

Things I knowingly did not do, and why:

| Not done | Reason | Trigger to revisit |
|---|---|---|
| Audit log and soft deletes | Not required by the business; very few people can change data | Any deployment with more than a couple of admins, or a dispute that needs "who changed this" |
| Database `CHECK` constraints | Rules were already centralized in application code (an engineering trade-off, not a business requirement) | When a second writer (script, integration) appears |
| CI pipeline | Single maintainer, manual releases | First time a regression ships |
| Full-text or trigram search index | Catalog size does not need it yet | Search latency becomes noticeable |
| Customer database | The business did not want to track customers | A business that needs customer history or credit |
| Multi-location stock | Single shop | A second branch |
| Per-product locks | Single-shop write rate | Lock waits show up in practice |
