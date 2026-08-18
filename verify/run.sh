#!/bin/bash
# Install the built spamassassin RPMs on AL2023, pair them with spamass-milter
# from SPAL, wire both into Postfix, and run the milter in the foreground.
#
#   verify/run.sh /path/to/rpms
#
# Run on AL2023 as root (a container is fine). Listens on 127.0.0.1:25.
# Runs until killed.
#
# This is here because a build that produces installable RPMs still says
# nothing about whether the package this repo builds (spamassassin) actually
# satisfies the package it's meant to pair with (spal-release's
# spamass-milter, which Requires: spamassassin by name) and whether the
# resulting Postfix -> milter -> spamd chain scores real mail correctly. That
# is what this checks, not just "did rpmbuild succeed".

set -eux -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
RPMS=${1:?usage: run.sh <directory of RPMs>}

wait_for_port() {
    local port=$1
    for i in $(seq 1 60); do
        (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { exec 3<&-; exec 3>&-; return 0; }
        [ "$i" = 60 ] && { echo "nothing listening on 127.0.0.1:$port"; return 1; }
        sleep 1
    done
}

dnf -y install procps-ng findutils python3
dnf -y install "$RPMS"/*.rpm

# spal-release, and from it spamass-milter -- the milter half of the pair,
# published unofficially by AWS itself. Its Requires: spamassassin (no
# version pin) is exactly what the RPMs just installed above are meant to
# satisfy; if this install step fails, that pairing is broken.
dnf -y install spal-release
dnf -y install spamass-milter postfix

# spamd ships no systemd User=, so it runs as root, same as the packaged
# unit. --razor-home-dir is in the shipped sysconfig regardless of whether
# Razor is installed (it isn't: perl-Razor-Agent has no AL2023 package,
# checked directly, so the build skips it same as it would on RHEL); the
# Razor2 plugin fails to load and disables itself, but only if the directory
# it's told about actually exists, so create it to keep that path quiet.
mkdir -p /var/lib/razor
set -a
. /etc/sysconfig/spamassassin
set +a
/usr/bin/spamd $SPAMDOPTIONS &
wait_for_port 783

# -r -1: reject at the SMTP level when SpamAssassin's own verdict is spam,
# instead of only tagging headers -- gives verify a clean pass/fail signal
# instead of having to set up local delivery and inspect a mailbox.
/usr/sbin/spamass-milter -p inet:8891@127.0.0.1 -r -1 &
wait_for_port 8891

postconf -e myhostname=verify.example.com
postconf -e mydomain=example.com
postconf -e "mydestination=\$myhostname, localhost.\$mydomain, localhost, example.net"
# Empty: accept any recipient at the domains above without checking against
# system accounts. The point here is the milter's SMTP-time verdict, not
# final local delivery.
postconf -e local_recipient_maps=
postconf -e inet_interfaces=loopback-only
postconf -e smtpd_milters=inet:127.0.0.1:8891
postconf -e milter_protocol=6
postconf -e milter_default_action=tempfail

postfix start-fg &
wait_for_port 25

echo "postfix, spamd and spamass-milter are all up"
wait
