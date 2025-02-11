#!/usr/bin/python
#
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

import base64
import datetime
import google.auth
import google.auth.impersonated_credentials
import json
import time
import pytz

from io import StringIO

import google_auth_httplib2
from googleapiclient import discovery
from googleapiclient import errors

from google.cloud import bigquery
from google.cloud import pubsub
from google.cloud import storage

IMPERSONATED_SVC_ACCOUNT = 'your-service-account@your-project-name.iam.gserviceaccount.com'

API_SCOPES = ['https://www.googleapis.com/auth/dfareporting',
              'https://www.googleapis.com/auth/dfatrafficking',
              'https://www.googleapis.com/auth/ddmconversions',
              'https://www.googleapis.com/auth/devstorage.read_write']
CM360_API_NAME = 'dfareporting'
CM360_API_VERSION = 'v3.4'

# Defaults to America/New_York, please update to 
# your respective timezone if needed.
PROJECT_TIMEZONE = 'America/New_York'

def setup():
    source_credentials, project_id = google.auth.default()

    target_credentials = google.auth.impersonated_credentials.Credentials(
        source_credentials=source_credentials,
        target_principal=IMPERSONATED_SVC_ACCOUNT,
        target_scopes=API_SCOPES,
        delegates=[],
        lifetime=500)

    http = google_auth_httplib2.AuthorizedHttp(target_credentials)
    # setup API service here
    return discovery.build(
        CM360_API_NAME,
        CM360_API_VERSION,
        cache_discovery=False,
        http=http)


def today_date():
    tz = pytz.timezone(PROJECT_TIMEZONE)
    return datetime.datetime.now(tz).date()


def time_now_str():
      # set correct timezone for datetime check
    tz = pytz.timezone(PROJECT_TIMEZONE)
    return datetime.datetime.now(tz).strftime("%m-%d-%Y, %H:%M:%S")


def upload_data(rows, profile_id, fl_configuration_id, fl_activity_id):
    print('Starting conversions for ' + time_now_str())
    if not fl_activity_id or not fl_configuration_id:
        print('Please make sure to provide a value for both floodlightActivityId and floodlightConfigurationId!!')
        return
    # Build the API connection
    service = setup()
    # upload_log = ''
    print('Authorization successful')
    currentrow = 0
    all_conversions = """{"kind": "dfareporting#conversionsBatchInsertRequest", "conversions": ["""
    while currentrow < len(rows):
        for row in rows[currentrow:min(currentrow+100, len(rows))]:
            conversion = json.dumps({
                'kind': 'dfareporting#conversion',
                'gclid': row['conversionVisitExternalClickId'],
                'floodlightActivityId': fl_activity_id, # (Use short form CM Floodlight Activity Id )
                'floodlightConfigurationId': fl_configuration_id, # (Can be found in CM UI)
                'ordinal': row['conversionId'],
                'timestampMicros': row['conversionTimestampMicros'],
                'value': row['conversionRevenue'],
                'quantity': row['conversionQuantity'] #(Alternatively, this can be hardcoded to 1)
            })
            # print('Conversion: ', conversion) # uncomment if you want to output each conversion
            all_conversions = all_conversions + conversion + ','
        all_conversions = all_conversions[:-1] + ']}'
        request = service.conversions().batchinsert(profileId=profile_id, body=json.loads(all_conversions))
        print('[{}] - CM360 API Request: '.format(time_now_str()), request)
        response = request.execute()
        print('[{}] - CM360 API Response: '.format(time_now_str()), request)
        if not response['hasFailures']:
            print('Successfully inserted batch of 100.')
        else:
            status = response['status']
            for line in status:
                try:
                    if line['errors']:
                        for error in line['errors']:
                            print('Error in line ' + json.dumps(line['conversion']))
                            print('\t[%s]: %s' % (error['code'], error['message']))
                except:
                    print('Conversion with gclid ' + line['gclid'] + ' inserted.')
        print('Either finished or found errors.')
        currentrow += 100
        all_conversions = """{"kind": "dfareporting#conversionsBatchInsertRequest", "conversions": ["""


def main(event, context):
    print('[{}] - Start CM360 conversion upload'.format(time_now_str()))
    print('Event: ', event)

    # decode pub/sub payload
    payload = base64.b64decode(event.get('data')).decode('ascii')
    json_payload = json.loads(payload)

    print('Payload: ', json_payload)
    # General required data
    conversion_data = json_payload['data']['conversions'] if 'conversions' in json_payload['data'] else None
    config = json_payload['data']['config'] if 'config' in json_payload['data'] else None

    if conversion_data:
        # CM specific data
        profile_id = config['profile_id'] if 'profile_id' in config else None

        floodlight_activity_id = config['floodlight_activity_id'] if 'floodlight_activity_id' in config else None

        floodlight_configuration_id = config['floodlight_configuration_id'] if 'floodlight_configuration_id' in config else None

        if profile_id and floodlight_activity_id and floodlight_configuration_id:
            upload_data(
                conversion_data,
                profile_id,
                floodlight_configuration_id,
                floodlight_activity_id)
        else:
            print('Missing values profile_id, floodlight_activity_id or floodlight_configuration_id. PLease check pub/sub message. Upload aborted!')
    else:
        print('No conversion data passed into the function! Please check your workflow for downstream errors')