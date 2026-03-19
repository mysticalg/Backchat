#!/usr/bin/env bash

set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
: "${EB_ENVIRONMENT_NAME:?EB_ENVIRONMENT_NAME is required}"
: "${TURN_USERNAME:?TURN_USERNAME is required}"
: "${TURN_PASSWORD:?TURN_PASSWORD is required}"

RESOURCE_PREFIX="${RESOURCE_PREFIX:-backchat-turn}"
INSTANCE_TAG_NAME="${RESOURCE_PREFIX}-relay"
SECURITY_GROUP_NAME="${RESOURCE_PREFIX}-sg"
EIP_TAG_NAME="${RESOURCE_PREFIX}-eip"
REALM="${TURN_REALM:-turn.backchat.local}"
TURN_PORT="${TURN_PORT:-3478}"
TURN_MIN_PORT="${TURN_MIN_PORT:-49160}"
TURN_MAX_PORT="${TURN_MAX_PORT:-49200}"
INSTANCE_TYPE="${TURN_INSTANCE_TYPE:-t3.micro}"
FORCE_RECREATE="${FORCE_RECREATE:-true}"

ensure_security_group_rule() {
  local group_id="$1"
  local protocol="$2"
  local from_port="$3"
  local to_port="$4"
  local permission
  permission="$(jq -n \
    --arg protocol "$protocol" \
    --argjson fromPort "$from_port" \
    --argjson toPort "$to_port" \
    '[{
      IpProtocol: $protocol,
      FromPort: $fromPort,
      ToPort: $toPort,
      IpRanges: [{CidrIp: "0.0.0.0/0", Description: "Backchat TURN relay"}]
    }]')"
  aws ec2 authorize-security-group-ingress \
    --region "$AWS_REGION" \
    --group-id "$group_id" \
    --ip-permissions "$permission" >/dev/null 2>&1 || true
}

beanstalk_instance_id="$(
  aws elasticbeanstalk describe-environment-resources \
    --region "$AWS_REGION" \
    --environment-name "$EB_ENVIRONMENT_NAME" \
    --query 'EnvironmentResources.Instances[0].Id' \
    --output text
)"

if [[ -z "$beanstalk_instance_id" || "$beanstalk_instance_id" == "None" ]]; then
  echo "Failed to resolve an Elastic Beanstalk instance for environment $EB_ENVIRONMENT_NAME" >&2
  exit 1
fi

read -r vpc_id subnet_id availability_zone <<<"$(
  aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$beanstalk_instance_id" \
    --query 'Reservations[0].Instances[0].[VpcId,SubnetId,Placement.AvailabilityZone]' \
    --output text
)"

if [[ -z "$vpc_id" || -z "$subnet_id" || "$vpc_id" == "None" || "$subnet_id" == "None" ]]; then
  echo "Failed to resolve VPC/subnet from Elastic Beanstalk instance $beanstalk_instance_id" >&2
  exit 1
fi

security_group_id="$(
  aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=$SECURITY_GROUP_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || true
)"

if [[ -z "$security_group_id" || "$security_group_id" == "None" ]]; then
  security_group_id="$(
    aws ec2 create-security-group \
      --region "$AWS_REGION" \
      --group-name "$SECURITY_GROUP_NAME" \
      --description "Backchat TURN relay security group" \
      --vpc-id "$vpc_id" \
      --query 'GroupId' \
      --output text
  )"
  aws ec2 create-tags \
    --region "$AWS_REGION" \
    --resources "$security_group_id" \
    --tags "Key=Name,Value=$SECURITY_GROUP_NAME" "Key=Project,Value=Backchat" >/dev/null
fi

ensure_security_group_rule "$security_group_id" "udp" "$TURN_PORT" "$TURN_PORT"
ensure_security_group_rule "$security_group_id" "tcp" "$TURN_PORT" "$TURN_PORT"
ensure_security_group_rule "$security_group_id" "udp" "$TURN_MIN_PORT" "$TURN_MAX_PORT"
ensure_security_group_rule "$security_group_id" "tcp" "$TURN_MIN_PORT" "$TURN_MAX_PORT"

read -r allocation_id public_ip <<<"$(
  aws ec2 describe-addresses \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$EIP_TAG_NAME" \
    --query 'Addresses[0].[AllocationId,PublicIp]' \
    --output text 2>/dev/null || true
)"

if [[ -z "${allocation_id:-}" || "$allocation_id" == "None" ]]; then
  read -r allocation_id public_ip <<<"$(
    aws ec2 allocate-address \
      --region "$AWS_REGION" \
      --domain vpc \
      --query '[AllocationId,PublicIp]' \
      --output text
  )"
  aws ec2 create-tags \
    --region "$AWS_REGION" \
    --resources "$allocation_id" \
    --tags "Key=Name,Value=$EIP_TAG_NAME" "Key=Project,Value=Backchat" >/dev/null
fi

instance_id="$(
  aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
      "Name=tag:Name,Values=$INSTANCE_TAG_NAME" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || true
)"

user_data_file=""
cleanup() {
  if [[ -n "$user_data_file" && -f "$user_data_file" ]]; then
    rm -f "$user_data_file"
  fi
}
trap cleanup EXIT

if [[ -z "${instance_id:-}" || "$instance_id" == "None" ]]; then
  :
else
  state_name="$(
    aws ec2 describe-instances \
      --region "$AWS_REGION" \
      --instance-ids "$instance_id" \
      --query 'Reservations[0].Instances[0].State.Name' \
      --output text
  )"
  if [[ "$FORCE_RECREATE" == "true" && "$state_name" != "terminated" && "$state_name" != "shutting-down" ]]; then
    aws ec2 terminate-instances \
      --region "$AWS_REGION" \
      --instance-ids "$instance_id" >/dev/null
    aws ec2 wait instance-terminated \
      --region "$AWS_REGION" \
      --instance-ids "$instance_id"
    instance_id=""
  elif [[ "$state_name" == "stopped" ]]; then
    aws ec2 start-instances --region "$AWS_REGION" --instance-ids "$instance_id" >/dev/null
  fi
fi

if [[ -z "${instance_id:-}" || "$instance_id" == "None" ]]; then
  ami_id="$(
    aws ec2 describe-images \
      --region "$AWS_REGION" \
      --owners 099720109477 \
      --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" "Name=state,Values=available" \
      --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
      --output text
  )"

  if [[ -z "$ami_id" || "$ami_id" == "None" ]]; then
    echo "Failed to resolve an Ubuntu 24.04 AMI" >&2
    exit 1
  fi

  user_data_file="$(mktemp)"
  cat >"$user_data_file" <<EOF
#!/bin/bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y coturn curl

TOKEN=""
for attempt in \$(seq 1 30); do
  TOKEN=\$(curl -fsS -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" http://169.254.169.254/latest/api/token || true)
  if [[ -n "\$TOKEN" ]]; then
    break
  fi
  sleep 2
done

metadata() {
  local path="\$1"
  curl -fsS -H "X-aws-ec2-metadata-token: \$TOKEN" "http://169.254.169.254/latest/meta-data/\$path"
}

LOCAL_IP=\$(metadata local-ipv4)

cat >/etc/turnserver.conf <<TURNCONF
fingerprint
lt-cred-mech
user=$(printf '%s' "$TURN_USERNAME"):${TURN_PASSWORD}
realm=$(printf '%s' "$REALM")
server-name=backchat-turn
listening-ip=\${LOCAL_IP}
relay-ip=\${LOCAL_IP}
listening-port=${TURN_PORT}
min-port=${TURN_MIN_PORT}
max-port=${TURN_MAX_PORT}
external-ip=${public_ip}/\${LOCAL_IP}
no-cli
no-tls
no-dtls
no-multicast-peers
simple-log
TURNCONF

if grep -q '^#TURNSERVER_ENABLED=1' /etc/default/coturn; then
  sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
fi
if grep -q '^TURNSERVER_ENABLED=' /etc/default/coturn; then
  sed -i 's/^TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
else
  echo 'TURNSERVER_ENABLED=1' >> /etc/default/coturn
fi

systemctl enable coturn
systemctl restart coturn
systemctl --no-pager --full status coturn || true
ss -lntup || true
EOF

  instance_id="$(
    aws ec2 run-instances \
      --region "$AWS_REGION" \
      --image-id "$ami_id" \
      --instance-type "$INSTANCE_TYPE" \
      --subnet-id "$subnet_id" \
      --security-group-ids "$security_group_id" \
      --user-data "file://$user_data_file" \
      --metadata-options HttpTokens=required,HttpEndpoint=enabled \
      --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_TAG_NAME},{Key=Project,Value=Backchat}]" \
        "ResourceType=volume,Tags=[{Key=Name,Value=$INSTANCE_TAG_NAME-root},{Key=Project,Value=Backchat}]" \
      --query 'Instances[0].InstanceId' \
      --output text
  )"
fi

aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$instance_id"
aws ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$instance_id"

aws ec2 associate-address \
  --region "$AWS_REGION" \
  --allocation-id "$allocation_id" \
  --instance-id "$instance_id" \
  --allow-reassociation >/dev/null

read -r final_public_dns final_private_ip <<<"$(
  aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].[PublicDnsName,PrivateIpAddress]' \
    --output text
)"

if ! timeout 300 bash -c "until (echo >/dev/tcp/${public_ip}/${TURN_PORT}) >/dev/null 2>&1; do sleep 5; done"; then
  aws ec2 get-console-output \
    --region "$AWS_REGION" \
    --instance-id "$instance_id" \
    --query 'Output' \
    --output text || true
  echo "TURN relay did not open TCP port ${TURN_PORT} on ${public_ip} within 5 minutes." >&2
  exit 1
fi

turn_urls="turn:${public_ip}:${TURN_PORT}?transport=udp,turn:${public_ip}:${TURN_PORT}?transport=tcp"
stun_urls="stun:${public_ip}:${TURN_PORT},stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302"

result_json="$(jq -n \
  --arg region "$AWS_REGION" \
  --arg environmentName "$EB_ENVIRONMENT_NAME" \
  --arg vpcId "$vpc_id" \
  --arg subnetId "$subnet_id" \
  --arg availabilityZone "$availability_zone" \
  --arg securityGroupId "$security_group_id" \
  --arg allocationId "$allocation_id" \
  --arg instanceId "$instance_id" \
  --arg publicIp "$public_ip" \
  --arg publicDns "$final_public_dns" \
  --arg privateIp "$final_private_ip" \
  --arg turnUsername "$TURN_USERNAME" \
  --arg turnUrls "$turn_urls" \
  --arg stunUrls "$stun_urls" \
  '{
    region: $region,
    environmentName: $environmentName,
    vpcId: $vpcId,
    subnetId: $subnetId,
    availabilityZone: $availabilityZone,
    securityGroupId: $securityGroupId,
    allocationId: $allocationId,
    instanceId: $instanceId,
    publicIp: $publicIp,
    publicDns: $publicDns,
    privateIp: $privateIp,
    turnUsername: $turnUsername,
    turnUrls: $turnUrls,
    stunUrls: $stunUrls
  }')"

printf '%s\n' "$result_json"
