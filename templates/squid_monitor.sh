#!/bin/bash
#
#  DESCRIPTION:
#  ============
#  NAT self-monitoring script for a simple HA hot fail-over NAT
#  based on the AWS [HA NAT](https://aws.amazon.com/articles/2781451301784570)
#  Should be run on each of the **two** NAT instances
#
#  OUTPUT:
#  =======
#
#  REQUIREMENTS:
#  =============
#  AWS CLI version >= 1.3
#  IAM Instance profile role allowing:
#   - ec2:CreateRoute
#   - ec2:CreateRouteTable
#   - ec2:DeleteRoute
#   - ec2:DeleteRouteTable
#   - ec2:DescribeInstances
#   - ec2:DescribeNetworkInterfaces
#   - ec2:DescribeRouteTables
#   - ec2:DescribeTags
#   - ec2:ReplaceRoute
#
#  VERSION:  1.0
#  CREATED:  20/08/2014 09:01:57 EST
#
#  $Id$

PROG=${0##*/}

# Not dryrun by default
DRYRUN=0
# No excessive output
DEBUG=0

# Directory to store all temporary files in
TMPDIR="/tmp/$PROG.$$"
mkdir -p "$TMPDIR"

# Exit on any error
set -e

# Clean up after yourself on exit
trap '_exit_trap' 0 HUP INT QUIT ABRT TERM

# Function to execute upon termination
_exit_trap()
{
    exit_status=$?
    # Clear the traps
    trap 0 HUP INT QUIT ABRT TERM

    if [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
    exit $exit_status
}

# Fallback functions before any libraries are sourced
log()
{
    sns_notice=false
    case ${pri:-notice} in
        *notice)
            out_msg="$*"
            ;;
        *warning)
            out_msg="-WARN- $*"
            sns_notice=true
            ;;
        *error)
            out_msg="*ERROR* $*"
            sns_notice=true
            ;;
        *)
            out_msg="$*"
            ;;
    esac
    if [ -w "$LOGFILE" ]; then
        echo "[$(${date:-date} --iso-8601=seconds)] ${PROG:+$PROG:} $out_msg" >> "$LOGFILE"
    fi
    if [ -t 0 ]; then
        echo "$out_msg" >&2
    fi
    if [ -n "$SYSLOG_FAC" ]; then
        logger -t $PROG -p $SYSLOG_FAC.$pri -- "$out_msg"
    fi
    if [ -n "$SNSARN" ] && $sns_notice; then
        aws sns --region $region publish --topic-arn "$SNSARN" --subject "$pri message from $PROG on NAT $instance_id" \
            --message "$out_msg"
    fi
}

info()
{
    pri=notice log "$@"
}

warn()
{
    pri=warning log "$@"
}

error()
{
    pri=error log "$@"
}


debug_info()
{
    if [ ${DEBUG:-0} -gt 0 ]; then
        echo "$@" >&2
    fi
}

debug_cat()
{
    if [ ${DEBUG:-0} -gt 0 ]; then
        echo "$@" >&2
        cat - >&2
    fi
}

die()
{
    error "$@"
    exit 1
}

run()
{
    if [ ${DRYRUN:-0} -gt 0 ]; then
        echo "--dry-run: $@" >&2
    else
        if [ ${DEBUG:-0} -gt 0 ]; then
            echo "+ run: $@" >&2
        fi
        log "+ run: $@"
        "$@"
    fi
}

query_nat_instances()
{
    debug_info "Running query_nat_instances with arguments $@"
    aws ec2 describe-instances --region $region \
         --query "$1" \
         --filters ${vpc_id:+Name=vpc-id,Values=$vpc_id} ${iam_profile:+Name=iam-instance-profile.arn,Values=$iam_profile} ${2} \
         --output text
}

get_vpc_id_for_instances()
{
    {
        if [ $? -ne 0 ]; then
            error "Error querying instances for VPC id using ${iam_profile:+'$iam_profile' IAM profile} ${1:+'$1' filters}"
            return 1
        fi
        uniq | awk '{ print $1 }
                END { if (NR != 1) {
                        print "*ERROR* More than 1 VPC id for instances using \"'"${iam_profile:+$iam_profile IAM profile} ${1:+$1 filters}"'\"" | "cat - >&2"
                        exit 1
                      }
                    } '
    }<<EOF_QUERY_NAT
$(debug_info "Running get_vpc_id_for_instances with arguments $@"
query_nat_instances 'Reservations[*].Instances[*].VpcId' $1)
EOF_QUERY_NAT

}

filter_route_tables_by_gw()
{
    {
        if [ $? -ne 0 ]; then
            error "Error occured running describe-route-tables"
            return 1
        fi
        sort -k 2
    }<<EOF_EC2_DESCRIBE_RTABLES
$(debug_info "Running filter_route_tables_by_gw with arguments $@"
aws ec2 describe-route-tables --region $region \
            --query 'RouteTables[*][Associations[*].[SubnetId,RouteTableId]]' \
            --filters Name=vpc-id,Values=$vpc_id Name=route.gateway-id,Values=$1 --output text)
EOF_EC2_DESCRIBE_RTABLES
}

filter_route_tables_by_monitor_tag()
{
    {
        if [ $? -ne 0 ]; then
            error "Error occured running describe-route-tables"
            return 1
        fi
        sort -k 2
    }<<EOF_EC2_DESCRIBE_RTABLES
$(debug_info "Running filter_route_tables_by_monitor_tag with arguments $@"
aws ec2 describe-route-tables --region $region \
            --query 'RouteTables[*][Associations[*].[SubnetId,RouteTableId]]' \
            --filters Name=vpc-id,Values=$vpc_id Name=tag:Monitor,Values=$1 --output text)
EOF_EC2_DESCRIBE_RTABLES
}

get_local_metadata()
{
    debug_info "Running get_local_metadata with arguments $@"
    /usr/bin/curl --silent http://169.254.169.254/latest/meta-data/$1
}

assign_outbound_route()
{
    debug_info "Running assign_outbound_route with arguments $@"
    local command="$1"
    local route_table="$2"
    local to_instance_id="${3:-$instance_id}"

    aws ec2 $command-route --region $region \
        --route-table-id $route_table \
        --destination-cidr-block 0.0.0.0/0 \
        --instance-id $to_instance_id --output text
}


query_nat_state()
{
    {
        if [ $? -ne 0 ]; then
            error "Error occurred running query_nat_instances"
            echo "ERROR"
            return 1
        fi
        awk '/'"${1:-$instance_id}"'/ { print $NF}'
    }<<EOF_QUERY_NAT_STATE
$(debug_info "Running query_nat_state with arguments $@"
query_nat_instances "Reservations[*].Instances[*].[InstanceId, State.Name]" "Name=instance-id,Values=${1:-$instance_id}")
EOF_QUERY_NAT_STATE
}

wait_for_nat_state()
{
    debug_info "Running wait_for_nat_state with arguments $@"
    local sought_state=${1:-running}
    local sought_instance_id=${2:-$instance_id}
    local current_state="unknown"
    local wait_time=0

    current_state=$(query_nat_state $sought_instance_id)
    while [ $current_state != "$sought_state" ] && [ $wait_time -lt $timeout  ]; do
        sleep $sleep_time
        wait_time=$((wait_time + sleep_time))
        current_state=$(query_nat_state $sought_instance_id)
    done
    if [ "$current_state" == "$sought_state" ]; then
        return 0
    else
        error  "Timed out waiting for the other NAT instance in '$vpc_id' to turn to a '$sought_state' state"
        return 1
    fi
}

wait_for_nat_ping()
{
    debug_info "Running wait_for_nat_ping with arguments $@"
    local ping_ip=${1:-$other_nat_ip}
    local ping_count=${2:-$num_pings}
    local successful_pings=$(ping -c ${ping_count} -W $ping_timeout $ping_ip | grep time= | wc -l)
    local wait_time=0

    while [ ${successful_pings:-0} -eq 0 ] && [ $wait_time -lt $timeout  ]; do
        sleep $sleep_time
        wait_time=$((wait_time + sleep_time))
        successful_pings=$(ping -c ${ping_count} -W $ping_timeout $ping_ip | grep time= | wc -l)
    done
    if [ ${successful_pings:-0} -gt 0 ]; then
        return 0
    else
        error  "Timed out waiting for the other NAT instance in '$vpc_id' to turn to start respoding to ping"
        return 1
    fi
}

# Usage helper
usage()
{
    cat >&2 <<EOF_USAGE

Usage: $PROG [options]

Options description:

    --dryrun (-n)               : dry-run level
    --verbose (-v)              : verbosity (more v's = more verbose)
    --log (-L)                  : log file
    --sns (-S)                  : SNS topic to post into

EOF_USAGE

}

# getopts-style loop: walk the args in order, processing options and placing non-option
# arguments at the end. When finished, arguments are in reverse order.
i=0
n=$#
while [ "$i" -lt "$n" ]
do
    arg="$1" ; shift
    case "$arg" in
    --log|-L) LOGFILE="$1"; i=$((i+1)); shift ;;
    --sns|-S) SNSTOPIC="$1"; i=$((i+1)); shift ;;
    --dryrun|-n) DRYRUN=$((DRYRUN+1)) ;;
    --verbose|-v) DEBUG=$((DEBUG+1)) ;;
    --region|-r) region="$1"; i=$((i+1)); shift ;;
    --help|-h) usage; exit 0 ;;
    -*) error "Wrong option used: '$arg'"; usage; exit 1 ;;
    *) set -- "$@" "$arg"; ;;
    esac
    i=$((i+1))
done

: ${sleep_time:=60}
: ${timeout:=600}
: ${ping_timeout:=1}
: ${num_pings:=3}
: ${wait_between_pings:=2}

# Redirect all stdout and stderr to a log file in case its name is provided
if [ -n "$LOGFILE" ]; then
    touch "$LOGFILE"
    if ! [  -t 0 ]; then
        # Close STDOUT file descriptor
        exec 1<&-
        # Close STDERR FD
        exec 2<&-
    fi
    # Open STDOUT as $LOG_FILE file for read and write
    exec 1<>$LOGFILE
    # Redirect STDERR to STDOUT
    exec 2>&1
fi

export PATH=/usr/local/bin:$PATH

# Get this instance's ID
instance_id=$(get_local_metadata instance-id)
# Get this instance availabilty zone
my_az=$(get_local_metadata placement/availability-zone)
# Form the region based on the current AZ
: ${region:=${my_az%[a-z]*}}
# Get this instance IAM profile
iam_profile=$(get_local_metadata iam/info |
                    python -c 'import sys, json; print json.load(sys.stdin)["InstanceProfileArn"]')
# Get a VPC ID for this instance
vpc_id=$(get_vpc_id_for_instances Name=instance-id,Values=$instance_id)

# Get the AWS account ID in order to form the proper SNS ARN
if [ -n "$SNSTOPIC" ]; then
    user_arn="$(aws iam --output text list-users --query Users[0].Arn)"
    arn_id="${user_arn%:*}"
    aws_account_id="${arn_id##*:}"
    SNSARN="arn:aws:sns:$region:$aws_account_id:$SNSTOPIC"
fi

# First make sure the default route for private subnets in the current AZ is being routed
# through this NAT instance
# 1. Get the list of all subnets associated with a route table with at least one local gateway
#    it will be a mixture of private and public subnets as public ones also have at least
#    one local gateway for talking to their peers in the same private network
subnets_with_local_gw="$TMPDIR/subnets_with_local_gw.$$"
filter_route_tables_by_gw local > "$subnets_with_local_gw"
debug_cat subnets_with_local_gw < "$subnets_with_local_gw"

# 2. Get the list of all subnets associated with a route table which has an internet gateway in it:
#    those would be the public subnets
public_subnets="$TMPDIR/public_subnets.$$"
filter_route_tables_by_gw igw-* > "$public_subnets"
debug_cat public_subnets < "$public_subnets"

# 3. Filter the first list of subnets by the public subnets to get the list of private ones
private_subnets="$TMPDIR/private_subnets.$$"
grep -v -f "$public_subnets" "$subnets_with_local_gw" > "$private_subnets"
debug_cat private_subnets < "$private_subnets"

# 3.1 Filter the monitor subnet by tag
monitor_subnets="$TMPDIR/monitor_subnets.$$"
filter_route_tables_by_monitor_tag squid > "$monitor_subnets"
debug_cat monitor_subnets < "$monitor_subnets"

# 4. Get the list of all subnets in the current AZ
all_subnets_az="$TMPDIR/all_subnets_az.$$"
aws ec2 describe-subnets --region $region \
         --query 'Subnets[*].[SubnetId]' \
         --filters Name=vpc-id,Values=$vpc_id Name=availabilityZone,Values=$my_az --output text > "$all_subnets_az"
debug_cat all_subnets_az < "$all_subnets_az"

# 5. Get the list of the route tables for private subnets in the current AZ
#    filtering the list of all private subnets
my_route_table_ids=$(grep -f "$all_subnets_az" "$monitor_subnets" | sort -k 2 | uniq -f 1 | awk '{print $2}')
debug_info my_route_table_ids=$my_route_table_ids
# 6. Update route tables for all private subnets in the current AZ
for rt_id in $my_route_table_ids; do
    info "Adding this instance to $rt_id default route on start"
    if assign_outbound_route replace $rt_id; then
        :
    else
        info "Creating a route in $rt_id for this instance to be a gateway on start"
        assign_outbound_route create $rt_id
    fi
done

info "Starting NAT monitor"
# Obtain all NAT instances ids and their state
nat_instances_ip="$TMPDIR/nat_instances_ip.$$"
nat_instances_state="$TMPDIR/nat_instances_state.$$"
query_nat_instances "Reservations[*].Instances[*].[InstanceId, Placement.AvailabilityZone, State.Name]" > "$nat_instances_state"

# Check there are only 2 NAT instances and fail the script otherwise
nat_num=$(sed -n '$ { $=; }' "$nat_instances_state")
[ "${nat_num:-0}" -eq 2 ] || die "Number of detected NAT instances assigned IAM profile '$iam_profile' in VPC '$vpc_id' is $nat_num != 2"

# Make sure to wait for the other NAT to come up in case it is not in the 'running' state
other_nat_state=$(awk '! /'"$instance_id"'/ { print $NF}' "$nat_instances_state" )
other_az=$(awk '! /'"$instance_id"'/ { print $2}' "$nat_instances_state" )
other_nat_id=$(awk '! /'"$instance_id"'/ { print $1}' "$nat_instances_state" )

while ! wait_for_nat_state running $other_nat_id; do
    case "$(query_nat_state $other_nat_id)" in
        pending) :
            ;;
        *) die "The other NAT instance is in not running, not monitoring it"
            ;;
    esac
done

# Obtain all NAT instances instance ids and private IPs matching the VPC ID and the IAM profile
query_nat_instances 'Reservations[*].Instances[*].[InstanceId, PrivateIpAddress]' > "$nat_instances_ip"

# Get the other NAT instance's IP
other_nat_ip=$(awk '! /'"$instance_id"'/ { print $NF}' "$nat_instances_ip" )

# Get the list of all subnets in the other NAT's AZ
all_subnets_other_az="$TMPDIR/all_subnets_other_az.$$"
aws ec2 describe-subnets --region $region \
         --query 'Subnets[*].[SubnetId]' \
         --filters Name=vpc-id,Values=$vpc_id Name=availabilityZone,Values=$other_az --output text > "$all_subnets_other_az"
debug_cat all_subnets_other_az < "$all_subnets_other_az"

# Get the list of the route tables for private subnets in the other AZ
#    filtering the list of all private subnets
other_route_table_ids=$(grep -f "$all_subnets_other_az" "$monitor_subnets" | sort -k 2 | uniq -f 1 | awk '{print $2}')
debug_info other_route_table_ids=$other_route_table_ids

info "Monitoring other NAT instance '$other_nat_id' ($other_nat_ip)"
while true; do
    # Check health of other NAT instance
    pingresult=$(ping -c ${retry_pings:-$num_pings} -W $ping_timeout $other_nat_ip | grep time= | wc -l)
    if [ ${pingresult:-0} -eq 0 ]; then
        other_nat_state="$(query_nat_state $other_nat_id)"
        # If the other NAT state is not 'running' or we have already retried pinging it
        # then set all vars so that a fail-over occur
        if [ "$other_nat_state" != "running" ] || [ $retry_pings ]; then
            # Set all health-tracking vars to false
            route_healthy=false
            nat_healthy=false
            unset retry_pings
        else
            # Retry pinging the other NAT for a random number of pings again
            # this is in order to prevent race condition where both NATs
            # cannot reach each other but both are healthy
            retry_pings=$(($num_pings + $RANDOM%32))
        fi
        while ! $nat_healthy; do
            # NAT instance is unhealthy, loop while we try to fix it
            if ! $route_healthy; then
                warn "Other NAT '$other_nat_id' ($other_nat_ip) heartbeat failed, taking over default routes: $other_route_table_ids"
                for rt_id in $other_route_table_ids; do
                    assign_outbound_route replace $rt_id
                done
                route_healthy=true
            fi
            # Check NAT state to see if we should stop it or start it again
            case "$other_nat_state" in
                stopped)
                    info "Other NAT instance '$other_nat_id' stopped, starting it back up"
                    aws ec2 start-instances --region $region --instance-ids $other_nat_id --output text
                    if wait_for_nat_state running $other_nat_id; then
                        info "Other NAT instance '$other_nat_id' started, continuing to monitor"
                        nat_healthy=true
                    fi
                    ;;
                running)
                    info "Other NAT instance '$other_nat_id' is running, attempting to reboot it"
                    aws ec2 reboot-instances --region $region --instance-ids $other_nat_id --output text
                    if wait_for_nat_ping $other_nat_ip 3; then
                        info "Other NAT instance '$other_nat_id' started, continuing to monitor"
                        nat_healthy=true
                    fi
                    ;;
                stopping)
                    info "Other NAT instance '$other_nat_id' is stopping, waiting for it to stop"
                    if wait_for_nat_state stopped $other_nat_id; then
                        :
                    fi
                    ;;
                shutting-down|terminated)
                    die "Other NAT instance '$other_nat_id' is terminated, nothing to monitor any more"
                    ;;
            esac
        done
    else
        sleep $wait_between_pings
    fi
done

# vi: sw=4 ts=4 et:
