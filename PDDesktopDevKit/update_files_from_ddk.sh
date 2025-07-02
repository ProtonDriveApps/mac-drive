#!/bin/bash

set -ex

# Load env variables
test -f ~/.env && source ~/.env

# Verify env variables
if [ -z "$PROTON_DRIVE_DDK_DIR" ]; then
  echo "Please add the location of the directory containing your desktop-dev-kit repo to ~/.env as \"PROTON_DRIVE_DDK_DIR\""
  exit
fi


SCRIPT_DIR="$(dirname $0)"
pushd "$SCRIPT_DIR"

BASE_DIR="$(pwd)"

DDK_PROTO_DIRECTORY="$PROTON_DRIVE_DDK_DIR/protos"

OUTPUT_DIRECTORY="./Sources/PDDesktopDevKit/Generated"
mkdir -p "$OUTPUT_DIRECTORY"


protoc \
    --swift_out="Visibility=Public:$OUTPUT_DIRECTORY" \
    "$DDK_PROTO_DIRECTORY/account.proto" \
    --proto_path="$DDK_PROTO_DIRECTORY"

protoc \
    --swift_out="Visibility=Public:$OUTPUT_DIRECTORY" \
    "$DDK_PROTO_DIRECTORY/drive.proto" \
    --proto_path="$DDK_PROTO_DIRECTORY"

echo Success!
