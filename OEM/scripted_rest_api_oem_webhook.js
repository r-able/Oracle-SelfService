/*
  Scripted REST API - Resource script
  ------------------------------------
  Set up in ServiceNow: System Web Services > Scripted REST APIs
    - Create a new API, e.g. "OEM ALR Webhook" (api id: oem_alr)
    - Add a Resource: HTTP method = POST, relative path = /incident
    - Paste this as the resource's script
    - Note the full endpoint URL shown at the top of the resource -
      that's what goes into the OEM Notification Method (webhook) config.

  Expected inbound JSON body from OEM's webhook notification (this
  shape is a REASONABLE ASSUMPTION based on OEM's typical notification
  payload variables - CONFIRM against a real test webhook payload
  before relying on field names exactly matching. OEM notification
  methods let you customize the JSON body template; adjust either side
  to match).

  {
    "target_name":        "ORCL",
    "target_host":        "lnx001",
    "tablespace_name":    "TEST_ORA_FULL",
    "severity":           "Critical",
    "message":            "Tablespace [TEST_ORA_FULL] is [100 percent] full",
    "oem_incident_id":    "155"
  }
*/

(function process(/*RESTAPIRequest*/ request, /*RESTAPIResponse*/ response) {

    var body = request.body.data;

    // --- Basic validation --------------------------------------------
    var required = ['target_host', 'target_name', 'tablespace_name', 'message'];
    for (var i = 0; i < required.length; i++) {
        if (!body[required[i]]) {
            response.setStatus(400);
            response.setBody({ error: 'Missing required field: ' + required[i] });
            return;
        }
    }

    // --- Build the incident --------------------------------------------
    var gr = new GlideRecord('incident');
    gr.initialize();

    // Discriminator convention matching your other 9 projects' "TAG | spec"
    // pattern - the resolution playbook parses this exact format. The 5th
    // field carries OEM's own incident_id, since EM CLI has no verb to
    // search/look up an incident by target+metric after the fact - this
    // is the only place that ID is available, so it must be threaded
    // through here or it's lost.
    gr.short_description = 'ALR | ' + body.target_host + ' | ' + body.target_name + ' | ' +
                            body.tablespace_name + ' | ' + (body.oem_incident_id || 'UNKNOWN');

    gr.description = body.message + '\n\nRaw OEM payload:\n' + JSON.stringify(body, null, 2);

    // ASSUMPTION - verify these choice values / sys_ids exist on this
    // instance before relying on them (same lookup-first discipline as
    // the other 9 projects - don't guess category/impact/urgency values).
    gr.category = 'Database';
    gr.subcategory = 'Capacity';
    gr.impact = (body.severity === 'Critical') ? 1 : 2;   // 1=High, 2=Medium
    gr.urgency = (body.severity === 'Critical') ? 1 : 2;
    gr.assignment_group.setDisplayValue('Database Atlanta');  // matches your existing group convention

    var newSysId = gr.insert();

    if (!newSysId) {
        response.setStatus(500);
        response.setBody({ error: 'Failed to insert incident record' });
        return;
    }

    response.setStatus(201);
    response.setBody({
        result: 'created',
        incident_sys_id: newSysId,
        incident_number: gr.getValue('number')
    });

})(request, response);
