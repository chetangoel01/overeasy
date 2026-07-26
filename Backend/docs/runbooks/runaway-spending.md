# Runaway provider spending

1. Compare atomic `spent + reserved` units with provider billing; inspect
   import volume, retry rate, cache misses, and rate-limit policy.
2. Immediately lower the application budget or disable live provider dispatch.
   Do not raise limits to clear a queue. Keep admitted work durable and return
   typed quota failures when the budget is exhausted.
3. Block abusive IP/installations/users, open provider circuits if appropriate,
   and release only reservations whose worker/attempt is provably dead.
4. Reconcile every running attempt and provider invoice. Find any estimate that
   systematically understates actual cost before resuming.
5. Resume at a small canary budget, verify cache hit rate and per-import cost,
   then increase gradually with an owner watching the spend alert.
