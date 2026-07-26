# Worker rollback

1. Stop routing new tasks to the bad worker image, but preserve its logs/traces
   and do not acknowledge tasks it did not finish.
2. Confirm the prior image supports the current schema, task payload, encrypted
   envelope versions, and provider contract. If not, fix forward.
3. Deploy one prior-image worker with the same queue, hard/soft limits,
   visibility timeout, and egress policy. Keep Beat singleton unchanged.
4. Worker loss causes late-ack tasks to redeliver; fencing, idempotency,
   reservations, and the outbox must make this safe. Do not manually clone jobs.
5. Verify one recovered import, claim ownership, provider cost reconciliation,
   queue age, dead letters, and terminal status before scaling the rollback.
