import { betterAuth } from 'better-auth';
import { createAuthMiddleware } from 'better-auth/api';
import { bearer, username } from 'better-auth/plugins';
import { D1Dialect } from 'kysely-d1';

export function createAuth(env: Env) {
  return betterAuth({
    appName: 'CC保镖',
    baseURL: env.AUTH_ORIGIN,
    secret: env.BETTER_AUTH_SECRET,
    database: { dialect: new D1Dialect({ database: env.DB }), type: 'sqlite' },
    emailAndPassword: { enabled: true, disableSignUp: true },
    session: { expiresIn: 60 * 60 * 24 * 7, updateAge: 60 * 60 * 24 },
    hooks: {
      after: createAuthMiddleware(async (ctx) => {
        const created = ctx.context.newSession;
        const data = ctx.context.returned;
        if (ctx.path === '/sign-in/username' && created && data &&
            typeof data === 'object' && 'user' in data && 'token' in data) {
          // Reuse the authenticated session; clients need no second round trip.
          return ctx.json({ ...data, session: { expiresAt: created.session.expiresAt.toISOString() } });
        }
      }),
    },
    // Database-backed limits stay consistent across isolates; /v1/config uses a
    // separate D1 counter so config polling does not compete with auth keys.
    rateLimit: {
      enabled: true,
      storage: 'database',
      window: 60,
      max: 30,
      customRules: { '/sign-in/username': { window: 60, max: 5 } },
    },
    advanced: {
      ipAddress: { ipAddressHeaders: ['cf-connecting-ip'] },
      database: { validateSchema: false },
    },
    plugins: [username(), bearer({ requireSignature: true })],
  });
}
