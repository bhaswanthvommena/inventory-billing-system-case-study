# Security model

> **Context first.** This system was deliberately designed with simple security for a small single-location business with a very small, trusted user base. It intentionally has **no login rate limiting, no complex password rules, no multi-factor login and no layered security**. Those controls would add friction for users who needed the system to be easy to operate, and the business did not need them. Anyone deploying this in a different setting (more users, public exposure, multiple admins, regulated data) should treat the gaps below as required work, not optional. See [design-context.md](design-context.md).

This is an internal business application used by a small number of trusted staff over the internet. It handles inventory, supplier and customer billing data, but not payment card data. This document describes what is implemented, what is not, and what I would fix next if the context were different. It is a self-assessment from reading the code, not a penetration test, and the application should not be described as "secure" on the strength of its role checks alone.

## Implemented controls

### Authentication

- Passwords are stored as **bcrypt** hashes (cost factor 12). Plaintext passwords are never stored or logged.
- A successful login issues a **JWT signed with HS256**, valid for 8 hours, in an **`httpOnly`, `SameSite=Lax`** cookie that is `Secure` in production. The signing secret must be at least 32 characters or the application refuses to sign or verify.
- The login endpoint returns the same generic message for unknown users and wrong passwords.
- New and changed passwords must be at least 8 characters, entered twice.

### Authorization

- Two roles, `ADMIN` and `EMPLOYEE`, mapped to a permission set in one place. `ADMIN` has every permission; `EMPLOYEE` has read-only product lookup and nothing else.
- **The role is read from the database on every request**, not from the token. Demoting or deleting a user takes effect on their next request, not when their 8-hour token expires.
- **Every page and every API route calls a guard explicitly.** The only unguarded API routes are login and logout. I verified this by scanning the route files. There is no global middleware, so a new route that forgets to call a guard would be open; see the backlog below.
- Server-side guards are the enforcement point. Hiding navigation items for employees is a usability measure only.

### Second factor for user administration

Creating, changing and deleting users requires a separate **"system security password"** in addition to an admin session. Verifying it sets a second short-lived (15 minute) signed cookie with a distinct purpose claim, which the user-management routes check. This limits the damage from a hijacked admin session to anything *other than* account management, though see the gap below.

### Data integrity as a security property

- Every stock-changing operation runs in one database transaction with explicit row locks, so concurrent requests cannot corrupt stock or consume the same inventory twice.
- Request bodies are validated with Zod schemas on the server (the feature data layer parses its input before touching the database).
- Database access is through Prisma's query API, which parameterizes queries. The few raw SQL statements use tagged-template parameters, not string concatenation.
- Cost and profit are snapshotted on sale lines, so changing master data later cannot silently rewrite financial history.
- Returns are idempotent through unique client request ids, so retries do not duplicate stock movements.

### Secrets and configuration

- Secrets (database URLs, JWT secret, seed passwords) come from environment variables. The repository ships an example file with placeholders only.
- Migrations are applied with `prisma migrate deploy`; the runbook explicitly forbids `prisma migrate dev` against production because of its reset behavior.

## Known gaps (honest list)

Almost all of these are **[Business decision]** simplifications for a very small, trusted user base, as explained above. Items marked **[Engineering gap]** are worth fixing even in this context.

| Gap | Impact | Suggested fix |
|---|---|---|
| **[Business decision] No rate limiting or lockout on login** | Online password guessing is limited only by bcrypt's cost | Per-IP and per-username throttling; progressive delay; lockout alerts |
| **[Engineering gap] No bcrypt comparison for unknown usernames** | Response time can reveal whether a username exists | Compare against a dummy hash on the not-found path |
| **[Business decision] Second factor protects only user management** | A stolen admin session can still change prices, stock and records | Require re-verification for destructive or high-impact operations; consider real MFA (TOTP) for login |
| **[Engineering gap] Second factor seed has a fallback default** | If the environment variable is unset at first run, the second factor is seeded from the admin seed password or, failing that, a hard-coded placeholder | Fail startup when neither is set; force change on first login |
| **[Business decision] Stateless sessions cannot be revoked** | Logout deletes the cookie, but a copied token stays valid until expiry | Server-side session table or token version on the user row |
| **[Business decision] No audit trail** (not required by the business; very few people can change data) | No record of who changed or deleted what; hard deletes | Audit table (actor, action, entity, before/after); soft delete for business records |
| **[Engineering gap] No explicit CSRF token** | Relies on `SameSite=Lax` and JSON content type | Origin/Fetch-Metadata checks on state-changing routes |
| **[Engineering gap] No security headers configured** | Default framework headers only; no CSP, frame restrictions or HSTS configured in the app | Add a header policy in the framework config |
| **[Engineering gap] Guards are per route, no default-deny** | A future route could ship without a guard | Central middleware default-deny with an allowlist, plus a test that enumerates routes |
| **[Business decision] Simple password policy** (modest minimum length, by design for simple operation) | Length only | Longer minimum, breached-password check |
| **[Engineering gap] No automated dependency or secret scanning, no CI** | Vulnerable dependencies or committed secrets would not be caught automatically | CI pipeline with audit and secret-scan steps |
| **[Engineering gap] Backups and monitoring depend on the hosting platform** | Not verified from this codebase | Documented, tested restore procedure and alerting |

## Threat model, briefly

| Threat | Current mitigation | Residual risk |
|---|---|---|
| Stolen or guessed admin password | bcrypt; second factor for account management | High in a general setting; accepted for a very small, trusted user base |
| Employee account abusing access | Employee role is read-only lookup; enforced server-side | Low |
| Concurrent operations corrupting stock | Transactions plus row locks; diagnostics screen | Low |
| Accidental data loss through deployment | Migration discipline, manual dumps before major releases | Medium: depends on a manual procedure |
| Insider altering history | Cost and profit snapshots protect against indirect changes | Medium in general; accepted here because the business did not want an audit trail |
| Vulnerable dependency | None automated | Unknown |

## Priorities if the context were different

If this were to be used by more people, exposed more widely, or handle more sensitive data, this is the order I would work in. For the original small business, items 2, 4 and 5 are the ones worth doing; the rest were intentionally left out.

1. Login throttling and the unknown-user timing fix (small, high value).
2. Fail-closed startup for missing secrets, including the second-factor seed.
3. An audit table for sales, purchases, adjustments, returns and user changes.
4. Default-deny middleware with an enumerating test.
5. CI with dependency audit and secret scanning.
6. Security headers and Fetch-Metadata checks.
7. TOTP-based MFA for admin login.
