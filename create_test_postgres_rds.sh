#!/usr/bin/env bash
# create_test_postgres_rds.sh
#
# Creates the CHEAPEST realistic AWS RDS PostgreSQL instance for testing
# SNOW_CDPPG_reset_postgres_password.yml, then prints the connection details
# you need to fill into pg_environments in vars/main.yml.
#
# Cost-minimizing choices made deliberately:
#   * db.t4g.micro    - cheapest current-generation instance (~$0.016/hr,
#                        ~$11.68/month if left running a full month; a few
#                        hours of testing costs a few CENTS)
#   * 20 GB gp3        - the minimum allowed storage size
#   * Single-AZ         - no standby replica (Multi-AZ = 2x the price)
#   * --backup-retention-period 0 - disables automated backups entirely,
#                        which also means delete_test_postgres_rds.sh can
#                        skip the final-snapshot step (faster, and avoids
#                        lingering snapshot storage charges after deletion)
#   * --no-deletion-protection - so cleanup never gets blocked by a
#                        protection flag you'd have to remember to unset
#   * Publicly accessible, but locked down to ONLY your current public IP
#                        via a dedicated security group - not open to the
#                        internet
#
# IMPORTANT: check https://console.aws.amazon.com/billing/home#/freetier
# before running this. New AWS accounts get 750 hrs/month of a *.micro
# instance + 20GB storage free for the first 12 months - if you qualify,
# this entire test could cost $0 instead of a few cents.
#
# Prerequisites:
#   * AWS CLI v2 installed and configured (aws configure) with credentials
#     that have RDS + EC2 (security group) permissions
#   * jq installed (for parsing CLI JSON output)
#
# Usage:
#   ./create_test_postgres_rds.sh
#
# Then, once it finishes:
#   1. Fill the printed endpoint/port/master credentials into
#      pg_environments in vars/main.yml (as a single "TEST" environment)
#   2. Run SNOW_CDPPG_reset_postgres_password.yml
#   3. Run ./delete_test_postgres_rds.sh IMMEDIATELY after you're done
#      testing - every extra hour it sits running costs more, even if
#      it's only a couple of cents

set -euo pipefail

# ── Configuration - change these if you want, sensible defaults otherwise ──

AWS_REGION="${AWS_REGION:-us-east-1}"
DB_INSTANCE_ID="${DB_INSTANCE_ID:-cdppg-test}"
DB_INSTANCE_CLASS="db.t4g.micro"        # cheapest current-gen instance
ALLOCATED_STORAGE_GB=20                 # minimum allowed
STORAGE_TYPE="gp3"
MASTER_USERNAME="${MASTER_USERNAME:-pgadmin}"
DB_NAME="testdb"
SECURITY_GROUP_NAME="cdppg-test-sg"

# ── Preflight checks ─────────────────────────────────────────────────────

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found. Install AWS CLI v2 first."; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq not found. Install it (e.g. 'sudo apt install jq' or 'sudo yum install jq')."; exit 1; }

aws sts get-caller-identity --region "${AWS_REGION}" >/dev/null 2>&1 || {
    echo "ERROR: AWS CLI is not authenticated. Run 'aws configure' first."
    exit 1
}

echo "========================================================"
echo "Creating cheapest-possible RDS PostgreSQL test instance"
echo "Region          : ${AWS_REGION}"
echo "Instance class  : ${DB_INSTANCE_CLASS}"
echo "Storage         : ${ALLOCATED_STORAGE_GB}GB ${STORAGE_TYPE}"
echo "========================================================"

# ── 1. Generate a random master password (never echoed to the terminal) ───

MASTER_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)Aa1!"
echo "Generated a random master password (not shown here - saved to ./cdppg_test_credentials.txt, chmod 600)."

# ── 2. Find your current public IP, so the security group only allows YOU ─

MY_IP="$(curl -s https://checkip.amazonaws.com)"
if [[ -z "${MY_IP}" ]]; then
    echo "ERROR: could not determine your public IP automatically. Set MY_IP manually and re-run."
    exit 1
fi
echo "Your public IP  : ${MY_IP} (security group will allow only this /32)"

# ── 3. Find the default VPC (most accounts have one) ──────────────────────

DEFAULT_VPC_ID="$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)"

if [[ "${DEFAULT_VPC_ID}" == "None" || -z "${DEFAULT_VPC_ID}" ]]; then
    echo "ERROR: no default VPC found in ${AWS_REGION}. This script assumes a default VPC exists."
    echo "If you deleted your default VPC, either recreate one or adapt this script to pass an explicit --vpc-id."
    exit 1
fi
echo "Default VPC     : ${DEFAULT_VPC_ID}"

# ── 4. Create a dedicated security group, locked to your IP only ──────────

EXISTING_SG="$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
    --filters Name=group-name,Values="${SECURITY_GROUP_NAME}" Name=vpc-id,Values="${DEFAULT_VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")"

if [[ "${EXISTING_SG}" != "None" && -n "${EXISTING_SG}" ]]; then
    echo "Security group  : ${EXISTING_SG} (already exists, reusing)"
    SG_ID="${EXISTING_SG}"
else
    SG_ID="$(aws ec2 create-security-group --region "${AWS_REGION}" \
        --group-name "${SECURITY_GROUP_NAME}" \
        --description "Temporary - CDPPG PostgreSQL pilot test, safe to delete" \
        --vpc-id "${DEFAULT_VPC_ID}" \
        --query 'GroupId' --output text)"
    echo "Security group  : ${SG_ID} (created)"

    aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" \
        --group-id "${SG_ID}" \
        --protocol tcp --port 5432 \
        --cidr "${MY_IP}/32" >/dev/null
    echo "  -> allowed inbound TCP 5432 from ${MY_IP}/32 only"
fi

# ── 5. Create the RDS instance ─────────────────────────────────────────────

echo ""
echo "Launching RDS instance '${DB_INSTANCE_ID}' - this typically takes 5-10 minutes..."

aws rds create-db-instance \
    --region "${AWS_REGION}" \
    --db-instance-identifier "${DB_INSTANCE_ID}" \
    --db-instance-class "${DB_INSTANCE_CLASS}" \
    --engine postgres \
    --master-username "${MASTER_USERNAME}" \
    --master-user-password "${MASTER_PASSWORD}" \
    --allocated-storage "${ALLOCATED_STORAGE_GB}" \
    --storage-type "${STORAGE_TYPE}" \
    --db-name "${DB_NAME}" \
    --vpc-security-group-ids "${SG_ID}" \
    --backup-retention-period 0 \
    --no-multi-az \
    --publicly-accessible \
    --no-deletion-protection \
    --no-enable-performance-insights \
    --tags Key=Purpose,Value=CDPPG-pilot-test Key=DeleteMe,Value=true \
    >/dev/null

echo "Waiting for the instance to become available (this is the slow part)..."
aws rds wait db-instance-available --region "${AWS_REGION}" --db-instance-identifier "${DB_INSTANCE_ID}"

# ── 6. Print connection details ────────────────────────────────────────────

ENDPOINT="$(aws rds describe-db-instances --region "${AWS_REGION}" \
    --db-instance-identifier "${DB_INSTANCE_ID}" \
    --query 'DBInstances[0].Endpoint.Address' --output text)"
PORT="$(aws rds describe-db-instances --region "${AWS_REGION}" \
    --db-instance-identifier "${DB_INSTANCE_ID}" \
    --query 'DBInstances[0].Endpoint.Port' --output text)"

cat > ./cdppg_test_credentials.txt <<EOF
# CDPPG PostgreSQL pilot test - RDS connection details
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# Paste this into vars/main.yml as a pg_environments entry:
#
# pg_environments:
#   TEST:
#     endpoint: "${ENDPOINT}"
#     port: ${PORT}
#     dbname: "${DB_NAME}"
#     master_user: "${MASTER_USERNAME}"
#     master_pass: "${MASTER_PASSWORD}"    # vault-encrypt this before committing anywhere

DB_INSTANCE_ID=${DB_INSTANCE_ID}
ENDPOINT=${ENDPOINT}
PORT=${PORT}
DB_NAME=${DB_NAME}
MASTER_USERNAME=${MASTER_USERNAME}
MASTER_PASSWORD=${MASTER_PASSWORD}
SECURITY_GROUP_ID=${SG_ID}
REGION=${AWS_REGION}
EOF
chmod 600 ./cdppg_test_credentials.txt

echo ""
echo "========================================================"
echo "  RDS PostgreSQL test instance is READY"
echo "========================================================"
echo "  Endpoint : ${ENDPOINT}"
echo "  Port     : ${PORT}"
echo "  Database : ${DB_NAME}"
echo "  Username : ${MASTER_USERNAME}"
echo "  Password : (saved to ./cdppg_test_credentials.txt, chmod 600 - not printed here)"
echo "========================================================"
echo ""
echo "Quick manual connectivity test (requires psql client):"
echo "  PGPASSWORD=\$(grep MASTER_PASSWORD ./cdppg_test_credentials.txt | cut -d= -f2) \\"
echo "    psql -h ${ENDPOINT} -p ${PORT} -U ${MASTER_USERNAME} -d ${DB_NAME} -c 'SELECT version();'"
echo ""
echo "IMPORTANT: run ./delete_test_postgres_rds.sh as soon as you're done testing"
echo "to stop AWS charges. Every extra hour running costs about \$0.016 + storage,"
echo "so leaving it up overnight by accident costs well under a dollar - but"
echo "there's no reason to pay even that if you're done."
