# Oracle-SelfService

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

## Screenshots

**ServiceNow** — the nine workflows as a Service Catalog category
(*Database Automation Platform*), what a business user sees when
requesting work:

![ServiceNow Database Automation Platform catalog](screenshots/servicenow-catalog.png)

**Jira** — one project's board (*Migrate Code* / DCR) mid-run: work
sitting in **To Do** waiting on the poller, two issues already picked up
and sitting in **In Progress**:

![Jira DCR board](screenshots/jira-board.png)

## The nine DBA workflows

| Tag | Workflow | Approval | Jira playbook(s) | ServiceNow playbook(s) |
|---|---|---|---|---|
| **REF** | Refresh a lower environment from another environment | None | `REF_jira_oracle_schema_refresh.yml` + `_job.yml` | `SNOW_REF_oracle_schema_refresh.yml` + `_job.yml` |
| **DCR** | Data/code Change Request — run attached `.sql` script(s) | None | `DCR_jira_data_change.yml` | `SNOW_DCR_data_change.yml` |
| **CAU** | Create a new Oracle user across one or more target databases | Management | `CAU_jira_create_user.yml` | `SNOW_CAU_create_user.yml` |
| **CDP** | Reset a user's own Oracle password across every environment | None | `CDP_jira_reset_own_oracle_password.yml` | `SNOW_CDP_reset_own_oracle_password.yml` |
| **PAT** | Patch an Oracle home (real MOS/OPatch download + apply) | Management + CAB | `PAT_jira_oracle_patch.yml` + `_job.yml` | `SNOW_PAT_oracle_patch.yml` + `_job.yml` |
| **UPG** | Upgrade an Oracle database via AutoUpgrade | Management + CAB | `UPG_jira_oracle_upgrade.yml` + `_job.yml` | `SNOW_UPG_oracle_upgrade.yml` + `_job.yml` |
| **PDB** | Provision a new pluggable database | Management | `PDB_jira_create_pluggable_database.yml` | `SNOW_PDB_create_pluggable_database.yml` |
| **DDP** | Drop a pluggable database (destructive, double-confirmed) | Management + CAB | `DDP_jira_drop_pluggable_database.yml` + `ddp_process_issue.yml` | `DDP_drop_pluggable_database.yml` + `DDP_process_change.yml` |
| **PRF** | AWR-based performance analysis + SQL Tuning Advisor on a PDB | None for the analysis itself — a separate follow-up ticket gates approval before any tuning change is implemented | `PRF_jira_performance_analysis.yml` + `_job.yml` | `SNOW_PRF_performance_analysis.yml` + `_job.yml` |

Every workflow shares the same shape: **shepherd the intake queue → find
approved work → do the Oracle work → write evidence back → transition the
ticket → open a DBA follow-up on failure.**

### Ticket formats

**Jira** — submitted through the imported Jira forms (custom fields per
project); each playbook only picks up issues that have already reached
**In Progress** (i.e., cleared approval).

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
normal approval before it will touch anything.

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
COMMON_*.yml                 Shared includes (both backends)
  jira_shepherd_statuses.yml       generic Jira approval-gate walk
  jira_create_followup_task.yml    opens a DBA repair task on failure
  snow_intake.yml                  shared short_description parsing + state walk
  snow_create_followup.yml         opens a DBA repair CR on failure
  snow_itil_classify.yml           CI linkage, risk/impact, FSC window
  snow_cost_check.yml              budget gate (>$10 one-time or >$1/mo & >6mo)
  orchestration_gate_check.yml     pre-dependency gate (pilot — see below)
  orchestration_spawn_step.yml     creates a dependent CR (pilot)
  orchestration_fire_post.yml      post-dependency fan-out (pilot)

<TAG>_jira_*.yml              Jira-side playbook for each of the nine workflows
<TAG>_jira_cron_wrapper.sh    PID-locked cron wrapper for the Jira playbook
SNOW_<TAG>_*.yml              ServiceNow-side playbook for each workflow
<TAG>_snow_cron_wrapper.sh    PID-locked cron wrapper for the ServiceNow playbook

SNOW_CAUPG_create_postgres_user.yml       PostgreSQL/Aurora pilot (see below)
SNOW_CDPPG_reset_postgres_password.yml    PostgreSQL/Aurora pilot (see below)
create_test_postgres_rds.sh / delete_test_postgres_rds.sh   throwaway RDS instance for pilot testing

SNOW_sync_oracle_targets.yml       syncs real PDBs into a ServiceNow reference table (feeds PRF's dropdown)
SNOW_cleanup_followup_crs.yml      dry-run-by-default cleanup of duplicate follow-up CRs
SNOW_DCR_diag_*.yml                 one-off diagnostic playbooks used while debugging the CR state walk — safe to delete
TEST_jira_1000_tasks.attachments.random.yml   bulk test-data generator (1,000 DCR issues)
CR_snow_create.yml                  scratch/example CR-creation snippet

vars/main.yml                 All variables (Jira + ServiceNow creds, oracle_instance_map, etc.) — gitignored, keep local
VARS_ADDITIONS_REQUIRED.yml   Reference block of additive vars/main.yml keys the orchestration pilot needs
hosts / inventory / ansible.cfg   Ansible control-node config
```

### Naming quirk worth knowing

Jira-side files are named `<TAG>_jira_*.yml`; ServiceNow-side files are
named `SNOW_<TAG>_*.yml` (prefix, not suffix). This is a leftover of build
order, not a convention change — both are correct, active files.

### Known stale/incomplete items

- `CAU_jira_oracle_create_user_self.yml` is a superseded duplicate of
  `CAU_jira_create_user.yml` (hardcodes a custom field ID instead of using
  the parameterized var). Kept for reference only — do not schedule it.
- There is no `DDP_jira_cron_wrapper.sh` yet; the ServiceNow side of DDP
  is cron-wrapped, the Jira side currently needs to be invoked manually or
  wrapped before adding it to cron.
- `vars/main.yml` is currently plaintext (gitignored, never committed) —
  encrypting it with Ansible Vault is a recommended next step before
  production use.

## Getting started

**Dependencies:**
1. A Jira Cloud site (URL, username, API token) and/or a ServiceNow
   instance (URL, a service account with the `itil` role) — you don't need
   both, pick the backend(s) you want to run.
2. An Ansible control node (Linux; this suite assumes `/etc/ansible` owned
   by an `ansible_admin` OS user). Built and tested on Ansible 2.16–2.21.
3. One or more Oracle databases to manage — built and tested against
   Oracle Enterprise Edition on Oracle Linux, container databases (CDBs)
   with one or more pluggable databases (PDBs).
4. For the ServiceNow `servicenow.itsm` collection and the Postgres pilot:
   `ansible-galaxy collection install servicenow.itsm`, and `psycopg2` on
   the control node for the Postgres playbooks.

**Installation:**
1. Clone this repo onto your Ansible control node's `/etc/ansible`.
2. If using Jira: import the Jira site export (forms/dashboards) into your
   Jira Cloud instance — see Atlassian's [partial/selective import
   guide](https://support.atlassian.com/atlassian-cloud/kb/partial-or-selective-import-of-a-jira-backup-export-into-jira-cloud/).
3. If using ServiceNow: build the record producers / catalog category and
   the `u_u_oracle_target` reference table (used by PRF) on your instance,
   and grant the four base ACLs (read/write/create/delete) on any new
   custom tables.
4. Build your own `vars/main.yml` (it's gitignored, so it isn't in this
   repo) using `VARS_ADDITIONS_REQUIRED.yml` as a reference for the
   orchestration-pilot keys, plus your own Jira/ServiceNow credentials,
   `oracle_instance_map`, and (if using the Postgres pilot)
   `pg_environments`.
5. Update `hosts`, `inventory`, and `ansible.cfg` to match your
   environment.
6. Schedule the cron wrappers you need. Typical cadences used in
   development:

   ```
   # Jira
   */1 * * * * /etc/ansible/DCR_jira_cron_wrapper.sh >> /tmp/cron.JIRA.DCR.log 2>&1
   */1 * * * * /etc/ansible/CAU_jira_cron_wrapper.sh >> /tmp/cron.JIRA.CAU.log 2>&1
   */1 * * * * /etc/ansible/CDP_jira_cron_wrapper.sh >> /tmp/cron.JIRA.CDP.log 2>&1
   */1 * * * * /etc/ansible/REF_jira_cron_wrapper.sh >> /tmp/cron.JIRA.REF.log 2>&1
   */5 * * * * /etc/ansible/PDB_jira_cron_wrapper.sh >> /tmp/cron.JIRA.PDB.log 2>&1
   */5 * * * * /etc/ansible/PRF_jira_cron_wrapper.sh >> /tmp/cron.JIRA.PRF.log 2>&1
   0 * * * *   /etc/ansible/PAT_jira_cron_wrapper.sh >> /tmp/cron.JIRA.PAT.log 2>&1
   0 0 * * *   /etc/ansible/UPG_jira_cron_wrapper.sh >> /tmp/cron.JIRA.UPG.log 2>&1

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
   frequently than the fast, low-risk ones by design.
7. After testing, encrypt `vars/main.yml` with `ansible-vault` and update
   the cron entries to pass `--vault-password-file`, e.g.:

   ```
   */1 * * * * ansible-playbook DCR_jira_data_change.yml --vault-password-file /etc/ansible/.vault_pass >> /tmp/cron.DCR.log 2>&1
   ```

### Log layout

Each Jira project writes evidence under its own directory on the control
node, e.g.:

```
/home/ansible_admin/
├── jira_cau/logs
├── jira_cdp/logs
├── jira_dcr/logs
├── jira_pat/logs
├── jira_ref/logs
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

0.3

## License

MIT License — see [LICENSE](LICENSE).
