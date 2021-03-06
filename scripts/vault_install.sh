#!/bin/sh
# Configures the Vault server for a database secrets demo

echo "Preparing to install Vault..."
echo 'libc6 libraries/restart-without-asking boolean true' | sudo debconf-set-selections
export DEBIAN_FRONTEND=noninteractive
sudo apt-get -y update > /dev/null 2>&1
sudo apt-get -y upgrade > /dev/null 2>&1
sudo apt-get install -y unzip jq cowsay mysql-client > /dev/null 2>&1
sudo apt-get install -y python3 python3-pip
pip3 install awscli Flask mysql-connector-python hvac

mkdir /etc/vault.d
mkdir -p /opt/vault
mkdir -p /root/.aws
mkdir -p /var/run/vault

sudo bash -c "cat >/root/.aws/config" <<EOT
[default]
aws_access_key_id=${AWS_ACCESS_KEY}
aws_secret_access_key=${AWS_SECRET_KEY}
EOT
sudo bash -c "cat >/root/.aws/credentials" <<EOT
[default]
aws_access_key_id=${AWS_ACCESS_KEY}
aws_secret_access_key=${AWS_SECRET_KEY}
EOT

echo "Installing Vault..."
curl -sfLo "vault.zip" "${VAULT_URL}"
sudo unzip vault.zip -d /usr/local/bin/

# Server configuration
sudo bash -c "cat >/etc/vault.d/vault.hcl" <<EOT
storage "file" {
  path = "/opt/vault"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

ui = true
EOT

# Set Vault up as a systemd service
echo "Installing systemd service for Vault..."
sudo bash -c "cat >/etc/systemd/system/vault.service" <<EOT
[Unit]
Description=Hashicorp Vault
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
Restart=on-failure # or always, on-abort, etc

[Install]
WantedBy=multi-user.target
EOT

sudo systemctl start vault
sudo systemctl enable vault

sleep 5

export VAULT_IP=`curl -s http://169.254.169.254/latest/meta-data/public-ipv4`
export VAULT_ADDR=http://localhost:8200
vault operator init -recovery-shares=1 -recovery-threshold=1 > /root/init.txt 2>&1
export VAULT_TOKEN=`cat /root/init.txt | sed -n -e '/^Initial Root Token/ s/.*\: *//p'`
export DB_HOST=`echo '${MYSQL_HOST}' | awk -F ":" '/1/ {print $1}'`

export AWS_ACCESS_KEY=${AWS_ACCESS_KEY}
export AWS_SECRET_KEY=${AWS_SECRET_KEY}
export AMI_ID=${AMI_ID}
export AWS_REGION=${AWS_REGION}
export MYSQL_HOST=${MYSQL_HOST}
export MYSQL_USER=${MYSQL_USER}
export MYSQL_PASS=${MYSQL_PASS}
export AWS_KMS_KEY_ID=${AWS_KMS_KEY_ID}
export VAULT_URL=${VAULT_URL}
export VAULT_LICENSE=${VAULT_LICENSE}
export CTPL_URL=${CTPL_URL}

sleep 5

# Setup demos
UNSEAL_KEY_1=`cat /root/init.txt | sed -n -e '/^Unseal Key 1/ s/.*\: *//p'`
UNSEAL_KEY_2=`cat /root/init.txt | sed -n -e '/^Unseal Key 2/ s/.*\: *//p'`
UNSEAL_KEY_3=`cat /root/init.txt | sed -n -e '/^Unseal Key 3/ s/.*\: *//p'`
mkdir /root/unseal
mkdir /root/database
mkdir /root/ec2auth
mkdir /root/eaas
mkdir /root/pki

cd /root
git clone --single-branch --branch ${GIT_BRANCH} https://github.com/kevincloud/vault-aws-demo.git

. /root/vault-aws-demo/scripts/01_unseal.sh
. /root/vault-aws-demo/scripts/02_database.sh
. /root/vault-aws-demo/scripts/03_ec2auth.sh
. /root/vault-aws-demo/scripts/04_eaas.sh
. /root/vault-aws-demo/scripts/05_pki.sh

# echo "Setting up environment variables..."
echo "export VAULT_ADDR=http://localhost:8200" >> /home/ubuntu/.profile
echo "export VAULT_TOKEN=$VAULT_TOKEN" >> /home/ubuntu/.profile
echo "export VAULT_ADDR=http://localhost:8200" >> /root/.profile
echo "export VAULT_TOKEN=$VAULT_TOKEN" >> /root/.profile

vault operator unseal $UNSEAL_KEY_1
vault operator unseal $UNSEAL_KEY_2
vault operator unseal $UNSEAL_KEY_3
vault login $VAULT_TOKEN
vault secrets enable -path="secret" -version=2 kv
vault audit enable file file_path=/var/log/vault_audit.log

# Add our AWS secrets
curl \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST \
    --data '{"data": { "aws_access_key": "${AWS_ACCESS_KEY}", "aws_secret_key": "${AWS_SECRET_KEY}" } }' \
    http://127.0.0.1:8200/v1/secret/data/aws

curl \
    --header "X-Vault-Token: $VAULT_TOKEN" \
    --request POST \
    --data '{"data": { "username": "vault_user", "password": "Super$ecret1" } }' \
    http://127.0.0.1:8200/v1/secret/data/creds

echo "Vault installation complete."
