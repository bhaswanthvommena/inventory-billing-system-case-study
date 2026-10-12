# Demo assets

Everything here is fictional.

## `demo-products.csv`

Ten made-up products (`DEMO-` SKUs) with invented prices and stock quantities, in the column format the application's CSV importer accepts. It was imported into a throwaway local database to produce the screenshots and the FIFO worked example.

## How the demo environment was produced

Not reproducible from this repository alone, because the application source is private, but the sequence was:

1. Create an empty local PostgreSQL cluster on a non-default port and apply the application's migrations. (The demo used PostgreSQL 17 and Node.js 24 as installed on my machine; the Docker setup targets PostgreSQL 16 and Node 22. See the version note in the main README.)
2. Start the application in development mode with environment variables pointing at that database only.
3. Import `demo-products.csv` (preview, then apply).
4. Create three fictional suppliers.
5. Initialize FIFO, which creates one opening layer per product with stock.
6. Enter a few purchases, sales, one customer return and one positive stock correction through the application's HTTP API.
7. Capture screenshots, then delete the database.

## `concurrency-check.ps1`

A PowerShell script that fires several simultaneous sale requests for the same product at a running demo instance and checks that no more units were sold than existed and that final stock reconciles. It creates real sales in whatever database the instance points to, so run it only against a throwaway demo. Credentials are parameters; none are stored here.

Sample output from the run documented in [`../docs/testing-strategy.md`](../docs/testing-strategy.md):

```text
Stock before: 10. Sending 6 concurrent requests for 3 unit(s) each.
Maximum that may succeed: 3
Accepted (201): 3   Rejected as insufficient stock (409): 3   Other: 0
Stock after: 1   Expected: 1
PASS: no oversell, stock reconciles with accepted sales.
```
