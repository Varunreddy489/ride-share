# 14 — Security Design

> Covers prompt section 16. Target: OWASP ASVS Level 2 and the OWASP API Security Top 10 (2023).

---

## 1. Threat model (STRIDE, abbreviated)

| Asset | Threat | Control |
|---|---|---|
| Rider location history | Information disclosure (stalking) | AuthZ on every ride read; co-riders see first name + stop *order* only; retention limits; admin access audited |
| Accounts | Spoofing (credential stuffing, token theft) | Rate limits, argon2id, short-lived JWT, refresh rotation + reuse detection |
| Fares / payments | Tampering (client-sent price), repudiation | Server-side pricing from `quote_id` only; idempotency keys; double-entry ledger; audit log |
| Driver GPS | Tampering (spoofing to inflate fares) | Server-side route validation, speed sanity checks, pay on planned route ± tolerance |
| APIs | DoS / scraping | Edge + app rate limits, payload limits, pagination caps |
| Ride resources | **BOLA / IDOR** (API1:2023), the #1 API vulnerability | Ownership check in *every* handler via a shared dependency; UUIDv7 ids; 404 (not 403) for others' resources |
| Admin functions | Elevation of privilege | RBAC + separate admin audience in JWT + MFA + audit log |
| Secrets | Disclosure | External secret store, no secrets in images/Git, rotation |

---

## 2. Authentication: JWT access tokens + rotating refresh tokens

### 2.1 Token design

| | Access token | Refresh token |
|---|---|---|
| Format | **JWT, signed with ES256 (or RS256)**; asymmetric, so verifiers only need the public key (and future services verify without sharing a secret) | **Opaque random string** (32 bytes, `secrets.token_urlsafe`), stored **hashed** (SHA-256) in `identity.refresh_tokens` |
| Lifetime | 15 min | 30 days sliding, 90 days absolute |
| Where (mobile) | Memory | OS secure storage (Keychain / Android Keystore) |
| Where (web admin) | Memory | `HttpOnly; Secure; SameSite=Strict` cookie on `/v1/auth/refresh` path only |
| Revocation | Not individually (short TTL); globally via `token_version` claim check | Row `revoked_at`; whole family on reuse |

Why not HS256: a symmetric secret must be shared with every verifier. After the
microservices split, any service that can verify can also *forge*. Asymmetric keys with a
JWKS endpoint (`/.well-known/jwks.json`) and a `kid` header enable **zero-downtime key rotation**.

### 2.2 Access token claims

```json
{
  "iss": "https://auth.rideshare.dev",
  "aud": "rideshare-api",
  "sub": "01933c3e-7a2b-7c1e-9f00-1c2d3e4f5a6b",
  "roles": ["RIDER"],
  "tv": 3,
  "jti": "01933c50-...",
  "iat": 1763028900,
  "exp": 1763029800
}
```

Verification (PyJWT) must pin the algorithm, audience, and issuer, and require `exp`:

```python
claims = jwt.decode(
    token, key=jwks.get_signing_key(kid).key,
    algorithms=["ES256"],                          # NEVER take alg from the token header
    audience="rideshare-api", issuer=settings.jwt_issuer,
    options={"require": ["exp", "iat", "sub", "aud", "iss"]}, leeway=30)
```

### 2.3 Refresh token rotation with reuse detection

```mermaid
sequenceDiagram
  participant C as Client
  participant A as Auth
  participant DB
  C->>A: POST /auth/refresh {rt_1}
  A->>DB: find hash(rt_1) → family F, not revoked, not expired
  A->>DB: revoke rt_1 (replaced_by = rt_2); insert rt_2 (family F)
  A-->>C: {access_token, rt_2}
  Note over C,A: Attacker stole rt_1 and replays it later
  C->>A: POST /auth/refresh {rt_1} (attacker)
  A->>DB: rt_1 already revoked → REUSE DETECTED
  A->>DB: revoke entire family F (logs out attacker AND victim)
  A-->>C: 401 + security event logged / user notified
```

Handle the benign race (two app tabs refreshing at the same moment) with a short grace
window (~10 s) in which the *immediately* replaced token returns the same new pair.

### 2.4 Passwords and OTP

- **argon2id** via `pwdlib` (already a dependency), with a server-side pepper from the secret store. Drop `bcrypt` from dependencies once migrated, or keep it only for verifying legacy hashes.
- Minimum 10 characters; check against breached passwords (HaveIBeenPwned k-anonymity API).
- Login responses identical for "no such user" and "wrong password"; constant-time compare.
- Phone OTP (production norm for ride-hailing in India): 6 digits, 5-minute TTL, 5 attempts max, stored hashed in Redis, rate-limited per phone + per IP + per device.
- Admin accounts: **TOTP MFA required**.

---

## 3. Authorization: RBAC plus ownership (ABAC-lite)

Roles: `RIDER`, `DRIVER`, `SUPPORT`, `ADMIN`. RBAC alone isn't enough: a RIDER may read
*a* ride only if it's *their* ride. Every resource access needs an **ownership policy**.

```python
class Permission(StrEnum):
    RIDE_READ_OWN = "ride:read:own"; RIDE_READ_ANY = "ride:read:any"
    RIDE_CANCEL_OWN = "ride:cancel:own"; TRIP_OPERATE_OWN = "trip:operate:own"
    USER_SUSPEND = "user:suspend"; REFUND_ISSUE = "refund:issue"; RATECARD_WRITE = "ratecard:write"

ROLE_PERMISSIONS = {
    "RIDER":   {RIDE_READ_OWN, RIDE_CANCEL_OWN},
    "DRIVER":  {TRIP_OPERATE_OWN},
    "SUPPORT": {RIDE_READ_ANY, REFUND_ISSUE},
    "ADMIN":   {RIDE_READ_ANY, USER_SUSPEND, REFUND_ISSUE, RATECARD_WRITE},
}

def require(perm: Permission):
    def dep(principal: Principal = Depends(current_principal)) -> Principal:
        if perm not in principal.permissions:
            raise Forbidden()
        return principal
    return dep

# Ownership is enforced in the query itself, so it can't be forgotten in Python:
async def get_ride_for(principal, ride_id, repo) -> Ride:
    ride = await repo.get(ride_id,
        rider_id=None if principal.can(RIDE_READ_ANY) else principal.user_id)
    if ride is None:
        raise NotFound("RIDE_NOT_FOUND")      # 404, not 403: don't leak existence
    return ride
```

Write a test suite that walks **every route** in the OpenAPI spec as (anonymous, rider A,
rider B, driver, admin) and asserts the expected status. That's how you catch BOLA
regressions systematically.

---

## 4. API rate limiting (layered)

| Layer | Mechanism | Limits |
|---|---|---|
| Edge | ingress-nginx `limit-rps` per IP | 50 rps, burst 150 |
| App (global) | Redis token bucket per `user_id` (authenticated) or IP | 20 rps |
| App (per endpoint) | Redis fixed/sliding window | login 5/min per IP+account; OTP 3/10 min per phone; quotes 30/min; rides 5/min; location 30/min per driver |
| Business | Domain rules | One active ride per rider (DB constraint); max declines per proposal window |

Respond `429` with `Retry-After` and `RateLimit-*` headers. Log and meter (`rate_limited_total{route}`).

---

## 5. Injection prevention

- **SQL:** SQLAlchemy Core/ORM with bound parameters only. For raw PostGIS SQL, use `text()` with `:params`, **never** f-strings. Add a ruff/bandit rule (`S608`) and a code-review checklist item. Dynamic `ORDER BY` / column names come from an **allow-list** mapping, never from user input.
- **Geometry input:** accept `lat/lng` numbers validated by Pydantic ranges, never WKT/GeoJSON strings passed through to `ST_GeomFromText`.
- **Mass assignment:** separate Pydantic request models from ORM models. Never `Model(**request.dict())`. Unknown fields rejected with `model_config = ConfigDict(extra="forbid")`.
- **SSRF:** the routing and PSP URLs come from config, never from requests. Restrict pod egress with NetworkPolicies.
- **Log injection:** structured JSON logging escapes control characters.
- **Deserialization:** JSON only; validate all Kafka payloads against schemas.

---

## 6. Secret management

| Environment | Mechanism |
|---|---|
| Local | `.env` (gitignored) loaded by `pydantic-settings`; `.env.example` with dummy values |
| CI | GitHub Environments secrets; cloud access via **OIDC federation** (no static keys) |
| Kubernetes | **External Secrets Operator** → cloud secret manager / Vault. Sealed Secrets for kind. |
| Database | Separate roles: `app_rw` (DML), `migrator` (DDL), `readonly` (analytics). With Vault, *dynamic* DB credentials (short-lived). |
| Rotation | JWT keys every 90 days (overlap via JWKS `kid`); DB passwords quarterly; PSP keys on staff change |
| Detection | gitleaks in pre-commit + CI; GitHub secret scanning + push protection |

`pydantic-settings` should type secrets as `SecretStr`, so they never print in logs or tracebacks.

---

## 7. Encryption

### In transit
- TLS 1.2+ (prefer 1.3) at the edge via cert-manager + Let's Encrypt; HSTS.
- **Inside the cluster:** Postgres `sslmode=verify-full` (CloudNativePG issues certs), Redis TLS, Kafka TLS + SASL/SCRAM or mTLS (Strimzi automates it). Service-to-service mTLS via a mesh (Linkerd is the lightest) once you have real microservices.
- Certificate pinning in mobile apps is optional and has operational risk. Know the tradeoff.

### At rest
- Volume encryption (cloud KMS-backed disks); encrypted backups (pgBackRest/Barman with KMS).
- **Application-level field encryption** for the most sensitive PII (phone number, saved home/work addresses): envelope encryption (data key per record, wrapped by a KMS key) using `cryptography`'s AES-GCM. Keep a **blind index** (HMAC of the normalized phone) for lookups on encrypted fields.
- Payment cards: **never stored**. Use PSP tokenization (Razorpay/Stripe SDKs) → PCI-DSS SAQ-A scope.
- Kubernetes Secrets: enable etcd encryption at rest (managed clusters do by default).

---

## 8. Privacy and compliance (DPDP Act 2023, India)

- Purpose limitation: location data used only for dispatch, safety, fraud, and billing.
- Retention: raw GPS 90 days → aggregate/anonymize (drop to H3 res-7) after that.
- Right to erasure: `DELETE /v1/me` triggers a saga that anonymizes the user across modules (rides keep financial records with pseudonymous ids, as tax law requires).
- Masked phone numbers between rider and driver (proxy numbers via the telephony provider).
- Admin access to PII is logged in `platform.audit_log` and reviewed.

---

## 9. Security headers and app hardening

`Strict-Transport-Security`, `X-Content-Type-Options: nosniff`, `Content-Security-Policy` (admin
UI), `Referrer-Policy: no-referrer`. A strict CORS allow-list (admin origin only). Request body
size limits (1 MB). Disable `/docs` and `/redoc` in prod, or protect them behind admin auth.
Generic 500 responses (no stack traces). Dependency pinning via `poetry.lock` + Dependabot +
`pip-audit`. Container images: non-root, read-only rootfs, distroless or slim base, Trivy-scanned, cosign-signed.