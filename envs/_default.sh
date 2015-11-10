#!/usr/bin/env bash
# Environment tree:
#
#   _default.sh
#   ├── development.sh
#   │   └── test.sh
#   └── production.sh
#       └── staging.sh
#
# This provides DRY flexibilty, but in practice I recommend using mainly
# development.sh and production.sh, and duplication keys between them
# so you can easily compare side by side.
# Then just use _default.sh, test.sh, staging.sh for tweaks, to keep things
# clear.
#
# These variables are mandatory and have special meaning
#
#   - NODE_APP_PREFIX="MYAPP" # filter and nest vars starting with MYAPP right into your app
#   - NODE_ENV="production"   # the environment your program thinks it's running
#   - DEPLOY_ENV="staging"    # the machine you are actually running on
#   - DEBUG=*.*               # Used to control debug levels per module
#
# After getting that out of the way, feel free to start hacking on, prefixing all
# vars with MYAPP a.k.a an actuall short abbreviation of your app name.

export APP_PREFIX="TSD"
export NODE_APP_PREFIX="${APP_PREFIX}"

export FREY_DOMAIN="master.tus.io"

export FREY_APP_DIR="/srv/current"
export FREY_APP_NAME="infra-tusd"
export FREY_APP_PORT="8080"
export FREY_HOSTNAME="$(uname -n)"

export FREY_SERVICE_USER="www-data"
export FREY_SERVICE_GROUP="www-data"

export FREY_SSH_KEY_NAME="infra-tusd"
export FREY_SSH_USER="ubuntu"
export FREY_SSH_EMAIL="hello@infra-tusd"
export FREY_SSH_KEY_FILE="${__envdir}/infra-tusd.pem"
export FREY_SSH_KEYPUB_FILE="${__envdir}/infra-tusd.pub"
export FREY_SSH_KEYPUB=$(echo "$(cat "${FREY_SSH_KEYPUB_FILE}" 2>/dev/null)") || true
export FREY_SSH_KEYPUB_FINGERPRINT="$(ssh-keygen -lf ${FREY_SSH_KEYPUB_FILE} | awk '{print $2}')"


export FREY_ANSIBLE_TAGS="${IIM_ANSIBLE_TAGS:-}"

export FREY_VERIFY_TIMEOUT=5
