import { neon, type NeonQueryFunction } from '@neondatabase/serverless';

// Lazy so a build without DATABASE_URL (first deploy, before the Neon integration) does not throw.
let _sql: NeonQueryFunction<false, false> | null = null;
export function sql() {
  if (!_sql) _sql = neon(process.env.DATABASE_URL!);
  return _sql;
}
