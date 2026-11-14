\# RideShare: System Design\
\
A ride-hailing platform with intelligent ride sharing (Pool), designed as a production-grade\
learning system: a FastAPI modular monolith that evolves into microservices, with PostgreSQL/PostGIS,\
Redis, Kafka, Kubernetes, GitHub Actions, and Prometheus/Grafana/Loki/OpenTelemetry.\
\
\## Documents\
\
\| # | Document | Covers |\
\|---|---|---|\
\| 01 | [Product requirements]\(01-product-requirements.md) | Critical review, edge cases, abuse, revenue, functional and non-functional requirements, capacity estimates, scaling stages |\
\| 02 | [Domain model]\(02-domain-model.md) | Bounded contexts, aggregates (Ride vs. Trip), entities, value objects, domain services, events |\
\| 03 | [Architecture]\(03-architecture.md) | High-level architecture, modular monolith, repo structure, microservices + migration, sequence diagrams, tradeoffs |\
\| 04 | [Database]\(04-database.md) | ER diagram, all tables with constraints and indexes, operational DB concerns |\
\| 05 | [Geospatial]\(05-geospatial.md) | PostGIS vs. Redis GEO vs. OSRM vs. H3, GiST, nearest driver/rider, route overlap SQL, performance |\
\| 06 | [Matching algorithm]\(06-matching-algorithm.md) | Six-phase pool matcher, batching, insertion with slack times, pseudocode, complexity, how Uber does it |\
\| 07 | [Fare allocation]\(07-fare-allocation.md) | Five algorithms with formulas and the worked ₹450 example, comparison, receipts |\
\| 08 | [API design]\(08-api-design.md) | Conventions, every endpoint with request/response/errors, WebSockets, OpenAPI |\
\| 09 | [Kafka]\(09-event-driven-kafka.md) | Topics, partition keys, retries, DLQ, message schemas, schema evolution, consumer template |\
\| 10 | [Redis]\(10-redis.md) | Key catalog, per-use-case patterns, invalidation strategy, operations |\
\| 11 | [Kubernetes]\(11-kubernetes.md) | Cluster architecture, namespaces, full YAML, sizing, best practices |\
\| 12 | [CI/CD]\(12-cicd.md) | PR, main, and deploy workflows (YAML), rollback strategy |\
\| 13 | [Observability]\(13-observability.md) | Metrics, logs, traces, dashboards, SLIs/SLOs, burn-rate alerts |\
\| 14 | [Security]\(14-security.md) | Threat model, JWT + refresh rotation, RBAC + ownership, rate limiting, injection, secrets, encryption, DPDP |\
\| 15 | [Testing and performance]\(15-testing-and-performance.md) | Test pyramid, coverage, mocking, contract/E2E, Locust plans for 1k/10k/100k users, bottlenecks |\
\| 16 | [Reliability]\(16-reliability.md) | Retries, backoff, circuit breakers, sagas, outbox, DLQ, idempotency: where each lives |\
\| 17 | [Production readiness]\(17-production-readiness.md) | Checklist by area |\
\| 18 | [Learning roadmap]\(18-learning-roadmap.md) | Phase-by-phase plan from Junior to Staff |\
\| 19 | [Implementation plan]\(19-implementation-plan.md) | Core-first build plan, step by step (start here to code) |\
\
\## The decisions that shape everything\
\
1\. \*\*Opt-in Pool with upfront guaranteed pricing\*\* is the default. The two-party proposal flow is kept as a feature-flagged learning mode.\
2\. \*\*Ride ≠ Trip.\*\* A shared ride is a Trip serving multiple Rides, so there's one code path for solo and pool.\
3\. \*\*Layered monolith first\*\* (your existing \`api/controller/services/repositories/models/schemas\` layout), layer direction enforced in CI, deployed as several workloads from one image.\
4\. \*\*Async matching\*\* (202 + WebSocket) decouples the API latency SLO from the matching SLO.\
5\. \*\*Transactional outbox + idempotent consumers\*\* for every integration event.\
6\. \*\*Redis GEO for hot driver positions; PostGIS for route geometry; OSRM for road ETAs; H3 for bucketing.\*\*\
7\. \*\*Batched insertion-based matching\*\* with detour budgets and optimistic concurrency on the Trip.\
8\. \*\*Money as integer paise; fares immutable and reproducible.\*\*\