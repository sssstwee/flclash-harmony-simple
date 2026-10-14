import { betterAuth } from 'better-auth';
import { bearer, username } from 'better-auth/plugins';
import { D1Dialect } from 'kysely-d1';

export function createAuth(env: Env) {
  return betterAuth({
    appName: 'Clash Harmony',
    baseURL: env.AUTH_ORIGIN,
    secret: env.BETTER_AUTH_SECRET,
    database: { dialect: new D1Dialect({ database: env.DB }), type: 'sqlite' },
    emailAndPassword: { enabled: true, disableSignUp: true },
    session: { expiresIn: 60 * 60 * 24 * 7, updateAge: 60 * 60 * 24 },
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
