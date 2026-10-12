import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

export default defineConfig(async () => ({
  plugins: [cloudflareTest({
    wrangler: { configPath: './wrangler.jsonc' },
    miniflare: { bindings: {
      BETTER_AUTH_SECRET: 'test-only-secret-at-least-thirty-two-characters',
      TEST_MIGRATIONS: await readD1Migrations('./migrations'),
    } },
  })],
  test: { setupFiles: ['./test/setup.ts'], testTimeout: 15_000 },
}));
