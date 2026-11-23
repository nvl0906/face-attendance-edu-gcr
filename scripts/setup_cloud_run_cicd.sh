#!/usr/bin/env bash
#
# setup_cloud_run_cicd.sh
#
# One-time setup to deploy a FastAPI app to Cloud Run from GitHub Actions
# using Workload Identity Federation (no JSON keys).
#
# It does everything we had to fix along the way:
#   - enables the APIs
#   - creates the Artifact Registry repo
#   - lets the Cloud Run runtime account read the app's secrets
#   - gives the build account what it needs to push images and deploy
#     (including changing who may invoke the service)
#   - creates the GitHub "deployer" service account with its minimal roles,
#     including Service Usage Consumer and bucket access for `gcloud builds submit`
#   - creates the Workload Identity pool/provider, locked to one repo and branch
#   - makes the Cloud Run service public (if it already exists)
#   - sets the GitHub repo variables (if the gh CLI is available)
#   - makes the deploy script executable and writes the workflow file
#
# Usage:
#   cd <your repo root>
#   source .envrc
#   ./scripts/setup_cloud_run_cicd.sh
#
# Required env : PROJECT_ID  LOCATION  GITHUB_OWNER  GITHUB_REPO  SERVICE_NAME  REPO_NAME
# Optional env (defaults in brackets):
#   BRANCH            [main]
#   POOL              [github-pool]
#   PROVIDER          [github-provider]
#   DEPLOYER          [gh-deployer]
#   DEPLOYER_EMAIL    [<DEPLOYER>@<PROJECT_ID>.iam.gserviceaccount.com]
#   PROJECT_NUMBER    [looked up with gcloud]
#   BUILD_SA          [detected from your last build, else the Compute default account]
#   RUNTIME_SA        [the Compute default account, what Cloud Run uses unless you changed it]
#   SECRETS           [FAE_SUPABASE_URL FAE_SUPABASE_KEY FAE_JWT_SECRET FAE_JWT_ALGORITHM]
#   CONFIG_FILE       [deploy_face_attendance_edu_to_gcr.yaml]
#   DEPLOY_SCRIPT     [scripts/deploy_face_attendance_edu_to_gcr.sh]
#   ALLOW_PUBLIC      [1]  make the Cloud Run service publicly invokable (0 to skip)
#   WRITE_WORKFLOW    [1]  write .github/workflows/deploy-cloud-run.yml (0 to skip)
#   YES=1                  skip the confirmation prompt
#
# Safe to re-run: existing resources are reused or updated.
 
set -euo pipefail
 
TOTAL=11
step() { printf '\n\033[1;34m==> %s/%s %s\033[0m\n' "$1" "$TOTAL" "$2"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
 
# ---------------------------------------------------------------- config
: "${PROJECT_ID:?PROJECT_ID is not set. Did you run: source .envrc ?}"
: "${LOCATION:?LOCATION is not set. Did you run: source .envrc ?}"
: "${GITHUB_OWNER:?GITHUB_OWNER is not set. Did you run: source .envrc ?}"
: "${GITHUB_REPO:?GITHUB_REPO is not set. Did you run: source .envrc ?}"
: "${SERVICE_NAME:?SERVICE_NAME is not set. Did you run: source .envrc ?}"
: "${REPO_NAME:?REPO_NAME is not set. Did you run: source .envrc ?}"
 
BRANCH="${BRANCH:-main}"
POOL="${POOL:-github-pool}"
PROVIDER="${PROVIDER:-github-provider}"
DEPLOYER="${DEPLOYER:-gh-deployer}"
DEPLOYER_EMAIL="${DEPLOYER_EMAIL:-${DEPLOYER}@${PROJECT_ID}.iam.gserviceaccount.com}"
SECRETS="${SECRETS:-FAE_SUPABASE_URL FAE_SUPABASE_KEY FAE_JWT_SECRET FAE_JWT_ALGORITHM}"
CONFIG_FILE="${CONFIG_FILE:-deploy_face_attendance_edu_to_gcr.yaml}"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-scripts/deploy_face_attendance_edu_to_gcr.sh}"
ALLOW_PUBLIC="${ALLOW_PUBLIC:-1}"
WRITE_WORKFLOW="${WRITE_WORKFLOW:-1}"
 
GITHUB_SLUG="${GITHUB_OWNER}/${GITHUB_REPO}"
BUCKET="gs://${PROJECT_ID}_cloudbuild"
read -r -a SECRET_LIST <<< "$SECRETS"
 
# ---------------------------------------------------------------- checks
command -v gcloud >/dev/null || { echo "gcloud CLI not found"; exit 1; }
 
ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n1)"
[[ -n "$ACTIVE_ACCOUNT" ]] || { echo "Not logged in. Run: gcloud auth login"; exit 1; }
 
PROJECT_NUMBER="${PROJECT_NUMBER:-$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')}"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
RUNTIME_SA="${RUNTIME_SA:-$COMPUTE_SA}"
 
# Service account Cloud Build runs builds as (the one that already deploys your first app)
BUILD_SA="${BUILD_SA:-}"
if [[ -z "$BUILD_SA" ]]; then
  BUILD_SA="$(gcloud builds list --region="$LOCATION" --project="$PROJECT_ID" --limit=1 \
              --format='value(serviceAccount)' 2>/dev/null || true)"
  BUILD_SA="${BUILD_SA##*/}"   # strip projects/.../serviceAccounts/ prefix if present
fi
if [[ -z "$BUILD_SA" ]]; then
  BUILD_SA="$COMPUTE_SA"
  warn "Could not detect the build service account, assuming the Compute default one."
  warn "If your builds run as another account, set BUILD_SA in .envrc."
fi
 
WIF_PROVIDER_NAME="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
PRINCIPAL_SET="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${GITHUB_SLUG}"
ATTR_CONDITION="assertion.repository=='${GITHUB_SLUG}' && assertion.ref=='refs/heads/${BRANCH}'"
 
bind_project() {  # <member> <role>
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="$1" --role="$2" --condition=None --quiet >/dev/null
}
 
cat <<EOF
 
Plan
----
Logged in as        : ${ACTIVE_ACCOUNT}
Project             : ${PROJECT_ID} (number ${PROJECT_NUMBER})
Region              : ${LOCATION}
Cloud Run service   : ${SERVICE_NAME}  (public: ${ALLOW_PUBLIC})
Artifact repo       : ${REPO_NAME}
Secrets             : ${SECRETS}
GitHub repo         : ${GITHUB_SLUG} (branch: ${BRANCH})
Pool / provider     : ${POOL} / ${PROVIDER}
Deployer account    : ${DEPLOYER_EMAIL}
Build account       : ${BUILD_SA}
Runtime account     : ${RUNTIME_SA}
Staging bucket      : ${BUCKET}
EOF
 
if [[ "${YES:-0}" != "1" ]]; then
  read -r -p $'\nProceed? [y/N] ' ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi
 
# ---------------------------------------------------------------- 1. APIs
step 1 "Enabling required APIs"
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  serviceusage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project "$PROJECT_ID"
 
# ---------------------------------------------------------------- 2. Artifact Registry
step 2 "Artifact Registry repository ${REPO_NAME}"
if gcloud artifacts repositories describe "$REPO_NAME" \
     --location "$LOCATION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Already exists: $REPO_NAME"
else
  gcloud artifacts repositories create "$REPO_NAME" \
    --repository-format=docker --location "$LOCATION" --project "$PROJECT_ID"
fi
 
# ---------------------------------------------------------------- 3. secrets access
step 3 "Letting the Cloud Run runtime account read the secrets"
for s in "${SECRET_LIST[@]}"; do
  if gcloud secrets describe "$s" --project "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud secrets add-iam-policy-binding "$s" --project "$PROJECT_ID" \
      --member="serviceAccount:${RUNTIME_SA}" \
      --role="roles/secretmanager.secretAccessor" --quiet >/dev/null
    echo "OK: $s"
  else
    warn "Secret $s does not exist, skipped. Create it first, then re-run."
  fi
done
 
# ---------------------------------------------------------------- 4. build account roles
step 4 "Roles for the build account (push images, deploy, set invoker policy)"
bind_project "serviceAccount:${BUILD_SA}" "roles/run.admin"                 # deploy AND change who can invoke
bind_project "serviceAccount:${BUILD_SA}" "roles/artifactregistry.writer"   # push images
bind_project "serviceAccount:${BUILD_SA}" "roles/logging.logWriter"         # CLOUD_LOGGING_ONLY builds
gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --member="serviceAccount:${BUILD_SA}" \
  --role="roles/iam.serviceAccountUser" \
  --project "$PROJECT_ID" --quiet >/dev/null                                # deploy "as" the runtime account
 
# ---------------------------------------------------------------- 5. deployer SA
step 5 "GitHub deployer service account and its roles"
if gcloud iam service-accounts describe "$DEPLOYER_EMAIL" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Already exists: $DEPLOYER_EMAIL"
else
  gcloud iam service-accounts create "$DEPLOYER" \
    --display-name="GitHub Actions deployer (${GITHUB_REPO})" \
    --project "$PROJECT_ID"
  echo "Waiting for the new account to propagate..."
  sleep 15
fi
bind_project "serviceAccount:${DEPLOYER_EMAIL}" "roles/cloudbuild.builds.editor"            # start builds
bind_project "serviceAccount:${DEPLOYER_EMAIL}" "roles/logging.viewer"                      # stream build logs
bind_project "serviceAccount:${DEPLOYER_EMAIL}" "roles/serviceusage.serviceUsageConsumer"   # use project APIs/quota
gcloud iam service-accounts add-iam-policy-binding "$BUILD_SA" \
  --member="serviceAccount:${DEPLOYER_EMAIL}" \
  --role="roles/iam.serviceAccountUser" \
  --project "$PROJECT_ID" --quiet >/dev/null                                                # run builds "as" the build account
 
# ---------------------------------------------------------------- 6. staging bucket
step 6 "Cloud Build staging bucket ${BUCKET}"
if ! gcloud storage buckets describe "$BUCKET" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Bucket missing, creating it"
  gcloud storage buckets create "$BUCKET" \
    --project "$PROJECT_ID" --location "$LOCATION" --uniform-bucket-level-access
fi
gcloud storage buckets add-iam-policy-binding "$BUCKET" \
  --member="serviceAccount:${DEPLOYER_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null        # upload source
gcloud storage buckets add-iam-policy-binding "$BUCKET" \
  --member="serviceAccount:${DEPLOYER_EMAIL}" \
  --role="roles/storage.legacyBucketReader" >/dev/null # look the bucket up (storage.buckets.get)
 
# ---------------------------------------------------------------- 7. WIF pool + provider
step 7 "Workload Identity pool and GitHub provider (locked to ${GITHUB_SLUG} on ${BRANCH})"
if gcloud iam workload-identity-pools describe "$POOL" \
     --project "$PROJECT_ID" --location global >/dev/null 2>&1; then
  echo "Pool already exists: $POOL"
else
  gcloud iam workload-identity-pools create "$POOL" \
    --project "$PROJECT_ID" --location global --display-name="GitHub Actions"
fi
 
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
 
# ---------------------------------------------------------------- 8. impersonation
step 8 "Letting ${GITHUB_SLUG} impersonate the deployer"
gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER_EMAIL" \
  --project "$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$PRINCIPAL_SET" --quiet >/dev/null
 
# ---------------------------------------------------------------- 9. public access
step 9 "Public access to the Cloud Run service"
if [[ "$ALLOW_PUBLIC" != "1" ]]; then
  echo "Skipped (ALLOW_PUBLIC=0)."
elif gcloud run services describe "$SERVICE_NAME" --region "$LOCATION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  if gcloud run services add-iam-policy-binding "$SERVICE_NAME" \
       --region "$LOCATION" --project "$PROJECT_ID" \
       --member="allUsers" --role="roles/run.invoker" --quiet >/dev/null; then
    echo "allUsers can now invoke ${SERVICE_NAME}."
  else
    warn "Could not bind allUsers (an organization policy may block it). Alternative:"
    warn "  gcloud run services update ${SERVICE_NAME} --region ${LOCATION} --project ${PROJECT_ID} --no-invoker-iam-check"
  fi
else
  echo "Service ${SERVICE_NAME} does not exist yet. The first deploy will make it public"
  echo "(--allow-unauthenticated), now that the build account has roles/run.admin."
fi
 
# ---------------------------------------------------------------- 10. GitHub variables
step 10 "GitHub repository variables"
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
 
# ---------------------------------------------------------------- 11. repo files
step 11 "Repo files (deploy script permissions, workflow)"
if [[ -f "$DEPLOY_SCRIPT" ]]; then
  chmod +x "$DEPLOY_SCRIPT"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git update-index --add --chmod=+x "$DEPLOY_SCRIPT"
    echo "$DEPLOY_SCRIPT is executable and marked executable in git."
  else
    echo "$DEPLOY_SCRIPT is executable. Not a git repo yet: after git init, run:"
    echo "  git update-index --add --chmod=+x $DEPLOY_SCRIPT"
  fi
else
  warn "$DEPLOY_SCRIPT not found here. Run this script from your repo root."
fi
 
if [[ "$WRITE_WORKFLOW" == "1" ]]; then
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
            --gcs-source-staging-dir="gs://${PROJECT_ID}_cloudbuild/source" \
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
  echo "Workflow file skipped (WRITE_WORKFLOW=0)."
fi
 
# ---------------------------------------------------------------- summary
cat <<EOF
 
Done.
 
GitHub repository variables (Settings > Secrets and variables > Actions > Variables):
  WIF_PROVIDER = ${WIF_PROVIDER_NAME}
  DEPLOYER_SA  = ${DEPLOYER_EMAIL}
 
Next:
  1. git add .github ${DEPLOY_SCRIPT} && git commit -m "CI/CD" && git push origin ${BRANCH}
  2. Watch the run in the GitHub Actions tab.
  3. Check the service:
       gcloud run services describe ${SERVICE_NAME} --region ${LOCATION} --format='value(status.url)'
       curl -i "\$(gcloud run services describe ${SERVICE_NAME} --region ${LOCATION} --format='value(status.url)')/docs"
 
For another app: copy .envrc, change SERVICE_NAME, REPO_NAME, GITHUB_REPO, SECRETS, CONFIG_FILE,
DEPLOY_SCRIPT, and use a new PROVIDER and DEPLOYER (e.g. github-provider-app2, gh-deployer-app2).
EOF