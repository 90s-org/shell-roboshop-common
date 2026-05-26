#!/bin/bash

export PATH=$PATH:/usr/local/bin:/usr/bin:/bin

AMI_ID="ami-0220d79f3f480ecf5"
ZONE_ID="Z07086101C1CVP7AT2UK4"
DOMAIN_NAME="daws90s.shop"

### Validation ###
if [ $# -lt 2 ]; then
    echo "ERROR: At least 2 arguments required."
    echo "Usage: $0 <create|delete> <instance1> [instance2 ...]"
    exit 1
fi

ACTION=$1
shift  # remaining args are instance names

if [ "$ACTION" != "create" ] && [ "$ACTION" != "delete" ] && [ "$ACTION" != "destroy" ]; then
    echo "ERROR: First argument must be 'create' or 'delete'."
    echo "Usage: $0 <create|delete> <instance1> [instance2 ...]"
    exit 1
fi

get_instance_id() {
    local name=$1
    aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=roboshop-$name" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text
}

update_r53() {
    local ip=$1
    local record=$2

    aws route53 change-resource-record-sets \
        --hosted-zone-id "$ZONE_ID" \
        --change-batch '
        {
            "Comment": "Update A record to new IP",
            "Changes": [
                {
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": "'"$record"'",
                        "Type": "A",
                        "TTL": 1,
                        "ResourceRecords": [
                            {
                                "Value": "'"$ip"'"
                            }
                        ]
                    }
                }
            ]
        }
        '
}

for instance in "$@"; do
    echo "-------------------------------------------"
    echo "Processing: $instance | Action: $ACTION"

    INSTANCE_ID=$(get_instance_id "$instance")

    if [ "$ACTION" = "create" ]; then
        if [ "$INSTANCE_ID" != "None" ] && [ -n "$INSTANCE_ID" ]; then
            echo "INFO: roboshop-$instance is already running (ID: $INSTANCE_ID). Skipping launch."
        else
            echo "INFO: Launching new instance for $instance..."
            INSTANCE_ID=$(aws ec2 run-instances \
                --image-id "$AMI_ID" \
                --instance-type t3.micro \
                --security-groups "roboshop-common" "roboshop-$instance" \
                --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=roboshop-$instance}]" \
                --query 'Instances[0].InstanceId' \
                --output text
            )
            echo "INFO: Launched instance ID: $INSTANCE_ID"
        fi

        # Update R53 in either case (already running or newly created)
        if [ "$instance" = "frontend" ]; then
            IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
                --query 'Reservations[*].Instances[*].PublicIpAddress' \
                --output text)
            R53_RECORD="$DOMAIN_NAME"
        else
            IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
                --query 'Reservations[*].Instances[*].PrivateIpAddress' \
                --output text)
            R53_RECORD="$instance.$DOMAIN_NAME"
        fi

        echo "INFO: Updating R53 record $R53_RECORD -> $IP"
        update_r53 "$IP" "$R53_RECORD"
        echo "INFO: R53 updated successfully."

    else  # delete / destroy
        if [ "$INSTANCE_ID" = "None" ] || [ -z "$INSTANCE_ID" ]; then
            echo "INFO: roboshop-$instance not found or already terminated. Nothing to do."
        else
            echo "INFO: Terminating instance roboshop-$instance (ID: $INSTANCE_ID)..."
            aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" \
                --query 'TerminatingInstances[0].CurrentState.Name' \
                --output text
            echo "INFO: Termination initiated for $instance."
        fi
    fi
done

echo "-------------------------------------------"
echo "Done."
