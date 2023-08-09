#!/bin/bash
set -eu -o pipefail

KMS_KEY_ID="$1"
if [ -z $KMS_KEY_ID ]; then
    echo "KMS_KEY_ID is required"
    exit 1
fi

AWS_ZONE="$2"
if [ -z $AWS_ZONE ]; then
    echo "AWS_ZONE is required"
    exit 1
fi

INGRESS_NAME="$3"
if [ -z $INGRESS_NAME ]; then
    echo "INGRESS_NAME is required"
    exit 1
fi

cat > /tmp/ovpn.tmpl <<- EOM
client
nobind
dev tun
redirect-gateway def1
data-ciphers AES-256-GCM
<key>
{{ .Key }}</key>
<cert>
{{ .Cert }}</cert>
<ca>
{{ .Ca }}</ca>
<tls-crypt>
___TLSCRYPT_PLACEHOLDER___
</tls-crypt>
<connection>
remote ___FQDN_PLACEHOLDER___ 32767 tcp
</connection>
EOM

function encrypt() {
    PLAINTEXT="$1"
    OUTPUT="$2"
    aws kms encrypt --key-id $KMS_KEY_ID --region $AWS_ZONE --plaintext fileb://<(echo "$PLAINTEXT") --output text --query CiphertextBlob > $OUTPUT
}

pushd ovpn-tool
./build -s
OS_ARCH=$(./build --print-arch)
popd
PASSWORD="$(pwgen 20 -sy1)"
./ovpn-tool/bin/$OS_ARCH/ovpn-tool /tmp/ovpn.db init my-ca -E PASSWORD
./ovpn-tool/bin/$OS_ARCH/ovpn-tool /tmp/ovpn.db server k8s.gw -E PASSWORD
./ovpn-tool/bin/$OS_ARCH/ovpn-tool /tmp/ovpn.db client k8s.gw@client -E PASSWORD
CLIENT_CONFIG="$(./ovpn-tool/bin/$OS_ARCH/ovpn-tool /tmp/ovpn.db export k8s.gw@client -E PASSWORD -t /tmp/ovpn.tmpl)"
TLSCRYPT="$(./ovpn-tool/bin/$OS_ARCH/ovpn-tool /tmp/ovpn.db export k8s.gw -E PASSWORD | sed '0,/<tls-crypt>/d' | sed -n '/<\/tls-crypt>/q;p')"
CA="$(./ovpn-tool/bin/$OS_ARCH/ovpn-tool /tmp/ovpn.db export k8s.gw -E PASSWORD -jjson | jq '.Config.Cert' -r)"
SERVER_CERT="$(./ovpn-tool/bin/$OS_ARCH/ovpn-tool /tmp/ovpn.db export k8s.gw -E PASSWORD -jjson | jq '.Servers | .[0].Cert' -r)"
SERVER_KEY="$(./ovpn-tool/bin/$OS_ARCH/ovpn-tool /tmp/ovpn.db export k8s.gw -E PASSWORD -jjson | jq '.Servers | .[0].Key' -r)"
INGRESS_NS="$(kubectl get services --all-namespaces  -o jsonpath='{range .items[*]}{.metadata.namespace}' --field-selector metadata.name=$INGRESS_NAME)"
INGRESS_FQDN="$(kubectl get -n $INGRESS_NS $INGRESS_NAME -o jsonpath='{range .status.loadBalancer.ingress[*]}{.hostname}')"
mkdir -p ovpn_secrets
encrypt "$TLSCRYPT" "ovpn_secrets/tlscrypt.enc"
encrypt "$CA" "ovpn_secrets/ca.crt.enc"
encrypt "$SERVER_CERT" "ovpn_secrets/server.crt.enc"
encrypt "$SERVER_KEY" "ovpn_secrets/server.key.enc"
encrypt "$(openssl dhparam -2 4096)" "ovpn_secrets/dh_4096.enc"
encrypt "$(sed '/___TLSCRYPT_PLACEHOLDER___/r /dev/stdin' <(echo "$CLIENT_CONFIG" | sed "s@___FQDN_PLACEHOLDER___@$INGRESS_FQDN@g") <<< "$TLSCRYPT" | grep -v ___TLSCRYPT_PLACEHOLDER___)" "ovpn_secrets/client_config.enc"
rm /tmp/ovpn.tmpl
rm /tmp/ovpn.db
unset PASSWORD