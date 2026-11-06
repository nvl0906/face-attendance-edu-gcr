#!/usr/bin/env bash

set -e
set -o pipefail
set -u

echo "############# Deploying the Cloud Run service $SERVICE_NAME"

gcloud run deploy "$SERVICE_NAME" \
  --image "$LOCATION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$SERVICE_NAME:$IMAGE_TAG" \
  --region "$LOCATION" \
  --project "$PROJECT_ID" \
  --platform "managed" \
  --allow-unauthenticated \
  --set-secrets=FAE_SUPABASE_URL=FAE_SUPABASE_URL:latest,FAE_SUPABASE_KEY=FAE_SUPABASE_KEY:latest,FAE_JWT_SECRET=FAE_JWT_SECRET:latest,FAE_JWT_ALGORITHM=FAE_JWT_ALGORITHM:latest
  
