/**
 * Read-path observation assertions (spec §7.5 / D15 / A12).
 *
 * Two probes around a read request, implemented at the PostgreSQL level so
 * they need zero application changes:
 *
 *  1. No hidden writes — temporary AFTER ROW triggers on every business table
 *     append to `conformance.write_audit`; an empty audit table after the
 *     request proves the read path wrote nothing (committed or not).
 *
 *  2. Bounded query count — `pg_stat_statements` is reset before the request;
 *     the statement sum afterwards bounds the PG work of one read. Targets
 *     must run SEQUENTIALLY against a shared instance for this to attribute
 *     cleanly (the CLI default).
 */

import { Client } from "pg";

export interface ReadObservation {
  /** Committed/attempted writes observed on business tables during the read. */
  hiddenWrites: Array<{ table: string; operation: string }>;
  /** Total PG statements executed by the target during the read (undefined = not measured). */
  queryCount?: number;
  maxQueries?: number;
  ok: boolean;
  notes: string[];
}

export interface ReadPathProbe {
  install(): Promise<void>;
  uninstall(): Promise<void>;
  beginRead(maxQueries?: number): Promise<void>;
  endRead(): Promise<ReadObservation>;
}

export interface PostgresReadPathProbeOptions {
  connectionString: string;
  /** Schemas whose tables are audited, e.g. ["chat_v2", "public"]. */
  schemas: string[];
}

const AUDIT_SCHEMA = "conformance";
const AUDIT_TABLE = "write_audit";

export class PostgresReadPathProbe implements ReadPathProbe {
  private client: Client | null = null;
  private maxQueries?: number;
  private notes: string[] = [];
  private statStatementsAvailable = false;

  constructor(private readonly opts: PostgresReadPathProbeOptions) {}

  private async withClient<T>(fn: (client: Client) => Promise<T>): Promise<T> {
    if (!this.client) {
      this.client = new Client({ connectionString: this.opts.connectionString });
      await this.client.connect();
    }
    return fn(this.client);
  }

  private async listTables(): Promise<Array<{ schema: string; table: string }>> {
    return this.withClient(async (client) => {
      const res = await client.query(
        `SELECT n.nspname AS schema, c.relname AS table
           FROM pg_class c
           JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relkind IN ('r', 'p')
            AND n.nspname = ANY($1)
          ORDER BY 1, 2`,
        [this.opts.schemas],
      );
      return res.rows as Array<{ schema: string; table: string }>;
    });
  }

  async install(): Promise<void> {
    await this.withClient(async (client) => {
      await client.query(`CREATE SCHEMA IF NOT EXISTS ${AUDIT_SCHEMA}`);
      await client.query(
        `CREATE TABLE IF NOT EXISTS ${AUDIT_SCHEMA}.${AUDIT_TABLE} (
           id BIGSERIAL PRIMARY KEY,
           table_name TEXT NOT NULL,
           operation TEXT NOT NULL,
           ts TIMESTAMPTZ NOT NULL DEFAULT now()
         )`,
      );
      await client.query(
        `CREATE OR REPLACE FUNCTION ${AUDIT_SCHEMA}.audit_write_fn() RETURNS trigger AS $$
         BEGIN
           INSERT INTO ${AUDIT_SCHEMA}.${AUDIT_TABLE} (table_name, operation) VALUES (TG_TABLE_NAME, TG_OP);
           RETURN NEW;
         END;
         $$ LANGUAGE plpgsql`,
      );
      const tables = await this.listTables();
      for (const t of tables) {
        const triggerName = `conformance_audit_${t.table}`.slice(0, 63);
        await client.query(`DROP TRIGGER IF EXISTS ${triggerName} ON ${t.schema}.${t.table}`);
        await client.query(
          `CREATE TRIGGER ${triggerName}
             AFTER INSERT OR UPDATE OR DELETE ON ${t.schema}.${t.table}
             FOR EACH ROW EXECUTE FUNCTION ${AUDIT_SCHEMA}.audit_write_fn()`,
        );
      }
    });
  }

  async uninstall(): Promise<void> {
    if (!this.client) return;
    try {
      const tables = await this.listTables().catch(() => []);
      for (const t of tables) {
        const triggerName = `conformance_audit_${t.table}`.slice(0, 63);
        await clientSafe(this.client, `DROP TRIGGER IF EXISTS ${triggerName} ON ${t.schema}.${t.table}`);
      }
      await clientSafe(this.client, `DROP FUNCTION IF EXISTS ${AUDIT_SCHEMA}.audit_write_fn()`);
      await clientSafe(this.client, `DROP TABLE IF EXISTS ${AUDIT_SCHEMA}.${AUDIT_TABLE}`);
      await clientSafe(this.client, `DROP SCHEMA IF EXISTS ${AUDIT_SCHEMA}`);
    } finally {
      await this.client.end().catch(() => {});
      this.client = null;
    }
  }

  async beginRead(maxQueries?: number): Promise<void> {
    this.maxQueries = maxQueries;
    this.notes = [];
    await this.withClient(async (client) => {
      await client.query(`TRUNCATE ${AUDIT_SCHEMA}.${AUDIT_TABLE}`);
      try {
        await client.query(`CREATE EXTENSION IF NOT EXISTS pg_stat_statements`);
        await client.query(`SELECT pg_stat_statements_reset()`);
        this.statStatementsAvailable = true;
      } catch (err) {
        this.statStatementsAvailable = false;
        this.notes.push(`pg_stat_statements unavailable: ${errMsg(err)}`);
      }
    });
  }

  async endRead(): Promise<ReadObservation> {
    const observation: ReadObservation = { hiddenWrites: [], maxQueries: this.maxQueries, ok: true, notes: [...this.notes] };
    await this.withClient(async (client) => {
      const writes = await client.query(`SELECT table_name, operation FROM ${AUDIT_SCHEMA}.${AUDIT_TABLE} ORDER BY id`);
      observation.hiddenWrites = writes.rows as Array<{ table: string; operation: string }>;

      if (this.statStatementsAvailable) {
        // Exclude the probe's own bookkeeping statements from the count.
        const stats = await client.query(
          `SELECT COALESCE(SUM(calls), 0)::bigint AS total
             FROM pg_stat_statements
            WHERE query NOT ILIKE '%${AUDIT_SCHEMA}.${AUDIT_TABLE}%'
              AND query NOT ILIKE '%pg_stat_statements%'`,
        );
        observation.queryCount = Number(stats.rows[0]?.total ?? 0);
      }
    });

    const writesOk = observation.hiddenWrites.length === 0;
    const queriesOk =
      observation.queryCount === undefined || observation.maxQueries === undefined || observation.queryCount <= observation.maxQueries;
    observation.ok = writesOk && queriesOk;
    if (!writesOk) observation.notes.push(`hidden write(s): ${observation.hiddenWrites.map((w) => `${w.table}.${w.operation}`).join(", ")}`);
    if (!queriesOk) observation.notes.push(`query count ${observation.queryCount} exceeds bound ${observation.maxQueries}`);
    return observation;
  }
}

async function clientSafe(client: Client, sql: string): Promise<void> {
  try {
    await client.query(sql);
  } catch {
    // best-effort teardown
  }
}

function errMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
