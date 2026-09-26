# Tablespace demo — webhook receiver + remediation playbook

The front door of the loop: a ServiceNow Business Rule (or Flow Designer
flow) calls the receiver when the forecasting job (not built yet) opens a
capacity-alert Change Request. The receiver hands off to `run_playbook.sh`,
which locks and runs `remediate_tablespace.yml` — the playbook does the
actual diagnose → act → verify → RCA → close cycle and talks to ServiceNow
directly via `servicenow.itsm.change_request`, the same collection and
Standard/no-approval pattern the rest of the Oracle automation suite uses.

Runs entirely on infrastructure you already own — no cloud free tier
required. The only piece with any marginal cost is an optional AWS Bedrock
call for the RCA writeup; the default (a local Ollama model) is $0.

## Files

| File | Purpose |
|---|---|
| `webhook_receiver.py` | Flask app — the HTTP endpoint ServiceNow hits |
| `run_playbook.sh` | Locking + `ansible-playbook` invocation (called by the receiver) |
| `ansible/remediate_tablespace.yml` | The actual remediation: diagnose → act → verify → RCA → close |
| `ansible/vars/demo_vars.yml` | Centralized config — host, PDB, ServiceNow instance, AI provider choice |
| `ansible/inventory.ini` | Example inventory — point `oracle_target_host` at your own VM |
| `requirements.txt` | `pip install -r requirements.txt` |
| `.env.example` | Copy to `.env`, fill in a real secret |
| `tablespace-webhook.service` | systemd unit so the receiver survives reboots |

## What `remediate_tablespace.yml` actually does

Three plays, same shape as the rest of the Oracle automation suite's
ServiceNow conversion:

1. **Verify + advance to Implement** (localhost) — looks up the Change
   Request by number, confirms it exists, and walks it `New → Scheduled →
   Implement` (Standard changes can't jump straight to Implement — same
   rule the production suite already works around). Posts a "starting"
   work note.
2. **Diagnose → Act → Verify** (the DB host, over SSH as `oracle`) —
   queries `dba_data_files`/`dba_free_space` for the named tablespace (as
   JSON via Oracle's native `JSON_OBJECT`, not fragile text-parsing),
   picks the fullest datafile, either enables autoextend or resizes it up
   by `resize_increment_pct`, then re-queries to confirm the fix actually
   helped before calling it verified. Wrapped in `block`/`rescue` — a
   genuine failure here (e.g. a real `ORA-` error) no longer aborts the
   whole playbook and strands the CR at Implement forever; it gets caught
   and handed to play 3 as a failure to close out honestly.
3. **Confirm** (localhost) — builds a plain-English RCA prompt from the
   before/after numbers (or the error, on the failure path), sends it to
   whichever `llm_provider` you've set in `demo_vars.yml` (`ollama` =
   free/local, `bedrock` = metered AWS call), posts the result as a work
   note, then walks the CR `Review → Closed` — **on both the success and
   failure path**, with `close_code` set to `successful` or `unsuccessful`
   accordingly. If the LLM call fails or is unreachable, it degrades to a
   plain facts-only note instead of failing the whole run.

### Things I verified this actually needs, not just assumed

I pulled the real `servicenow.itsm.change_request` module source (Galaxy
isn't reachable from where I built this, so I cloned it straight from
GitHub) rather than guess at its parameters, and corrected two real
mistakes from a first draft against it:

- **`assignment_group` is a required parameter** on every call that sets
  `state` to `assess`/`authorize`/`scheduled`/`implement`/`review`/`closed`
  — confirmed in the module source, not just inferred from the production
  suite's note about it. Added `sn_assignment_group` to `demo_vars.yml`
  and pass it on every state-changing call.
- **`close_code` and `close_notes` are top-level parameters**, not nested
  under `other:` the way `work_notes` is — my first draft had this wrong.
  `close_code` is also a fixed enum: `successful` / `successful_issues` /
  `unsuccessful` — lowercase, not free text. Fixed in `demo_vars.yml`.

### Before running this for real

- Install the collection: `ansible-galaxy collection install servicenow.itsm`
- Fill in `ansible/vars/demo_vars.yml` — host, PDB, ServiceNow instance,
  assignment group, and your AI provider choice. `sn_password` is a
  placeholder; move it to Ansible Vault before this touches anything real
  (same flag already raised on the production `vars/main.yml`).
- The CR must already exist as a **Standard**-type, pre-approved change
  (same no-approval pattern as REF/CDP/PRF) before this playbook runs —
  that's the forecasting job's responsibility once it's built. This
  playbook only walks state forward; it doesn't set `type` or `chg_model`.
- **Ollama path (default, $0):** install Ollama on whichever box runs
  `ansible-playbook` (your control node, not the DB host) and pull a
  model: `ollama pull llama3.1:8b`. Confirm it's reachable at
  `ollama_host` before the first real run.
- **Bedrock path (metered):** run `aws configure` on the control node (or
  attach an instance role) with `bedrock:InvokeModel` permission, and set
  `bedrock_model_id`/`aws_region` in `demo_vars.yml`.
- I syntax-checked the playbook **against the real collection** (not just
  YAML validity) and unit-tested the trickier logic — the JSON-per-row
  parsing, the fullest-datafile sort, and the failure-path RCA/fallback
  branching — against mock data. All passed. What I *couldn't* test here:
  the actual SQL against a real Oracle instance, real ServiceNow API
  calls, or whether `close_code`'s enum values are customized on your
  specific instance (per your own lookup-first discipline — check
  `sys_choice` before trusting these). Worth a dry run against a
  throwaway PDB and a test CR before pointing it at anything real.

## Manual test of the playbook alone (no webhook needed)

```bash
cd ansible
ansible-playbook -i inventory.ini remediate_tablespace.yml \
  --extra-vars "change_number=CHG0000001 tablespace=USERS"
```

## Deploy the receiver on your own VM

```bash
sudo mkdir -p /opt/tablespace-demo/{ansible,logs}
cd /opt/tablespace-demo
# copy webhook_receiver.py, run_playbook.sh, requirements.txt, .env.example
# and the ansible/ directory here

python3 -m venv venv
./venv/bin/pip install -r requirements.txt
ansible-galaxy collection install servicenow.itsm

cp .env.example .env
python3 -c "import secrets; print(secrets.token_urlsafe(32))"   # paste into .env
chmod 600 .env
chmod +x run_playbook.sh

sudo cp tablespace-webhook.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now tablespace-webhook
curl http://localhost:8443/healthz     # {"status":"ok"}
```

Adjust `User=` in `tablespace-webhook.service` to whatever account actually
runs this on your box — it's currently a placeholder (`CHANGE_ME`).

Open port 8443 in your firewall/router for whatever's reaching this from
the outside (your ServiceNow instance, specifically), and put it behind a
free Cloudflare Tunnel or Caddy+Let's Encrypt reverse proxy so the call is
`https://`, not bare `http://`. Not strictly required for a demo, but the
shared secret is your *only* line of defense on plain HTTP — worth the
extra 15 minutes.

## Wire up the ServiceNow side

The cleanest trigger is a **Business Rule** on `change_request`, since
that's the table this whole flow revolves around:

1. **System Definition → Business Rules → New**
   - Table: `Change Request [change_request]`
   - When: `after`, on **update** (or **insert**, if the forecasting job
     creates CRs already in the right starting state for this to fire on)
   - Filter conditions: whatever marks a CR as "ready for auto-remediation"
     — e.g. a category or short_description pattern the forecasting job
     sets, so this doesn't fire on every unrelated CR your team creates.
2. **Advanced script** — build the JSON body and POST it:
   ```javascript
   (function executeRule(current, previous) {
       var body = {
           change_number: current.number.toString(),
           short_description: current.short_description.toString()
       };
       var r = new sn_ws.RESTMessageV2();
       r.setEndpoint('https://<your-vm>:8443/webhook/tablespace-remediate');
       r.setHttpMethod('POST');
       r.setRequestHeader('Content-Type', 'application/json');
       r.setRequestHeader('X-Webhook-Secret', '<the secret from your .env>');
       r.setRequestBody(JSON.stringify(body));
       r.executeAsync();  // don't block the transaction on our webhook
   })(current, previous);
   ```
   That's enough on its own — the receiver parses the tablespace name out
   of `short_description` if you don't add a dedicated field. If you'd
   rather add a real "Tablespace" field to the CR form later, just add
   `tablespace: current.u_tablespace.toString()` and it'll be preferred
   over the parsed guess.
3. Save, then test by moving a real CR into the trigger condition — check
   `journalctl -u tablespace-webhook -f` on the VM to watch it come in.

(If you'd rather use Flow Designer instead of a Business Rule, the shape
is the same: a trigger on the change_request table, an action that builds
the same JSON body, and a **REST — Send REST Message** or **Script** step
to POST it. Business Rule is simpler for a demo since it doesn't need a
separately-configured Outbound REST Message record.)

## Manual test (no ServiceNow needed)

```bash
curl -X POST https://<your-vm>:8443/webhook/tablespace-remediate \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Secret: <your secret>" \
  -d '{"change_number":"CHG0000001","tablespace":"USERS_TBS"}'
# -> 202 {"status":"triggered","change_number":"CHG0000001","tablespace":"USERS_TBS"}
```

Then check `/opt/tablespace-demo/logs/CHG0000001_*.log` for the Ansible run.

## Known simplification (fine for a demo, worth knowing)

The lock check in `run_playbook.sh` is check-then-write, not atomic — the
same pattern the DCR cron wrapper uses. There's a tiny race window if two
webhook calls for the *same CR* land within milliseconds of each other.
For a demo (or honestly for this workload in general) it's not worth the
extra complexity of `flock`/atomic `mkdir`, but flagging it rather than
pretending it isn't there.

## What's next

The remediation half is done. What's still missing is the **forecasting
job** — the piece that predicts the breach and opens the Change Request in
the first place (as a Standard, pre-approved type, with `assignment_group`
set), which is what actually triggers this whole chain.

Say the word and I'll build that next.
