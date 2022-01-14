#!/bin/bash -eu

# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Functions
function usage() {
  cat << EOF
install.sh
==========
Usage:
  install.sh [options]
Options:
  --project         GCP Project Id
  --dataset         The Big Query dataset to verify or create
CM360 Deployment Options:
  --cm360-table            BQ table to read conversions from
  --cm360-profile-id       CM360 profile id
  --cm360-fl-activity-id   CM360 floodlight activity id
  --cm360-fl-config-id     CM360 floodlight configuration id
Deployment directives:
  --activate-apis   Activate all missing but required Cloud APIs
  --create-service-account
                    Create the service account and client secrets
  --deploy-all Deploy all services
  --deploy-bigquery  Create BQ datasets
  --deploy-storage   Create storage buckets
  --deploy-delegator Create delegator cloud function
  --deploy-cm360-function Create cm360 cloud function

General switches:
  --dry-run         Don't do anything, just print the commands you would otherwise run. Useful
                    for testing.
EOF
}

function join { local IFS="$1"; shift; echo "$*"; }

function cm360-json {
cat <<EOF
{
  "table_name": "${CM360_TABLE}",
  "topic": "cm360_conversion_upload",
  "cm360_config": {
    "profile_id": "${CM360_PROFILE_ID}",
    "floodlight_activity_id": "${CM360_FL_ACTIVITY_ID}",
    "floodlight_configuration_id": "${CM360_FL_CONFIG_ID}"
  }
}
EOF
}

function get-roles {
  gcloud projects get-iam-policy ${PROJECT} --flatten="bindings[].members" --format='table(bindings.role)' --filter="bindings.members:${SA_EMAIL}"
}

function deploy-timestamp {
  # 2021-11-01-08-21-49
  date +%Y-%m-%d-%H-%M-%S
}

function maybe-run {
    if [ "${DRY_RUN:-}" = "echo" ]; then
        echo "$@"
    else
        if [ "$VERBOSE" = "true" ]; then
            echo "$@"
        fi
        "$@"
    fi
}

# Switch definitions
PROJECT=
USER=
DATASET="profitbidder"
ACTIVATE_APIS=0
BACKGROUND=0
CREATE_SERVICE_ACCOUNT=0
USERNAME=0
ADMIN=
SERVICE_ACCOUNT_NAME="profit-bidder"
STORAGE_BUCKET_NAME="conversion-upload_log"
CF_REGION="us-central1"
CM360_TABLE=""
CM360_PROFILE_ID=""
CM360_FL_ACTIVITY_ID=""
CM360_FL_CONFIG_ID=""
DEPLOY_BQ=0
DEPLOY_CM360_FUNCTION=0
DEPLOY_DELEGATOR=0
DEPLOY_STORAGE=0
DRY_RUN=""
SA_ROLES="roles/bigquery.dataViewer roles/pubsub.publisher roles/iam.serviceAccountTokenCreator"
VERBOSE=false

# Command line parser
while [[ ${1:-} == -* ]] ; do
  case $1 in
    --project*)
      IFS="=" read _cmd PROJECT <<< "$1" && [ -z ${PROJECT} ] && shift && PROJECT=$1
      ;;
    --dataset*)
      IFS="=" read _cmd DATASET <<< "$1" && [ -z ${DATASET} ] && shift && DATASET=$1
      ;;
    --cm360-table*)
      IFS="=" read _cmd CM360_TABLE <<< "$1" && [ -z ${CM360_TABLE} ] && shift && CM360_TABLE=$1
      ;;
    --cm360-profile-id*)
      IFS="=" read _cmd CM360_PROFILE_ID <<< "$1" && [ -z ${CM360_PROFILE_ID} ] && shift && CM360_PROFILE_ID=$1
      ;;
    --cm360-fl-activity-id*)
      IFS="=" read _cmd CM360_FL_ACTIVITY_ID <<< "$1" && [ -z ${CM360_FL_ACTIVITY_ID} ] && shift && CM360_FL_ACTIVITY_ID=$1
      ;;
    --cm360-fl-config-id*)
      IFS="=" read _cmd CM360_FL_CONFIG_ID <<< "$1" && [ -z ${CM360_FL_CONFIG_ID} ] && shift && CM360_FL_CONFIG_ID=$1
      ;;
    --deploy-all)
      DEPLOY_BQ=1
      DEPLOY_STORAGE=1
      DEPLOY_DELEGATOR=1
      DEPLOY_CM360_FUNCTION=1
      ACTIVATE_APIS=1
      CREATE_SERVICE_ACCOUNT=1
      ;;
    --deploy-bigquery)
      DEPLOY_BQ=1
      ;;
    --deploy-storage)
      DEPLOY_STORAGE=1
      ;;
    --deploy-delegator)
      DEPLOY_DELEGATOR=1
      ;;
    --deploy-cm360-function)
      DEPLOY_CM360_FUNCTION=1
      ;;
    --activate-apis)
      ACTIVATE_APIS=1
      ;;
    --create-service-account)
      CREATE_SERVICE_ACCOUNT=1
      ;;
    --dry-run)
      DRY_RUN=echo
      ;;
    --verbose)
      VERBOSE=true
      ;;
    --no-code)
      DEPLOY_CODE=0
      ;;
    *)
      usage
      echo -e "\nUnknown parameter $1."
      exit
  esac
  shift
done

if [ "${DRY_RUN:-}" = "echo" ]; then
    echo "--dry-run enabled: commands will be echoed instead of executed"
fi

if [ -z "${PROJECT}" ]; then
  usage
  echo -e "\nYou must specify a project to proceed."
  exit
fi

SA_EMAIL=${SERVICE_ACCOUNT_NAME}@${PROJECT}.iam.gserviceaccount.com
if [ ! -z ${ADMIN} ]; then
  _ADMIN="ADMINISTRATOR_EMAIL=${ADMIN}"
fi

if [ ${ACTIVATE_APIS} -eq 1 ]; then
  # Check for active APIs
  echo "Activating APIs"
  APIS_USED=(
    "bigquery"
    "bigquerystorage"
    "bigquerydatatransfer"
    "cloudbuild"
    "cloudfunctions"
    "cloudscheduler"
    "dfareporting"
    "doubleclickbidmanager"
    "doubleclicksearch"
    "iamcredentials"
    "pubsub"
    "storage-api"
  )
  ACTIVE_SERVICES="$(gcloud --project=${PROJECT} services list --enabled '--format=value(config.name)')"

  for api in ${APIS_USED[@]}; do
    if [[ "${ACTIVE_SERVICES}" =~ ${api} ]]; then
      echo "${api} already active"
    else
      echo "Activating ${api}"
      maybe-run gcloud --project=${PROJECT} services enable ${api}.googleapis.com
    fi
  done
fi

# create service account
if [ ${CREATE_SERVICE_ACCOUNT} -eq 1 ]; then
  if !gcloud iam service-accounts describe $SA_EMAIL &> /dev/null; then 
    echo "Creating service account '${SERVICE_ACCOUNT_NAME}'"
    maybe-run gcloud iam service-accounts create ${SERVICE_ACCOUNT_NAME} --description 'Profit Bidder Service Account' --project ${PROJECT}
  fi
  for role in ${SA_ROLES}; do
    echo -n "Adding ${SERVICE_ACCOUNT_NAME} to ${role} "
    if get-roles | grep $role &> /dev/null; then
      echo "already added."
    else
      maybe-run gcloud projects add-iam-policy-binding ${PROJECT} --member="serviceAccount:${SA_EMAIL}" --role="${role}"
      echo "added."
    fi
  done
fi


# create cloud storage bucket
if [ ${DEPLOY_STORAGE} -eq 1 ]; then
  # Create buckets
  echo "Creating buckets"
  for bucket in ${STORAGE_BUCKET_NAME}; do
    gsutil ls -p ${PROJECT} gs://${PROJECT}-${bucket} > /dev/null 2>&1
    RETVAL=$?
    if (( ${RETVAL} != "0" )); then
      maybe-run gsutil mb -p ${PROJECT} gs://${PROJECT}-${bucket}
    fi
  done
fi

# create bq datasets
if [ ${DEPLOY_BQ} -eq 1 ]; then
  echo "Creating BQ datasets"
  # Create dataset
  for dataset in sa360_data gmc_data business_data; do
    echo -n "Creating BQ dataset: '${dataset}'" 
    if ! bq --project_id=${PROJECT} show --dataset ${dataset} > /dev/null 2>&1; then
      maybe-run bq --project_id=${PROJECT} mk --dataset ${dataset}
      echo " created."
    else
      echo " already exists."
    fi
  done
fi

echo "Deploy Delegator: ${DEPLOY_DELEGATOR}"
# create cloud funtions
if [ ${DEPLOY_DELEGATOR} -eq 1 ]; then
  echo "Deploying Delegator Cloud Function"
  pushd converion_upload_delegator
  maybe-run gcloud functions deploy "cloud_conversion_upload_delegator" \
    --region=${CF_REGION} \
    --project=${PROJECT} \
    --trigger-topic=conversion_upload_delegator \
    --memory=2GB \
    --timeout=540s \
    --runtime python37 \
    --update-env-vars="SA_EMAIL=${SA_EMAIL}" \
    --service-account=${SA_EMAIL} \
    --update-labels="deploy-timestamp=$(deploy-timestamp)" \
    --entry-point=main 
  popd
fi

if [ ${DEPLOY_CM360_FUNCTION} -eq 1 ]; then
  echo "Creating CM360 Cloud Function"
 # Create scheduled job
  maybe-run gcloud beta scheduler jobs delete \
    --location=${CF_REGION} \
    --project=${PROJECT} \
    --quiet \
    "cm360-scheduler" || echo "No job to delete"

  maybe-run gcloud beta scheduler jobs create pubsub \
    "cm360-scheduler" \
    --location=${CF_REGION} \
    --project=${PROJECT} \
    --schedule="0 6 * * *" \
    --topic="conversion_upload_delegator" \
    --message-body='$(cm360-json)' || echo "scheduler failed!"

  if [ "$VERBOSE" = "true" ]; then
    echo
    echo
    echo "Delegator payload JSON:"
    cm360-json
    echo
    echo
  fi

  echo "Deploying CM360 Cloud Function"
  pushd CM360_cloud_conversion_upload_node
  # TAKE NOTE: this will create the trigger topic in pubsub if it does not 
  # already exist.
  maybe-run gcloud functions deploy "cm360_cloud_conversion_upload_node" \
    --region=${CF_REGION} \
    --project=${PROJECT} \
    --trigger-topic=cm360_conversion_upload \
    --memory=256MB \
    --timeout=540s \
    --runtime python37 \
    --update-env-vars="SA_EMAIL=${SA_EMAIL}" \
    --service-account=${SA_EMAIL} \
    --update-labels="deploy-timestamp=$(deploy-timestamp)" \
    --entry-point=main
  popd
fi

echo 'Script ran successfully!'
