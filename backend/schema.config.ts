import { createAuth } from './src/auth';
import { betterAuth } from 'better-auth';
import { DatabaseSync } from 'node:sqlite';

// The CLI needs the production plugin/options schema, not a live database.
const options = createAuth({
  DB: undefined!,
  AUTH_ORIGIN: 'https://auth.example.com',
  BETTER_AUTH_SECRET: 'schema-generation-only-not-a-production-secret',
}).options;
export const auth = betterAuth({ ...options, database: new DatabaseSync(':memory:') });
