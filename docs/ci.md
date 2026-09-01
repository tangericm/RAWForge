# What runs automatically, and what does not

Settled in [#20](https://github.com/tangericm/RAWForge/issues/20).

## Where it runs, and why not on GitHub's runners

CI runs on a **self-hosted macOS runner** — the development Mac.

This repository is private. GitHub bills macOS runners at **10×** against
included minutes, so a Free account's 2,000 minutes are 200 macOS minutes. A
realistic hosted run — checkout, install `xcodegen`, boot a simulator, build,
test, build Release — is four to six minutes, or **40–60 billed minutes**. That
is three to five runs a month. Rationed CI is CI nobody trusts.

The same work takes **14 seconds** locally. The cost is GitHub's runner
overhead, not this codebase.

> **If this repository goes public**, change `runs-on: [self-hosted, macOS]` to
> `macos-15` and nothing else. Public repositories get standard runners free.
> The workflow deliberately avoids anything machine-specific so that this stays
> a one-line change.

## The three tiers

| | runs | blocks | where |
|---|---|---|---|
| **Simulator suite** | every push and PR | yes | `.github/workflows/ci.yml` |
| **Release build + developer-code check** | every push and PR | yes | `app/tools/release-check.sh` |
| **Hardware suite** | manually, phone tethered | at release only | `app/tools/run-hardware-suite.sh` |

### Simulator suite

148 tests. 13 of them skip — those are the device-only ones, and **a skip reads
as green**, which is the entire reason the hardware gate below exists.

### Release build and the developer-code check

Release differs from Debug in whole-module optimisation and had never been built
at all until late in this project. The check also proves the developer-only
screens are absent, because gating a `NavigationLink` is not the same as gating
the view behind it — that exact mistake shipped once, and `strings` caught it
where the diff did not. App Store guideline 2.3.1(a) forbids shipping hidden
features, so this is a review exposure, not tidiness.

**Every token carries a positive control.** The first version of this check
reported six passes, two of which could never have failed: Swift stores short
string literals inline in the `String` struct rather than in `__TEXT`, so
`strings` cannot see `RAWFORGE_DEMO` or `focus-point` at any optimisation level.
A check that cannot fail is worse than none — it reports safety it has not
established. So a token must be **found in the Debug binary** before its absence
from Release means anything, and a token that cannot be seen in Debug fails the
run as a broken check (`BLIND`) rather than passing as a clean result.

## The hardware gate

13 tests need a real sensor. The rule:

> **A commit is "hardware verified" if the device suite passed on it, or on an
> ancestor of it with no changes under `app/` since.**

Recorded in [`hardware-verification.json`](hardware-verification.json), which
names a commit, a device, an OS version, and how many tests actually executed.
Written only by `run-hardware-suite.sh`, never by hand — a hand-edited entry is
a claim nobody made.

Deliberately **not** strict SHA equality. Verification is a claim about a
binary, so it survives a commit that cannot change one (a doc edit, an ADR, a
workflow tweak) and is invalidated by anything under `app/`. A gate that fired
on every README edit would be bypassed within a week.

**CI reports it; only the release preflight enforces it.** `main` is
legitimately unverified for most of a development cycle, and a check that is red
by design gets ignored — losing the signal exactly when it starts to matter.

```bash
bash app/tools/require-hardware-verification.sh          # blocking
bash app/tools/require-hardware-verification.sh --warn   # what CI runs
```

### Running it

```bash
bash app/tools/run-hardware-suite.sh
```

Refuses on a dirty tree (the ledger names a commit, and a commit does not
describe uncommitted edits) and refuses when no phone is found (no phone is not
a pass). Signing is resolved from the installed Apple Development certificate,
or from `DEVELOPMENT_TEAM` if set.

**One manual step per device, unavoidable:** camera permission needs a physical
tap the first time the app is installed. It survives reinstalls, so a phone that
has run the app before can be driven automatically.

## Before an archive

```bash
bash app/tools/preflight-release.sh
```

Clean tree → simulator suite → Release build and developer-code check → hardware
gate. It does not archive for you: signing an upload is a decision with an audit
trail, and a script doing it as a side effect of a check would be doing
something nobody asked for.

## Current status

**Nothing has ever been hardware verified.** #17 and #18 are both merged to
`main` with device runs outstanding, and until this ticket nothing in the
repository recorded that. `preflight-release.sh` refuses today, correctly.

## Setting up the runner

Not done by an agent — registering a runner needs a repository token and a
machine decision.

1. **Settings → Actions → Runners → New self-hosted runner**, macOS/arm64.
2. Label it `self-hosted, macOS`. Add `device` as a third label if the phone
   lives with this machine; the `hardware` job requires it.
3. Run it as a launchd service (`./svc.sh install && ./svc.sh start`) so it
   survives a reboot.
4. Prerequisites on the machine: Xcode with an iOS 17+ simulator, `xcodegen`,
   `python3`, and a signing identity.

The runner executes workflow code with the rights of the account it runs as.
That is acceptable here because the repository is private and has no forks — it
would **not** be acceptable on a public repository accepting pull requests,
which is a second reason the public switch means moving to hosted runners rather
than opening this one up.
