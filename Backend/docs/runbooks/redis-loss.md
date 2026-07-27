# Redis loss or failover

1. Confirm which role failed: broker DB 0, result DB 1, rate-limit DB 2, or
   metrics DB 3. Treat rate-limit failure as a public-API security incident.
2. Drain API admission if rate limiting is unavailable. Stop workers before a
   destructive Redis replacement; keep PostgreSQL and the outbox untouched.
3. Fail over to the durable replica/snapshot. Require AOF health,
   `noeviction`, and successful writes before reopening traffic.
4. Restart one worker and Beat. The outbox sweep redispatches committed,
   undispatched jobs; abandoned claims are fenced and recovered or dead-lettered.
5. Verify queue depth/age, worker and Beat heartbeats, duplicate-delivery
   idempotency, rate-limit behavior, and no job remains `parsing` past the stale
   threshold. Record any RPO breach and page if queue data disappeared.
