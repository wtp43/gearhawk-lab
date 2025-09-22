#!/bin/bash

# Define an alias for generating random strings. This needs to be a function in a script.
randstring() {
  openssl rand -base64 69 | tr -d "\n=+/" | cut -c1-$1
}

# Create keys directory
mkdir -p ./keys

# Function to clean up the keys directory
# cleanup() {
#   rm -rf ./keys
# }

# Register the cleanup function to be called on the EXIT signal
# trap cleanup EXIT

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
  echo "Docker could not be found. Please install Docker."
  exit 1
fi

# Generate keysets using Docker
docker run --user $(id -u):$(id -g) -v $(pwd)/keys:/hatchet/keys ghcr.io/hatchet-dev/hatchet/hatchet-admin:latest /hatchet/hatchet-admin keyset create-local-keys --key-dir /hatchet/keys

# Read keysets from files
SERVER_ENCRYPTION_MASTER_KEYSET=$(<./keys/master.key)
SERVER_ENCRYPTION_JWT_PRIVATE_KEYSET=$(<./keys/private_ec256.key)
SERVER_ENCRYPTION_JWT_PUBLIC_KEYSET=$(<./keys/public_ec256.key)
