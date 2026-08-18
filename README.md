# SpamAssassin for Amazon Linux 2023

Amazon Linux 2023 ships neither `spamassassin` nor a way to run it as a Postfix milter. This repo rebuilds `spamassassin` for AL2023, `x86_64` and `aarch64`, by rebasing Fedora's current spec (there is no RHEL/EPEL9 vendor build of SpamAssassin to rebase instead, unlike some other packages) the way [dovecot.2.4.ALinux2023](https://github.com/YasharF/dovecot.2.4.ALinux2023) rebases Dovecot's own RHEL9 spec.

The milter half (`spamass-milter`) turns out not to be missing: AWS already publishes it through SPAL (Supplementary Packages for Amazon Linux), for both architectures. What SPAL can't provide on its own is the `spamassassin` package that `spamass-milter` requires by name -- AL2023's base repo and SPAL both lack it, and EPEL 9's own repo doesn't carry it either (checked directly, not inferred from its absence in SPAL). This repo's `spamassassin` build is what makes SPAL's `spamass-milter` installable at all. See "Why not rebuild spamass-milter too" below for how that was confirmed and what to do if it stops holding.

## Install

```sh
curl -fsSLo /etc/yum.repos.d/spamassassin-al2023.repo https://yasharf.github.io/spamassassin.ALinux2023/spamassassin-al2023.repo
dnf install spamassassin
dnf install spal-release
dnf install spamass-milter
```

The `spamassassin-al2023` packages are unsigned, so the repository sets `gpgcheck=0`.

New versions are likely to show up here within a day of a spec bump in Fedora's `spamassassin` dist-git, via the GitHub Action workflow in this repo. `dnf upgrade` picks them up when they do.

Every published build stays published. `dnf list --showduplicates spamassassin` shows what's available, and you can install a specific version by name, e.g. `dnf install spamassassin-4.0.2-3`.

## How it works

GitHub Actions handles the whole process, chained end-to-end:

- `watch.yml` checks daily for a spec version-release on Fedora's `rawhide` branch not yet published here.
- `build.yml` rebuilds it for AL2023, `x86_64` and `aarch64`.
- `verify.yml` installs the RPMs, pairs them with SPAL's `spamass-milter`, wires both into Postfix, and checks that real mail gets scored through the whole chain.
- `publish.yml` publishes the RPMs as the `dnf` repository above.

### Build

[`build/build.sh`](build/build.sh) is the whole build, and runs in a docker container:

```sh
docker run --rm -v "$PWD:/w" -w /w public.ecr.aws/amazonlinux/amazonlinux:2023 ./build/build.sh 4.0.2 3
```

RPMs land in `out/RPMS`.

There's no vendor SRPM to pull for SpamAssassin the way the dovecot repo pulls one from `dovecot.org`, or the way `spamass-milter` itself could be pulled from EPEL 9 -- SpamAssassin has no `epel9` branch in Fedora's dist-git at all (only `epel10`), and its own EPEL 9 packages don't exist either. So `build.sh` fetches Fedora's `spamassassin.spec`, its RH-specific patches, and every scriplet/unit/config file the spec installs directly from Fedora's `rawhide` dist-git branch, fetches the upstream tarballs the spec points at from `apache.org` (same as the spec's own `Source0`/`Source1`), and builds from that assembled tree. `rawhide` always carries only the current spec, the same situation as the dovecot repo's `ce-2.4-latest` channel -- there's no older release to pin against or replay, only "is what's there now already published".

### Verify

[`verify/run.sh`](verify/run.sh) installs the built RPMs, installs `spal-release` and its `spamass-milter`, wires spamd and the milter into Postfix, and starts everything in the foreground for `verify.yml` to test. `verify.yml` then sends a clean message and a [GTUBE](https://spamassassin.apache.org/gtube/) test message through the full Postfix -> milter -> spamd chain and checks that only the GTUBE one gets rejected, plus a direct `spamc` check against spamd alone so a milter-layer failure can be told apart from a spamd/rules failure.

### Changes to Fedora's spec

The SpamAssassin sources themselves are not touched. Three things needed changing to build Fedora's spec on AL2023:

- **`--define "rhel 9"`** -- the spec already special-cases RHEL-family builds to skip two optional dependencies it can't resolve there: `perl-Net-Patricia` and `perl-Razor-Agent`. Neither has an AL2023 package either (checked directly: not in the base repo, not in SPAL, not in EPEL 9), so `build.sh` passes `--define "rhel 9"` to both `dnf builddep` and `rpmbuild`, which is exactly what `mock`'s own `epel9` config does -- no spec edit needed, just telling the spec's existing conditional that this is an EPEL9-family build, which for this purpose it genuinely is.
- **Dropping `perl(Mail::DMARC)`** -- `perl-Mail-DMARC` has no AL2023 package anywhere (base, SPAL, or EPEL 9), so its hard `Requires`/`BuildRequires` is stripped from the spec before building. This leaves the optional DMARC authentication plugin absent; the SPF and DKIM plugins, and everything else, are unaffected. The check is conditional on the package still being unavailable, so this self-heals if AL2023 or SPAL ever ships it.
- **Dropping `%{gpgverify}`** -- this macro comes from `redhat-rpm-config`, which AL2023 doesn't carry at all, so it's undefined here and `%prep` would fail on the literal text. `build.sh` checks whether it's actually defined before stripping the two calls to it, so if a future AL2023 image does carry the macro, the signature checks run instead of being skipped.

### Why not rebuild spamass-milter too

SPAL's `spamass-milter-0.4.0` (currently `13.x.spal2023` for some `x`) is a straight rebuild of EPEL 9's own `spamass-milter` package, and carries an unversioned `Requires: spamassassin`. Since AL2023 has no `spamassassin` package anywhere else, that `Requires` currently can't be satisfied except by what this repo publishes -- confirmed by reading SPAL's own repo metadata directly for both architectures, not by assuming SPAL's release notes are exhaustive. Rebuilding `spamass-milter` here too would just duplicate a build AWS already maintains and re-publishes on its own schedule. If SPAL ever stops shipping `spamass-milter`, drops an architecture, or publishes a build incompatible with this repo's `spamassassin`, `verify.yml` is what will notice first (the "pairs them with SPAL's spamass-milter" step downloads and installs it fresh on every run) -- that's the signal to add `spamass-milter` to this repo's own build/verify/publish pipeline instead of depending on SPAL for it.

## License

[LICENSE](LICENSE) covers this repository's own content -- the build script, the verify harness, and the workflows -- under the MIT license, the same one large parts of SpamAssassin itself use. It does not cover SpamAssassin: no SpamAssassin source is vendored here, and the RPM this repo builds and publishes is SpamAssassin's own unmodified software (aside from the spec changes above), carrying its own `LICENSE`, `NOTICE`, `CREDITS` and `TRADEMARK` inside the package as built by its spec. Likewise, `spamass-milter` itself is not built or published by this repo at all; it comes straight from AWS's own SPAL repository, under whatever terms AWS publishes it.
