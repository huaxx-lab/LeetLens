#!/usr/bin/env bash
set -euo pipefail

JDT_VERSION="1.60.0"
JDT_ARCHIVE="jdt-language-server-1.60.0-202606262232.tar.gz"
JDT_URL="https://download.eclipse.org/jdtls/milestones/${JDT_VERSION}/${JDT_ARCHIVE}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends openjdk-21-jre-headless ca-certificates curl

if ! id -u leetcode-lsp >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/leetcode-lsp --create-home --shell /usr/sbin/nologin leetcode-lsp
fi

install -d -m 0755 /opt/leetcode-lsp
install -d -o leetcode-lsp -g leetcode-lsp -m 0750 /var/lib/leetcode-lsp

if [ ! -f "/opt/leetcode-lsp/jdtls/plugins/org.eclipse.equinox.launcher_1.7.0.v20250519-0528.jar" ] && ! compgen -G '/opt/leetcode-lsp/jdtls/plugins/org.eclipse.equinox.launcher_*.jar' >/dev/null; then
  temporary_archive="$(mktemp /tmp/jdtls.XXXXXX.tar.gz)"
  trap 'rm -f "$temporary_archive"' EXIT
  if [ -f jdtls.tar.gz ]; then
    cp jdtls.tar.gz "$temporary_archive"
  else
    curl --fail --location --retry 3 --output "$temporary_archive" "$JDT_URL"
  fi
  rm -rf /opt/leetcode-lsp/jdtls
  install -d -m 0755 /opt/leetcode-lsp/jdtls
  tar -xzf "$temporary_archive" -C /opt/leetcode-lsp/jdtls
fi

install -m 0755 gateway.py /opt/leetcode-lsp/gateway.py
install -m 0644 leetcode-lsp.service /etc/systemd/system/leetcode-lsp.service
chown -R root:root /opt/leetcode-lsp
chown -R leetcode-lsp:leetcode-lsp /var/lib/leetcode-lsp

systemctl daemon-reload
systemctl enable --now leetcode-lsp.service
systemctl --no-pager --full status leetcode-lsp.service
