#!/bin/bash
set -euo pipefail

# put the opsworks name of your server if you don't use the ocm_server tag
declare -x OCM_SERVER="Puppet-Master-3"
# put the region of your OCM Server if you don't use the ocm_region tag
declare -x OCM_REGION="us-east-2"

# extra optional settings
AWS_CLI_EXTRA_OPTS=()
CFN_SIGNAL=""

# check OS and install related packages
function prepare_os_packages {
  local OS=`uname -a`
  if [[ ${OS} = *"Ubuntu"* ]]; then
    apt update && DEBIAN_FRONTEND=noninteractive apt -y upgrade
    apt -y install unzip python python-pip
    pip install awscli
  else
    yum -y update
    yum install -y git
  fi
}

function set_aws_settings {
  export PP_INSTANCE_ID=$(curl --silent --show-error --retry 3 http://169.254.169.254/latest/meta-data/instance-id)
  # this uses the EC2 instance ID as the node name
  export PP_IMAGE_NAME=$(curl --silent --show-error --retry 3 http://169.254.169.254/latest/meta-data/ami-id)
  export PP_REGION=$(curl --silent --show-error --retry 3 http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/.$//')


  # we're detecting if a tag is set, if so, override anything in the file
  export TAG_SERVER=$(aws ec2 describe-tags --region ${PP_REGION} --filters "Name=resource-id,Values=${PP_INSTANCE_ID}" \
  --query 'Tags[?Key==`ocm_server`].Value' --output text)
  export TAG_REGION=$(aws ec2 describe-tags --region ${PP_REGION} --filters "Name=resource-id,Values=${PP_INSTANCE_ID}" \
  --query 'Tags[?Key==`ocm_region`].Value' --output text)

  if [ -n ${TAG_SERVER} ] && [ ! -z ${TAG_SERVER} ]; then
    export OCM_SERVER=${TAG_SERVER}
  fi

  if [ -n ${TAG_REGION} ] && [ ! -z ${TAG_REGION} ]; then
    export OCM_REGION=${TAG_REGION}
  fi

  # set global settings
  export PUPPETSERVER=$(aws  opsworks-cm describe-servers --region=${OCM_REGION} ${AWS_CLI_EXTRA_OPTS[@]:-} \
  --query "Servers[?ServerName=='${OCM_SERVER}'].Endpoint" --output text)
  export PRUBY='/opt/puppetlabs/puppet/bin/ruby'
  export PUPPET='/opt/puppetlabs/bin/puppet'
  export DAEMONSPLAY='true'
  export SPLAYLIMIT='180'
  export PUPPET_CA_PATH='/etc/puppetlabs/puppet/ssl/certs/ca.pem'
}

function prepare_puppet {
  mkdir -p /opt/puppetlabs/puppet/cache/state
  mkdir -p /etc/puppetlabs/puppet/ssl/certs/
  mkdir -p /etc/puppetlabs/code/modules/

  echo "{\"disabled_message\":\"Locked by OpsWorks Deploy - $(date --iso-8601=seconds)\"}" > /opt/puppetlabs/puppet/cache/state/agent_disabled.lock
}

function establish_trust {
 aws opsworks-cm describe-servers --region=${OCM_REGION} --server-name ${OCM_SERVER} ${AWS_CLI_EXTRA_OPTS[@]:-} \
 --query "Servers[0].EngineAttributes[?Name=='PUPPET_API_CA_CERT'].Value" --output text > /etc/puppetlabs/puppet/ssl/certs/ca.pem
}

function install_puppet {
  ADD_EXTENSIONS=$(generate_csr_attributes)
  curl --cacert /etc/puppetlabs/puppet/ssl/certs/ca.pem --retry 3 "https://${PUPPETSERVER}:8140/packages/current/install.bash" | \
  /bin/bash -s agent:certname=${PP_INSTANCE_ID} \
  agent:splay=${DAEMONSPLAY} \
  extension_requests:pp_instance_id=${PP_INSTANCE_ID} \
  extension_requests:pp_region=${PP_REGION} \
  extension_requests:pp_image_name=${PP_IMAGE_NAME} ${ADD_EXTENSIONS}

  ${PUPPET} resource service puppet ensure=stopped
}

function generate_csr_attributes {
  pp_tags=$(aws ec2 describe-tags --region ${PP_REGION} --filters "Name=resource-id,Values=${PP_INSTANCE_ID}" \
  --query 'Tags[?starts_with(Key, `pp_`)].[Key,Value]' --output text | sed s/[[:blank:]]/=/)
  if [ -z ${pp_tags} ]; then
    # couldn't describe tags, probably missing permissions in the IAM Role
    return 0
  fi

  csr_attrs=""
  for i in $pp_tags; do
    csr_attrs="${csr_attrs} extension_requests:${i}"
  done

  echo ${csr_attrs}
}

function install_puppet_bootstrap {
  ${PUPPET} help bootstrap > /dev/null && bootstrap_installed=true || bootstrap_installed=false
  if [ "${bootstrap_installed}" = false ]; then
    echo "Puppet Bootstrap not present, installing"
    curl --retry 3 https://s3-eu-west-1.amazonaws.com/opsworks-cm-eu-west-1-beta-default-assets/misc/owpe/puppet-agent-bootstrap-0.2.1.tar.gz \
    -o /tmp/puppet-agent-bootstrap-0.2.1.tar.gz
    ${PUPPET} module install /tmp/puppet-agent-bootstrap-0.2.1.tar.gz --ignore-dependencies
    echo "Puppet Bootstrap installed"
  else
    echo "Puppet Bootstrap already present"
  fi
}

function run_puppet {
  sleep $[ ( ${RANDOM} % ${SPLAYLIMIT} ) + 1]s
  ${PUPPET} agent --enable
  ${PUPPET} agent --onetime --verbose --no-daemonize --no-usecacheonfailure --no-splay --show_diff
  ${PUPPET} resource service puppet ensure=running enable=true
}

function associate_node {
  CERTNAME=$(${PUPPET} config print certname --section agent)
  SSLDIR=$(${PUPPET} config print ssldir --section agent)
  PP_CSR_PATH="${SSLDIR}/certificate_requests/${CERTNAME}.pem"
  PP_CERT_PATH="${SSLDIR}/certs/${CERTNAME}.pem"

  # clear out extraneous certs and generate a new one
  ${PUPPET} bootstrap purge
  ${PUPPET} bootstrap csr

  # submit the cert
  ASSOCIATE_TOKEN=$(aws opsworks-cm associate-node --region ${OCM_REGION} --server-name ${OCM_SERVER} ${AWS_CLI_EXTRA_OPTS[@]:-} \
  --node-name ${CERTNAME} --engine-attributes Name=PUPPET_NODE_CSR,Value="`cat ${PP_CSR_PATH}`" --query "NodeAssociationStatusToken" --output text)

  # wait
  aws opsworks-cm wait node-associated --region ${OCM_REGION} --node-association-status-token "${ASSOCIATE_TOKEN}" \
  --server-name ${OCM_SERVER} ${AWS_CLI_EXTRA_OPTS[@]:-}
  # install and verify
  aws opsworks-cm describe-node-association-status --region ${OCM_REGION} --node-association-status-token "${ASSOCIATE_TOKEN}" \
  --server-name ${OCM_SERVER} ${AWS_CLI_EXTRA_OPTS[@]:-} --query 'EngineAttributes[0].Value' --output text > ${PP_CERT_PATH}

  ${PUPPET} bootstrap verify
}

# order of execution of functions
prepare_os_packages
set_aws_settings
prepare_puppet
establish_trust
install_puppet
install_puppet_bootstrap
associate_node
run_puppet

touch /tmp/userdata.done
eval ${CFN_SIGNAL}
