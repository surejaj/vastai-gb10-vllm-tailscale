#!/usr/bin/env python3
"""Rent and manage the NVIDIA GB10 on vast.ai that sits behind vastai-ts-proxy.

The instance runs the vastai-gb10-vllm-tailscale image (vLLM per model + LiteLLM on
127.0.0.1:8080, exposed only through `tailscale serve`) and joins the tailnet
as `gb10-vast` (tag:vastai-gb10) with Tailscale in userspace-networking mode.
The image source is in image/. See README.md.

Subcommands:
  search    list rentable GB10 offers, cheapest first (read-only; the default)
  create    rent an offer. DRY RUN unless --yes is given.
  status    list instances labelled gb10-vast (--ids: bare ids, for scripts)
  destroy   delete a gb10-vast instance and its disk (needs --yes)

Lifecycle is destroy/recreate only. There is no stop/start: Tailscale state
lives in RAM, so a restarted instance would try to re-use its already
consumed single-use key. Every `create` needs a FRESH single-use, ephemeral,
pre-tagged tag:vastai-gb10 auth key.

Secrets (never taken from the command line, never printed):
  VAST_API_KEY   vast.ai API key. Read from Infisical (the Infisical CLI,
                 logged in as you: `infisical login --domain ...`), secret
                 VAST_API_KEY at $VAST_INFISICAL_PATH. The env var VAST_API_KEY
                 is only a fallback (with a warning). Fetched lazily, so
                 --help, --print-onstart and a dry-run `create` need nothing.
  HF_TOKEN       optional Hugging Face token handed to the instance; same
                 lookup (Infisical first, then env), silently skipped if absent
  TS_AUTHKEY     GB10 Tailscale auth key handed to the instance (create --yes).
                 ENV ONLY: a fresh single-use key per create, never stored.
                 Not the proxy's key (that one lives in Infisical).

Infisical settings (env, with defaults): INFISICAL_DOMAIN
(https://infisical.rattlesnake-pauling.ts.net), INFISICAL_ENV (prod),
VAST_INFISICAL_PATH (/vast-ai), INFISICAL_PROJECT_ID (optional; otherwise the
CLI uses .infisical.json from `infisical init`, looked up in this script's
directory), INFISICAL_TIMEOUT (seconds, 20).
"""

import argparse
import json
import os
import subprocess
import sys
import textwrap
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LABEL = "gb10-vast"
DEFAULT_IMAGE = "ghcr.io/surejaj/vastai-gb10-vllm-tailscale:latest"
# Space-separated alias=hf_repo@mem_frac@max_len[@extra]; extra = vLLM args
# joined with '+'. Started one at a time, largest share first (~0.78 total).
# Repos are researched, not test-run: see README "Models".
DEFAULT_MODELS = (
    "main=unsloth/Qwen3.8-27B-NVFP4@0.38@65536@"
    "--kv-cache-dtype+fp8+--reasoning-parser+qwen3+--enable-auto-tool-choice"
    "+--tool-call-parser+qwen3_xml+--max-num-seqs+4 "
    "worker=NVFP4/Qwen3-30B-A3B-Instruct-2507-FP4@0.25@32768@"
    "--kv-cache-dtype+fp8+--enable-auto-tool-choice+--tool-call-parser+hermes"
    "+--max-num-seqs+4 "
    "vision=Qwen/Qwen3-VL-8B-Instruct-FP8@0.12@16384@--max-num-seqs+2 "
    "embed=nomic-ai/nomic-embed-text-v1.5@0.03@8192@--runner+pooling+--trust-remote-code"
)
DEFAULT_DISK = 100
DEFAULT_TS_TAG = "tag:vastai-gb10"
SERVE_PORT = 8080
HOURS_PER_MONTH = 730
# Onstart is a one-liner: the image ships the supervisor. vast.ai's ssh launch
# mode replaces the image ENTRYPOINT and runs this instead. The supervisor is
# flock-guarded, so a repeated onstart is a no-op; it is backgrounded because
# onstart must return. It reads TS_AUTHKEY / HF_TOKEN / GB10_* from the env.
ONSTART_SCRIPT = ("nohup /opt/gb10/start-gb10.sh </dev/null >/dev/null 2>&1 &\n")


class CliError(Exception):
    """A user-facing error: printed without a traceback, exit code 1."""


# ---------------------------------------------------------------- helpers ---

def die(msg):
    raise CliError(msg)


_SEEN_SECRETS = []   # resolved secret values, scrubbed from error text


def env_secret(name, required=True):
    val = os.environ.get(name, "").strip()
    if required and not val:
        die(f"{name} is not set. Export it in the environment "
            f"(secrets are never taken from the command line).")
    return val


def infisical_get(name):
    """Fetch one secret with the Infisical CLI. Returns (value, reason).

    value is None on any failure and reason is a generic string (exit code,
    timeout, ...). The CLI's stderr is never shown: it could echo secrets.
    cwd is this script's directory so `.infisical.json` (infisical init) is found.
    """
    domain = os.environ.get("INFISICAL_DOMAIN", "https://infisical.rattlesnake-pauling.ts.net")
    cmd = ["infisical", "secrets", "get", name, "--plain", "--silent",
           "--path", os.environ.get("VAST_INFISICAL_PATH", "/vast-ai"),
           "--env", os.environ.get("INFISICAL_ENV", "prod"),
           "--domain", domain]
    project = os.environ.get("INFISICAL_PROJECT_ID", "").strip()
    if project:
        cmd += ["--projectId", project]
    try:
        timeout = float(os.environ.get("INFISICAL_TIMEOUT", "20"))
        r = subprocess.run(cmd, cwd=SCRIPT_DIR, capture_output=True, text=True,
                           timeout=timeout)
    except FileNotFoundError:
        return None, "the infisical CLI is not installed"
    except subprocess.TimeoutExpired:
        return None, "the infisical CLI timed out"
    except (OSError, ValueError) as e:
        return None, f"could not run the infisical CLI ({type(e).__name__})"
    if r.returncode != 0:
        return None, f"the infisical CLI failed (exit code {r.returncode})"
    val = r.stdout.strip()
    if not val:
        return None, "the infisical CLI returned an empty value"
    return val, ""


def resolve_vast_key():
    """VAST_API_KEY: Infisical first; env only as a warned fallback."""
    val, reason = infisical_get("VAST_API_KEY")
    if val:
        _SEEN_SECRETS.append(val)
        return val
    env_val = os.environ.get("VAST_API_KEY", "").strip()
    if env_val:
        _SEEN_SECRETS.append(env_val)
        print(f"WARNING: using VAST_API_KEY from the environment because "
              f"Infisical failed ({reason}). Infisical is the source of truth.",
              file=sys.stderr)
        return env_val
    domain = os.environ.get("INFISICAL_DOMAIN", "https://infisical.rattlesnake-pauling.ts.net")
    die(f"no vast.ai API key: {reason}, and VAST_API_KEY is not set in the "
        f"environment. Fix with: `infisical login --domain {domain}` (then "
        f"`infisical init` in {SCRIPT_DIR} or export INFISICAL_PROJECT_ID; "
        f"secret VAST_API_KEY at {os.environ.get('VAST_INFISICAL_PATH', '/vast-ai')}, "
        f"env {os.environ.get('INFISICAL_ENV', 'prod')}), or export VAST_API_KEY as a fallback.")


def resolve_hf_token():
    """Optional HF_TOKEN: Infisical, then env; absent means '' with no warning."""
    val, _ = infisical_get("HF_TOKEN")
    val = val or os.environ.get("HF_TOKEN", "").strip()
    if val:
        _SEEN_SECRETS.append(val)
    return val or ""


def default_client_factory():
    """Build the real SDK client. Imported lazily: --help needs no SDK."""
    key = resolve_vast_key()
    try:
        from vastai_sdk import VastAI
    except ImportError:
        die("vastai_sdk is not installed. Run: pip install -r "
            "requirements.txt (or: pip install vastai-sdk)")
    return VastAI(api_key=key, quiet=True)


def build_env(args, ts_authkey, hf_token=""):
    env = {
        "TS_AUTHKEY": ts_authkey,
        "TS_HOSTNAME": args.ts_hostname,
        "TS_TAGS": args.ts_tag,
        "GB10_MODELS": args.models,
        "HF_HOME": "/workspace/hf",
    }
    if args.main_fallback:
        env["GB10_MAIN_FALLBACK"] = args.main_fallback
    if hf_token:
        env["HF_TOKEN"] = hf_token
    return env


SECRET_KEYS = ("TS_AUTHKEY", "HF_TOKEN")


def redacted(env):
    return {k: ("***REDACTED***" if k in SECRET_KEYS else v) for k, v in env.items()}


def scrub(text, secrets):
    for s in secrets:
        if s:
            text = text.replace(s, "***REDACTED***")
    return text


def build_query(args):
    parts = ["rentable=true", "rented=false"]
    if args.gpu_name.lower() != "any":
        parts.append("gpu_name=" + args.gpu_name.replace(" ", "_"))
    if args.cpu_arch.lower() != "any":
        parts.append(f"cpu_arch={args.cpu_arch}")
    parts.append("verified=any" if args.allow_unverified else "verified=true")
    parts.append(f"reliability>={args.min_reliability}")
    parts.append(f"disk_space>={args.disk}")
    return " ".join(parts)


def num(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def print_table(headers, rows):
    widths = [max(len(str(x)) for x in col) for col in zip(headers, *rows)]
    for r in [headers] + rows:
        print("  ".join(str(c).ljust(w) for c, w in zip(r, widths)).rstrip())


def fmt_uptime(seconds):
    s = int(num(seconds))
    return f"{s // 3600}h{(s % 3600) // 60:02d}m"


def gb10_instances(client):
    return [i for i in client.show_instances() if (i.get("label") or "") == LABEL]


def get_gb10_instance(client, instance_id):
    """Fetch one instance; refuse unless its label is gb10-vast."""
    inst = client.show_instance(instance_id)
    if not inst:
        die(f"instance {instance_id} not found")
    if inst.get("label") != LABEL:
        die(f"instance {instance_id} has label {inst.get('label')!r}, not "
            f"{LABEL!r}; refusing to touch it")
    return inst


def instance_line(i):
    return (f"id={i.get('id')} status={i.get('actual_status')} "
            f"${num(i.get('dph_total')):.3f}/hr")


# -------------------------------------------------------------- subcommands ---

def cmd_search(args, client_factory):
    client = client_factory()
    query = build_query(args)
    offers = client.search_offers(query=query, type="on-demand", order="dph_total",
                                  limit=args.limit, storage=args.disk)
    print(f"query: {query}")
    if not offers:
        print("No matching offers. The GB10 gpu_name string is unconfirmed: try "
              "--gpu-name any (with --cpu-arch arm64) and read the gpu column, "
              "or lower --min-reliability / add --allow-unverified.")
        return 0
    rows = []
    for o in sorted(offers, key=lambda o: num(o.get("dph_total"))):
        dph = num(o.get("dph_total"))
        rel = o.get("reliability", o.get("reliability2"))
        rows.append([o.get("id"), o.get("gpu_name"), f"{dph:.3f}",
                     f"{dph * HOURS_PER_MONTH:.0f}", f"{num(rel):.4f}",
                     o.get("geolocation"), o.get("host_id"),
                     f"{num(o.get('disk_space')):.0f}"])
    print_table(["offer", "gpu", "$/hr", "$/month(730h)", "reliab", "location",
                 "host", "disk_GB"], rows)
    print(f"\nPrice includes {args.disk} GB storage. Rent with: "
          f"provision-gb10.py create --offer-id <offer>")
    return 0


def cmd_create(args, client_factory):
    sent = ONSTART_SCRIPT
    dry = not args.yes
    ts_key = env_secret("TS_AUTHKEY", required=not dry)
    # Dry run is offline: it never calls Infisical, so HF_TOKEN is only shown
    # (redacted) if it happens to be in the environment.
    hf_token = env_secret("HF_TOKEN", required=False) if dry else resolve_hf_token()
    env = build_env(args, ts_key or "<TS_AUTHKEY not set>", hf_token)
    request = {
        "id": args.offer_id, "image": args.image, "disk": args.disk,
        "env": redacted(env), "label": LABEL, "ssh": True,
        "cancel_unavail": True, "price": None,
        "onstart_cmd": sent.strip(),
    }
    if dry:
        print("DRY RUN: nothing is rented and no vast.ai API call is made. "
              "Add --yes to rent.\n")
        print("create_instance request:")
        print(json.dumps(request, indent=2))
        print("\nOnstart (supervisor script ships in the image: "
              "vast-ai/image/start-gb10.sh):\n" + "-" * 60)
        print(sent, end="")
        print("-" * 60)
        print("Not checked in dry run: offer price/availability and "
              f"existing {LABEL} instances (checked with --yes).")
        return 0

    client = client_factory()
    secrets = [ts_key, hf_token, os.environ.get("VAST_API_KEY", "")] + _SEEN_SECRETS

    existing = gb10_instances(client)
    if existing and not args.allow_duplicate:
        die(f"an instance labelled {LABEL} already exists ("
            + "; ".join(instance_line(i) for i in existing)
            + "). Use --allow-duplicate to rent another.")

    found = client.search_offers(query=f"id={args.offer_id}", type="on-demand",
                                 order="dph_total", limit=1, storage=args.disk)
    offer = next((o for o in found or [] if o.get("id") == args.offer_id), None)
    if not offer:
        die(f"offer {args.offer_id} is no longer available (or not rentable). "
            "Run `search` again.")
    name = offer.get("gpu_name") or ""
    if args.gpu_name.lower() != "any" and args.gpu_name.lower() not in name.lower():
        die(f"offer gpu_name is {name!r}, not {args.gpu_name!r}. "
            "Pass --gpu-name with the right value (or 'any') if intended.")
    dph = num(offer.get("dph_total"))
    print(f"Offer {args.offer_id}: {name}  ${dph:.3f}/hr "
          f"(~${dph * HOURS_PER_MONTH:.0f}/month at 730h, incl. {args.disk} GB disk)  "
          f"reliability={offer.get('reliability')}  host={offer.get('host_id')}")
    if args.max_price is not None and dph > args.max_price:
        die(f"price ${dph:.3f}/hr exceeds --max-price {args.max_price}")

    print("Renting (on-demand, billable)...")
    result = client.create_instance(
        id=args.offer_id, image=args.image, disk=args.disk, env=env,
        label=LABEL, onstart_cmd=sent, ssh=True, cancel_unavail=True)
    if not isinstance(result, dict) or not result.get("success") \
            or not result.get("new_contract"):
        die("create_instance failed: " + scrub(json.dumps(result, default=str), secrets))
    iid = result["new_contract"]
    print(f"Created instance {iid}. Waiting for status 'running' "
          f"(timeout {args.timeout}s)...")

    deadline = time.monotonic() + args.timeout
    last = None
    while True:
        inst = client.show_instance(iid) or {}
        status = inst.get("actual_status")
        if status != last:
            print(f"  status: {status}")
            last = status
        if status == "running":
            break
        if status in ("exited", "unknown", "offline"):
            die(f"instance {iid} entered status {status!r}; it will not reach "
                f"running. Check the vast.ai console, then `destroy --instance-id "
                f"{iid} --yes` and retry with another offer (charges accrue).")
        if time.monotonic() >= deadline:
            die(f"timed out waiting for instance {iid} (last status {status!r}). "
                f"It is still billing: `status`, or `destroy --instance-id {iid} --yes`.")
        time.sleep(args.poll_interval)

    print(f"\nInstance {iid} is running (${num(inst.get('dph_total')):.3f}/hr).")
    print("'running' means the container is up; the supervisor and the model "
          "downloads (first boot: tens of GB) take longer. Next:")
    print(f"  1. On the instance: tail -f /var/log/gb10.log "
          f"(vast.ai console / ssh)")
    print(f"  2. tailscale status | grep {args.ts_hostname}   "
          f"(name must be exactly {args.ts_hostname}, not {args.ts_hostname}-1)")
    print("  3. docker exec Hermes-Agent curl -sS "
          f"http://vastai-ts-proxy:{SERVE_PORT}/v1/models   (aliases appear as each model becomes healthy)")
    return 0


def cmd_status(args, client_factory):
    client = client_factory()
    insts = gb10_instances(client)
    if args.ids:  # machine-readable: one id per line, nothing else
        for i in insts:
            print(i.get("id"))
        return 0
    if not insts:
        print(f"No instances labelled {LABEL}.")
        return 0
    rows = [[i.get("id"), i.get("label"), i.get("actual_status"),
             i.get("cur_state"), f"{num(i.get('dph_total')):.3f}",
             fmt_uptime(i.get("duration")), i.get("gpu_name"), i.get("machine_id")]
            for i in insts]
    print_table(["id", "label", "status", "state", "$/hr", "uptime", "gpu", "machine"], rows)
    return 0


def cmd_destroy(args, client_factory):
    client = client_factory()
    inst = get_gb10_instance(client, args.instance_id)
    print(f"About to destroy {instance_line(inst)}.")
    print("WARNING: this deletes the instance disk, including all pulled models "
          "(tens of GB, re-download on the next rental). It cannot be undone.")
    if not args.yes:
        die("refusing to destroy without --yes")
    print(client.destroy_instance(args.instance_id))
    print("Destroyed. Recreate with a FRESH single-use TS_AUTHKEY. Remove the gb10-vast node in the Tailscale admin console "
          "if it lingers, and revoke the auth key.")
    return 0


# ------------------------------------------------------------------ parser ---

COMMANDS = {"search", "create", "status", "destroy"}


def build_parser():
    p = argparse.ArgumentParser(
        prog="provision-gb10.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=textwrap.dedent(__doc__),
        epilog="With no subcommand, `search` runs. Use `<subcommand> --help` for options.")
    p.add_argument("--print-onstart", action="store_true",
                   help="print the generated onstart script and exit (no API key needed)")
    sub = p.add_subparsers(dest="cmd", metavar="{search,create,status,destroy}")

    offer = argparse.ArgumentParser(add_help=False)
    offer.add_argument("--disk", type=int, default=DEFAULT_DISK,
                       help="instance disk in GB (default %(default)s)")
    offer.add_argument("--gpu-name", default="GB10",
                       help="vast.ai gpu_name to match (default %(default)s; UNCONFIRMED "
                            "string. 'any' drops the filter)")
    offer.add_argument("--cpu-arch", default="arm64",
                       help="host cpu_arch filter (default %(default)s; 'any' to drop)")

    s = sub.add_parser("search", parents=[offer],
                       help="list rentable GB10 offers by $/hr (read-only)",
                       description="Search on-demand, rentable, verified offers, cheapest first.")
    s.add_argument("--min-reliability", type=float, default=0.98,
                   help="minimum host reliability (default %(default)s)")
    s.add_argument("--allow-unverified", action="store_true",
                   help="include unverified hosts")
    s.add_argument("--limit", type=int, default=20, help="max offers (default %(default)s)")

    c = sub.add_parser("create", parents=[offer],
                       help="rent an offer (DRY RUN unless --yes)",
                       description="Print the create request and onstart script (dry run, "
                                   "offline). With --yes: re-fetch the offer, refuse if a "
                                   "gb10-vast instance exists, rent, and wait for running. "
                                   "VAST_API_KEY / HF_TOKEN come from Infisical (env is a "
                                   "fallback). TS_AUTHKEY (env only, needed with --yes): a FRESH "
                                   "single-use, ephemeral, tag:vastai-gb10 key per create.")
    c.add_argument("--offer-id", type=int, required=True, help="offer id from `search`")
    c.add_argument("--yes", action="store_true", help="actually rent (billable)")
    c.add_argument("--image", default=DEFAULT_IMAGE, help="docker image (default %(default)s)")
    c.add_argument("--models", default=DEFAULT_MODELS,
                   help="vLLM models, space separated 'alias=hf_repo@mem_frac@max_len[@extra]' "
                        "(extra = vLLM args joined with '+'). Default: %(default)s")
    c.add_argument("--main-fallback", default="",
                   help="same spec, used if `main` fails to start (GB10_MAIN_FALLBACK)")
    c.add_argument("--ts-hostname", default=LABEL, help="tailnet hostname (default %(default)s)")
    c.add_argument("--ts-tag", default=DEFAULT_TS_TAG, help="advertised tag (default %(default)s)")
    c.add_argument("--max-price", type=float, default=None, help="refuse above this $/hr")
    c.add_argument("--allow-duplicate", action="store_true",
                   help=f"rent even if a {LABEL} instance already exists")
    c.add_argument("--timeout", type=int, default=900,
                   help="seconds to wait for running (default %(default)s)")
    c.add_argument("--poll-interval", type=float, default=15,
                   help="seconds between status polls (default %(default)s)")

    st = sub.add_parser("status", help="list gb10-vast instances",
                        description="Show id, status, $/hr and uptime of gb10-vast instances.")
    st.add_argument("--ids", action="store_true",
                    help="print only the instance ids, one per line (for scripts)")
    d = sub.add_parser("destroy", help="destroy a gb10-vast instance and its disk (needs --yes)",
                       description="Destroy an instance and its disk (models are deleted). "
                                   f"Only acts on instances labelled {LABEL}. Recreate with a "
                                   "fresh single-use TS_AUTHKEY.")
    d.add_argument("--instance-id", type=int, required=True)
    d.add_argument("--yes", action="store_true", help="confirm deletion")
    return p


HANDLERS = {"search": cmd_search, "create": cmd_create, "status": cmd_status,
            "destroy": cmd_destroy}


def main(argv=None, client_factory=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    client_factory = client_factory or default_client_factory
    parser = build_parser()
    if not (COMMANDS & set(argv)) and not ({"-h", "--help", "--print-onstart"} & set(argv)):
        argv = ["search"] + argv
    args = parser.parse_args(argv)
    if args.print_onstart:
        print(ONSTART_SCRIPT, end="")
        return 0
    if not args.cmd:
        parser.print_help()
        return 0
    try:
        return HANDLERS[args.cmd](args, client_factory)
    except CliError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except Exception as e:  # SDK/HTTP errors: no traceback, no secrets
        secrets = [os.environ.get("VAST_API_KEY", ""), os.environ.get("TS_AUTHKEY", "")] + _SEEN_SECRETS
        print(f"ERROR: {type(e).__name__}: {scrub(str(e), secrets)}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
