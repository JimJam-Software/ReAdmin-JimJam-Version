/* eslint-disable sort-keys */
// @ts-check

/* eslint-disable @typescript-eslint/no-var-requires */
const { z } = require('zod');

/*eslint sort-keys: "error"*/
const envSchema = z.object({
  MONGODB_URI: z.string().url(),
  MONGODB_DATABASE: z.string(),
  REDIS_URL: z.string().url(),
  NODE_ENV: z.enum(['development', 'test', 'production']),
  DISCORD_CLIENT_ID: z.string(),
  DISCORD_PUBLIC_KEY: z.string(),
  DISCORD_CLIENT_SECRET: z.string(),
  DISCORD_TOKEN: z.string(),
  ROBLOX_SECRET: z.string(),
  // Optional because a self-hosted instance can run with billing switched off
  // (BILLING_ENABLED=false). They are still required when billing is on — see
  // the check below the schema, which fails just as loudly as the schema does.
  STRIPE_PUBLIC: z.string().optional(),
  STRIPE_SECRET: z.string().optional(),
  STRIPE_SIGNING_SECRET: z.string().optional(),
  // 'false' turns off every Stripe code path: no customer is created at login,
  // the billing webhook stops accepting requests, and new workspaces are
  // created with Premium already on. Premium cannot be sold on a self-hosted
  // instance anyway (SUBSCRIPTIONS_CLOSED in constants/Subscriptions), so the
  // only thing Stripe was still doing there was breaking login.
  // Unset means enabled, so the hosted deployment is unaffected.
  BILLING_ENABLED: z.string().optional(),
  JSON_WEB_TOKEN_SECRET: z.string(),
  CDN_URL: z.string(),
  CDN_ACCESS_KEY_ID: z.string(),
  CDN_SECRET_ACCESS_KEY: z.string(),
  CDN_ENDPOINT: z.string(),
  CDN_BUCKET_NAME: z.string().optional(),
  CDN_REIGON: z.string(),
  // Self-hosting escape hatches. Both default to the hosted service's
  // behaviour, so leaving them unset changes nothing.
  //
  // 'false' disables TLS on the Mongo connection — needed when Mongo runs as a
  // container on a private Docker network rather than as a managed cluster.
  MONGODB_TLS: z.string().optional(),
  // 'true' switches the S3 client to path-style addressing
  // (<endpoint>/<bucket>/<key>). Required for MinIO; Spaces uses virtual-host
  // style, which is the default.
  CDN_FORCE_PATH_STYLE: z.string().optional(),
  CRYPTO_KEY: z.string(),
  ROBLOX_COOKIE: z.string(),
  ROBLOX_API_KEY: z.string(),
  VERCEL_URL: z.string().optional(),
  NEXT_PUBLIC_VERCEL_URL: z.string().optional(),
  VERCEL_GIT_COMMIT_SHA: z.string().optional(),
  NEXT_PUBLIC_VERCEL_GIT_COMMIT_MESSAGE: z.string().optional(),
  VERCEL_ENV: z.enum(['production', 'preview', 'development']).optional(),
  NEXT_PUBLIC_VERCEL_ENV: z
    .enum(['production', 'preview', 'development'])
    .optional(),
  ROBLOX_USER_ID: z.string(),
  ROBLOX_CLIENT_ID: z.string(),
  // Same value as ROBLOX_CLIENT_ID. The authorize URLs are built in the
  // browser, so this must be NEXT_PUBLIC_ and present at build time — Next
  // inlines it into the client bundle. Required, so a missing value fails the
  // build rather than rendering a login button that cannot work.
  NEXT_PUBLIC_ROBLOX_CLIENT_ID: z.string(),
  ROBLOX_CLIENT_SECRET: z.string(),
  BLOXLINK_TOKEN: z.string(),
  CONTIGUITY_SECRET: z.string(),
  COMMIT_HASH: z.string().optional(),
  APP_NAME: z.enum(['panel', 'lambda']).default('panel'),
  AWS_ACCESS_KEY_ID: z.string(),
  AWS_SECRET_ACCESS_KEY: z.string(),
  AWS_ENV: z.enum(['prod', 'dev']).optional(),
  // Set to 'true' on a self-hosted deployment (anything that is not
  // readmin.app). Enables the workspace data import tooling. Left unset, it is
  // inferred — see utils/deployment.ts.
  SELF_HOSTED: z.string().optional(),
  // OpenSearch (optional — when set, powers Roblox user search).
  OPENSEARCH_URL: z.string().optional(),
  OPENSEARCH_USERNAME: z.string().optional(),
  OPENSEARCH_PASSWORD: z.string().optional()
});

const env = envSchema.safeParse(process.env);

if (env.success && env.data.BILLING_ENABLED !== 'false') {
  const missing = [
    ['STRIPE_PUBLIC', env.data.STRIPE_PUBLIC],
    ['STRIPE_SECRET', env.data.STRIPE_SECRET],
    ['STRIPE_SIGNING_SECRET', env.data.STRIPE_SIGNING_SECRET],
  ]
    .filter(([, value]) => !value)
    .map(([key]) => key);
  if (missing.length) {
    console.error(
      `\u274c Billing is enabled but ${missing.join(', ')} ${missing.length > 1 ? 'are' : 'is'} not set.\n` +
        '   Set them, or set BILLING_ENABLED=false to run without Stripe.',
    );
    process.exit(1);
  }
}

if (!env.success) {
  console.error(
    '❌ Invalid environment variables:',
    JSON.stringify(env.error.format(), null, 4),
  );
  process.exit(1);
}
module.exports.env = env.data;