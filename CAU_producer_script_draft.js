// CAU Record Producer script (onSubmit / script include invoked at submission)
// Draft — follows the same hardcoded-prefix + self-diagnosing field-name
// fallback pattern already used for REF and CDP.
//
// INTAKE FORM FIELD ORDER (per the requested redesign):
//   1. target_databases — List Collector variable (real Name confirmed), Reference table u_oracle_target,
//                          MULTI-SELECT enabled. Label shows "lnx001:DEV" style values,
//                          same source table REF/PRF already sync via SNOW_sync_oracle_hosts.yml
//                          / the PDB-level sync playbook.
//   2. database_username_or_full_first_and_last_name — plain Single Line Text
//                          variable (real Name confirmed). Same dual-mode parsing
//                          as CDP: "VGRIGORIAN" used as-is, "Vlad Grigorian" derived
//                          to VGRIGORIAN.
//
// Old spec_text (if CAU still has one) should be DEACTIVATED, not deleted —
// matching the REF/CDP migration pattern already used elsewhere in this suite.

(function assembleCauSpec(current, producer) {

    // ---- 1. Resolve the multi-select host:db targets ----------------------
    // List Collector variables come back as a comma-separated string of
    // sys_ids. Guard defensively in case the variable name guessed below is
    // wrong on this instance — dump populated variables so it's obvious what
    // to fix, same as the CAU/PAT self-diagnosing pattern.

    var targetVarNames = ['target_databases', 'target_host_db', 'u_target_host_db'];
    var targetsRaw = null;
    var targetsFieldUsed = null;

    for (var i = 0; i < targetVarNames.length; i++) {
        var v = producer.variables[targetVarNames[i]];
        if (v !== undefined && v !== null && v.toString() !== '') {
            targetsRaw = v.toString();
            targetsFieldUsed = targetVarNames[i];
            break;
        }
    }

    if (!targetsRaw) {
        gs.error('CAU producer: could not find the host:db target variable. ' +
            'Checked: ' + targetVarNames.join(', ') + '. ' +
            'Populated variables on this submission: ' + JSON.stringify(producer.variables));
        return;
    }

    var targetSysIds = targetsRaw.split(',');
    var hostDbLabels = [];

    // Confirmed real column names on u_oracle_target (matches the identical
    // u_host / u_oracle_sid / u_label pattern already used by PAT's
    // u_oracle_host table): u_host = host key, u_oracle_sid = PDB name
    // (reused field name from the host-level table - NOT a literal SID on
    // this PDB-granular table), u_label = display value ("lnx001:DEV" style).
    var gr = new GlideRecord('u_oracle_target');
    for (var j = 0; j < targetSysIds.length; j++) {
        if (gr.get(targetSysIds[j])) {
            var hostKey = gr.getValue('u_host');
            var dbName  = gr.getValue('u_oracle_sid');
            if (hostKey && dbName) {
                hostDbLabels.push(hostKey + ':' + dbName);
            } else {
                gs.error('CAU producer: u_oracle_target record ' + targetSysIds[j] +
                    ' is missing u_host or u_oracle_sid — skipping this target.');
            }
        } else {
            gs.error('CAU producer: could not resolve u_oracle_target sys_id ' + targetSysIds[j]);
        }
    }

    if (hostDbLabels.length === 0) {
        gs.error('CAU producer: no valid host:db targets resolved from variable "' +
            targetsFieldUsed + '" — refusing to submit an empty target list.');
        return;
    }

    // ---- 2. Resolve the name/username field --------------------------------

    var nameVarNames = ['database_username_or_full_first_and_last_name', 'username_or_name', 'u_username_or_name'];
    var nameRaw = null;

    for (var k = 0; k < nameVarNames.length; k++) {
        var nv = producer.variables[nameVarNames[k]];
        if (nv !== undefined && nv !== null && nv.toString().trim() !== '') {
            nameRaw = nv.toString().trim();
            break;
        }
    }

    if (!nameRaw) {
        gs.error('CAU producer: could not find the username/name variable. ' +
            'Checked: ' + nameVarNames.join(', '));
        return;
    }

    // ---- 3. Assemble the spec — "CAU" prefix is HARDCODED here, never typed
    //         by the user, matching the REF/CDP pattern -----------------------

    var spec = 'CAU | ' + hostDbLabels.join(',') + ' | ' + nameRaw;

    current.short_description = spec;

    // type / chg_model must ALSO be set explicitly here (per the confirmed
    // MAJOR ROOT CAUSE finding for this instance) — CAU's approval level is
    // MANAGEMENT, so this stays Normal/Assess-gated:
    current.chg_model = '007c4001c343101035ae3f52c1d3aeb2'; // Normal — verify fresh per instance, never reuse across environments
    current.type = 'normal';

})(current, producer);
