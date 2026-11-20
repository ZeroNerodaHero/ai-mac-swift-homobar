#!/opt/homebrew/bin/python3
# <xbar.title>Slop Jobs</xbar.title>
# <xbar.desc>Cursor cloud agents + open PRs on slop-stream-architecture</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
"""SwiftBar plugin: shows running Cursor cloud agents and open PRs.

API key is read from macOS Keychain (service "cursor-api-key") or
~/.config/job-menubar/key (chmod 600). It is never printed.
Set JOBBAR_FIXTURE=/path/to/dir to run against sample JSON (testing).
"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

REPO = "ZeroNerodaHero/slop-stream-architecture"
API = "https://api.cursor.com/v1"
GH = "/opt/homebrew/bin/gh"
RECENT_HOURS = 6        # also show agents that ended within this window
MAX_RECENT = 8
STATE = os.path.expanduser("~/.config/job-menubar/state.json")
FIXTURE = os.environ.get("JOBBAR_FIXTURE")
ACTIVE_RUN = {"CREATING", "RUNNING", "WAITING_FOR_BACKGROUND_WORK"}
ICON = {"CREATING": "🟡", "RUNNING": "🟢", "WAITING_FOR_BACKGROUND_WORK": "🟡",
        "FINISHED": "✅", "ERROR": "❌", "CANCELLED": "⚪️", "EXPIRED": "⚪️"}


def get_key():
    try:
        out = subprocess.run(["/usr/bin/security", "find-generic-password", "-s",
                              "cursor-api-key", "-w"], capture_output=True, text=True, timeout=5)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    p = os.path.expanduser("~/.config/job-menubar/key")
    if os.path.exists(p):
        with open(p) as f:
            k = f.read().strip()
            return k or None
    return None


def api_get(path, key):
    if FIXTURE:
        name = path.strip("/").split("?")[0].replace("/", "_") + ".json"
        with open(os.path.join(FIXTURE, name)) as f:
            return json.load(f)
    req = urllib.request.Request(API + path, headers={
        "Authorization": "Basic " + base64.b64encode((key + ":").encode()).decode(),
        "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def gh_prs():
    if FIXTURE:
        with open(os.path.join(FIXTURE, "prs.json")) as f:
            return json.load(f)
    out = subprocess.run([GH, "pr", "list", "-R", REPO, "--state", "open", "--limit", "30",
                          "--json", "number,title,url,createdAt,isDraft,headRefName"],
                         capture_output=True, text=True, timeout=20)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip().splitlines()[-1] if out.stderr.strip() else "gh failed")
    return json.loads(out.stdout)


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def age(s, now):
    secs = int((now - parse_ts(s)).total_seconds())
    if secs < 60: return f"{max(secs,0)}s"
    if secs < 3600: return f"{secs//60}m"
    if secs < 86400: return f"{secs//3600}h{(secs%3600)//60:02d}m"
    return f"{secs//86400}d"


def clean(s, n=60):
    s = (s or "untitled").replace("|", "/").replace("\n", " ").strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def collect_agents(key, now):
    items = api_get("/agents?limit=50&includeArchived=false", key).get("items", [])
    picked = []
    for a in items:
        if a.get("status") == "ACTIVE":
            picked.append(a)
        elif a.get("status") == "IDLE" and a.get("updatedAt") and \
                (now - parse_ts(a["updatedAt"])).total_seconds() < RECENT_HOURS * 3600:
            picked.append(a)
    active = [a for a in picked if a.get("status") == "ACTIVE"]
    recent = [a for a in picked if a.get("status") != "ACTIVE"][:MAX_RECENT]
    picked = active + recent

    def with_run(a):
        run = {}
        if a.get("latestRunId"):
            try:
                run = api_get(f"/agents/{a['id']}/runs/{a['latestRunId']}", key)
            except Exception:
                run = {}
        a["_run"] = run
        a["_runStatus"] = run.get("status") or ("RUNNING" if a.get("status") == "ACTIVE" else "FINISHED")
        return a

    with ThreadPoolExecutor(max_workers=8) as ex:
        return list(ex.map(with_run, picked))


def notify(title, msg):
    if FIXTURE:
        return
    script = f'display notification {json.dumps(msg)} with title {json.dumps(title)} sound name "Glass"'
    subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True)


def track_finish(running_ids):
    """Notify once when the running set goes from non-empty to empty."""
    try:
        prev = json.load(open(STATE)).get("running", [])
    except Exception:
        prev = []
    if prev and not running_ids:
        notify("Slop Jobs", f"All jobs finished ({len(prev)} done)")
    if FIXTURE:
        return
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, "w") as f:
        json.dump({"running": running_ids, "at": time.time()}, f)


def main():
    now = datetime.now(timezone.utc)
    key = get_key() if not FIXTURE else "fixture"
    out, body = [], []
    agents, agent_err = [], None

    if not key:
        agent_err = "needs API key"
    else:
        try:
            agents = collect_agents(key, now)
        except urllib.error.HTTPError as e:
            agent_err = "API key rejected (401)" if e.code in (401, 403) else f"Cursor API HTTP {e.code}"
        except Exception as e:
            agent_err = f"Cursor API error: {type(e).__name__}"

    try:
        prs, pr_err = gh_prs(), None
    except Exception as e:
        prs, pr_err = [], f"gh error: {clean(str(e), 50)}"

    running = [a for a in agents if a["_runStatus"] in ACTIVE_RUN]
    ended = [a for a in agents if a["_runStatus"] not in ACTIVE_RUN]
    errors = [a for a in ended if a["_runStatus"] == "ERROR"]

    # --- menu bar title ---
    if agent_err == "needs API key":
        out.append(f"⚙ ? · PR {len(prs)} | color=orange")
    elif agent_err:
        out.append(f"⚙ ! · PR {len(prs)} | color=red")
    elif running:
        out.append(f"⚙ {len(running)}" + (f" · PR {len(prs)}" if prs else ""))
    else:
        out.append("✓" + (f" · PR {len(prs)}" if prs else "") + (" | color=red" if errors else ""))
    out.append("---")

    # --- agents ---
    if agent_err:
        body.append(f"⚠️ {agent_err} | color=red")
        if agent_err == "needs API key":
            body.append("Create key: cursor.com/dashboard → API Keys | href=https://cursor.com/dashboard")
            body.append("Then: security add-generic-password -a $USER -s cursor-api-key -w | font=Menlo size=11")
    else:
        body.append(f"Running agents ({len(running)}) | size=12 color=gray")
        if not running:
            body.append("Nothing running 🎉")
        for a in running:
            st = a["_runStatus"]
            body.append(f"{ICON.get(st,'•')} {clean(a.get('name'))}  ·  {age(a['createdAt'], now)} | href={a.get('url') or 'https://cursor.com/agents/' + a['id']}")
            body.append(f"--{st} · started {age(a['createdAt'], now)} ago | color=gray")
            for b in (a["_run"].get("git") or {}).get("branches", []):
                if b.get("prUrl"):
                    body.append(f"--Open PR | href={b['prUrl']}")
        if ended:
            body.append("---")
            body.append(f"Ended in last {RECENT_HOURS}h ({len(ended)}) | size=12 color=gray")
            for a in ended:
                st = a["_runStatus"]
                body.append(f"{ICON.get(st,'•')} {clean(a.get('name'))}  ·  {age(a.get('updatedAt') or a['createdAt'], now)} ago | href={a.get('url') or 'https://cursor.com/agents/' + a['id']}")
                for b in (a["_run"].get("git") or {}).get("branches", []):
                    if b.get("prUrl"):
                        body.append(f"--Open PR | href={b['prUrl']}")

    # --- PRs ---
    body.append("---")
    body.append(f"Open PRs · {REPO.split('/')[1]} ({len(prs)}) | size=12 color=gray")
    if pr_err:
        body.append(f"⚠️ {pr_err} | color=red")
    elif not prs:
        body.append("No open PRs")
    for p in prs:
        draft = " (draft)" if p.get("isDraft") else ""
        body.append(f"#{p['number']} {clean(p.get('title'), 55)}{draft}  ·  {age(p['createdAt'], now)} | href={p['url']}")

    body.append("---")
    body.append("All agents on cursor.com | href=https://cursor.com/agents")
    body.append(f"All PRs on GitHub | href=https://github.com/{REPO}/pulls")
    body.append("Refresh now | refresh=true")

    if not agent_err and not FIXTURE:
        track_finish([a["id"] for a in running])
    print("\n".join(out + body))


if __name__ == "__main__":
    main()
