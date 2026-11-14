\# 17 — Production Readiness Checklist

\> Covers prompt section 20. Use it as a gate before calling any phase "done". Each item is
\> phrased as a verifiable statement. Production readiness reviews (PRRs) at Google, Uber,
\> and others use the same format: a list of facts with evidence, not aspirations.

Legend: \*\*[P1]\*\* required by the end of Phase 3 (monolith on K8s), \*\*[P2]\*\* before
"production" (Phase 6), \*\*[P3]\*\* stretch.

\---

\## Architecture
\- [ ] [P1] Layer direction is enforced by import-linter in CI; \`services/\` has no I/O imports; each feature's repository touches only its own schema.
\- [ ] [P1] Every module emits integration events only through the outbox.
\- [ ] [P1] Every external call has an explicit timeout.
\- [ ] [P1] ADRs exist for: modular monolith, Ride/Trip split, Redis GEO vs PostGIS (with benchmark), outbox, upfront pricing, matching batching.
\- [ ] [P2] Every dependency has a documented failure mode and fallback (doc 16 §3 table is implemented, not just written).
\- [ ] [P2] No single-replica stateless workloads in prod (except the leader-elected relay, which has a standby).
\- [ ] [P3] At least two modules extracted as services following the strangler playbook.

\## Security
\- [ ] [P1] JWT asymmetric signing, \`alg\` pinned, \`aud\`/\`iss\`/\`exp\` verified; refresh rotation with reuse detection.
\- [ ] [P1] The authz matrix test covers 100% of routes (BOLA protection).
\- [ ] [P1] No secrets in Git (gitleaks green on full history); \`.env\` gitignored.
\- [ ] [P1] Rate limits on auth, quotes, rides, location.
\- [ ] [P2] Secrets from an external store; rotation procedure documented and tested once.
\- [ ] [P2] TLS everywhere, including Postgres, Redis, and Kafka in-cluster.
\- [ ] [P2] Images non-root, read-only rootfs, scanned (no HIGH/CRITICAL unfixed), signed; signature verified at deploy.
\- [ ] [P2] Default-deny NetworkPolicies; separate DB roles (app/migrator/readonly).
\- [ ] [P2] PII field encryption for phone and saved addresses; log scrubbing tested.
\- [ ] [P2] Admin MFA; admin actions audited.
\- [ ] [P3] OWASP ZAP baseline scan clean; threat model reviewed.

\## Scalability
\- [ ] [P1] Load test report at small scale (1k users) meets SLOs.
\- [ ] [P2] Load test report at medium scale (10k users) meets SLOs; first bottleneck at stress identified and documented.
\- [ ] [P2] HPA/KEDA configured; spike test shows scale-up within 2 min without SLO breach.
\- [ ] [P2] PgBouncer in place; \`max_connections\` budget documented (pods × pool size).
\- [ ] [P2] Location history partitioned with automated partition creation and retention drop.
\- [ ] [P2] Kafka partition counts justified by target consumer parallelism.
\- [ ] [P3] Large-scale (100k) stress test run once, with report.

\## Reliability
\- [ ] [P1] All non-idempotent POSTs require \`Idempotency-Key\`; replay returns the identical response.
\- [ ] [P1] All consumers dedupe via the inbox table; duplicate-delivery integration test exists.
\- [ ] [P1] DLQ + replay tool exist; replay tested.
\- [ ] [P1] Optimistic locking on Trip; concurrent-insertion test exists.
\- [ ] [P2] Circuit breakers + fallbacks on OSRM, Redis, PSP, notifications.
\- [ ] [P2] Reconciliation jobs (stuck rides, missing fares, ledger balance) running and alerting.
\- [ ] [P2] Graceful shutdown verified: rolling deploy under load gives 0 errors.
\- [ ] [P2] Chaos tests: kill a Redis pod, a Kafka broker, and an api pod under load. No data loss, SLO impact within budget.
\- [ ] [P2] PodDisruptionBudgets and topology spread; node drain under load gives 0 errors.
\- [ ] [P3] Proposal saga migrated to (or compared with) Temporal.

\## Monitoring and operations
\- [ ] [P1] RED metrics for every deployment; business metrics (match rate, pool match rate, detour) on a dashboard.
\- [ ] [P1] Structured logs with trace_id; trace propagation through Kafka verified end to end (one trace spans API → relay → matcher → consumer).
\- [ ] [P2] SLOs defined for the 9 SLIs (doc 13 §4) with burn-rate alerts.
\- [ ] [P2] Every alert has a runbook; every runbook was exercised at least once ("game day").
\- [ ] [P2] Dashboards and alert rules provisioned from Git.
\- [ ] [P2] Deploy annotations on Grafana; a change log is linkable from incidents.
\- [ ] [P2] Incident postmortem template (blameless) in \`docs/postmortems/\`; at least one practice postmortem written after a chaos test.
\- [ ] [P3] Synthetic monitoring: a canary rider/driver bot runs a full ride every 5 min in prod.

\## Deployment
\- [ ] [P1] PR pipeline: lint, types, unit, integration, security, migrations, contracts.
\- [ ] [P1] Immutable SHA-tagged images; the same digest is promoted across environments.
\- [ ] [P2] Staging → manual gate → prod; smoke tests and auto-rollback on failure.
\- [ ] [P2] Expand/contract migrations; migration linter (squawk) in CI; code rollback is always safe.
\- [ ] [P2] Feature flags for matching algorithm, proposal mode, and pool per city.
\- [ ] [P3] Canary releases with automated analysis (Argo Rollouts).

\## Disaster recovery
\- [ ] [P2] Postgres: continuous WAL archiving + daily base backups to object storage (pgBackRest / CloudNativePG barman), encrypted, in a different region/bucket.
\- [ ] [P2] \*\*Restore drill performed\*\* and timed: PITR to a timestamp in a fresh cluster. Measured RTO ≤ 30 min, RPO ≤ 5 min (async) / 0 (sync replica for payments).
\- [ ] [P2] Kafka: RF=3, \`min.insync.replicas=2\`; topic configs in Git (Strimzi CRs). Documented: Kafka is *\*not\** the system of record. Postgres + outbox can re-publish.
\- [ ] [P2] Redis loss drill: flush Redis in staging under load → system recovers (geo index rebuilds from the next pings within 5 s; caches warm).
\- [ ] [P2] Cluster rebuild from Git (IaC + manifests + secrets store) documented and tested in a fresh namespace or cluster.
\- [ ] [P3] Multi-region strategy documented (active-passive with promoted replica), even if not built.

\## Cost optimization
\- [ ] [P2] Resource requests right-sized from observed p95 usage (e.g. with the VPA recommender in "Off" mode).
\- [ ] [P2] Non-prod environments scale to zero overnight (KEDA cron / scheduled scale-down); cloud load tests torn down after runs.
\- [ ] [P2] Log retention tuned (14 d) and debug logs sampled; trace tail sampling configured.
\- [ ] [P2] Prometheus cardinality budget: series count per service tracked; no unbounded labels.
\- [ ] [P2] Storage lifecycle: location history → aggregate after 90 days; drop partitions; object-storage tiering for backups.
\- [ ] [P3] Spot/preemptible node pool for stateless workers and load generators.
\- [ ] [P3] Cost dashboard (OpenCost / Kubecost) with cost per 1,000 rides as a unit-economics metric.