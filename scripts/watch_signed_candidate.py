"""Follow a public signed candidate from inside a local t snapshot runner."""
import argparse
import json
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import urlopen


def watch(run_id, expected_sha):
    url = f"https://api.github.com/repos/agenthangar/nightr/actions/runs/{run_id}"
    last_status = None
    # The release job has a 90-minute deadline. Queue time is additional.
    deadline = time.monotonic() + 100 * 60
    while time.monotonic() < deadline:
        try:
            with urlopen(url, timeout=15) as response:
                run = json.load(response)
        except HTTPError as error:
            if error.code < 500:
                raise
        except (URLError, TimeoutError) as error:
            print(f"GitHub status temporarily unavailable: {error}", flush=True)
        else:
            if (run["id"], run["head_sha"], run["head_branch"], run["path"], run["event"]) != (
                run_id, expected_sha, "main", ".github/workflows/release.yml", "workflow_dispatch"
            ):
                raise SystemExit("Run does not match the expected signed candidate and merge commit.")
            if run["status"] != last_status:
                print(f'{run["html_url"]} {run["head_sha"]} {run["status"]}', flush=True)
                last_status = run["status"]
            if last_status == "completed":
                print(run["conclusion"], flush=True)
                return 0 if run["conclusion"] == "success" else 1
        time.sleep(60)
    raise SystemExit("Candidate still unverified at the observation deadline.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_id", type=int)
    parser.add_argument("merge_sha")
    args = parser.parse_args()
    sys.exit(watch(args.run_id, args.merge_sha))
