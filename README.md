# Oracle-SelfService

For demo refer to [Replayable: Replay Your IT](https://r-able.com).

Check out the [GitHub Docs](https://docs.github.com) for more information.
Ansible-driven, closed-loop self-service automation for routine Oracle DBA
work. Business users open a ticket — in **Jira Cloud** or **ServiceNow** —
describing what they need (a new user, a password reset, a schema refresh,
a new pluggable database, a patch, an upgrade, a performance review, or a
destructive drop). An Ansible control node polls both ticketing systems on
a cron schedule, waits for the ticket to clear approval, executes the work
directly against the target Oracle database(s), writes the evidence back
onto the ticket, and transitions it to **Done**/**Closed** or **Failed** —
opening a DBA repair follow-up automatically on failure.

The two backends (Jira and ServiceNow) are independent, parallel
implementations of the **same nine DBA workflows**, kept behaviorally
consistent on purpose so a site can run either one, or both side by side
during a migration.

A small **PostgreSQL/Aurora RDS pilot** (ServiceNow only, two of the nine
workflows) and an early **cross-domain orchestration layer** (ServiceNow
only, one workflow) are also included — see below.

> **Aug 2026 rebuild.** After a snapshot restore, every Jira-side project
> turned out to be wired to one fixed database/host rather than reading
> what the ticket actually asked for — some had never been wired up at
> all. All nine Jira workflows were reviewed against their ServiceNow
> counterpart and rebuilt to resolve host/database dynamically per ticket,
> live-synced from `oracle_instance_map` rather than fixed at write time.
> See **"The Aug 2026 Jira rebuild"** below for what changed in each one.
> The ServiceNow side was not touched and is unaffected.

## The nine DBA workflows

| Tag | Workflow | Approval | Jira playbook(s) | ServiceNow playbook(s) |
|---|---|---|---|---|
| **REF** | Refresh a lower environment from another environment, any environment to any environment, cross-host | None | `JIRA_REF_oracle_schema_refresh.yml` + `_job.yml` | `SNOW_REF_oracle_schema_refresh.yml` + `_job.yml` |
| **DCR** | Data/code Change Request — run attached `.sql` script(s) against a chosen database | None | `JIRA_DCR_data_change.yml` | `SNOW_DCR_data_change.yml` |
| **CAU** | Create a new Oracle user across one or more target host:PDB combinations | Management | `JIRA_CAU_create_user.yml` | `SNOW_CAU_create_user.yml` |
| **CDP** | Reset a user's own Oracle password in one chosen host:database | None | `JIRA_CDP_reset_own_oracle_password.yml` | `SNOW_CDP_reset_own_oracle_password.yml` |
| **PAT** | Patch an Oracle home (real MOS/OPatch download + apply) | Management + CAB | `JIRA_PAT_oracle_patch.yml` + `_job.yml` | `SNOW_PAT_oracle_patch.yml` + `_job.yml` |
| **UPG** | Upgrade an Oracle database via AutoUpgrade | Management + CAB | `JIRA_UPG_oracle_upgrade.yml` + `_job.yml` | `SNOW_UPG_oracle_upgrade.yml` + `_job.yml` |
| **PDB** | Provision a new pluggable database in a chosen host:CDB | Management | `JIRA_PDB_create_pluggable_database.yml` | `SNOW_PDB_create_pluggable_database.yml` |
| **DDP** | Drop a pluggable database (destructive, double-confirmed) | Management + CAB | `JIRA_DDP_drop_pluggable_database.yml` | `DDP_drop_pluggable_database.yml` + `DDP_process_change.yml` |
| **PRF** | AWR-based performance analysis + SQL Tuning Advisor on a PDB | None for the analysis itself — a separate follow-up ticket gates approval before any tuning change is implemented | `JIRA_PRF_performance_analysis.yml` + `_job.yml` | `SNOW_PRF_performance_analysis.yml` + `_job.yml` |

Every workflow shares the same shape: **shepherd the intake queue → find
approved work → do the Oracle work → write evidence back → transition the
ticket → open a DBA follow-up on failure.**

### Ticket formats

**Jira** — submitted through discrete custom fields on the imported Jira
forms (not free text); each playbook only picks up issues that have
already reached **In Progress** (i.e., cleared approval). Field IDs are
never hardcoded — every playbook resolves its fields by exact display
name at runtime (`COMMON_jira_resolve_field.yml`), and fails loudly with
a full field-name dump if a name doesn't match, rather than silently
reading the wrong field. See **"Jira dynamic field reference"** below for
the full list of fields, which are live-synced, and which sync job feeds
each one.

| Tag | Jira fields |
|---|---|
| REF | Source Schema, Target Schema (each `host:PDB:schema`) |
| DCR | Database Instance (`host:PDB`), attached `.sql` script(s) |
| CAU | Target Databases (multi-select, `host:PDB` each), user picker, approver picker |
| CDP | Server:database (`host:PDB`), reporter supplies the username |
| PAT | Target Host & Container (CDB) (`host:CDB`), patch number (dedicated field or parsed from summary) |
| UPG | Target Host & Container (CDB) (`host:CDB`) |
| PDB | Target Host & Container (CDB) (`host:CDB`), New pluggable database name (free text) |
| DDP | Database Instance (`host:PDB`), Confirm Drop (free text, must read exactly `CONFIRM DROP <PDB_NAME>`) |
| PRF | Database Instance (`host:PDB`), Analysis Start, Analysis End (Date Time Picker) |

**ServiceNow** — all nine workflows share the single `change_request`
table. Each project finds its own work by a `short_description` prefix,
parsed by `COMMON_snow_intake.yml`:

```
REF | PROD:DEV                     (legacy long form: PRO:HR=>UAT:HR_COPY)
DCR | <free title>                 (.sql scripts attached to the CR)
CAU | Vlad Grigorian | PROD,DEV,SIT
CDP | Vlad Grigorian
PAT | lnx001:CDB1 | 234234234      (host:SID | patch number)
UPG | CDB1
PDB | lnx001 | CDB1 | TSTPDB01     (host | CDB | new PDB name)
DDP | lnx001 | CDB1 | TSTPDB01     (host | CDB | PDB to drop — see below)
PRF | lnx001 | TSTPDB01 | <start datetime> | <end datetime>
```

`DDP` is intentionally never a loop over multiple databases the way `CDP`
and `CAU` can be — dropping a database is single-target only, and requires
a literal `CONFIRM DROP <PDB_NAME>` string on the ticket in addition to
normal approval before it will touch anything (on the Jira side this
string goes in a dedicated **Confirm Drop** field, not the issue
description — a plain-text field beats free text buried in a
general-purpose box that's easy to miss or mistype into the wrong place).

## The Aug 2026 Jira rebuild

Every Jira project below was reviewed against its ServiceNow counterpart
and, where they'd drifted, brought back into parity. All nine now resolve
their target host(s)/database(s) **per ticket**, live, rather than
assuming a fixed database written into the playbook.

| Tag | What was wrong | What changed |
|---|---|---|
| **DCR** | Always ran against one fixed `ORCLPDB`, ignoring the form's "Choose Database" field entirely | Reads **Database Instance** (`host:PDB`) and connects dynamically via `oracle_instance_map` |
| **REF** | Assumed the source was always PROD and the only host was `lnx001` | Rebuilt for genuine cross-host, any-to-any refreshes via a live `NETWORK_LINK` database-link import (no dump file) — ported from ServiceNow's proven design. Settled on 2 fields (**Source Schema**, **Target Schema**, each fully-qualified `host:PDB:schema`) after an initial 4-field version proved awkward: Jira's plain select fields can't cascade the way ServiceNow's reference fields can, so 2 fields removes the mismatch possibility outright instead of just detecting it |
| **PDB** | Never actually existed — its cron wrapper pointed at the wrong playbook (a copy-paste leftover) | Built from scratch, ported from ServiceNow's `CREATE PLUGGABLE DATABASE` logic (OMF/`FILE_NAME_CONVERT` handling, admin password posted in a separate confidential comment, never mixed with evidence) |
| **CDP** | Looped over *every* environment on one fixed host for every request | Rewritten to target exactly **one** `host:database` per request (**Server:database**), matching ServiceNow's documented model |
| **DDP** | Five real, confirmed bugs: fixed single host; hardcoded placeholder field IDs never verified against a real instance; called a `COMMON_jira_transition_issue.yml` include that doesn't exist anywhere in this repo; called the follow-up-task include with the wrong variable names; uploaded evidence as a non-multipart file POST (Jira's API requires multipart) | Fully rewritten and consolidated into one file. Reuses **Database Instance**; added a dedicated **Confirm Drop** field (not the issue description, which returns JSON `null` rather than empty when unset — a real Jinja gotcha worth remembering elsewhere); all protective gates (protected-PDB block list, pre-drop snapshot, confirmation match) preserved |
| **PAT** | Target-host field ID was a hardcoded placeholder (`customfield_10500`, per its own comment "adjust to your field ID") never actually verified | Field now resolved by name, pointed at **Target Host & Container (CDB)** — the same field PDB already populates |
| **CAU** | Still on ServiceNow's *old*, already-superseded design: a fixed 6-environment checkbox list on one implicit host | Rewritten to match ServiceNow's own redesign: a multi-select **Target Databases** field (`host:PDB` each), so one request can create a user across several hosts/PDBs at once. Unrecognized hosts are deliberately *not* filtered at parse time — they fail loudly per-target at the connection attempt instead of silently vanishing |
| **PRF** | Never existed — same wrapper-points-nowhere gap as PDB | Built from scratch, ported from ServiceNow's AWR snapshot-resolution → report → top-5-SQL → Tuning Advisor pipeline. Reuses **Database Instance**; added **Analysis Start**/**Analysis End** (Date Time Picker). First use of real Jira file attachments (multipart upload) in this repo, since AWR/tuning output can run 50–200KB+, too large for a comment. **Timezone caveat:** Jira's Date/Time Picker records the reporter's browser timezone, not necessarily the Oracle server's — no conversion is attempted, confirm this is a non-issue for your organization |
| **UPG** | Same fixed-host bug as the others, shared with the ServiceNow version (the ticket's host was parsed but never actually used) — never surfaced because only one 26ai-capable host has existed so far | Reuses **Target Host & Container (CDB)**; the one-time 26ai-install pre-flight check moved from a single blanket check to running per-job against that job's own target host |

A recurring class of bug worth remembering if you touch any of this code:
Ansible's `| default(x)` filter only substitutes for a genuinely
**undefined** Jinja value — a Jira field returned as JSON `null` sails
straight through untouched and can crash a later filter, or silently
render as the literal text `"None"`. Use the boolean form,
`| default(x, true)`, on any raw field read that might come back
`null`. Several of the rebuilds above hit this; it's now fixed
everywhere it was found, but it's an easy trap to reintroduce.

## Jira dynamic field reference

Nine of these fields are now kept live by three sync playbooks, instead
of being populated once by hand:

| Field | Type | Used by | Synced by |
|---|---|---|---|
| Database Instance | Select (single) | DCR, DDP, PRF | `JIRA_sync_oracle_targets.yml` |
| Server:database | Select (single) | CDP | `JIRA_sync_oracle_targets.yml` |
| Target Databases | Select (multi) | CAU | `JIRA_sync_oracle_targets.yml` |
| Source Schema / Target Schema | Select (single) | REF | `JIRA_sync_oracle_schemas.yml` |
| Target Host & Container (CDB) | Select (single) | PDB, PAT, UPG | `JIRA_sync_oracle_hosts.yml` |
| New pluggable database name | Short text | PDB | — (free text, not synced) |
| Confirm Drop | Short text | DDP | — (free text, not synced) |
| Analysis Start / Analysis End | Date Time Picker | PRF | — (picked per-ticket, not synced) |

- **`JIRA_sync_oracle_targets.yml`** (cron `*/1`) — discovers real, open
  PDBs on every host via `v$pdbs` and syncs `host:PDB` labels
  (e.g. `lnx001:DEV`) into every field in `jira_target_field_names`.
- **`JIRA_sync_oracle_schemas.yml`** (cron `*/15`) — discovers real
  (non-Oracle-maintained) schemas per PDB via `dba_users` and syncs flat
  `host:PDB:schema` labels (e.g. `lnx001:DEV:HR`) — flat rather than
  cascading, since Jira's plain select fields can't filter off another
  field's value without Automation or a paid app.
- **`JIRA_sync_oracle_hosts.yml`** (cron `*/30`, or run manually after
  editing `oracle_instance_map`) — the simplest of the three: no live SQL
  at all, it's a direct reflection of `oracle_instance_map` itself
  (`host:CDB`, e.g. `lnx001:CDB1`).

All three share `COMMON_jira_sync_field_options.yml`, which creates
missing options and disables (never deletes) stale ones, with
host-aware staleness protection — an unreachable host during a given sync
run never causes its still-valid options to be disabled just because it
contributed nothing that pass.

Adding the same live picker to a new field anywhere is just adding its
name to the relevant `jira_*_field_names` list in `vars/main.yml` — no
new sync job needed unless the field needs a genuinely new granularity
(host-only, host:PDB, or host:PDB:schema are the three currently
supported).

## Ticket lifecycle

**Jira:**

```
To Do → Pending Approval → In Progress (all approvals = approved)
                          → Rejected  (any approval rejected)
In Progress → Done (success) | Failed (failure, opens a DBA follow-up task)
```

Handled generically for every project by the shared
`COMMON_jira_shepherd_statuses.yml` — it doesn't need per-project
knowledge of what "approved" means, just that every entry in the issue's
approvals field has `finalDecision == approved`.

**ServiceNow:**

```
Standard-type CRs (no approval):  New → Scheduled → Implement → Review → Closed
Normal-type CRs (approval gate):  New → Assess → Authorize → Scheduled → Implement → Review → Closed
```

Both success *and* failure always walk the full chain to **Closed** —
never a direct jump — because the Change Model's own state-transition
rules reject a skip and the ticket would otherwise silently re-enter the
polling queue every cron pass. A failure opens a DBA repair follow-up CR,
assigned to the DBA group with no individual owner (so automation never
re-picks its own follow-up as new work).

## Repo layout

```
COMMON_*.yml                        Shared includes (both backends)
  jira_shepherd_statuses.yml              generic Jira approval-gate walk
  jira_create_followup_task.yml           opens a DBA repair task on failure
  jira_resolve_field.yml                  resolves a customfield_XXXXX ID by exact display name
  jira_sync_field_options.yml             shared create/disable logic for the three sync playbooks below
  snow_intake.yml                         shared short_description parsing + state walk
  snow_create_followup.yml                opens a DBA repair CR on failure
  snow_itil_classify.yml                  CI linkage, risk/impact, FSC window
  snow_cost_check.yml                     budget gate (>$10 one-time or >$1/mo & >6mo)
  orchestration_gate_check.yml            pre-dependency gate (pilot — see below)
  orchestration_spawn_step.yml            creates a dependent CR (pilot)
  orchestration_fire_post.yml             post-dependency fan-out (pilot)

JIRA_<TAG>_*.yml               Jira-side playbook for each of the nine workflows
JIRA_<TAG>_cron_wrapper.sh     PID-locked cron wrapper for the Jira playbook
JIRA_sync_oracle_targets.yml / _schemas.yml / _hosts.yml   live field-option sync (see above)
JIRA_sync_oracle_*_cron_wrapper.sh                          PID-locked wrappers for the three sync playbooks

SNOW_<TAG>_*.yml               ServiceNow-side playbook for each workflow
<TAG>_snow_cron_wrapper.sh     PID-locked cron wrapper for the ServiceNow playbook

SNOW_CAUPG_create_postgres_user.yml       PostgreSQL/Aurora pilot (see below)
SNOW_CDPPG_reset_postgres_password.yml    PostgreSQL/Aurora pilot (see below)
create_test_postgres_rds.sh / delete_test_postgres_rds.sh   throwaway RDS instance for pilot testing

SNOW_sync_oracle_targets.yml / _schemas.yml / _hosts.yml   ServiceNow-side equivalents (feed u_oracle_target etc., used by REF/PAT/PRF's reference fields)
SNOW_cleanup_followup_crs.yml       dry-run-by-default cleanup of duplicate follow-up CRs
SNOW_DCR_diag_*.yml                  one-off diagnostic playbooks used while debugging the CR state walk — safe to delete
TEST_jira_1000_tasks.attachments.random.yml   bulk test-data generator (1,000 DCR issues) — deliberately left out of the JIRA_ rename, it's a test utility, not a project

fix_lnx_networking.sh          standalone script for a recurring lnx002 issue — see "Known operational notes" below

vars/main.yml                  All variables (Jira + ServiceNow creds, oracle_instance_map, etc.) — gitignored, keep local
VARS_ADDITIONS_REQUIRED.yml    Reference block of additive vars/main.yml keys the orchestration pilot needs
hosts / inventory / ansible.cfg   Ansible control-node config
```

### Naming convention

Every Jira-side file now uses the `JIRA_<TAG>_<function>.yml` /
`JIRA_<TAG>_cron_wrapper.sh` pattern, mirroring ServiceNow's
`SNOW_<TAG>_<function>.yml` exactly. Earlier versions of this repo used
`<TAG>_jira_*.yml` (tag first, prefix second) — if you have local scripts,
crontabs, or documentation referencing the old names, they'll need
updating; every in-repo cross-reference (wrapper `PLAYBOOK=` lines,
`include_tasks:` paths) has already been updated to the new names.

### Known stale/incomplete items

- `JIRA_CAU_oracle_create_user_self.yml` is a superseded duplicate of
  `JIRA_CAU_create_user.yml` (hardcodes a custom field ID instead of using
  the parameterized, name-resolved var). Kept for reference only — do not
  schedule it.
- `vars/main.yml` is currently plaintext (gitignored, never committed) —
  encrypting it with Ansible Vault is a recommended next step before
  production use. It also currently has a few duplicate mapping keys
  (harmless — YAML silently keeps the last value — but worth cleaning up
  for clarity): `oracle_dba_user`, `oracle_dba_pass`, and
  `jira_target_field_names` are each defined more than once.

## Known operational notes

- **lnx002 has a recurring networking issue** (roughly every few months,
  typically after a snapshot restore): NetworkManager's global
  `NetworkingEnabled` flag gets persisted as `false`
  (`/var/lib/NetworkManager/NetworkManager.state`), which marks every
  interface unmanaged/no-carrier even though the underlying `ifcfg`
  profiles are correct. Root-caused and confirmed fixed with
  `nmcli networking on` as root. `fix_lnx_networking.sh` (in this repo)
  checks and fixes the global flag, verifies the expected interface
  actually comes back up with its expected IP, and falls back to a
  vCenter/ESXi portgroup checklist if the flag alone doesn't resolve it —
  copy it onto the affected host and re-run whenever this recurs.
- **Jira service account:** the automation account needs Jira's global
  **"Administer Jira"** permission, not just project-level access — field
  *context*/option management (what the three sync playbooks do) 403s
  without it, even for an account that can otherwise fully administer the
  target projects. Confirm this before assuming a 403 means something
  else is wrong.
- **Team-managed ("Space") Jira projects cannot use classic field-context
  API calls on their own local fields** — a field created inside a
  team-managed project's own "Fields" screen has no queryable context and
  will 404 on `/rest/api/3/field/{id}/context`. The fix used throughout
  this rebuild: create the field as a **global** field (Jira admin →
  Work items → Fields → Create new field) and explicitly add it to the
  team-managed project afterward (Space settings → Fields → Add field,
  then Space settings → Work types → Task → drag it into Context fields,
  then add it to the Forms builder) — three separate attachment steps,
  each of which is silently a no-op if skipped.

## Getting started

**Dependencies:**
1. A Jira Cloud site (URL, username, API token) and/or a ServiceNow
   instance (URL, a service account with the `itil` role) — you don't need
   both, pick the backend(s) you want to run. The Jira service account
   additionally needs the global **Administer Jira** permission — see
   "Known operational notes" above.
2. An Ansible control node (Linux; this suite assumes `/etc/ansible` owned
   by an `ansible_admin` OS user). Built and tested on Ansible 2.16–2.21.
3. One or more Oracle databases to manage — built and tested against
   Oracle Enterprise Edition on Oracle Linux, container databases (CDBs)
   with one or more pluggable databases (PDBs), declared in
   `oracle_instance_map`.
4. For the ServiceNow `servicenow.itsm` collection and the Postgres pilot:
   `ansible-galaxy collection install servicenow.itsm`, and `psycopg2` on
   the control node for the Postgres playbooks. For every Jira workflow:
   `ansible-galaxy collection install community.general`.

**Installation:**
1. Clone this repo onto your Ansible control node's `/etc/ansible`.
2. If using Jira: import the Jira site export (forms/dashboards) into your
   Jira Cloud instance — see Atlassian's [partial/selective import
   guide](https://support.atlassian.com/atlassian-cloud/kb/partial-or-selective-import-of-a-jira-backup-export-into-jira-cloud/) —
   then create the nine fields in **"Jira dynamic field reference"**
   above as **global** fields and attach each to its project(s) (see
   "Known operational notes" for the three-step attachment gotcha on
   team-managed projects).
3. If using ServiceNow: build the record producers / catalog category and
   the `u_u_oracle_target` reference table (used by REF/PAT/PRF), and
   grant the four base ACLs (read/write/create/delete) on any new
   custom tables.
4. Build your own `vars/main.yml` (it's gitignored, so it isn't in this
   repo) using `VARS_ADDITIONS_REQUIRED.yml` as a reference for the
   orchestration-pilot keys, plus your own Jira/ServiceNow credentials,
   `oracle_instance_map`, every `jira_*_field_name` var listed in "Jira
   dynamic field reference", and (if using the Postgres pilot)
   `pg_environments`.
5. Update `hosts`, `inventory`, and `ansible.cfg` to match your
   environment.
6. Run each `JIRA_sync_oracle_*.yml` playbook once by hand to seed the
   fields with live data before testing any project against a real
   ticket.
7. Schedule the cron wrappers you need. Typical cadences used in
   development:

   ```
   # Jira - sync jobs (keep dropdown options live)
   */1  * * * * /etc/ansible/JIRA_sync_oracle_targets_cron_wrapper.sh >> /tmp/cron.sync_oracle_targets.jira.log 2>&1
   */15 * * * * /etc/ansible/JIRA_sync_oracle_schemas_cron_wrapper.sh >> /tmp/cron.sync_oracle_schemas.jira.log 2>&1
   */30 * * * * /etc/ansible/JIRA_sync_oracle_hosts_cron_wrapper.sh   >> /tmp/cron.sync_oracle_hosts.jira.log 2>&1

   # Jira - the nine workflows
   */1 * * * * /etc/ansible/JIRA_DCR_cron_wrapper.sh >> /tmp/cron.JIRA.DCR.log 2>&1
   */1 * * * * /etc/ansible/JIRA_CAU_cron_wrapper.sh >> /tmp/cron.JIRA.CAU.log 2>&1
   */1 * * * * /etc/ansible/JIRA_CDP_cron_wrapper.sh >> /tmp/cron.JIRA.CDP.log 2>&1
   */1 * * * * /etc/ansible/JIRA_REF_cron_wrapper.sh >> /tmp/cron.JIRA.REF.log 2>&1
   */1 * * * * /etc/ansible/JIRA_PDB_cron_wrapper.sh >> /tmp/cron.JIRA.PDB.log 2>&1
   */1 * * * * /etc/ansible/JIRA_PRF_cron_wrapper.sh >> /tmp/cron.JIRA.PRF.log 2>&1
   *   * * * * /etc/ansible/JIRA_DDP_cron_wrapper.sh >> /tmp/cron.JIRA.DDP.log 2>&1   # see caution below
   0   * * * * /etc/ansible/JIRA_PAT_cron_wrapper.sh >> /tmp/cron.JIRA.PAT.log 2>&1
   0 0 * * *   /etc/ansible/JIRA_UPG_cron_wrapper.sh >> /tmp/cron.JIRA.UPG.log 2>&1

   # ServiceNow
   */1 * * * * /etc/ansible/DCR_snow_cron_wrapper.sh >> /tmp/cron.SNOW.DCR.log 2>&1
   */1 * * * * /etc/ansible/CAU_snow_cron_wrapper.sh >> /tmp/cron.SNOW.CAU.log 2>&1
   */1 * * * * /etc/ansible/CDP_snow_cron_wrapper.sh >> /tmp/cron.SNOW.CDP.log 2>&1
   */1 * * * * /etc/ansible/REF_snow_cron_wrapper.sh >> /tmp/cron.SNOW.REF.log 2>&1
   */1 * * * * /etc/ansible/PDB_snow_cron_wrapper.sh >> /tmp/cron.SNOW.PDB.log 2>&1
   */1 * * * * /etc/ansible/DDP_snow_cron_wrapper.sh >> /tmp/cron.SNOW.DDP.log 2>&1
   */5 * * * * /etc/ansible/PRF_snow_cron_wrapper.sh >> /tmp/cron.SNOW.PRF.log 2>&1
   0 * * * *   /etc/ansible/PAT_snow_cron_wrapper.sh >> /tmp/cron.SNOW.PAT.log 2>&1
   0 * * * *   /etc/ansible/UPG_snow_cron_wrapper.sh >> /tmp/cron.SNOW.UPG.log 2>&1
   ```

   Adjust cadence to taste — patch/upgrade projects poll far less
   frequently than the fast, low-risk ones by design. **DDP performs an
   irreversible, destructive action** — consider starting it at a slower
   cadence, or manual-only, until you're confident its safety gates
   (protected-PDB list, required confirmation string, pre-drop snapshot)
   hold up in practice, before matching the `*/1` cadence of the others.
8. After testing, encrypt `vars/main.yml` with `ansible-vault` and update
   the cron entries to pass `--vault-password-file`, e.g.:

   ```
   */1 * * * * ansible-playbook JIRA_DCR_data_change.yml --vault-password-file /etc/ansible/.vault_pass >> /tmp/cron.DCR.log 2>&1
   ```

### Log layout

Each Jira project writes evidence under its own directory on the control
node, e.g.:

```
/home/ansible_admin/
├── jira_cau/logs
├── jira_cdp/logs
├── jira_dcr/logs
├── jira_ddp/logs
├── jira_pat/logs
├── jira_pdb/logs
├── jira_prf/logs
├── jira_ref/logs
├── jira_sync_oracle_hosts/logs
├── jira_sync_oracle_schemas/logs
├── jira_sync_oracle_targets/logs
└── jira_upg/logs
```

## PostgreSQL / Aurora RDS pilot (ServiceNow only)

A scoped proof of concept extending two of the nine workflows —
**CAUPG** (create user) and **CDPPG** (reset password) — to PostgreSQL on
AWS Aurora/RDS, validated end-to-end against a real throwaway RDS
instance. Distinct tags keep this pilot fully isolated from the
production Oracle CAU/CDP projects. Genuine architectural differences
from the Oracle versions, not a find-and-replace port:

- PostgreSQL roles are **cluster-wide**, not per-database, so the loop is
  (user × environment) rather than (user × database-within-a-host).
- Each environment has its own endpoint/port/master credentials — there's
  no single shared host the way Oracle's `oracle_instance_map` assumes.
- Usernames are lower-case by Postgres convention, not upper-case like
  Oracle.

`create_test_postgres_rds.sh` / `delete_test_postgres_rds.sh` spin up and
tear down the cheapest realistic `db.t4g.micro` instance for testing.
The remaining seven workflows (and other database engines) are not yet
ported — several of them (PDB, PAT, PRF) don't translate directly to a
fully-managed RDS/Aurora target and would need real redesign, not a port.

## Orchestration layer (early pilot, ServiceNow + PAT only)

`COMMON_orchestration_gate_check.yml`, `_spawn_step.yml`, and
`_fire_post.yml` add an optional cross-domain dependency layer on top of
the normal approval gate: a hand-maintained `dependency_registry` (see
`VARS_ADDITIONS_REQUIRED.yml`) can declare that a change on one CI must
wait for another CI's change to close first (`pre`), or should trigger a
follow-on change once it succeeds (`post`). Currently wired into **PAT**
only, as the first integration; with an empty `dependency_registry` it's
a complete no-op and every project runs exactly as it did before.

## ITIL compliance

All nine ServiceNow workflows call `COMMON_snow_itil_classify.yml` for
CMDB CI linkage, risk/impact classification, and a planned start/end
(Forward Schedule of Change) window, and `COMMON_snow_cost_check.yml` for
a budget-approval gate on any project with a real cost driver. Both are
purely additive and never touch approval/state-transition logic.

## Author

Vlad von Grigorian
[@GRIGORIANV](https://github.com/GRIGORIANV)
grigorianvlad@gmail.com

## Version

0.4

## License

MIT License — see [LICENSE](LICENSE).
