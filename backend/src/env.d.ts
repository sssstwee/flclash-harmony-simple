// Optional private KV with versioned remote-config envelopes (user:<username>, group:<g>, default).
interface Env {
  CONFIGS?: KVNamespace;
}
declare namespace Cloudflare {
  interface Env {
    CONFIGS?: KVNamespace;
  }
}
