#!/bin/bash
# Copyright 2025 Google LLC
# Licensed under the Apache License, Version 2.0

set -e

PROJECT_ID="acn-cloud-solution-factory"
REGION="europe-west1"
JOB_NAME="cstudio-db-migrate"

echo "===================================================="
echo " Running Database Migration via Cloud Run Job"
echo "===================================================="
echo ""
echo "The migration job runs inside the VPC with private"
echo "access to Cloud SQL. No proxy needed."
echo ""

# Before running, update the job image to the latest backend image.
# Get the latest image from the backend service.
echo "1. Getting latest backend image..."
BACKEND_IMAGE=$(gcloud run services describe cstudio-backend-secdev \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format='value(spec.template.spec.containers[0].image)' 2>/dev/null || true)

if [ -n "$BACKEND_IMAGE" ]; then
  echo "   Updating job with image: $BACKEND_IMAGE"
  gcloud run jobs update "$JOB_NAME" \
    --image="$BACKEND_IMAGE" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet
fi

echo "2. Executing migration job..."
gcloud run jobs execute "$JOB_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --wait

echo "===================================================="
echo " Bootstrap Complete! "
echo "===================================================="
