# Ravon Assist

A support agent for restaurants on Ravon. A merchant asks "why is my payout
short?" and the agent answers from the ledger. It has two properties that are
enforced outside the model:

1. **Every amount it shows is re-summed from ledger entries the merchant may
   see.** Before an answer is displayed, `checkAnswer()` adds up the cited
   entries for each amount and rejects anything that does not match, cites an
   entry the merchant cannot see, or writes money into free text. A rejected
   answer goes back to the model at most twice, then it is withheld.
2. **Its only action is a proposal that waits for a human, and an approved
   proposal posts once.** The agent can insert a pending proposal and nothing
   else. A Ravon operator approves it through `assist_approve`, which locks
   the proposal and posts through `ledger_post` with key `assist:<proposal id>`.

The agent runs as the merchant: every read goes through views filtered by
row-level security on the session's merchant, and no tool takes a merchant id.

**Evaluated on seeded, synthetic cases only.** No restaurant has used this, and
no real money or merchant is involved. Dated results go in
[`docs/results/`](../../docs/results/) once a measured run exists.

| Path | What it is |
| :--- | :--- |
| [`01_assist.sql`](01_assist.sql) | roles, RLS policies, the `assist` views, `assist_propose`, `assist_approve`, `assist_reject` |
| [`seed.py`](seed.py) | the 40 eval cases and 8 dev cases, through the real order RPCs and `db/ledger/tests/ledger_api.py` |
| [`cases.eval.json`](cases.eval.json), [`cases.dev.json`](cases.dev.json) | what `seed.py` produced; reseeding reproduces them exactly |
| [`tests/`](tests) | privileges, scoping and the 50-click approval race, each with a negative control |
| [`PREREGISTRATION.md`](PREREGISTRATION.md) | cases, causes, metrics, model and repeats, fixed before the first measured run |
| [`FINDINGS.md`](FINDINGS.md) | what did not work and what is still wrong |
| [`../../apps/merchant-assist`](../../apps/merchant-assist) | the agent (TypeScript), the checker `grade.ts`, the runner, transcripts |

## Claims and the tests behind them

| Claim | Test | Negative control |
| :--- | :--- | :--- |
| The agent's roles cannot execute `ledger_post`, approve, write any table, or read a base table | `test_privileges.py::test_no_agent_role_holds_a_forbidden_privilege` | six forbidden grants, each detected |
| A tool calling `ledger_post` is refused under either agent role | `test_privileges.py`, `grade.test.ts` | |
| Each of the 40 merchants sees exactly its own entries and no courier leg | `test_scope.py::test_each_merchant_sees_exactly_its_own_entries` | opening the policies leaks, and the oracle sees it |
| No merchant set means no rows in any view | `test_scope.py::test_no_merchant_set_means_no_rows_anywhere` | |
| A proposal cannot cite another merchant's entry or exceed its evidence | `test_scope.py::test_propose_refuses` | |
| 50 concurrent approvals post 1 transaction | `test_approval_race.py` | lock and key removed: 50 of 50 post |
| An amount off by one, a phantom id, another merchant's entry and money in text are all flagged | `apps/merchant-assist/test/grade.test.ts` | the correct answer passes |
| A rogue `assist:` posting without an approved proposal is flagged | `grade.test.ts` | an approved proposal leaves none |
| A failing answer is never displayed | `apps/merchant-assist/test/agent.test.ts` | |

## Run it

PostgreSQL 17 and Python 3.11+ for the database half, Node 22+ for the agent.

```bash
# a database
initdb -D /tmp/pg-assist -U postgres --auth=trust
pg_ctl -D /tmp/pg-assist -o "-p 5436" -l /tmp/pg-assist.log start

# schema, ledger, assist, seed
createdb -h 127.0.0.1 -p 5436 -U postgres ravon_assist
./db/schema/apply.sh -h 127.0.0.1 -p 5436 -U postgres -d ravon_assist --local
psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5436 -U postgres -d ravon_assist -f db/ledger/schema.sql
psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5436 -U postgres -d ravon_assist -f db/assist/01_assist.sql
psql -h 127.0.0.1 -p 5436 -U postgres -d ravon_assist -c "ALTER ROLE assist_agent LOGIN PASSWORD 'assist_agent_pw'"
python3 -m venv .venv && .venv/bin/pip install -r db/assist/tests/requirements.txt
.venv/bin/python db/assist/seed.py --dsn postgresql://postgres@127.0.0.1:5436/ravon_assist \
  --set eval --out /tmp/cases.eval.json
diff <(jq .cases /tmp/cases.eval.json) <(jq .cases db/assist/cases.eval.json)   # identical

# database tests (they create and drop their own database)
cd db/assist && ASSIST_DSN=postgresql://postgres@127.0.0.1:5436/postgres ../../.venv/bin/python -m pytest

# agent tests, and re-grading the committed transcripts (no API key needed)
cd apps/merchant-assist && npm ci
export ASSIST_ADMIN_DSN=postgresql://postgres@127.0.0.1:5436/ravon_assist
export ASSIST_AGENT_DSN=postgresql://assist_agent:assist_agent_pw@127.0.0.1:5436/ravon_assist
npm test
npx tsx grade.ts results/*.jsonl --check
```

Running the agent itself needs `ANTHROPIC_API_KEY` in the shell (never in the
repo) and a spend cap:

```bash
npx tsx agent/run.ts --cases-file ../../db/assist/cases.eval.json --repeats 3 \
  --model claude-sonnet-5-5 --effort low --max-usd 15 --out results/<date>-sonnet-5-5.jsonl
```
