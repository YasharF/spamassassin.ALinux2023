# SpamAssassin for Amazon Linux 2023

## Objective
Amazon Linux 2023 does not package SpamAssassin or its milter companion `spamass-milter` — not in its own base repositories, and not in SPAL (Supplementary Packages for Amazon Linux, AL2023's EPEL9-derived extra repo). This repo rebuilds both for AL2023, `x86_64` and `aarch64`.

## Reference pattern
Follow the structure of [dovecot.2.4.ALinux2023](https://github.com/YasharF/dovecot.2.4.ALinux2023), an existing repo doing the same thing for a different package:
- `README.md` — why the repo exists, install instructions, how the automation works, and a section documenting exactly what had to change from the upstream spec to build cleanly on AL2023 and why.
- `build/` — a `build.sh` that runs inside an `amazonlinux:2023` container (e.g. `docker run --rm -v "$PWD:/w" -w /w public.ecr.aws/amazonlinux/amazonlinux:2023 ./build/build.sh <version> <release>`) and produces RPMs under `out/RPMS`. Any spec patches or stub packages needed live alongside it.
- `verify/` — installs the built RPMs on a clean AL2023 host/container and runs functional checks against the running service, not just an install-succeeded check.
- GitHub Actions, chained end-to-end: a job that watches for a new upstream release not yet published here, a job that rebuilds it for both architectures, a job that runs the verify harness against the build output, and a job that publishes the RPMs as a `dnf` repository (e.g. via GitHub Pages).
- Every published build stays published — `dnf list --showduplicates` should show the full history, with any specific version installable by name.
- License: MIT (or whatever the maintainer prefers) covering only this repo's own content — build scripts, spec patches, verify harness, workflows. It does not cover SpamAssassin or spamass-milter themselves: no upstream source is vendored, and the RPMs this repo builds and publishes are that project's own unmodified software (aside from whatever AL2023-specific spec changes prove necessary), carrying its own license inside each package as built by its spec.

## Source material
Unlike some packages, SpamAssassin has no equivalent official vendor-published RPM repository for RHEL/EL9-family distros. Before assuming a rebuild path, check, in order:
- Whether Fedora's current `spamassassin` package spec (Fedora is the usual upstream source for what eventually reaches EPEL) can be rebased for AL2023, the way the dovecot repo rebased Dovecot's own RHEL 9 spec.
- Whether EPEL 9 itself actually carries `spamassassin` and `spamass-milter` directly. SPAL describes itself as rebuilding "approximately 7,823 packages derived from EPEL 9," which is not the entirety of EPEL 9, so a package's absence from SPAL doesn't confirm its absence from EPEL 9 itself — check EPEL 9's own package list directly rather than inferring from SPAL alone.
- Failing both, building from the Apache SpamAssassin source tarball directly is the fallback — it's fundamentally a set of Perl modules (`Mail::SpamAssassin`), installable via CPAN — but that means writing a spec largely from scratch rather than adapting an existing one, a materially bigger lift than rebasing an existing spec. `spamass-milter` is a separate upstream project with its own source and its own build, independent of whichever path `spamassassin` itself ends up taking.

## What to expect
No attempt has been made yet to actually build either package on AL2023 — this is a starting brief, not a known-working recipe. Expect to find and document real AL2023-specific incompatibilities during the build, the way the dovecot repo did (see its README's "Changes to RHEL Spec" section for the kind of thing that turns up: a `BuildRequires` on a `-devel` package AL2023 ships under a different name, an optional dependency AL2023's version of some library can't support, and so on). Document whatever's actually found and why it was necessary — don't guess at likely issues ahead of time. Since `spamassassin` and `spamass-milter` are two separate source projects, treat their build issues as independent — one having a clean path doesn't imply the other will.

## Architecture
Both `x86_64` and `aarch64`.

## Two packages, not one
A milter-based Postfix integration needs both `spamassassin` (the `spamd` daemon and rule engine) and `spamass-milter` (the milter-protocol glue in front of it) — SpamAssassin has no native milter mode of its own. Scope both into this repo's build/verify/publish pipeline, not just the first one.
