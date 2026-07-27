# Provider outage

1. Confirm `ladle_provider_total` outcome, circuit state, provider status page,
   credential validity, and one redacted trace. Do not repeatedly run paid
   probes.
2. If one rung failed, disable or remove that provider credential and let the
   chain use free/audio/vision/fallback rungs. If extraction itself failed,
   pause new imports at ingress while recipe CRUD/sync remain available.
3. Keep jobs in the durable outbox or terminate them with the typed
   `providerUnavailable` failure; never leave them indefinitely `parsing`.
4. Restore the provider in staging, run one credential-gated smoke import, then
   close the circuit and resume a small production canary.
5. Verify success/latency/cost, queue age, and no retry storm for 30 minutes.
   Escalate quota/auth failures to the provider owner and rotate credentials
   through the secret-rotation runbook.
