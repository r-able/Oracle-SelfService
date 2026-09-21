"""
webhook_receiver.py — the front door for the closed-loop + AI demo.

A ServiceNow Business Rule (or Flow Designer flow) POSTs here when the
forecasting job opens a "tablespace capacity" Change Request. This receiver:

  1. Checks a shared-secret header (this will sit on a public IP, so
     don't skip this even for a demo).
  2. Pulls the CR number + tablespace name out of the payload.
  3. Hands off to run_playbook.sh, which does the actual locking and
     ansible-playbook invocation — this file stays a thin HTTP layer.
  4. Returns immediately (202) so the calling Business Rule doesn't block
     waiting for a multi-minute Ansible run. The playbook posts its own
     work notes and state transitions back to the CR as it goes, the same
     way the rest of the Oracle automation suite's ServiceNow playbooks do.

Run it with:  gunicorn -w 2 -b 0.0.0.0:8443 webhook_receiver:app
(or `python webhook_receiver.py` for quick local testing — see bottom)
"""

import logging
import os
import re
import subprocess
from pathlib import Path
from typing import Optional

from flask import Flask, jsonify, request

app = Flask(__name__)

# ---------------------------------------------------------------------
# Config — all overridable via environment variables so nothing secret
# ever needs to be hardcoded or committed.
# ---------------------------------------------------------------------
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")
RUN_SCRIPT = os.environ.get("DEMO_RUN_SCRIPT", "/opt/tablespace-demo/run_playbook.sh")
LOG_FILE = os.environ.get("DEMO_RECEIVER_LOG", "/opt/tablespace-demo/logs/receiver.log")

# ServiceNow change_request numbers: CHG followed by digits (matches the
# real CHG0033168-style numbers already in use on the production instance).
# Loosened to CHG+digits generically rather than a fixed digit count, since
# padding width can differ per instance.
CHANGE_NUMBER_RE = re.compile(r"^CHG\d+$")
TABLESPACE_RE = re.compile(r"^[A-Za-z0-9_$#]{1,30}$")

Path(os.path.dirname(LOG_FILE)).mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("webhook_receiver")


def _extract_tablespace(payload: dict) -> Optional[str]:
    """Prefer an explicit field; fall back to parsing the short description,
    e.g. 'Capacity alert: USERS_TBS projected to breach in 4 days'."""
    tbs = payload.get("tablespace")
    if tbs:
        return tbs.strip().upper()

    summary = (payload.get("short_description") or "").upper()
    m = re.search(r"\b([A-Z0-9_$#]{2,30}_TBS|SYSTEM|SYSAUX|USERS|TEMP)\b", summary)
    return m.group(1) if m else None


@app.get("/healthz")
def healthz():
    return jsonify(status="ok"), 200


@app.post("/webhook/tablespace-remediate")
def tablespace_remediate():
    # --- auth ---
    if not WEBHOOK_SECRET or request.headers.get("X-Webhook-Secret") != WEBHOOK_SECRET:
        log.warning("rejected webhook call: bad or missing secret (from %s)", request.remote_addr)
        return jsonify(error="unauthorized"), 401

    # --- parse + validate payload ---
    payload = request.get_json(silent=True) or {}
    change_number = (payload.get("change_number") or "").strip().upper()
    tablespace = _extract_tablespace(payload)

    if not CHANGE_NUMBER_RE.match(change_number):
        log.warning("rejected payload: invalid/missing change_number %r", change_number)
        return jsonify(error="change_number missing or not a valid CR number (e.g. CHG0033168)"), 400
    if not tablespace or not TABLESPACE_RE.match(tablespace):
        log.warning("rejected payload for %s: could not determine tablespace (%r)", change_number, payload)
        return jsonify(error="could not determine tablespace name from payload"), 400

    log.info("triggering remediation for %s (tablespace=%s)", change_number, tablespace)

    # --- hand off to the wrapper script, fully detached ---
    try:
        subprocess.Popen(
            [RUN_SCRIPT, change_number, tablespace],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,  # survives this request finishing
        )
    except FileNotFoundError:
        log.error("run script not found or not executable: %s", RUN_SCRIPT)
        return jsonify(error="server misconfigured: run script missing"), 500

    return jsonify(status="triggered", change_number=change_number, tablespace=tablespace), 202


if __name__ == "__main__":
    # Quick local testing only — use gunicorn (see module docstring) on the VM.
    app.run(host="0.0.0.0", port=8443, debug=True)
