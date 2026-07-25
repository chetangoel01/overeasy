"""Real end-to-end imports: API -> queue -> worker -> acquisition -> extraction.

Six live URLs, three per platform. Nothing here is mocked.
"""

import json
import sys
import time
import uuid

import httpx

API = "http://api.ladle.localhost"
POLL_SECONDS = 5
TIMEOUT_SECONDS = 900

TARGETS = [
    ("tiktok", "https://www.tiktok.com/@mishkamakesfood/video/7628226554589482271"),
    ("tiktok", "https://www.tiktok.com/@shicocooks/video/7619000339425119510"),
    ("tiktok", "https://www.tiktok.com/@mishkamakesfood/video/7655788084671401247"),
    ("instagram", "https://www.instagram.com/reel/Ct-OnLxJlxw/"),
    ("instagram", "https://www.instagram.com/reel/C6IsG9BI3WZ/"),
    ("instagram", "https://www.instagram.com/reel/Cx8pqZDv7G0/"),
]

http = httpx.Client(timeout=60)

tokens = http.post(
    f"{API}/v1/auth/guest",
    json={"installationID": f"e2e-{uuid.uuid4()}"},
)
tokens.raise_for_status()
access = tokens.json()["accessToken"]
auth = {"Authorization": f"Bearer {access}"}
print("guest session established\n")

jobs: list[tuple[str, str, str]] = []
for platform, url in TARGETS:
    job_id = str(uuid.uuid4())
    response = http.post(
        f"{API}/v1/imports",
        headers=auth,
        json={"jobID": job_id, "sourceURL": url, "allowDuplicate": True},
    )
    if response.status_code not in (200, 202):
        print(
            f"SUBMIT FAILED {platform} {url}: "
            f"{response.status_code} {response.text[:300]}"
        )
        continue
    jobs.append((platform, url, job_id))
    print(f"submitted {platform:9} {url.rsplit('/', 2)[-2][:24]:24} job={job_id[:8]}")

print(f"\nwaiting for {len(jobs)} jobs...\n")
deadline = time.time() + TIMEOUT_SECONDS
results: dict[str, dict] = {}
while time.time() < deadline and len(results) < len(jobs):
    for platform, url, job_id in jobs:
        if job_id in results:
            continue
        response = http.get(f"{API}/v1/imports/{job_id}", headers=auth)
        if response.status_code != 200:
            continue
        body = response.json()
        state = body.get("status") or body.get("state")
        if state in ("succeeded", "failed", "needsReview", "duplicate", "completed"):
            results[job_id] = body
            print(f"  {state:12} {platform:9} {url.rsplit('/', 2)[-2][:24]}")
    if len(results) < len(jobs):
        time.sleep(POLL_SECONDS)

print()
for platform, url, job_id in jobs:
    body = results.get(job_id)
    print("=" * 78)
    print(f"{platform.upper()}  {url}")
    if body is None:
        print("  TIMED OUT — still pending")
        continue
    print(f"  status: {body.get('status') or body.get('state')}")
    if body.get("failureReason") or body.get("error"):
        print(f"  failure: {body.get('failureReason') or body.get('error')}")
    print(json.dumps({k: v for k, v in body.items() if k != "recipe"}, indent=2)[:900])
    recipe = body.get("recipe")
    if recipe:
        print(f"  --- RECIPE: {recipe.get('title')}")
        print(
            f"      servings={recipe.get('servings')} "
            f"basis={recipe.get('servingsBasis')} "
            f"totalMinutes={recipe.get('totalMinutes')}"
        )
        print(
            f"      methodProvenance={recipe.get('methodProvenance')} "
            f"review={recipe.get('reviewStatus')}"
        )
        for ing in (recipe.get("ingredients") or [])[:12]:
            print(
                f"      - {ing.get('quantityText') or ''} {ing.get('name')}"
                f"  [{ing.get('metricAmount')}{ing.get('metricUnit') or ''}]"
            )
        for step in (recipe.get("steps") or [])[:8]:
            print(
                f"      {step.get('orderIndex')}. "
                f"{str(step.get('instruction'))[:110]}"
                f"  ({step.get('sourceStartSeconds')}s)"
            )
        for note in (recipe.get("notes") or [])[:4]:
            print(f"      note: {str(note)[:110]}")

print("\n" + "=" * 78)
print(f"completed {len(results)}/{len(jobs)}")
sys.exit(0 if len(results) == len(jobs) else 1)
