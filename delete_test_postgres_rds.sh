#!/usr/bin/env bash
# delete_test_postgres_rds.sh
#
# Tears down everything create_test_postgres_rds.sh created: the RDS
# instance (immediately, no final snapshot - since backups were disabled
# at creation, there's nothing meaningful to snapshot anyway) and the
# dedicated security group. Run this as soon as you're done testing.
#
# Usage:
#   ./delete_test_postgres_rds.sh

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
DB_INSTANCE_ID="${DB_INSTANCE_ID:-cdppg-test}"
SECURITY_GROUP_NAME="cdppg-test-sg"

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found."; exit 1; }

echo "========================================================"
echo "Deleting RDS test instance '${DB_INSTANCE_ID}' in ${AWS_REGION}"
echo "========================================================"

# ── 1. Delete the RDS instance (no final snapshot - keeps this fast and
#       avoids ongoing snapshot storage charges after deletion) ───────────

EXISTS="$(aws rds describe-db-instances --region "${AWS_REGION}" \
    --db-instance-identifier "${DB_INSTANCE_ID}" \
    --query 'DBInstances[0].DBInstanceIdentifier' --output text 2>/dev/null || echo "None")"

if [[ "${EXISTS}" == "None" || -z "${EXISTS}" ]]; then
    echo "No RDS instance named '${DB_INSTANCE_ID}' found - already deleted, or wrong DB_INSTANCE_ID/region."
else
    aws rds delete-db-instance \
        --region "${AWS_REGION}" \
        --db-instance-identifier "${DB_INSTANCE_ID}" \
        --skip-final-snapshot \
        --delete-automated-backups \
        >/dev/null
    echo "Delete request submitted. Waiting for it to finish (a few minutes)..."
    aws rds wait db-instance-deleted --region "${AWS_REGION}" --db-instance-identifier "${DB_INSTANCE_ID}"
    echo "RDS instance deleted - compute charges stop now."
fi

# ── 2. Delete the security group (has to happen after the instance is
#       fully gone, since RDS holds a reference to it while it exists) ────

DEFAULT_VPC_ID="$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)"

SG_ID="$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
    --filters Name=group-name,Values="${SECURITY_GROUP_NAME}" Name=vpc-id,Values="${DEFAULT_VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")"

if [[ "${SG_ID}" == "None" || -z "${SG_ID}" ]]; then
    echo "Security group '${SECURITY_GROUP_NAME}' not found - already deleted or never created."
else
    aws ec2 delete-security-group --region "${AWS_REGION}" --group-id "${SG_ID}"
    echo "Security group ${SG_ID} deleted."
fi

# ── 3. Remove the local credentials file - no reason to keep a password
#       for a database that no longer exists ──────────────────────────────

if [[ -f ./cdppg_test_credentials.txt ]]; then
    rm -f ./cdppg_test_credentials.txt
    echo "Removed local ./cdppg_test_credentials.txt."
fi

echo ""
echo "========================================================"
echo "  Cleanup complete. No RDS charges should continue past this point."
echo "========================================================"
echo ""
echo "Double-check in the console if you want full peace of mind:"
echo "  https://console.aws.amazon.com/rds/home?region=${AWS_REGION}#databases:"
