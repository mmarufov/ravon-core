import pg from "pg";
import { env } from "./config.server";

// Job storage. Not the template's Prisma/SQLite: the guarantees here are PostgreSQL
// constraints and a trigger (db/001_delivery.sql).

let pool: pg.Pool | undefined;

export function pgPool(): pg.Pool {
  if (!pool) {
    pool = new pg.Pool({
      connectionString: env("RAVON_PG_URL"),
      max: Number(process.env.RAVON_PG_POOL ?? 10),
      options: "-c search_path=ravon_delivery",
    });
  }
  return pool;
}

export async function withTx<T>(fn: (c: pg.PoolClient) => Promise<T>, p = pgPool()): Promise<T> {
  const c = await p.connect();
  try {
    await c.query("BEGIN");
    const out = await fn(c);
    await c.query("COMMIT");
    return out;
  } catch (e) {
    await c.query("ROLLBACK").catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

// The actor and RPC the lifecycle trigger checks, scoped to the current transaction.
export async function asActor(c: pg.PoolClient, actor: string, rpc: string): Promise<void> {
  await c.query("SELECT set_config('ravon.actor', $1, true), set_config('ravon.rpc', $2, true)", [
    actor,
    rpc,
  ]);
}
