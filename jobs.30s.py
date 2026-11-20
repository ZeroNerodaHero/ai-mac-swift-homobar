#!/opt/homebrew/bin/python3
# <xbar.title>Slop Jobs</xbar.title>
# <xbar.desc>Cursor cloud agents + open PRs on slop-stream-architecture</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
"""SwiftBar plugin: shows running Cursor cloud agents, recent failures and open PRs.

API key is read from macOS Keychain (service "cursor-api-key") or
~/.config/job-menubar/key (chmod 600). It is never printed.
Set JOBBAR_FIXTURE=/path/to/dir to run against sample JSON (testing).
`jobs.30s.py --mark-seen` records that current failures were seen (clears red title).
"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

REPO = "ZeroNerodaHero/slop-stream-architecture"
API = "https://api.cursor.com/v1"
GH = "/opt/homebrew/bin/gh"
RECENT_HOURS = 6        # normal "ended" list window
FAIL_HOURS = 24         # failures window
MAX_RECENT = 8
MAX_FAILED = 15
STATE = os.path.expanduser("~/.config/job-menubar/state.json")
FIXTURE = os.environ.get("JOBBAR_FIXTURE")
SELF = os.path.realpath(__file__)
ACTIVE_RUN = {"CREATING", "RUNNING", "WAITING_FOR_BACKGROUND_WORK"}
ICON = {"CREATING": "🟡", "RUNNING": "🟢", "WAITING_FOR_BACKGROUND_WORK": "🟡",
        "FINISHED": "✅", "ERROR": "❌", "CANCELLED": "⚪️", "EXPIRED": "⚪️", "UNKNOWN": "⚠️"}


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


def load_state():
    try:
        with open(STATE) as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_state(d):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f)
    os.replace(tmp, STATE)


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


def dur(ms):
    s = int((ms or 0) / 1000)
    if s < 60: return f"{s}s"
    if s < 3600: return f"{s//60}m{s%60:02d}s"
    return f"{s//3600}h{(s%3600)//60:02d}m"


def clean(s, n=60):
    s = (s or "untitled").replace("|", "/").replace("\n", " ").strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def within(ts, now, hours):
    try:
        return ts and (now - parse_ts(ts)).total_seconds() < hours * 3600
    except Exception:
        return False


def collect_agents(key, now):
    items = api_get("/agents?limit=50&includeArchived=false", key).get("items", [])
    picked = [a for a in items if a.get("status") == "ACTIVE" or
              (a.get("status") == "IDLE" and within(a.get("updatedAt"), now, FAIL_HOURS))]

    def with_run(a):
        run = {}
        if a.get("latestRunId"):
            try:
                run = api_get(f"/agents/{a['id']}/runs/{a['latestRunId']}", key)
                st = run.get("status") or "UNKNOWN"
            except Exception:
                run, st = {}, "UNKNOWN"   # lookup failed: don't pretend it finished
        else:
            st = "RUNNING" if a.get("status") == "ACTIVE" else "FINISHED"
        a["_run"], a["_runStatus"] = run, st
        a["_endedAt"] = run.get("updatedAt") or a.get("updatedAt") or a.get("createdAt")
        return a

    with ThreadPoolExecutor(max_workers=8) as ex:
        return list(ex.map(with_run, picked))


def notify(title, msg):
    if FIXTURE:
        return
    script = f'display notification {json.dumps(msg)} with title {json.dumps(title)} sound name "Glass"'
    subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True)


def track(running_ids, failed_ids):
    """Notify when running set goes non-empty -> empty, and on newly seen failures."""
    st = load_state()
    prev = st.get("running", [])
    if prev and not running_ids:
        notify("Slop Jobs", f"All jobs finished ({len(prev)} done)")
    if "failed_ids" in st:
        new = [i for i in failed_ids if i not in set(st["failed_ids"])]
        if new:
            notify("Slop Jobs", f"{len(new)} new failed job(s)")
    st.update({"running": running_ids, "failed_ids": failed_ids, "at": time.time()})
    save_state(st)


def is_running(a):
    return a["_runStatus"] in ACTIVE_RUN or (a["_runStatus"] == "UNKNOWN" and a.get("status") == "ACTIVE")


def href(a):
    return a.get("url") or "https://cursor.com/agents/" + a["id"]


def pr_lines(a):
    return [f"--Open PR | href={b['prUrl']}" for b in (a["_run"].get("git") or {}).get("branches", []) if b.get("prUrl")]


def main():
    if "--mark-seen" in sys.argv[1:]:
        st = load_state()
        st["failures_seen_at"] = time.time()
        save_state(st)
        return

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

    seen_at = float(load_state().get("failures_seen_at", 0) or 0)
    running = [a for a in agents if is_running(a)]
    failed = [a for a in agents if a["_runStatus"] == "ERROR" and within(a["_endedAt"], now, FAIL_HOURS)]
    failed.sort(key=lambda a: a["_endedAt"], reverse=True)
    unseen = [a for a in failed if parse_ts(a["_endedAt"]).timestamp() > seen_at]
    ended = [a for a in agents if not is_running(a) and a["_runStatus"] != "ERROR"
             and within(a["_endedAt"], now, RECENT_HOURS)][:MAX_RECENT]
    unknown = [a for a in agents if a["_runStatus"] == "UNKNOWN"]

    # --- menu bar title ---
    pr_part = f" · PR {len(prs)}" if prs else ""
    fail_part = f" ✗ {len(unseen)}" if unseen else ""
    red = " | color=red" if unseen else ""
    if agent_err == "needs API key":
        out.append(f"⚙ ? · PR {len(prs)} | color=orange")
    elif agent_err:
        out.append(f"⚙ ! · PR {len(prs)} | color=red")
    elif running:
        out.append(f"⚙ {len(running)}{pr_part}{fail_part}{red}")
    else:
        out.append(f"✓{pr_part}{fail_part}{red}")
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
            body.append(f"{ICON.get(st,'•')} {clean(a.get('name'))}  ·  {age(a['createdAt'], now)} | href={href(a)}")
            label = "run status unknown (lookup failed)" if st == "UNKNOWN" else st
            body.append(f"--{label} · started {age(a['createdAt'], now)} ago | color=gray")
            body += pr_lines(a)

        body.append("---")
        hdr = f"Failed in last {FAIL_HOURS}h ({len(failed)})" + (f" · {len(unseen)} new" if unseen else "")
        body.append(f"{hdr} | size=12 color={'red' if unseen else 'gray'}")
        if not failed:
            body.append("No failures 👍")
        for a in failed[:MAX_FAILED]:
            d = a["_run"].get("durationMs")
            how = f"failed after {dur(d)}" if d is not None else "failed"
            new = a in unseen
            body.append(f"❌ {clean(a.get('name'), 50)}  ·  {how}  ·  {age(a['_endedAt'], now)} ago | href={href(a)}"
                        + (" color=red" if new else ""))
            body += pr_lines(a)
        if len(failed) > MAX_FAILED:
            body.append(f"…and {len(failed) - MAX_FAILED} more | href=https://cursor.com/agents color=gray")
        if failed:
            body.append(f'Mark failures seen | bash="{SELF}" param1=--mark-seen terminal=false refresh=true')

        if ended:
            body.append("---")
            body.append(f"Ended in last {RECENT_HOURS}h ({len(ended)}) | size=12 color=gray")
            for a in ended:
                st = a["_runStatus"]
                tail = "  ·  status unknown (lookup failed)" if st == "UNKNOWN" else ""
                body.append(f"{ICON.get(st,'•')} {clean(a.get('name'))}  ·  {age(a['_endedAt'], now)} ago{tail} | href={href(a)}")
                body += pr_lines(a)
        if unknown:
            body.append(f"⚠️ {len(unknown)} run lookup(s) failed; status may be stale | color=orange size=11")

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
        track([a["id"] for a in running], [a["id"] for a in failed])
    print("\n".join(out + body))


if __name__ == "__main__":
    main()
