# Database Automation Platform — PDI → Production Migration Runbook

## Why this exists, and its one big caveat

ServiceNow's normal migration mechanism is the **Update Set**, but Update
Sets only capture changes made *while actively recording*. Nothing built
today was created inside an active update set, so there is no one-click
export waiting for us. Instead, this runbook replays the actual sequence
of background scripts (all written to be idempotent/safe to re-run) plus
the handful of steps that were only ever done by hand in the UI.

**Read this whole document once before running anything.** Some scripts
listed here were later superseded by a manual UI edit (Catalog Item
Versioning blocked a few script-based writes on the PDI) — those are
called out explicitly so you don't replay a script that will silently
have no effect on production.

---

## Prerequisites on production before starting

- [ ] `hyperautomation.platform` service account exists with the `itil` role
- [ ] `sn_instance` / `sn_username` / `sn_password` in the production
      copy of `vars/main.yml` point at production, not the PDI
- [ ] `oracle_instance_map` and other vars in `vars/main.yml` reflect
      production's real hosts (this was never a PDI-only value, but
      worth double-checking before any playbook runs against production
      databases)
- [ ] All 9 `SNOW_*.yml` / `COMMON_*.yml` playbook files are copied to
      the production Ansible controller, including today's approval-level
      edits (COMMON_snow_intake.yml, SNOW_PDB_*, SNOW_DCR_*, and the 5
      dispatchers with `sn_type` set)

---

## Phase 1 — Foundation (run in this exact order)

Each of these is a background script (System Definition → Scripts -
Background). Run them one at a time, confirm no errors in the output,
then move to the next.

1. **`DBA_Automation_Catalog_Setup.js`**
   Creates the category, the `DBAAutomationRouting` Script Include, and
   the original 8 record producers (PDB/DDP/DCR/REF/CAU/PAT/CDP/UPG).

2. **`DBA_Automation_Catalog_Visibility_Fix.js`**
   Re-homes the category onto the instance's real default catalog so it
   actually appears under Self-Service → Service Catalog.
   ⚠️ Production's default-catalog sys_id will almost certainly be
   **different** from the PDI's (`e0d08b13c3330100c8b837659bba8fb4`).
   Look this up fresh on production before running — don't reuse the
   PDI's sys_id.

3. **`DBA_Automation_Fix_SpecText_Type.js`**
   Fixes the 5 spec-only producers' input field from the invisible
   Multi Line Text type to Single Line Text.

4. **`DBA_Automation_Fix_Attachment_Type.js`**
   Looks up the real Attachment field type code on production (do not
   assume it matches the PDI's) and applies it to DCR's file field.

5. **`DBA_Automation_Update_Descriptions.js`**
   Adds the spec-format examples to each producer's description.

6. **`DBA_Automation_Fix_CDP_Description.js`**
   Corrects CDP's label/description ("Change Database Password", not
   "Create Pluggable Database").

7. **`DBA_Automation_Fix_DCR_Attachment_Final.js`**
   The final, working DCR attachment-passing logic (re-parents the
   uploaded file onto the change request without the duplicate-CR bug).

---

## Phase 2 — PRF (the 9th project)

8. **`DBA_Automation_Add_PRF_Producer.js`**
   Creates the PRF producer with its original 3 fields.

9. **Manual: create the `u_u_oracle_target` table**
   System Definition → Tables → New. Label it something that does
   **not** already start with `u_` (typing an existing `u_` prefix
   double-prefixes the real table name — this is literally why it's
   called `u_u_oracle_target` and not `u_oracle_target` on the PDI).
   Add 3 String columns: `u_host`, `u_oracle_sid`, `u_label` — mark
   `u_label` as the Display field.

10. **Manual: create 4 ACLs on that table**
    Read / write / create / delete, `Applies to` = your new table name.
    Watch for ServiceNow auto-generating its own role for the ACL's
    "Requires role" (it did on the PDI, naming it
    `u_u_oracle_target_user`) — if so, grant that role directly to
    `hyperautomation.platform` rather than fighting the ACL's role list.

11. **Run `SNOW_sync_oracle_targets.yml` once** to populate the new
    table from production's real `oracle_instance_map`/PDBs.

12. **`DBA_Automation_Fix_PRF_DateTime_Fields.js`**
    Converts PRF's snapshot-ID fields to Date/Time fields with a
    calendar picker.

13. **Manual: paste the final PRF producer script** (below) directly
    into the producer's Script field via the UI, then Publish if it's
    checked out as a draft. This combines the Reference-table lookup
    *and* the empirically-calibrated timezone correction — **do not**
    run `DBA_Automation_Convert_PRF_Database_To_Reference.js` expecting
    this to happen automatically; that script hit ServiceNow's Catalog
    Item Versioning lock on the PDI and never actually wrote anything,
    which is exactly why this ended up as a manual step in the first
    place.

    ```javascript
    var host = '';
    var sid = '';
    var targetGr = new GlideRecord('u_u_oracle_target');
    if (targetGr.get(producer.getValue('database'))) {
        host = targetGr.getValue('u_host');
        sid = targetGr.getValue('u_oracle_sid');
    }

    // Empirically-calibrated timezone correction - see the "IMPORTANT"
    // note below before assuming this number is still correct on
    // production.
    var gdtStart = new GlideDateTime(producer.getValue('start_datetime'));
    gdtStart.addSeconds(-7 * 3600);
    var startDt = gdtStart.getValue();

    var gdtEnd = new GlideDateTime(producer.getValue('end_datetime'));
    gdtEnd.addSeconds(-7 * 3600);
    var endDt = gdtEnd.getValue();

    current.short_description = 'PRF | ' + host + ' | ' + sid + ' | ' + startDt + ' | ' + endDt;
    current.description = 'Automated AWR performance analysis request.\n\n' +
        'Database: ' + sid + ' on ' + host + '\n' +
        'Issue period: ' + startDt + ' -> ' + endDt + '\n\n' +
        'The automation will find the matching AWR snapshots for this time period,' +
        ' generate an AWR report, identify the top 5 CPU-consuming SQL statements,' +
        ' and run the SQL Tuning Advisor against each one. No approval is required' +
        ' for this analysis step - it is read-only and never modifies the database.' +
        ' A separate follow-up change requiring approval will be opened afterward' +
        ' for the DBA team to review and implement any recommended fix.';
    current.type = 'standard';
    new DBAAutomationRouting().route(current);
    ```

    ⚠️ **IMPORTANT**: the `-7 * 3600` offset was calibrated empirically
    to the PDI test user's specific ServiceNow profile timezone versus
    the Oracle server's timezone. **This number is not guaranteed to be
    correct on production** — it depends on whoever submits the form
    there having the same timezone mismatch. Test with a known,
    verifiable time on production before trusting this blindly; if the
    offset is different (or zero, if production users' profiles are
    already correctly configured), adjust or remove this correction
    accordingly.

14. **Manual: convert PRF's "database" variable to Reference type**
    Open the producer's `database` variable, change Type to Reference,
    set the Reference table to `u_u_oracle_target`. This is the piece
    the blocked script in step 13 was supposed to do.

15. Also manually re-apply, if wanted: the `onSubmit` Catalog Client
    Script from `DBA_Automation_Add_PRF_Validation.js`. Flagged here for
    completeness, but note it was **confirmed not to actually block bad
    input** in PDI testing — the Reference-field conversion in step 14
    is what actually solves the bad-input problem. Don't rely on this
    validation script alone.

---

## Phase 3 — Approval levels (today's work)

16. **`DBA_Automation_Fix_SpecOnly_Types_v2.js`**
    Sets both `chg_model` and `type` correctly for REF (standard), CAU
    (normal), PAT (normal), CDP (standard), UPG (normal). This was the
    fix that actually made approval levels take effect — setting `type`
    alone was silently overridden by the Model field's own default-value
    logic.

    First, look up production's own `chg_model` sys_ids for "Standard"
    and "Normal" (**do not reuse the PDI's** — `chg_model` sys_ids are
    almost certainly different per instance):
    ```javascript
    var m = new GlideRecord('chg_model');
    m.query();
    while (m.next()) {
        gs.info(m.getValue('name') + ' = ' + m.getValue('sys_id'));
    }
    ```
    Then update the `MODEL_SYS_ID` values inside
    `DBA_Automation_Fix_SpecOnly_Types_v2.js` to match before running it
    on production.

17. **Open verification item — PDB and DCR were not covered by step 16**
    PDB and DCR have their own dedicated producer scripts (not the
    generic spec-only template those 5 share), so they were never
    checked for the same `chg_model`/`type` issue. PDB now needs
    `type: normal` (MANAGEMENT) per today's approval-level spec — before
    assuming it works, submit a real PDB test request on production and
    confirm the CR's **Model** field actually shows "Normal", not just
    the Type field. If Model shows something else, PDB's own producer
    script needs the same `current.chg_model = '<normal_sys_id>';` line
    added by hand.

    DDP was already confirmed working with approval end-to-end earlier
    in this project (before the chg_model root cause was even
    discovered), so it likely already sets `chg_model` correctly on its
    own — but worth a quick confirmation on production regardless, since
    "worked on the PDI" doesn't guarantee the same producer script
    exists there unmodified.

---

## Scripts to SKIP — diagnostic-only, never meant to be replayed

These were written purely to inspect the PDI's live state while
debugging, and running them on production wastes time without changing
anything (or, worse, some are non-idempotent superseded first drafts):

- `DBA_Automation_Check_Producer_Types.js`
- `DBA_Automation_Dump_CDP_Script.js` / `_v2.js`
- `DBA_Automation_Check_Change_Models.js`
- `DBA_Automation_Diagnose_PRF_Validation.js`
- `DBA_Automation_Inspect_Versioning_Service.js`
- `DBA_Automation_Diagnose_Checkout_Rule.js`
- `DBA_Automation_Check_Category_Description_Type.js`
- `DBA_Automation_Fix_SpecOnly_Types.js` (v1 — superseded by v2 in step 16)
- `DBA_Automation_Fix_CDP_Type.js` (superseded by v2 in step 16)

---

## Manual-only items with no script at all

- **Category and producer icon images** — re-upload the same image
  files to each Picture field by hand (these were never scripted, only
  ever manually uploaded).
- **Category title and description text** — if you want production to
  show "Cargill Database Automation Platform" and the same "Comments to
  ___" line, either re-run `DBA_Automation_Set_Category_Comments_Line.js`
  (this one *is* scripted and safe to replay) or set it by hand.

---

## Ansible-side migration (separate from all of the above)

This part is simple by comparison: copy the actual playbook files to
production's Ansible controller —

- All `SNOW_*.yml` dispatcher and job files (9 projects)
- `COMMON_snow_intake.yml`, `COMMON_snow_create_followup.yml`
- `SNOW_sync_oracle_targets.yml` + its cron wrapper
- All `*_cron_wrapper.sh` files
- `vars/main.yml` — **do not copy this file verbatim**; production
  needs its own `sn_instance`/`sn_username`/`sn_password`,
  `oracle_instance_map`, and any other environment-specific values,
  even though the *structure* (variable names) should match exactly
  what the playbooks expect.

Then re-create each project's crontab entry pointing at the production
paths.

---

## Suggested order of operations end to end

1. Prerequisites checklist
2. Phase 1 (steps 1-7)
3. Phase 2 (steps 8-15)
4. Phase 3 (steps 16-17)
5. Copy Ansible files + fix `vars/main.yml`
6. Set up cron
7. Submit one real test CR per project on production before considering
   the migration complete — the same way each of these 9 projects was
   actually proven out on the PDI, one real submission at a time
