# `db/rush`: K buyers, N portions, one instant

A load harness for one question: when K buyers press "order" at the same moment for N
portions of one dish, does anything sell more than N, lose a stock update, or break
stock conservation?

| File | |
|---|---|
| `PREREGISTRATION.md` | strategies, K, latencies, seeds and metrics, committed before the first run |
| `strategies.sql` | the scratch schema and the four strategies |
| `rush.py` | the harness; also drives the real `public.create_order` (`--target rpc`) |
| `toxi.py` | a 60-line Toxiproxy client that adds latency to the database link |
| `RESULTS.md`, `results.json` | every measured number, with command, SHA, date and machine |
| `FINDINGS.md` | what the harness and the regression tests found, including what is not fixed |

Everything here is **local and simulated**: one laptop, one PostgreSQL, one Python
client process, synthetic buyers.

## Run it

```bash
# a database with db/schema applied and seeded
createdb ravon_rush
./db/schema/apply.sh -d ravon_rush --local
psql -d ravon_rush -f db/schema/seed.sql

python3 -m venv .venv && .venv/bin/pip install -r db/schema/tests/requirements.txt

# the CI gate: K = 200, no added latency, exits 1 on any oversell
.venv/bin/python db/rush/rush.py --dsn postgresql://postgres@127.0.0.1:5432/ravon_rush \
    --target strategies,rpc --k 200 --runs 3 --gate

# the pre-registered matrix, through Toxiproxy
toxiproxy-server -host 127.0.0.1 -port 8474 &
.venv/bin/python db/rush/rush.py --dsn postgresql://postgres@127.0.0.1:5432/ravon_rush \
    --target strategies,rpc --k 100,1000 --runs 10 --latency 0,20,100 \
    --toxiproxy http://127.0.0.1:8474 --out db/rush/results.json
```

K = 1,000 opens 1,000 connections at once, so the server needs
`max_connections` above that (the measured cluster used 1,200).

`--target rpc` also runs against a schema from before the fix, which is how the
harness shows it can see the regression: on 65ad66c the scheduled path puts every
buyer's order live.
