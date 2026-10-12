# Design context: built for one small business, not as general-purpose software

Many of the "gaps" listed in this repository are not oversights. They are deliberate scope decisions that follow from a single requirement: **software for a small, single-location business that is simple to install, simple to operate and hard to get wrong.** The system replaced a roughly 15-year-old Windows desktop application and was shaped by that business's needs, not by the feature list of a commercial inventory and billing package.

## Intended usage

| Who | Scale | Access |
|---|---|---|
| Administrator | A very small number of accounts | Everything |
| Staff | A few accounts | Read-only product and stock lookup |

The small team and low operational complexity are what made a deliberately minimal design appropriate.

## How that shaped the design

| Decision | Reason |
|---|---|
| **No audit trail** | Not required by the business. With very few people able to change data, attribution was not a requirement. |
| **No customer database** | Not required by the business. Customer name, phone and vehicle are entered on each bill and stored with that bill. |
| **No login rate limiting, complex password rules or multi-factor login** | Very small, trusted user base. Heavy security controls would add friction for users who needed the system to be easy to operate. A modest minimum password length is enforced. |
| **Two roles only** | Administrators can do everything; staff only look things up. Finer-grained permissions were not needed. |
| **Few screens and features** | Fewer options means fewer ways to make a mistake. |
| **Single location, single currency** | That is the business. |
| **Simple hosting and installation** | The system had to be easy to deploy and run without dedicated IT staff. |

The result is best described as **deliberately simple, small-business inventory and billing software**. It is not intended to compete with a full commercial package.

## What a full-featured system would add

A general-purpose inventory and billing product would typically include things this one intentionally omits:

- a separate customer database with history, credit and contact management;
- an audit trail of who changed what, with soft deletes;
- login throttling, a strong password policy, MFA and session management;
- more granular roles and approval workflows;
- multi-location stock, tax and invoice variants, integrations and notifications;
- automated tests in CI, database constraints and monitoring.

All of these are solvable. The limitation documents in this repository suggest a fix for each, so anyone adapting these ideas can see exactly where the boundaries are.

## Two kinds of limitations

The limitation documents separate:

1. **Business-driven simplifications.** Chosen on purpose for the reasons above (audit trail, customer table, login hardening, role granularity, feature breadth). Appropriate for this context and would be gaps elsewhere.
2. **Engineering gaps.** Things I would improve regardless of context, such as missing database `CHECK` constraints, no CI, mixed decimal and floating-point arithmetic, and an edited applied migration. These are not justified by the business requirement and are called out as such.
