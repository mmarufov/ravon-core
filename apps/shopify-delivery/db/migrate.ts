// Applies db/001_delivery.sql and db/900_harness.sql, and seeds the transition table from
// app/delivery/lifecycle.edges.json.
//
//   tsx db/migrate.ts [--fresh] [--control no_job_key,no_lifecycle_trigger]
//
// --fresh drops both schemas first. --control builds the schema a negative control needs:
// no_job_key drops UNIQUE (shop, order_gid) on jobs, no_lifecycle_trigger drops the
// trigger. Neither exists in a normal migration.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const here = dirname(fileURLToPath(import.meta.url));

export type SchemaControl = "no_job_key" | "no_lifecycle_trigger";

export async function migrate(url: string, opts: { fresh?: boolean; controls?: SchemaControl[] } = {}) {
  const c = new pg.Client({ connectionString: url });
  await c.connect();
  try {
    if (opts.fresh) {
      await c.query("DROP SCHEMA IF EXISTS ravon_delivery CASCADE; DROP SCHEMA IF EXISTS harness CASCADE");
    }
    await c.query(readFileSync(join(here, "001_delivery.sql"), "utf8"));
    await c.query(readFileSync(join(here, "900_harness.sql"), "utf8"));
    const edges = JSON.parse(readFileSync(join(here, "../app/delivery/lifecycle.edges.json"), "utf8")) as {
      from: string;
      to: string;
      actor: string;
      rpc: string;
      guards: string[];
    }[];
    await c.query("BEGIN");
    await c.query("DELETE FROM ravon_delivery.transitions");
    for (const e of edges) {
      await c.query(
        `INSERT INTO ravon_delivery.transitions (from_status, to_status, actor, rpc, guards)
         VALUES ($1, $2, $3, $4, $5)`,
        [e.from, e.to, e.actor, e.rpc, e.guards],
      );
    }
    await c.query("COMMIT");
    for (const ctl of opts.controls ?? []) {
      if (ctl === "no_job_key") {
        await c.query("ALTER TABLE ravon_delivery.jobs DROP CONSTRAINT IF EXISTS jobs_one_per_order");
      } else if (ctl === "no_lifecycle_trigger") {
        await c.query("DROP TRIGGER IF EXISTS jobs_enforce_transition ON ravon_delivery.jobs");
      } else {
        throw new Error(`unknown control ${ctl}`);
      }
    }
    return edges.length;
  } finally {
    await c.end();
  }
}

// The schema has to match the mechanisms the process runs with: a naive handler against
// a schema that still has the key would just fail on the constraint, and a full handler
// against a control schema would be unprotected.
export async function assertSchemaMatches(
  pool: pg.Pool,
  want: { jobKey: boolean; trigger: boolean },
): Promise<void> {
  const r = await pool.query<{ key: boolean; trig: boolean; edges: string }>(
    `SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'jobs_one_per_order') AS key,
            EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'jobs_enforce_transition') AS trig,
            (SELECT count(*) FROM ravon_delivery.transitions) AS edges`,
  );
  const got = r.rows[0];
  if (got.key !== want.jobKey || got.trig !== want.trigger) {
    throw new Error(
      `schema mismatch: job key ${got.key} (want ${want.jobKey}), trigger ${got.trig} (want ${want.trigger})`,
    );
  }
  if (Number(got.edges) !== 36) throw new Error(`transitions has ${got.edges} edges, want 36`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const args = process.argv.slice(2);
  const ctlArg = args.find((a) => a.startsWith("--control"));
  const controls = (ctlArg?.includes("=") ? ctlArg.split("=")[1] : args[args.indexOf("--control") + 1] ?? "")
    .split(",")
    .filter(Boolean) as SchemaControl[];
  const url = process.env.RAVON_PG_URL;
  if (!url) throw new Error("RAVON_PG_URL is not set");
  migrate(url, { fresh: args.includes("--fresh"), controls: ctlArg ? controls : [] }).then((n) => {
    console.log(`migrated ravon_delivery (${n} lifecycle edges)${ctlArg ? `, controls: ${controls.join(",")}` : ""}`);
  });
}
