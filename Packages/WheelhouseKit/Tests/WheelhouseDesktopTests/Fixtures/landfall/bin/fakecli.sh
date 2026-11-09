#!/bin/sh
# Stands in for aws, gcloud and az in tests. Logs what it saw into the isolated HOME and answers a few commands.
name=$(basename "$0")
echo "$name $* | HOME=$HOME AWS_CONFIG_FILE=$AWS_CONFIG_FILE CLOUDSDK_CONFIG=$CLOUDSDK_CONFIG AZURE_CONFIG_DIR=$AZURE_CONFIG_DIR GOOGLE_APPLICATION_CREDENTIALS=$GOOGLE_APPLICATION_CREDENTIALS AZURE_CLIENT_SECRET=$AZURE_CLIENT_SECRET" >> "$HOME/fake-cli.log"
case "$name $1" in
  "aws --version") echo "aws-cli/2.17.0 Python/3.12.4 Darwin/27.0 source/arm64" ;;
  "aws configure") printf 'default\nplatform-prod\n' ;;
  "gcloud version") echo '{"Google Cloud SDK":"512.0.0"}' ;;
  "az version") echo '{"azure-cli":"2.66.0"}' ;;
  *) echo "unexpected: $*" >&2; exit 3 ;;
esac
