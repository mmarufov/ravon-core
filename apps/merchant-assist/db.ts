// Database access for the agent, the checker and the runner.
//
// The agent connects as assist_agent, which holds assist_reader and
// assist_proposer WITH INHERIT FALSE (db/assist/01_assist.sql). Every tool call
// is one transaction that takes exactly one of those roles and sets the
// merchant from the session it was given. The model never supplies either.
import pg from "pg";

// bigint (int8) and bigint[] come back as strings by default. Every value
// here is a minor-unit amount or an entry id, far below 2^53.
pg.types.setTypeParser(20, (v) => Number.parseInt(v, 10));
// 1016 is bigint[]; it is not in pg's builtins enum, hence the cast.
pg.types.setTypeParser(1016 as Parameters<typeof pg.types.setTypeParser>[0], (v: string) => (v === "{}" ? [] : v.slice(1, -1).split(",").map((x) => Number.parseInt(x, 10))));

export type Role = "assist_reader" | "assist_proposer";

export function pool(dsn: string, max = 4): pg.Pool {
  return new pg.Pool({ connectionString: dsn, max });
}

export async function asMerchant<T>(
  db: pg.Pool,
  role: Role,
  merchantId: string,
  fn: (c: pg.PoolClient) => Promise<T>,
): Promise<T> {
  const c = await db.connect();
  try {
    // Reads run in a READ ONLY transaction as a second guard after the grants.
    await c.query(role === "assist_reader" ? "BEGIN READ ONLY" : "BEGIN");
    // Role names cannot be bound as parameters; this one comes from the Role
    // type above, never from the model.
    await c.query(`SET LOCAL ROLE ${role}`);
    await c.query("SELECT set_config('assist.merchant_id', $1, true)", [merchantId]);
    const out = await fn(c);
    await c.query("COMMIT");
    return out;
  } catch (err) {
    await c.query("ROLLBACK").catch(() => {});
    throw err;
  } finally {
    c.release();
  }
}

// The structured error convention of db/ledger and db/assist: DETAIL is a JSON
// object with a `reason`.
export function reasonOf(err: unknown): string | null {
  const detail = (err as { detail?: string }).detail;
  if (!detail) return null;
  try {
    return (JSON.parse(detail) as { reason?: string }).reason ?? null;
  } catch {
    return null;
  }
}
