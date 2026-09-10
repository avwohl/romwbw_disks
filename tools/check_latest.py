#!/usr/bin/env python3
"""check_latest.py - the release marked Latest must carry the index.

Usage: tools/check_latest.py [--repo owner/name]

WHY THIS EXISTS. Every client compiles in exactly one URL and it is

    https://github.com/avwohl/romwbw_disks/releases/latest/download/index-v0.json

`releases/latest/download/` rather than a tag, so that this repository can move
the index - rename its release, reorganise, cut a new one - without a build of
the Windows, Android, iOS and Linux clients. What that buys in freedom it costs
in a single point of failure: "Latest" is one flag on the whole repository, and
`gh release create` claims it by DEFAULT. So publishing any release without
`--latest=false` silently repoints every client in the world at a release that
has no index on it, and the only symptom is that every client stops finding the
catalog.

THIS IS NOT HYPOTHETICAL. On 2026-09-10 the `help-v0` release was cut with a
plain `gh release create`, took the flag from `catalog-v0`, and
`latest/download/index-v0.json` answered 404 until the flag was put back. It was
caught by hand, before any client depended on it. This script is so that the
next one is caught by a machine.

WHAT IT CHECKS, in order of how much it would hurt:

  1. Some release is marked Latest at all.
  2. That release carries an asset named index-<iface>.json.
  3. Fetching releases/latest/download/index-<iface>.json really does return
     that document, and it parses as the index. Steps 1 and 2 ask GitHub's API
     what it believes; this asks the URL a client will actually use, which is
     the only one that matters and is served through a different path.

Exit 0 if all three hold, 1 otherwise, with the remedy printed. Needs `gh` for
the first two and nothing but the standard library for the third.
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.request

IFACE = "v0"
DEFAULT_REPO = "avwohl/romwbw_disks"
INDEX_ASSET = "index-%s.json" % IFACE


def gh_json(args):
    try:
        out = subprocess.check_output(["gh"] + args, stderr=subprocess.PIPE)
    except FileNotFoundError:
        print("check_latest: gh is not on PATH; install https://cli.github.com", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        print("check_latest: gh failed: %s" % e.stderr.decode(errors="replace").strip(),
              file=sys.stderr)
        sys.exit(1)
    return json.loads(out.decode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.environ.get("ROMWBW_DISKS_REPO", DEFAULT_REPO))
    args = ap.parse_args()
    repo = args.repo

    releases = gh_json(["release", "list", "--repo", repo, "--limit", "50",
                        "--json", "tagName,isLatest"])
    latest = [r for r in releases if r.get("isLatest")]

    if not latest:
        print("FAIL: no release in %s is marked Latest.\n"
              "  Every client fetches releases/latest/download/%s, so there is\n"
              "  nothing for them to fetch.\n"
              "  Fix: gh release edit catalog-%s --repo %s --latest"
              % (repo, INDEX_ASSET, IFACE, repo))
        return 1
    if len(latest) > 1:                     # GitHub allows one; belt and braces
        print("FAIL: more than one release claims Latest: %s"
              % ", ".join(r["tagName"] for r in latest))
        return 1

    tag = latest[0]["tagName"]
    assets = gh_json(["release", "view", tag, "--repo", repo, "--json", "assets"])
    names = [a["name"] for a in assets.get("assets", [])]

    if INDEX_ASSET not in names:
        print("FAIL: the Latest release is %s and it does not carry %s.\n"
              "  Every client fetches releases/latest/download/%s and will get a 404.\n"
              "  This is what a `gh release create` without --latest=false does.\n"
              "  Fix: gh release edit catalog-%s --repo %s --latest\n"
              "  Assets on %s: %s"
              % (tag, INDEX_ASSET, INDEX_ASSET, IFACE, repo, tag,
                 ", ".join(names) or "(none)"))
        return 1

    # The one that matters: what a client actually gets.
    url = "https://github.com/%s/releases/latest/download/%s" % (repo, INDEX_ASSET)
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            body = r.read()
    except Exception as e:                  # noqa: BLE001 - any failure is a failure
        print("FAIL: %s did not fetch: %s" % (url, e))
        return 1

    try:
        doc = json.loads(body)
    except ValueError as e:
        print("FAIL: %s returned %d bytes that are not JSON: %s" % (url, len(body), e))
        return 1

    if doc.get("schema") != "romwbw-disks-index":
        print("FAIL: %s returned a document whose schema is %r, not the index."
              % (url, doc.get("schema")))
        return 1

    versions = [v.get("romwbw_version") for v in doc.get("romwbw_versions", [])]
    print("ok    Latest is %s and carries %s" % (tag, INDEX_ASSET))
    print("ok    %s serves the index (%d bytes, RomWBW %s)"
          % (url, len(body), ", ".join(v for v in versions if v) or "none"))
    if "help" in doc:
        print("ok    and a help block with %d topic(s)"
              % len(doc["help"].get("topics", [])))
    print("\nPASS: the entry point every client compiles in resolves.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
