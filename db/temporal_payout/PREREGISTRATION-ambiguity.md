# Pre-registration: payouts when the provider's reply is lost

Committed before the first run of `ambiguity_matrix.py`. If an implementation
detail below turns out to be wrong or impossible, the change is made in a later
commit that says what changed and why, and the results say which version of this
file they ran against. Nothing here is edited after seeing numbers.

Everything is **simulated**: a fake provider in PostgreSQL, a logical clock in
integer ticks, and the real `db/ledger/schema.sql` for the ledger side. No real
provider, bank, or money is involved.

## Question

When a payout request to the provider times out, the platform does not know
whether money moved. Which way of handling that timeout ends with the ledger and
the provider agreeing, and which ends with a courier paid twice, paid while the
ledger says failed, or recorded as paid when nothing arrived?

## Strategies (what the saga does when the submit call times out)

| key | name | on timeout |
|---|---|---|
| `fresh_key` | retry with a fresh request id | resubmit after the retry delay with request id `<id>:2` |
| `same_key` | retry with the same request id | resubmit after the retry delay with the same request id (what the Temporal workflow does today: unlimited retries) |
| `fail_on_timeout` | fail on timeout | fail the payout immediately, asserting verdict `not_found` without asking (what the hand-built `resume(NULL)` does today) |
| `status_first` | status first | mark the payout `unknown`, then ask `status(request_id)` every tick until it answers: `paid` -> mark submitted and post; `pending` -> mark submitted and wait; `failed` -> fail with verdict `declined` (or `returned`); `not_found` -> resubmit with the same request id |

Shared by all four, so the comparison isolates the timeout decision:

- Everything except the first submit call behaves normally.
- A payout with a provider ref and no final answer is polled every tick with
  `status`, by the same resolver code for every strategy: `paid` -> post;
  `failed` -> fail with the provider's verdict.
- A posted payout is polled the same way; `failed/returned` -> fail with verdict
  `returned`, which posts the reversal.
- Every `status` call, from any strategy, times out independently with
  probability 0.2 (seeded). A timed-out status call is retried on the next tick.

## Fault modes (applied to the first submit call of each payout)

Provider idempotency-key TTL is **10 ticks**. Horizon is **40 ticks**.

| key | what the provider does on the first call |
|---|---|
| `none` | control: pays and replies normally |
| `commit_then_timeout` | pays, then the reply is lost (timeout). Retry delay drawn from U{1..5}, inside the TTL |
| `timeout_before_commit` | the request is dropped before the provider records anything; the reply is a timeout. The dropped request never lands later |
| `async_pending_then_paid` | records the payout as `pending`, reply lost; it becomes `paid` after U{2..60} ticks |
| `async_pending_then_failed` | records `pending`, reply lost; it becomes `failed/declined` after U{2..60} ticks |
| `returned_after_delay` | pays, reply lost; the payout is returned by the bank after U{3..20} ticks |
| `key_expiry` | pays, reply lost; the retry comes after U{11..20} ticks, after the key has expired |

The retry delay for every mode other than `key_expiry` is U{1..5}. A new
provider object created by a retry or an expired key is paid immediately with no
fault. The provider's `status(request_id)` reads its permanent payout records,
not the idempotency-key cache, so it still answers after the key has expired.
This is an assumption about the provider, and it is the one that makes
`status_first` work under `key_expiry`.

## Seeds and pairing

Seeds 0..199 for the full run, 0..9 in CI. Each (mode, seed) gets its own
`random.Random(f"{mode}:{seed}")`, and the same draws (amount, delays, status
timeouts in call order) are used for all four strategies, so every comparison is
paired. One payout per run. Amounts U{100..50,000} minor units.

## Metrics per cell (strategy x mode, 200 runs)

The provider is judged by its **eventual** state (every scheduled transition
applied, even ones after the horizon). The ledger is judged at the horizon.

- **double**: 2 or more provider objects for the payout end `paid`.
- **orphaned**: the provider eventually paid at least once, and the ledger says
  `failed`.
- **phantom**: the ledger says `posted`, and the provider eventually paid nothing.
- **stuck**: the ledger is not terminal (`pending`, `unknown`, `submitted`) at the
  horizon.
- **wrong_money** = double or orphaned or phantom (a run counts once).

`stuck` is not counted as wrong money: the payable is still owed and visible, and
nothing has been paid or recorded incorrectly. It is reported next to it.

## Predictions (written before running)

- `none`: every strategy 0 on every metric.
- `status_first`: 0 wrong_money in every mode; some stuck in the two async modes,
  when the payout resolves after the horizon.
- `same_key`: 0 wrong_money in every mode except `key_expiry`, where every run is
  double.
- `fresh_key`: double in `commit_then_timeout`, `async_pending_then_paid`,
  `key_expiry`; 0 in `timeout_before_commit` and `async_pending_then_failed`.
- `fail_on_timeout`: orphaned in `commit_then_timeout`, `async_pending_then_paid`,
  `key_expiry`.

## Headline and gate

- Headline: wrong_money runs summed over the 6 fault modes (not `none`),
  `fail_on_timeout` (today's hand-built behaviour) vs `status_first`, out of
  6 x 200 = 1,200 runs each. The other two baselines are reported in the same
  table, and the same-key result is stated plainly: it is safe while the provider
  still holds the key.
- CI (`--seeds 10 --check`) fails if `status_first` has any wrong_money run, if
  any strategy has a nonzero metric under `none`, or if `fresh_key` has 0 double
  under `commit_then_timeout` (the negative control: the double detector has to
  be able to fire).

## Tests (pytest, `tests/test_ambiguous_timeout.py`)

- Schema: `ledger_payout_fail` without a verdict raises `PAYOUT_VERDICT_REQUIRED`;
  `ledger_payout_resume` on a `pending` or `unknown` payout with neither a ref nor
  a verdict raises it too; `declined` or `not_found` on a posted payout raises
  `PAYOUT_VERDICT_CONFLICT`; `returned` on a posted payout reverses it.
- Provider: each fault mode produces the stated provider state and `status`
  answer.
- Resolver: an `unknown` payout whose provider paid ends posted, exactly once.
- Temporal: with `commit_then_timeout` armed, the workflow's submit activity
  queries status on the timeout and the payout ends posted once, with one
  provider object.
- Negative control (per-attempt key): the same `commit_then_timeout` run with a
  fresh request id per attempt must produce a double payout, and the test that
  looks for doubles must see it.
- Negative control (ledger): posting a payout under a per-attempt ledger key
  (`payout:<id>:<attempt>`) instead of `payout:<id>` must produce two ledger
  transactions for one payout.
