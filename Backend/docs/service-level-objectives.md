# Service-level objectives

## Measurement window

Use a rolling 28-day window. Exclude announced maintenance only when traffic is
fully drained before the window; provider failures remain part of the import
experience and are not excluded.

## Objectives

| Indicator | Objective |
| --- | --- |
| Authenticated API availability, excluding import completion | 99.9% non-5xx responses |
| Guest creation and import admission availability | 99.5% non-5xx responses |
| Import terminal success (`ready` or `needsReview`) | 98% of admitted imports |
| Import latency | 95% terminal within 5 minutes; 99% within 15 minutes |
| Sync polling latency | 99% under 1 second |
| Queue age | 99% of jobs begin within 2 minutes |
| Account deletion | 99% completes within 5 minutes, excluding Apple outage |
| Recovery | PostgreSQL RPO ≤ 5 minutes and RTO ≤ 60 minutes |

Rate-limited abuse and user quota exhaustion are measured separately from
availability but reviewed weekly for false positives.

## Error-budget policy

- At 50% budget burn before the midpoint, stop risky backend changes and assign
  an owner.
- At 75%, allow only reliability, security, and rollback changes.
- At 100%, freeze backend feature rollout until the 28-day indicator is back
  within objective and the incident review has corrective actions.
- A projected one-hour fast burn pages immediately even when the monthly budget
  is otherwise healthy.

The Grafana dashboard and Prometheus rules in `deploy/observability` are the
canonical measurements. Review objectives quarterly after real traffic makes
the latency distribution representative.
