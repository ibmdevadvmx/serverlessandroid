#!/bin/bash
#
# Copyright 2017 IBM Corp. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the “License”);
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an “AS IS” BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# load configuration variables
source local.env

function usage() {
  echo "Usage: $0 [--install,--uninstall,--update,--recycle,--env]"
}

function install() {

  echo "Creating database..."
  # ignore "database already exists error"
  curl -s -X PUT $CLOUDANT_URL/users | grep -v file_exists
  curl -s -X PUT $CLOUDANT_URL/feedback | grep -v file_exists
  curl -s -X PUT $CLOUDANT_URL/moods | grep -v file_exists

  # echo "Inserting database design documents..."
  # # ignore "document already exists error"
  curl -s -X POST -H 'Content-Type: application/json' -d @actions/feedback/moods.json $CLOUDANT_URL/moods/_bulk_docs | grep -v conflict

  echo "Creating packages..."
  ibmcloud fn package create $PACKAGE_NAME\
    -p services.cloudant.url $CLOUDANT_URL\
    -p services.appid.url $APPID_URL\
    -p services.appid.clientId $APPID_CLIENTID\
    -p services.appid.secret $APPID_SECRET\
    -p services.ta.url $TONE_ANALYZER_URL\
    -p services.ta.username $TONE_ANALYZER_USERNAME\
    -p services.ta.password $TONE_ANALYZER_PASSWORD\

  ibmcloud fn package bind /whisk.system/cloudant \
    $PACKAGE_NAME-cloudant \
    -p username $CLOUDANT_USERNAME \
    -p password $CLOUDANT_PASSWORD \
    -p host $CLOUDANT_HOST

  ibmcloud fn package bind /whisk.system/pushnotifications \
    $PACKAGE_NAME-push \
    -p appId $PUSH_APP_GUID \
    -p appSecret $PUSH_APP_SECRET \
    -p apiHost $PUSH_APP_API_HOST

  echo "Creating actions..."
  ibmcloud fn action create $PACKAGE_NAME/auth-validate \
    actions/validate/build/libs/validate.jar \
    --main serverlessfollowup.auth.ValidateToken \
    --annotation final true

  ibmcloud fn action create $PACKAGE_NAME/users-add \
    actions/users/build/libs/users.jar \
    --main serverlessfollowup.users.AddUser \
    --annotation final true

  ibmcloud fn action create $PACKAGE_NAME/users-prepare-notify \
    actions/users/build/libs/users.jar \
    --main serverlessfollowup.users.PrepareUserNotification \
    --annotation final true

  ibmcloud fn action create $PACKAGE_NAME/feedback-put \
    actions/feedback/build/libs/feedback.jar \
    --main serverlessfollowup.feedback.AddFeedback \
    --annotation final true

  ibmcloud fn action create $PACKAGE_NAME/feedback-analyze \
    actions/feedback/build/libs/feedback.jar \
    --main serverlessfollowup.feedback.AnalyzeFeedback \
    --annotation final true

  echo "Creating sequences..."
  ibmcloud fn action create $PACKAGE_NAME/users-add-sequence \
    $PACKAGE_NAME/auth-validate,$PACKAGE_NAME/users-add \
    --sequence \
    --web true

  ibmcloud fn action create $PACKAGE_NAME/feedback-put-sequence \
    $PACKAGE_NAME/auth-validate,$PACKAGE_NAME/feedback-put \
    --sequence \
    --web true

  # sequence reading the document from cloudant changes then calling analyze feedback on it
  ibmcloud fn action create $PACKAGE_NAME/feedback-analyze-sequence \
    $PACKAGE_NAME-cloudant/read-document,$PACKAGE_NAME/feedback-analyze,$PACKAGE_NAME/users-prepare-notify,$PACKAGE_NAME-push/sendMessage \
    --sequence

  echo "Creating triggers..."
  ibmcloud fn trigger create feedback-analyze-trigger --feed $PACKAGE_NAME-cloudant/changes \
    -p dbname feedback
  ibmcloud fn rule create feedback-analyze-rule feedback-analyze-trigger $PACKAGE_NAME/feedback-analyze-sequence
}

function uninstall() {
  echo "Removing triggers..."
  ibmcloud fn rule delete feedback-analyze-rule
  ibmcloud fn trigger delete feedback-analyze-trigger

  echo "Removing sequence..."
  ibmcloud fn action delete $PACKAGE_NAME/users-add-sequence
  ibmcloud fn action delete $PACKAGE_NAME/feedback-put-sequence
  ibmcloud fn action delete $PACKAGE_NAME/feedback-analyze-sequence

  echo "Removing actions..."
  ibmcloud fn action delete $PACKAGE_NAME/auth-validate
  ibmcloud fn action delete $PACKAGE_NAME/users-add
  ibmcloud fn action delete $PACKAGE_NAME/users-prepare-notify
  ibmcloud fn action delete $PACKAGE_NAME/feedback-put
  ibmcloud fn action delete $PACKAGE_NAME/feedback-analyze

  echo "Removing packages..."
  ibmcloud fn package delete $PACKAGE_NAME-cloudant
  ibmcloud fn package delete $PACKAGE_NAME-push
  ibmcloud fn package delete $PACKAGE_NAME

  echo "Done"
  ibmcloud fn list
}

function update() {
  echo "Updating actions..."
  ibmcloud fn action update $PACKAGE_NAME/auth-validate \
    actions/validate/build/libs/validate.jar \
    --main serverlessfollowup.auth.ValidateToken

  ibmcloud fn action update $PACKAGE_NAME/users-add \
    actions/users/build/libs/users.jar \
    --main serverlessfollowup.users.AddUser

  ibmcloud fn action update $PACKAGE_NAME/users-prepare-notify \
    actions/users/build/libs/users.jar \
    --main serverlessfollowup.users.PrepareUserNotification

  ibmcloud fn action update $PACKAGE_NAME/feedback-put \
    actions/feedback/build/libs/feedback.jar \
    --main serverlessfollowup.feedback.AddFeedback

  ibmcloud fn action update $PACKAGE_NAME/feedback-analyze \
    actions/feedback/build/libs/feedback.jar \
    --main serverlessfollowup.feedback.AnalyzeFeedback
}

function showenv() {
  echo "PACKAGE_NAME=$PACKAGE_NAME"
  echo "CLOUDANT_URL=$CLOUDANT_URL"
}

function recycle() {
  uninstall
  install
}

case "$1" in
"--install" )
install
;;
"--uninstall" )
uninstall
;;
"--update" )
update
;;
"--env" )
showenv
;;
"--recycle" )
recycle
;;
* )
usage
;;
esac
