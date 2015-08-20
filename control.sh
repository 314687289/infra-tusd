#!/usr/bin/env bash
# infra-tusd. Copyright (c) 2015, Transloadit Ltd.
#
# This file:
#
#  - Runs on a workstation
#  - Looks at environment for cloud provider credentials, keys and their locations
#  - Takes a 1st argument, the step:
#    - prepare: Install prerequisites
#    - init   : Refreshes current infra state and saves to terraform.tfstate
#    - plan   : Shows infra changes and saves in an executable plan
#    - backup : Backs up server state
#    - launch : Launches virtual machines at a provider (if needed) using Terraform's ./infra.tf
#    - install: Runs Ansible to install software packages & configuration templates
#    - upload : Upload the application
#    - setup  : Runs the ./playbook/setup.sh remotely, installing app dependencies and starting it
#    - show   : Displays active platform
#  - Takes an optional 2nd argument: "done". If it's set, only 1 step will execute
#  - Will cycle through all subsequential steps. So if you choose 'upload', 'setup' will
#    automatically be executed
#  - Looks at TSD_DRY_RUN environment var. Set it to 1 to just show what will happen
#
# Run as:
#
#  ./control.sh upload
#
# Authors:
#
#  - Kevin van Zonneveld <kevin@transloadit.com>
#
# Changelog:
#
#  - 2015-08-19 refactored casing
#  - 2015-08-19 auto-install of terraform-inventory
#  - 2015-08-19 auto-install of Ansible
#  - 2015-08-19 quoting of all path vars (so they work with spaces)

set -o pipefail
set -o errexit
set -o nounset
# set -o xtrace

if [ -z "${DEPLOY_ENV}" ]; then
  echo "Environment ${DEPLOY_ENV} not recognized. "
  echo "Please first source envs/development/config.sh or source envs/production/config.sh"
  exit 1
fi

# Set magic variables for current FILE & DIR
__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__file="${__dir}/$(basename "${BASH_SOURCE[0]}")"
__base="$(basename ${__file} .sh)"

__os="linux"
if [[ "${OSTYPE}" == "darwin"* ]]; then
  __os="darwin"
fi
__arch="amd64"

__ansibleVersion="1.9.2"
__terraformVersion="0.6.3"
__terraformInventoryVersion="0.5"

__rootDir="${__dir}"
__binDir="${__rootDir}/bin"
__terraformDir="${__binDir}/terraform"
__envDir="${__rootDir}/envs/${DEPLOY_ENV}"
__playbookDir="${__rootDir}/playbook"
__terraformExe="${__terraformDir}/terraform"
__terraformInventoryExe="${__binDir}/terraform-inventory-${__terraformInventoryVersion}-${__os}-${__arch}"
__ansibleExe="ansible"
__ansiblePlaybookExe="ansible-playbook"
__ansibleCfg="${__rootDir}/ansible.cfg"

__planFile="${__envDir}/terraform.plan"
__stateFile="${__envDir}/terraform.tfstate"
__playbookFile="${__playbookDir}/main.yml"




### Functions
####################################################################################

function syncUp() {
  [ -z "${host:-}" ] && host="$(${__terraformExe} output public_address)"
  chmod 600 "${TSD_SSH_KEYPUB_FILE}"
  chmod 600 "${TSD_SSH_KEY_FILE}"
  rsync \
   --archive \
   --delete \
   --exclude=.git* \
   --exclude=.DS_Store \
   --exclude=node_modules \
   --exclude=terraform.* \
   --itemize-changes \
   --checksum \
   --no-times \
   --no-group \
   --no-motd \
   --no-owner \
   --rsh="ssh \
    -i \"${TSD_SSH_KEY_FILE}\" \
    -l ${TSD_SSH_USER} \
    -o CheckHostIP=no \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no" \
   ${@:2} \
  ${host}:${1}
}

function syncDown() {
  [ -z "${host:-}" ] && host="$(${__terraformExe} output public_address)"
  chmod 600 "${TSD_SSH_KEYPUB_FILE}"
  chmod 600 "${TSD_SSH_KEY_FILE}"
  rsync \
   --archive \
   --delete \
   --exclude=.git* \
   --exclude=.java* \
   --exclude=.* \
   --exclude=*.log \
   --exclude=*.log.* \
   --exclude=*.txt \
   --exclude=org.jenkinsci.plugins.ghprb.GhprbTrigger.xml \
   --exclude=*.bak \
   --exclude=*.hpi \
   --exclude=node_modules \
   --exclude=.DS_Store \
   --exclude=plugins \
   --exclude=builds \
   --exclude=lastStable \
   --exclude=lastSuccessful \
   --exclude=*secret* \
   --exclude=*identity* \
   --exclude=nextBuildNumber \
   --exclude=userContent \
   --exclude=nodes \
   --exclude=updates \
   --exclude=terraform.* \
   --itemize-changes \
   --checksum \
   --no-times \
   --no-group \
   --no-motd \
   --no-owner \
   --no-perms \
   --rsh="ssh \
    -i \"${TSD_SSH_KEY_FILE}\" \
    -l ${TSD_SSH_USER} \
    -o CheckHostIP=no \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no" \
  ${host}:${1} \
  ${2}
}

function remote() {
  [ -z "${host:-}" ] && host="$(${__terraformExe} output public_address)"
  chmod 600 "${TSD_SSH_KEYPUB_FILE}"
  chmod 600 "${TSD_SSH_KEY_FILE}"
  ssh ${host} \
    -i "${TSD_SSH_KEY_FILE}" \
    -l ${TSD_SSH_USER} \
    -o UserKnownHostsFile=/dev/null \
    -o CheckHostIP=no \
    -o StrictHostKeyChecking=no "${@:-}"
}

# Waits on first host, then does the rest in parallel
# This is so that the leader can be setup, and then all the followers can join
function inParallel () {
  cnt=0
  for host in $(${__terraformExe} output public_addresses); do
    let "cnt = cnt + 1"
    if [ "${cnt}" = 1 ]; then
      # wait on leader leader
      ${@}
    else
      ${@} &
    fi
  done

  fail=0
  for job in $(jobs -p); do
    # echo ${job}
    wait ${job} || let "fail = fail + 1"
  done
  if [ "${fail}" -ne 0 ]; then
    exit 1
  fi
}


### Vars
####################################################################################

dryRun="${TSD_DRY_RUN:-0}"
step="${1:-prepare}"
afterone="${2:-}"
enabled=0


### Runtime
####################################################################################

pushd "${__envDir}" > /dev/null

if [ "${step}" = "remote" ]; then
  remote ${@:2}
  exit ${?}
fi
if [ "${step}" = "facts" ]; then
  ANSIBLE_HOST_KEY_CHECKING=False \
  TF_STATE="${__stateFile}" \
    "${__ansibleExe}" all \
      --user="${TSD_SSH_USER}" \
      --private-key="${TSD_SSH_KEY_FILE}" \
      --inventory-file="${__terraformInventoryExe}" \
      --module-name=setup \
      --args='filter=ansible_*'

  exit ${?}
fi
if [ "${step}" = "backup" ]; then
  # syncDown "/var/lib/mysql" "${__dir}/data/"
  exit ${?}
fi
if [ "${step}" = "restore" ]; then
  # remote "sudo /etc/init.d/redis-server stop || true"
  # remote "sudo addgroup ubuntu redis || true"
  # remote "sudo chmod -R g+wr /var/lib/redis"
  # syncUp "/var/lib/redis/dump.rdb" "./data/redis-dump.rdb"
  # remote "sudo chown -R redis.redis /var/lib/redis"
  # remote "sudo /etc/init.d/redis-server start"
  exit ${?}
fi

processed=""
for action in "prepare" "init" "plan" "backup" "launch" "install" "upload" "setup" "show"; do
  [ "${action}" = "${step}" ] && enabled=1
  [ "${enabled}" -eq 0 ] && continue
  if [ -n "${processed}" ] && [ "${afterone}" = "done" ]; then
    break
  fi

  echo "--> ${TSD_HOSTNAME} - ${action}"

  if [ "${action}" = "prepare" ]; then
    # Install brew/wget on OSX
    if [ "${__os}" = "darwin" ]; then
      [ -z "$(which brew 2>/dev/null)" ] && ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
      [ -z "$(which wget 2>/dev/null)" ] && brew install wget
    fi

    # Install Ansible
    if [ "$(echo $("${__ansibleExe}" --version |head -n1))" != "ansible 1.9.2" ]; then
      echo "--> ${TSD_HOSTNAME} - installing Ansible v${__ansibleVersion}"
      set -x
      sudo easy_install pip
      sudo pip install --upgrade pip
      set +x
      if [ "${__os}" = "darwin" ]; then
        set -x
        sudo env CFLAGS=-Qunused-arguments CPPFLAGS=-Qunused-arguments pip install --upgrade ansible==1.9.2
        set +x
      else
        set -x
        sudo pip install --upgrade ansible=1.9.2
        set +x
      fi
    fi

    # Install Terraform
    mkdir -p "${__terraformDir}"
    pushd "${__terraformDir}" > /dev/null
      if [ "$(echo $("${__terraformExe}" version))" != "Terraform v${__terraformVersion}" ]; then
      echo "--> ${TSD_HOSTNAME} - installing Terraform v{__terraformVersion}"
        zipFile="terraform_${__terraformVersion}_${__os}_${__arch}.zip"
        url="https://dl.bintray.com/mitchellh/terraform/${zipFile}"
        rm -f "${zipFile}" || true
        wget "${url}"
        unzip -o "${zipFile}"
        rm -f "${zipFile}"
      fi
      "${__terraformExe}" version |grep "Terraform v${__terraformVersion}"
    popd > /dev/null

    # Install SSH Keys
    if [ ! -f "${TSD_SSH_KEY_FILE}" ]; then
      echo -e "\n\n" | ssh-keygen -t rsa -C "${TSD_SSH_EMAIL}" -f "${TSD_SSH_KEY_FILE}"
      echo "You may need to add ${TSD_SSH_KEYPUB_FILE} to the Digital Ocean"
      export TSD_SSH_KEYPUB=$(echo "$(cat "${TSD_SSH_KEYPUB_FILE}")") || true
      # Digital ocean requires this:
      export TSD_SSH_KEYPUB_FINGERPRINT="$(ssh-keygen -lf ${TSD_SSH_KEYPUB_FILE} | awk '{print $2}')"
    fi
    if [ ! -f "${TSD_SSH_KEYPUB_FILE}" ]; then
      chmod 600 "${TSD_SSH_KEY_FILE}" || true
      ssh-keygen -yf "${TSD_SSH_KEY_FILE}" > "${TSD_SSH_KEYPUB_FILE}"
      chmod 600 "${TSD_SSH_KEYPUB_FILE}" || true
    fi

    processed="${processed} ${action}" && continue
  fi

  terraformArgs=""
  terraformArgs="${terraformArgs} -var TSD_AWS_SECRET_KEY=${TSD_AWS_SECRET_KEY}"
  terraformArgs="${terraformArgs} -var TSD_AWS_ACCESS_KEY=${TSD_AWS_ACCESS_KEY}"
  terraformArgs="${terraformArgs} -var TSD_AWS_ZONE_ID=${TSD_AWS_ZONE_ID}"
  terraformArgs="${terraformArgs} -var TSD_DOMAIN=${TSD_DOMAIN}"
  terraformArgs="${terraformArgs} -var TSD_SSH_KEYPUB=\"${TSD_SSH_KEYPUB}\""
  terraformArgs="${terraformArgs} -var TSD_SSH_USER=${TSD_SSH_USER}"
  terraformArgs="${terraformArgs} -var TSD_SSH_KEY_FILE=${TSD_SSH_KEY_FILE}"
  terraformArgs="${terraformArgs} -var TSD_SSH_KEY_NAME=${TSD_SSH_KEY_NAME}"

  if [ "${action}" = "init" ]; then
    # if [ ! -f "${__stateFile}" ]; then
    #   echo "Nothing to refresh yet."
    # else
    bash -c "${__terraformExe} refresh ${terraformArgs}" || true
    # fi
  fi

  if [ "${action}" = "plan" ]; then
    rm -f "${__planFile}"
    bash -c ""${__terraformExe}" plan -refresh=false ${terraformArgs} -out "${__planFile}""
    processed="${processed} ${action}" && continue
  fi

  if [ "${action}" = "backup" ]; then
    # Save state before possibly destroying machine
    processed="${processed} ${action}" && continue
  fi

  if [ "${action}" = "launch" ]; then
    if [ -f "${__planFile}" ]; then
      echo "--> Press CTRL+C now if you are unsure! Executing plan in ${TSD_VERIFY_TIMEOUT}s..."
      [ "${dryRun}" -eq 1 ] && echo "--> Dry run break" && exit 1
      sleep ${TSD_VERIFY_TIMEOUT}
      # exit 1
      "${__terraformExe}" apply "${__planFile}"
      git add "${__stateFile}" || true
      git add "${__stateFile}.backup" || true
      git commit -m "Save infra state" || true
    else
      echo "Skipping, no changes. "
    fi
    processed="${processed} ${action}" && continue
  fi

  if [ "${action}" = "install" ]; then
    tags=""
    if [ -n "${TSD_ANSIBLE_TAGS}" ]; then
      tags="--tags="${TSD_ANSIBLE_TAGS}""
    fi
    ANSIBLE_CONFIG="${__ansibleCfg}" \
    ANSIBLE_HOST_KEY_CHECKING=False \
    TF_STATE="${__stateFile}" \
      "${__ansiblePlaybookExe}" \
        ${tags} \
        --user="${TSD_SSH_USER}" \
        --private-key="${TSD_SSH_KEY_FILE}" \
        --inventory-file="${__terraformInventoryExe}" \
        --sudo \
      "${__playbookFile}"

    # inParallel "remote" "bash -c \"source ~/playbook/env/config.sh && sudo -E bash ~/playbook/install.sh\""
    processed="${processed} ${action}" && continue
  fi

  if [ "${action}" = "upload" ]; then
    # Upload/Download app here
    processed="${processed} ${action}" && continue
  fi

  if [ "${action}" = "setup" ]; then
    # Restart services
    processed="${processed} ${action}" && continue
  fi

  if [ "${action}" = "show" ]; then
    echo "http://${TSD_DOMAIN}:${TSD_APP_PORT}"
    # for host in $("${__terraformExe}" output public_addresses); do
    #   echo " - http://${host}:${TSD_APP_PORT}"
    # done
    processed="${processed} ${action}" && continue
  fi
done
popd > /dev/null

echo "--> ${TSD_HOSTNAME} - completed:${processed} : )"
