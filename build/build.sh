#!/bin/bash
# Rebuild SpamAssassin for Amazon Linux 2023, rebasing Fedora's current spec.
#
#   build/build.sh 4.0.2 3
#
# Run on AL2023 as root (a container is fine). RPMs land in ./out/RPMS.

set -eux -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
V=${1:?usage: build.sh <spamassassin-version> <fedora-spec-release>}
R=${2:?usage: build.sh <spamassassin-version> <fedora-spec-release>}
# rawhide is Fedora's actively-developed branch, and the only one that ever
# carries spamassassin: the package has no epel9 branch in Fedora dist-git
# (checked directly), and EPEL 9's own repo carries no spamassassin package
# either (also checked directly, not inferred from SPAL). rawhide always
# holds whatever is currently newest, so, as with dovecot's ce-2.4-latest
# channel, "new" means "not in the published repo yet" -- there is no older
# release to pin against or replay.
BRANCH=${SPAMASSASSIN_SPEC_BRANCH:-rawhide}
DISTGIT=https://src.fedoraproject.org/rpms/spamassassin/raw/$BRANCH/f
APACHE=https://www.apache.org/dist/spamassassin/source
DEST=$PWD/out/RPMS
WORK=${SPAMASSASSIN_BUILD_WORK:-/var/tmp/spamassassin-build}
TOP=$WORK/rpmbuild

dnf -y install rpm-build 'dnf-command(builddep)' \
    findutils tar bzip2 gzip gcc make patch util-linux
# AL2023 ships gnupg2-minimal by default, which conflicts with the full
# gnupg2 package -- but %{gpgverify} (the macro %prep uses to check the
# upstream tarball signatures) needs gpgv2, which gnupg2-minimal doesn't
# have. --allowerasing swaps it in for this build container only; it has no
# effect on the built RPM's own Requires: gnupg2, which gnupg2-minimal
# already satisfies on any host that installs it.
dnf -y install --allowerasing gnupg2

# dnf needs root; rpmbuild must not have it.
id builder >/dev/null 2>&1 || useradd -m builder
build() { runuser -u builder -- "$@"; }

rm -rf "$WORK"
mkdir -p "$TOP"/SOURCES "$TOP"/SPECS "$TOP"/BUILD "$TOP"/RPMS "$TOP"/SRPMS "$TOP"/BUILDROOT

# Fedora's dist-git carries the spec itself, its RH-specific patches, and every
# scriptlet/unit/config file the spec installs, but not the upstream tarballs
# -- those come straight from Apache, same as the spec's own Source0/Source1.
for f in spamassassin.spec KEYS README.RHEL.Fedora redhat_local.cf \
         sa-update.cronscript sa-update.crontab sa-update.force-sysconfig \
         sa-update.logrotate sa-update.service sa-update.timer \
         spamassassin-4.0.0-add-logfile-homedir-options.patch \
         spamassassin-4.0.0-gnupg2.patch \
         spamassassin-4.0.1-remove_dep_to_digest_sha1.patch \
         spamassassin-default.rc spamassassin-official.conf \
         spamassassin-spamc.rc spamassassin.service spamassassin.sysconfig \
         spamassassin-helper.sh; do
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
        -o "$TOP/SOURCES/$f" "$DISTGIT/$f"
done
mv "$TOP/SOURCES/spamassassin.spec" "$TOP/SPECS/spamassassin.spec"

specver=$(sed -n 's/^Version:[[:space:]]*//p' "$TOP/SPECS/spamassassin.spec")
specrel=$(sed -n 's/^Release:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$TOP/SPECS/spamassassin.spec")
if [ "$specver-$specrel" != "$V-$R" ]; then
    echo "requested $V-$R but $BRANCH's spec is now $specver-$specrel; rerun watch"
    exit 1
fi

curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
    -o "$TOP/SOURCES/Mail-SpamAssassin-$V.tar.bz2" \
    "$APACHE/Mail-SpamAssassin-$V.tar.bz2"
rulesrev=$(sed -n '/^Source1:/s/.*\.\(r[0-9]\{1,\}\)\.tgz.*/\1/p' "$TOP/SPECS/spamassassin.spec")
curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
    -o "$TOP/SOURCES/Mail-SpamAssassin-rules-$V.$rulesrev.tgz" \
    "$APACHE/Mail-SpamAssassin-rules-$V.$rulesrev.tgz"
for sig in "Mail-SpamAssassin-$V.tar.bz2.asc" "Mail-SpamAssassin-rules-$V.$rulesrev.tgz.asc"; do
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$TOP/SOURCES/$sig" "$APACHE/$sig"
done

# perl(Mail::DMARC) has no package anywhere on AL2023 -- not in the base repo,
# not in SPAL, not in EPEL 9 (checked directly). The DMARC plugin is one of
# several optional authentication plugins (alongside SPF and DKIM, both of
# which stay); dropping its hard Requires/BuildRequires leaves it absent
# rather than failing the whole build. Conditional so this self-heals if
# AL2023 ever adds the package.
if ! dnf -y repoquery --available 'perl(Mail::DMARC)' 2>/dev/null | grep -q .; then
    sed -i '/Mail::DMARC/d' "$TOP/SPECS/spamassassin.spec"
fi

chown -R builder "$WORK"

dnf -y builddep "$TOP/SPECS/spamassassin.spec" --define "rhel 9"

# --define "rhel 9": makes the spec treat this like an EPEL9/RHEL9 build
# (which is genuinely what AL2023 is closest to here), the same as mock's own
# epel9 config would. That's what the spec itself uses to skip the two
# Fedora-only optional deps it cannot resolve on AL2023 either:
# perl-Net-Patricia and perl-Razor-Agent, neither of which are packaged here
# (checked directly; not in the base repo, SPAL, or EPEL 9).
build rpmbuild -ba --define "_topdir $TOP" --define "rhel 9" \
    "$TOP/SPECS/spamassassin.spec"

mkdir -p "$DEST"
find "$TOP/RPMS" -name '*.rpm' -exec mv -t "$DEST" {} +
ls -1 "$DEST"
