(function process(/*RESTAPIRequest*/ request, /*RESTAPIResponse*/ response) {

    var body = request.body.data;

    if (!body || !body.target_name || !body.metric_name) {
        response.setStatus(400);
        response.setBody({ error: "Missing required fields: target_name, metric_name" });
        return;
    }

    var correlationId = body.target_name + '_' + body.metric_name;

    var gr = new GlideRecord('incident');
    gr.addQuery('correlation_id', correlationId);
    gr.addQuery('active', true);
    gr.addQuery('state', '!=', 6);
    gr.addQuery('state', '!=', 7);
    gr.query();

    var incidentSysId;
    var action;

    if (gr.next()) {
        action = 'updated';

        if (body.event_type === 'CLEAR') {
            gr.state = 6;
            gr.close_code = 'Solved (Permanently)';
            gr.close_notes = 'OEM alert cleared: ' + body.message;
        } else {
            gr.work_notes = 'OEM alert re-fired at ' + body.collection_time + ': ' + body.message;
            gr.urgency = mapSeverityToUrgency(body.severity);
        }

        var updateResult = gr.update();
        var lastError = gr.getLastErrorMessage();
        incidentSysId = gr.getUniqueValue();

        gs.info('OEM_WEBHOOK_DEBUG: updateResult=' + updateResult + ', lastError=' + lastError + ', sys_id=' + incidentSysId);

        if (!updateResult) {
            response.setStatus(500);
            response.setBody({ result: 'update_failed', error: lastError, incident_sys_id: incidentSysId });
            return;
        }

    } else {
        if (body.event_type === 'CLEAR') {
            response.setStatus(200);
            response.setBody({ result: 'no_action', message: 'CLEAR received with no matching open incident' });
            return;
        }

        action = 'created';
        var newInc = new GlideRecord('incident');
        newInc.initialize();
        newInc.short_description = 'OEM Alert: ' + body.metric_name + ' on ' + body.target_name;
        newInc.description = body.message;
        newInc.correlation_id = correlationId;
        newInc.correlation_display = 'OEM';
        newInc.category = 'Database';
        newInc.urgency = mapSeverityToUrgency(body.severity);
        newInc.assignment_group = 'Database Atlanta';
        newInc.u_oem_target_name = body.target_name;
        newInc.u_oem_host = body.host;
        newInc.u_oem_metric_name = body.metric_name;
        newInc.u_oem_incident_id = body.notification_id;
        newInc.u_oem_metric_group = body.metric_group;
        incidentSysId = newInc.insert();
    }

    response.setStatus(200);
    response.setBody({
        result: action,
        incident_sys_id: incidentSysId
    });

    function mapSeverityToUrgency(severity) {
        switch (severity) {
            case 'CRITICAL': return '1';
            case 'WARNING': return '2';
            default: return '3';
        }
    }

})(request, response);
