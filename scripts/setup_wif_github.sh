#!/usr/bin/env bash
#
# setup_wif_github.sh
# One-time setup so a GitHub Actions workflow can deploy to Cloud Run
# through Workload Identity Federation (no JSON keys).
#
# Configuration comes from environment variables, normally loaded by
# sourcing your .envrc first:
#
#   source .envrc
#   ./scripts/setup_wif_github.sh
#
# Required : PROJECT_ID, LOCATION, GITHUB_OWNER, GITHUB_REPO
# Optional : BRANCH          [main]
#            POOL            [github-pool]
#            PROVIDER        [github-provider]
#            DEPLOYER        [gh-deployer]
#            DEPLOYER_EMAIL  [<DEPLOYER>@<PROJECT_ID>.iam.gserviceaccount.com]
#            PROJECT_NUMBER  [looked up with gcloud]
#            BUILD_SA        [detected from your last build, else Compute default]
#            SERVICE_NAME    [face-attendance-edu]   (workflow file only)
#            REPO_NAME       [face-attendance-edu-repo] (workflow file only)
#            CONFIG_FILE     [deploy_face_attendance_edu_to_gcr.yaml] (workflow file only)
#            YES=1              skip the confirmation prompt
#            WRITE_WORKFLOW=1   write .github/workflows/deploy-cloud-run.yml in the
#                               current directory (run from your repo root)
#
# Safe to re-run: existing resources are reused or updated.

set -euo pipefail

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }

# ---------------------------------------------------------------- config
: "${PROJECT_ID:?PROJECT_ID is not set. Did you run: source .envrc ?}"
: "${LOCATION:?LOCATION is not set. Did you run: source .envrc ?}"
: "${GITHUB_OWNER:?GITHUB_OWNER is not set. Did you run: source .envrc ?}"
: "${GITHUB_REPO:?GITHUB_REPO is not set. Did you run: source .envrc ?}"

BRANCH="${BRANCH:-main}"
POOL="${POOL:-github-pool}"
PROVIDER="${PROVIDER:-github-provider}"
DEPLOYER="${DEPLOYER:-gh-deployer}"
DEPLOYER_EMAIL="${DEPLOYER_EMAIL:-${DEPLOYER}@${PROJECT_ID}.iam.gserviceaccount.com}"

SERVICE_NAME="${SERVICE_NAME:-face-attendance-edu}"
REPO_NAME="${REPO_NAME:-face-attendance-edu-repo}"
CONFIG_FILE="${CONFIG_FILE:-deploy_face_attendance_edu_to_gcr.yaml}"

GITHUB_SLUG="${GITHUB_OWNER}/${GITHUB_REPO}"
BUCKET="gs://${PROJECT_ID}_cloudbuild"

# ---------------------------------------------------------------- checks
command -v gcloud >/dev/null || { echo "gcloud CLI not found"; exit 1; }

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n1)"
[[ -n "$ACTIVE_ACCOUNT" ]] || { echo "Not logged in. Run: gcloud auth login"; exit 1; }

PROJECT_NUMBER="${PROJECT_NUMBER:-$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')}"

# Service account Cloud Build runs builds as (the one that already deploys your first app)
BUILD_SA="${BUILD_SA:-}"
if [[ -z "$BUILD_SA" ]]; then
  BUILD_SA="$(gcloud builds list --region="$LOCATION" --project="$PROJECT_ID" --limit=1 \
              --format='value(serviceAccount)' 2>/dev/null || true)"
  BUILD_SA="${BUILD_SA##*/}"   # strip projects/.../serviceAccounts/ prefix if present
fi
if [[ -z "$BUILD_SA" ]]; then
  BUILD_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
  warn "Could not detect the build service account, assuming the Compute default one."
  warn "If your builds run as another account, set BUILD_SA in .envrc."
fi

WIF_PROVIDER_NAME="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
PRINCIPAL_SET="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${GITHUB_SLUG}"
ATTR_CONDITION="assertion.repository=='${GITHUB_SLUG}' && assertion.ref=='refs/heads/${BRANCH}'"

cat <<EOF

Plan
----
Logged in as        : ${ACTIVE_ACCOUNT}
Project             : ${PROJECT_ID} (number ${PROJECT_NUMBER})
Region              : ${LOCATION}
GitHub repo         : ${GITHUB_SLUG} (branch: ${BRANCH})
Pool / provider     : ${POOL} / ${PROVIDER}
Deployer account    : ${DEPLOYER_EMAIL}
Build account       : ${BUILD_SA}
Staging bucket      : ${BUCKET}
EOF

if [[ "${YES:-0}" != "1" ]]; then
  read -r -p $'\nProceed? [y/N] ' ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------- 1. APIs
log "1/8 Enabling required APIs"
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  cloudbuild.googleapis.com \
  --project "$PROJECT_ID"

# ---------------------------------------------------------------- 2. deployer SA
log "2/8 Creating deployer service account"
if gcloud iam service-accounts describe "$DEPLOYER_EMAIL" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Already exists: $DEPLOYER_EMAIL"
else
  gcloud iam service-accounts create "$DEPLOYER" \
    --display-name="GitHub Actions deployer (${GITHUB_REPO})" \
    --project "$PROJECT_ID"
  echo "Waiting for the new account to propagate..."
  sleep 15
fi

# ---------------------------------------------------------------- 3. deployer roles
log "3/8 Granting the deployer its roles"

# Start builds
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEPLOYER_EMAIL}" \
  --role="roles/cloudbuild.builds.editor" \
  --condition=None --quiet >/dev/null

# Read build logs (so the GitHub job can stream them and fail when the build fails)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEPLOYER_EMAIL}" \
  --role="roles/logging.viewer" \
  --condition=None --quiet >/dev/null

# Allowed to run builds "as" the build service account
gcloud iam service-accounts add-iam-policy-binding "$BUILD_SA" \
  --member="serviceAccount:${DEPLOYER_EMAIL}" \
  --role="roles/iam.serviceAccountUser" \
  --project "$PROJECT_ID" --quiet >/dev/null

# Upload source to the Cloud Build staging bucket
if ! gcloud storage buckets describe "$BUCKET" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Staging bucket missing, creating $BUCKET"
  gcloud storage buckets create "$BUCKET" \
    --project "$PROJECT_ID" --location "$LOCATION" --uniform-bucket-level-access
fi
gcloud storage buckets add-iam-policy-binding "$BUCKET" \
  --member="serviceAccount:${DEPLOYER_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null

# ---------------------------------------------------------------- 4. pool
log "4/8 Workload Identity Pool"
if gcloud iam workload-identity-pools describe "$POOL" \
     --project "$PROJECT_ID" --location global >/dev/null 2>&1; then
  echo "Pool already exists: $POOL"
else
  gcloud iam workload-identity-pools create "$POOL" \
    --project "$PROJECT_ID" --location global \
    --display-name="GitHub Actions"
fi

# ---------------------------------------------------------------- 5. provider
log "5/8 GitHub OIDC provider (locked to ${GITHUB_SLUG} on ${BRANCH})"
if gcloud iam workload-identity-pools providers describe "$PROVIDER" \
     --project "$PROJECT_ID" --location global --workload-identity-pool "$POOL" >/dev/null 2>&1; then
  echo "Provider exists, updating its condition"
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER" \
    --project "$PROJECT_ID" --location global --workload-identity-pool "$POOL" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition="$ATTR_CONDITION"
else
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --project "$PROJECT_ID" --location global --workload-identity-pool "$POOL" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition="$ATTR_CONDITION"
fi

# ---------------------------------------------------------------- 6. impersonation binding
log "6/8 Letting ${GITHUB_SLUG} impersonate the deployer"
gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER_EMAIL" \
  --project "$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$PRINCIPAL_SET" --quiet >/dev/null

# ---------------------------------------------------------------- 7. GitHub variables
log "7/8 GitHub repository variables"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if gh variable set WIF_PROVIDER --body "$WIF_PROVIDER_NAME" --repo "$GITHUB_SLUG" \
     && gh variable set DEPLOYER_SA --body "$DEPLOYER_EMAIL" --repo "$GITHUB_SLUG"; then
    echo "Variables WIF_PROVIDER and DEPLOYER_SA set on ${GITHUB_SLUG}."
  else
    warn "Could not set the variables (does ${GITHUB_SLUG} exist on GitHub yet?)."
    warn "Add them manually, see the summary at the end."
  fi
else
  echo "gh CLI not available or not logged in. Add the two variables manually,"
  echo "see the summary at the end."
fi

# ---------------------------------------------------------------- 8. workflow file
log "8/8 Workflow file"
if [[ "${WRITE_WORKFLOW:-0}" == "1" ]]; then
  WF=".github/workflows/deploy-cloud-run.yml"
  if [[ -e "$WF" ]]; then
    warn "$WF already exists, not overwriting."
  else
    mkdir -p .github/workflows
    cat > "$WF" <<'YAML'
name: Deploy to Cloud Run

on:
  push:
    branches: [__BRANCH__]
  workflow_dispatch:

permissions:
  contents: read
  id-token: write

env:
  PROJECT_ID: __PROJECT_ID__
  LOCATION: __LOCATION__
  SERVICE_NAME: __SERVICE_NAME__
  REPO_NAME: __REPO_NAME__

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.WIF_PROVIDER }}
          service_account: ${{ vars.DEPLOYER_SA }}

      - uses: google-github-actions/setup-gcloud@v2

      - name: Build, push and deploy
        run: |
          gcloud builds submit . \
            --config __CONFIG_FILE__ \
            --region "$LOCATION" \
            --project "$PROJECT_ID" \
            --substitutions=_REPO_NAME=$REPO_NAME,_SERVICE_NAME=$SERVICE_NAME,_IMAGE_TAG=${GITHUB_SHA::7}
YAML
    sed -i \
      -e "s|__BRANCH__|${BRANCH}|g" \
      -e "s|__PROJECT_ID__|${PROJECT_ID}|g" \
      -e "s|__LOCATION__|${LOCATION}|g" \
      -e "s|__SERVICE_NAME__|${SERVICE_NAME}|g" \
      -e "s|__REPO_NAME__|${REPO_NAME}|g" \
      -e "s|__CONFIG_FILE__|${CONFIG_FILE}|g" \
      "$WF"
    echo "Wrote $WF"
  fi
else
  echo "Skipped (run with WRITE_WORKFLOW=1 from your repo root to generate it)."
fi

# ---------------------------------------------------------------- summary
cat <<EOF

Done.

GitHub repository variables (Settings > Secrets and variables > Actions > Variables):
  WIF_PROVIDER = ${WIF_PROVIDER_NAME}
  DEPLOYER_SA  = ${DEPLOYER_EMAIL}

Next:
  1. chmod +x scripts/deploy_face_attendance_edu_to_gcr.sh
  2. Commit the workflow and push to '${BRANCH}' (or use "Run workflow" in the Actions tab).
  3. Check: gcloud run services describe ${SERVICE_NAME} --region ${LOCATION} --format='value(status.url)'

Reminder: the Cloud Run runtime account needs roles/secretmanager.secretAccessor on the
FAE_* secrets for --set-secrets, and ${BUILD_SA} needs it too if your yaml
still has the availableSecrets block.
EOF