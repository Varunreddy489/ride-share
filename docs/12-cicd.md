# 12 — CI/CD Design (GitHub Actions)

> Covers prompt section 14.

---

## 1. Pipeline architecture

```mermaid
flowchart LR
  subgraph PR["Pull request (pr.yml)"]
    L[Lint + format<br/>ruff] --> TY[Type check<br/>mypy]
    TY --> UT[Unit tests<br/>pytest + coverage]
    L --> SEC[Security<br/>bandit, pip-audit,<br/>gitleaks, trivy fs]
    UT --> IT[Integration tests<br/>testcontainers]
    L --> ARCH[Architecture<br/>import-linter]
    L --> CON[Contracts<br/>oasdiff, event schemas]
    L --> MIG[Migration check<br/>upgrade/downgrade/drift]
  end
  subgraph MAIN["Push to main (main.yml)"]
    B[Build image<br/>buildx + cache] --> SCAN[Trivy image scan]
    SCAN --> E2E[E2E on kind<br/>+ smoke]
    E2E --> PUSH[Push to GHCR<br/>sha tag + SBOM + cosign]
  end
  subgraph DEPLOY["deploy.yml (reusable)"]
    STG[Staging<br/>migrate → rollout → smoke] --> GATE{Manual approval<br/>env: production}
    GATE --> PROD[Prod<br/>migrate → rollout → smoke]
    PROD -- smoke fails --> RB[kubectl rollout undo]
  end
  PR --> MAIN --> DEPLOY
```

**Principles:**
- **Build once, promote everywhere.** The same image digest goes dev → staging → prod. Only config differs.
- **Fast feedback first:** lint (~20 s) runs before tests (~2 min) runs before integration (~5 min).
- **Required checks + branch protection** on `main`: PR checks green, 1 review (or self-review via the PR template when solo), linear history.
- **Concurrency groups** cancel superseded runs on the same PR.
- **Pin third-party actions by commit SHA** (supply-chain safety; Dependabot updates them).
- **OIDC to the cloud** (no long-lived cloud keys in GitHub secrets).

**Tooling changes recommended for the repo:** replace `flake8` + `isort` (currently in
`pyproject.toml`) with **ruff** (lint + format + import sort; 10–100× faster, one config).
Add `mypy`, `pytest`, `pytest-asyncio`, `pytest-cov`, `testcontainers`, `hypothesis`,
`import-linter`, `bandit`, `pip-audit`.

**Python version risk:** the repo pins `requires-python = ">=3.15"`, and 3.15 came out only
weeks ago. Native-extension packages this design depends on (`asyncpg`, `psycopg[binary]`,
`confluent-kafka`, `h3`, `shapely`) often take months to publish wheels for a new Python.
Without wheels, the Docker build compiles from source or fails. Check each one now. If any
are missing, pin `>=3.13,<3.16` and use `python:3.13-slim` until they catch up. Production
teams usually run one minor version behind the latest for this reason.

---

## 2. Pull request pipeline: `.github/workflows/pr.yml`

```yaml
name: pr
on:
  pull_request:
    branches: [main]

concurrency:
  group: pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read

env:
  PYTHON_VERSION: "3.15"     # matches pyproject (>=3.15) and the Dockerfile base image. See note in §1.
  POETRY_VERSION: "2.1.3"

jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "${{ env.PYTHON_VERSION }}" }
      - run: pipx install poetry==${{ env.POETRY_VERSION }}
      - uses: actions/setup-python@v5
        with: { python-version: "${{ env.PYTHON_VERSION }}", cache: poetry }
      - run: poetry install --with dev --no-interaction
      - name: Ruff lint
        run: poetry run ruff check --output-format=github .
      - name: Ruff format check
        run: poetry run ruff format --check .
      - name: Type check
        run: poetry run mypy src
      - name: Layer boundaries (import-linter)
        run: poetry run lint-imports

  security:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions: { contents: read, security-events: write }
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - name: Secret scan
        uses: gitleaks/gitleaks-action@v2
        env: { GITHUB_TOKEN: "${{ secrets.GITHUB_TOKEN }}" }
      - uses: actions/setup-python@v5
        with: { python-version: "${{ env.PYTHON_VERSION }}" }
      - run: pipx install poetry==${{ env.POETRY_VERSION }} && poetry install --with dev
      - name: SAST (bandit)
        run: poetry run bandit -r src -ll -f sarif -o bandit.sarif || true
      - uses: github/codeql-action/upload-sarif@v3
        with: { sarif_file: bandit.sarif, category: bandit }
      - name: Dependency vulnerabilities
        run: poetry run pip-audit --strict
      - name: Filesystem / IaC scan (Dockerfile, k8s manifests)
        uses: aquasecurity/trivy-action@0.28.0
        with:
          scan-type: fs
          scanners: vuln,misconfig,secret
          severity: HIGH,CRITICAL
          exit-code: "1"

  unit-tests:
    runs-on: ubuntu-latest
    needs: lint
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "${{ env.PYTHON_VERSION }}" }
      - run: pipx install poetry==${{ env.POETRY_VERSION }} && poetry install --with dev
      - name: Unit tests
        run: >
          poetry run pytest tests/unit -n auto
          --cov=src --cov-branch --cov-report=xml --cov-report=term-missing
          --cov-fail-under=85 --junitxml=junit-unit.xml
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: unit-results, path: "junit-unit.xml\ncoverage.xml" }

  integration-tests:
    runs-on: ubuntu-latest
    needs: unit-tests
    timeout-minutes: 25
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "${{ env.PYTHON_VERSION }}" }
      - run: pipx install poetry==${{ env.POETRY_VERSION }} && poetry install --with dev
      - name: Integration tests (testcontainers - postgis, redis, kafka)
        run: poetry run pytest tests/integration --junitxml=junit-int.xml
      - name: Contract tests (API fuzz + event schemas)
        run: poetry run pytest tests/contract

  migrations:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    services:
      postgres:
        image: postgis/postgis:16-3.4
        env: { POSTGRES_PASSWORD: postgres, POSTGRES_DB: rideshare }
        ports: ["5432:5432"]
        options: --health-cmd pg_isready --health-interval 5s --health-retries 10
    env:
      DATABASE_URL: postgresql+psycopg://postgres:postgres@localhost:5432/rideshare
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "${{ env.PYTHON_VERSION }}" }
      - run: pipx install poetry==${{ env.POETRY_VERSION }} && poetry install
      - name: Upgrade → downgrade → upgrade (reversibility)
        run: |
          poetry run alembic upgrade head
          poetry run alembic downgrade base
          poetry run alembic upgrade head
      - name: Models and migrations in sync (no pending autogenerate diff)
        run: poetry run alembic check
      - name: Lint migrations for dangerous operations
        run: poetry run python scripts/lint_migrations.py   # blocks e.g. non-concurrent CREATE INDEX, ADD COLUMN ... NOT NULL without default

  api-contract:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-python@v5
        with: { python-version: "${{ env.PYTHON_VERSION }}" }
      - run: pipx install poetry==${{ env.POETRY_VERSION }} && poetry install
      - name: Export OpenAPI
        run: poetry run python -m scripts.export_openapi > openapi.new.json
      - name: Detect breaking API changes vs main
        uses: oasdiff/oasdiff-action/breaking@main
        with:
          base: contracts/openapi/openapi.json
          revision: openapi.new.json
          fail-on: ERR
```

---

## 3. Main branch pipeline: `.github/workflows/main.yml`

```yaml
name: main
on:
  push:
    branches: [main]

concurrency:
  group: main
  cancel-in-progress: false        # never cancel a half-finished release

permissions:
  contents: read
  packages: write
  id-token: write                  # cosign keyless signing + cloud OIDC

env:
  IMAGE: ghcr.io/${{ github.repository }}

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    outputs:
      digest: ${{ steps.build.outputs.digest }}
      tag: sha-${{ steps.vars.outputs.short_sha }}
    steps:
      - uses: actions/checkout@v4
      - id: vars
        run: echo "short_sha=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build (load locally for scanning + e2e)
        uses: docker/build-push-action@v6
        with:
          context: .
          load: true
          tags: ${{ env.IMAGE }}:sha-${{ steps.vars.outputs.short_sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          build-args: APP_VERSION=${{ github.sha }}
      - name: Scan image
        uses: aquasecurity/trivy-action@0.28.0
        with:
          image-ref: ${{ env.IMAGE }}:sha-${{ steps.vars.outputs.short_sha }}
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"
      - name: Save image for e2e job
        run: docker save ${{ env.IMAGE }}:sha-${{ steps.vars.outputs.short_sha }} -o image.tar
      - uses: actions/upload-artifact@v4
        with: { name: image, path: image.tar, retention-days: 1 }

  e2e:
    runs-on: ubuntu-latest
    needs: build
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { name: image }
      - name: Create kind cluster
        uses: helm/kind-action@v1
        with: { cluster_name: ci, config: deploy/kind/kind-ci.yaml }
      - name: Load image into kind
        run: |
          docker load -i image.tar
          kind load docker-image ${{ env.IMAGE }}:${{ needs.build.outputs.tag }} --name ci
      - name: Install dependencies (postgis, redis, kafka, osrm-small) into kind
        run: ./scripts/ci/install_deps_kind.sh
      - name: Deploy app (dev overlay)
        run: |
          cd deploy/k8s/overlays/dev
          kustomize edit set image rideshare=${{ env.IMAGE }}:${{ needs.build.outputs.tag }}
          kubectl apply -k .
          kubectl -n rideshare wait --for=condition=complete job -l app=db-migrate --timeout=180s
          kubectl -n rideshare rollout status deploy --timeout=300s
      - name: E2E suite (full ride lifecycle incl. pool match)
        run: |
          kubectl -n rideshare port-forward svc/api 8080:80 &
          pipx install poetry && poetry install --with dev
          BASE_URL=http://localhost:8080 poetry run pytest tests/e2e -v
      - name: Dump logs on failure
        if: failure()
        run: kubectl -n rideshare logs -l app.kubernetes.io/part-of=rideshare --tail=300 --prefix

  publish:
    runs-on: ubuntu-latest
    needs: [build, e2e]
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with: { registry: ghcr.io, username: "${{ github.actor }}", password: "${{ secrets.GITHUB_TOKEN }}" }
      - name: Build & push (cache hit, identical layers)
        id: push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ env.IMAGE }}:${{ needs.build.outputs.tag }}
          cache-from: type=gha
          sbom: true
          provenance: mode=max
          build-args: APP_VERSION=${{ github.sha }}
      - uses: sigstore/cosign-installer@v3
      - name: Sign image (keyless, OIDC)
        run: cosign sign --yes ${{ env.IMAGE }}@${{ steps.push.outputs.digest }}

  deploy-staging:
    needs: [build, publish]
    uses: ./.github/workflows/deploy.yml
    with:
      environment: staging
      image_tag: ${{ needs.build.outputs.tag }}
    secrets: inherit

  deploy-prod:
    needs: [build, deploy-staging]
    uses: ./.github/workflows/deploy.yml
    with:
      environment: production        # GitHub Environment with required reviewers → manual gate
      image_tag: ${{ needs.build.outputs.tag }}
    secrets: inherit
```

---

## 4. Deployment pipeline: `.github/workflows/deploy.yml` (reusable)

```yaml
name: deploy
on:
  workflow_call:
    inputs:
      environment: { type: string, required: true }
      image_tag:   { type: string, required: true }
  workflow_dispatch:                       # manual deploys / rollbacks to a specific tag
    inputs:
      environment: { type: choice, options: [staging, production], required: true }
      image_tag:   { type: string, required: true }

permissions:
  contents: read
  id-token: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    timeout-minutes: 30
    concurrency:
      group: deploy-${{ inputs.environment }}
      cancel-in-progress: false
    env:
      NS: ${{ inputs.environment == 'production' && 'rideshare' || 'rideshare-staging' }}
      OVERLAY: ${{ inputs.environment == 'production' && 'prod' || 'staging' }}
      IMAGE: ghcr.io/${{ github.repository }}:${{ inputs.image_tag }}
    steps:
      - uses: actions/checkout@v4

      - name: Authenticate to cluster (OIDC → cloud → kubeconfig)
        uses: ./.github/actions/kube-auth                 # e.g. google-github-actions/auth + get-gke-credentials
        with: { environment: "${{ inputs.environment }}" }

      - name: Verify image signature
        run: |
          cosign verify "$IMAGE" \
            --certificate-identity-regexp "^https://github.com/${{ github.repository }}/" \
            --certificate-oidc-issuer https://token.actions.githubusercontent.com

      - name: Record current revision (for rollback)
        id: prev
        run: |
          echo "image=$(kubectl -n $NS get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}' || echo none)" >> "$GITHUB_OUTPUT"

      - name: Run DB migrations (expand-only migrations are backward-compatible)
        run: |
          JOB=db-migrate-${{ inputs.image_tag }}
          sed "s|IMAGE_PLACEHOLDER|$IMAGE|; s|JOB_NAME|$JOB|" deploy/k8s/jobs/migrate.yaml | kubectl -n $NS apply -f -
          kubectl -n $NS wait --for=condition=complete job/$JOB --timeout=600s \
            || { kubectl -n $NS logs job/$JOB; exit 1; }

      - name: Apply manifests
        run: |
          cd deploy/k8s/overlays/$OVERLAY
          kustomize edit set image rideshare=$IMAGE
          kubectl apply -k . --server-side
      - name: Wait for rollout
        run: |
          for d in api location-ingest tracking-gateway matching-worker consumers outbox-relay; do
            kubectl -n $NS rollout status deploy/$d --timeout=300s
          done

      - name: Smoke tests
        id: smoke
        run: |
          BASE_URL=${{ vars.BASE_URL }} ./scripts/smoke.sh
          # health → login (synthetic user) → fare quote → create ride → cancel ride → ride is CANCELLED

      - name: Check error rate didn't regress (5 min bake)
        if: inputs.environment == 'production'
        run: ./scripts/check_slo_burn.sh --prometheus ${{ vars.PROM_URL }} --window 5m --max-error-ratio 0.01

      - name: Rollback on failure
        if: failure() && steps.prev.outputs.image != 'none'
        run: |
          echo "::error::Deploy failed. Rolling back to ${{ steps.prev.outputs.image }}"
          for d in api location-ingest tracking-gateway matching-worker consumers outbox-relay; do
            kubectl -n $NS rollout undo deploy/$d
          done
          for d in api location-ingest tracking-gateway matching-worker consumers outbox-relay; do
            kubectl -n $NS rollout status deploy/$d --timeout=300s
          done
```

---

## 5. Rollback strategy

| Layer | Strategy |
|---|---|
| **Application** | `kubectl rollout undo` (automated in deploy.yml), or re-run `deploy.yml` via `workflow_dispatch` with the previous `image_tag`. Fast (~1 min) because images are immutable and cached on nodes. |
| **Database** | **Never roll back schema in an incident.** Migrations follow **expand → contract**: each release's migration is compatible with the *previous* code version. So rolling back code is always safe, and the schema stays forward. `downgrade()` exists for dev/CI reversibility tests, not prod. |
| **Events** | Consumers must tolerate fields from newer producers (backward/forward compatibility, doc 09 §6). Rolling back a producer must not break consumers. |
| **Config / flags** | Prefer **feature flags** to rollbacks for behavioral changes (e.g. a new matching algorithm). Flip the flag off: seconds, no deploy. |
| **Progressive delivery (advanced)** | **Argo Rollouts** canary: 5% → 25% → 100% with Prometheus analysis (error rate, p99) between steps, automatic abort. This is the industry-standard next step after rolling updates. |

---

## 6. Supporting files

- `.pre-commit-config.yaml` (currently empty): ruff, ruff-format, mypy (staged files), gitleaks, end-of-file-fixer, check-yaml.
- `.github/dependabot.yml`: weekly updates for `pip`, `github-actions`, `docker`.
- `.github/pull_request_template.md`: what/why, test evidence, migration safety checklist, rollback plan.
- `CODEOWNERS`: even solo, it documents ownership for the future.