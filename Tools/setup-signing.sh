#!/bin/bash
# 一次性配置本地代码签名证书，让辅助功能授权不随重建失效。
# 需要管理员密码（把自签名证书加入系统信任）。
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_ID="Yaosnap Local Signing"
DIR=".env-tools/signing"
CERT="$DIR/cert.pem"
P12="$DIR/cert.p12"
PASS="yaosnap"

if [ ! -f "$CERT" ]; then
    mkdir -p "$DIR"
    cat > "$DIR/openssl.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = Yaosnap Local Signing
[ v3 ]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -keyout "$DIR/key.pem" -out "$CERT" \
        -days 3650 -nodes -config "$DIR/openssl.cnf" 2>/dev/null
    openssl pkcs12 -export -legacy -out "$P12" -inkey "$DIR/key.pem" -in "$CERT" \
        -passout "pass:$PASS" 2>/dev/null
    echo "已生成证书：$CERT"
fi

if ! security find-certificate -c "$SIGN_ID" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    [ -f "$P12" ] || openssl pkcs12 -export -legacy -out "$P12" -inkey "$DIR/key.pem" \
        -in "$CERT" -passout "pass:$PASS" 2>/dev/null
    security import "$P12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
    echo "已导入证书到登录钥匙串"
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "签名证书已可用：$SIGN_ID"
    exit 0
fi

echo "需要把证书设为受信任（会要求管理员密码）…"
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CERT"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "完成。之后 ./build.sh 会自动使用该证书签名。"
else
    echo "仍未生效。可打开「钥匙串访问」，找到 $SIGN_ID，双击把它设为「始终信任」。"
    exit 1
fi
