#!/bin/bash
# Copyright 2025 Google LLC
# Licensed under the Apache License, Version 2.0

set -e

PROJECT_ID="acn-cloud-solution-factory"
REGION="europe-west1"
DB_INSTANCE="creative-studio-db-28a3193a"
CONNECTION_NAME="${PROJECT_ID}:${REGION}:${DB_INSTANCE}"
BUCKET_NAME="${PROJECT_ID}-cs-secure-dev-bucket"

echo "===================================================="
echo " Starting Creative Studio Database Bootstrap"
echo "===================================================="

# 1. Download and start Cloud SQL Proxy
echo "1. Downloading Cloud SQL Proxy..."
curl -o cloud-sql-proxy https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.11.0/cloud-sql-proxy.linux.amd64
chmod +x cloud-sql-proxy

echo "   Starting proxy in background..."
./cloud-sql-proxy $CONNECTION_NAME &
PROXY_PID=$!

# Ensure proxy is stopped when script exits
trap "kill -9 $PROXY_PID 2>/dev/null" EXIT

# Wait for proxy to initialize
sleep 3

# 2. Get the database password
echo "2. Retrieving database password..."
DB_PASS=$(gcloud secrets versions access latest --secret="creative-studio-db-password" --project="$PROJECT_ID")

# 3. Setup Python Environment and Install Dependencies
echo "3. Setting up Python virtual environment..."
cd backend
python3 -m venv .venv
source .venv/bin/activate

echo "   Installing dependencies..."
pip install -r requirements.txt

# 4. Run the Bootstrap Script
echo "4. Running database migrations and seeding..."
export USE_CLOUD_SQL_AUTH_PROXY='true'
export DB_PASS=$DB_PASS
export DB_HOST='127.0.0.1'
export DB_PORT='5432'
export DB_NAME='creative_studio'
export DB_USER='studio_user'
export PYTHONPATH=.

python3 -m bootstrap.bootstrap $PROJECT_ID $REGION $BUCKET_NAME $CONNECTION_NAME

echo "===================================================="
echo " Bootstrap Complete! "
echo "===================================================="
