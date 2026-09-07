#!/usr/bin/env python3
"""Check that every source the action fetches is reachable and shaped right.

Three consecutive releases were broken by one-line faults in the fetch
steps - a stale URL, a clone landing in a differently-named directory, a
raw file that was really an HTML page. Each cost a full ISO build, about
twenty-five minutes per edition, to discover.

None of them needed a build to catch. This parses the fetch steps out of
action.yml and checks, in seconds:

- every clone resolves, and lands in the directory the next line enters
- every fetched file exists and looks like what the step does with it
- no source has drifted back to an unreachable host

It reads action.yml rather than repeating its URLs, so a source added
without a corresponding check is still covered.
"""

import argparse
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

import yaml

# a clone, optionally with an explicit target directory
CLONE = re.compile(r"git clone[^\n]*?(https://\S+?\.git)[ \t]*([\w.-]*)")
# the pushd/cd that a clone is expected to be followed by
ENTER = re.compile(r"^\s*(?:pushd|cd)\s+([\w.-]+)", re.MULTILINE)
# a file fetched for its content rather than cloned
FETCH = re.compile(r"(?:curl -s|wget)\s+(https://\S+?)(?:\s|$|\))")

# what a fetched file must contain to be the thing the step thinks it is
EXPECTED = {
    "lsb-release": "DISTRIB_ID",
    "pacman-mirrors.conf": "/etc/pacman-mirrors.conf",
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def steps(action: Path) -> str:
    """Every run block in the action, concatenated."""
    doc = yaml.safe_load(action.read_text())
    return "\n".join(s.get("run", "") for s in doc["runs"]["steps"])


def check_clones(body: str, workdir: str) -> list[str]:
    """Each clone must resolve and land where the following line looks."""
    problems = []
    for match in CLONE.finditer(body):
        url, target = match.group(1), match.group(2)
        landed = target or url.rsplit("/", 1)[1].removesuffix(".git")

        after = ENTER.search(body[match.end() : match.end() + 300])
        expected = after.group(1) if after else None
        if expected and expected != landed:
            problems.append(
                f"{url} lands in {landed}/ but the next line enters {expected}/"
            )

        done = subprocess.run(
            ["git", "ls-remote", "--exit-code", url, "HEAD"],
            capture_output=True,
            timeout=120,
            check=False,
        )
        if done.returncode != 0:
            problems.append(f"{url} is not reachable")
            continue
        log(f"  clone {url.rsplit('/', 1)[1]:44} -> {landed}/")
    return problems


def fetch(url: str, attempts: int = 3) -> str | None:
    """Fetch a url, tolerating the transient failures mirrors actually serve.

    archlinux.org answers a run of requests with an intermittent 502, so a
    single attempt reports a source as gone when it is merely flaking. Only
    a url that fails every attempt is treated as a real problem.
    """
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=60) as resp:
                return resp.read().decode("utf-8", "replace")
        except (urllib.error.URLError, OSError) as e:
            log(f"  retry {url} ({e})" if attempt + 1 < attempts else f"  gave up on {url} ({e})")
            if attempt + 1 < attempts:
                time.sleep(2 * (attempt + 1))
    return None


def check_fetches(body: str) -> list[str]:
    """Each fetched file must exist and contain what the step relies on."""
    problems = []
    for match in FETCH.finditer(body):
        url = match.group(1)
        if "${" in url or "$(" in url:
            # interpolated at build time; nothing static to check
            continue
        payload = fetch(url)
        if payload is None:
            problems.append(f"{url} is not fetchable")
            continue

        name = url.rsplit("/", 1)[1]
        needle = EXPECTED.get(name)
        if needle and needle not in payload:
            # this is how a /-/tree/ url served html for a config file
            problems.append(f"{url} does not look like {name}: no {needle!r}")
            continue
        log(f"  fetch {name:44} -> {len(payload)} bytes")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", default="action.yml", type=Path)
    args = parser.parse_args()

    body = steps(args.action)
    with tempfile.TemporaryDirectory() as workdir:
        problems = check_clones(body, workdir) + check_fetches(body)

    if problems:
        log("")
        for problem in problems:
            log(f"  {problem}")
        log(f"\n{len(problems)} problem(s)")
        return 1

    log("\nevery source resolves and is shaped as the steps expect")
    return 0


if __name__ == "__main__":
    sys.exit(main())
