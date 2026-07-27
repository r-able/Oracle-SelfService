Project Title: 
Oracle-SelfService (JIRA)

Description:
This is a combination of Ansible, JIRA and LINUX shell files intended to auto-execute most common Oracle Database Administration (DBA) JIRA requests, such as upgrades, migrations, password resets, user creation, etc. 

Getting Started (Dependencies):
The following is required.
1) A cloud JIRA account, with a valid URL, username and API token.
2) An Ansible control node (LINUX in this variation, /etc/ansible home owned by ansible_admin OS user). This code has been created and tested using Ansible version 2.21.1.
3) One or more Oracle databases to provision and maintain. This project is tested on Oracle LINUX 8 with an Oracle Enterprise Edition database 21.3.0.0. 

Directories and files description:
JIRA - contains an export of the JIRA forms and dashboards to import into your JITA cloud. Replace the credentials in the ./vars/main.yml
attachments - an optional directory with Oracle SQL scripts for testing migrations and data JIRA change requests. 
vars - contains the main.yml. The file has all the variables to make the project run. Replace with own variables. 

Functionality:
There are three components. The JIRA cloud virtual server, the Ansible control node with the automation code in it, and one or more remote Oracle database assets. The Ansible control node polls the JIRA cloud for new work periodically, as defined by its crontab. The users open JIRA requests to perform routine work. There are 6 such routine DBA projects in this JIRA/Ansible implementation: PAT (Patch Oracle), UPG (Upgrade Oracle), DCR (Migrate Code or Data Change Request), REF (Refresh a lower environment Oracle database from the PROD instance), CAU (Create new Oracle user), CDP (Change Database Password). For example, a business user submits a form for the CAU project Create user. The Ansible control node scans the JIRA account every 60 seconds. If it detects a new request or a collection of thereof, it checks them for approvals and auto-excutes them in the order they were open. If an approval is missing, the control node will re-poll again that particular tasks in a minute (the period expands to 24 hours for more complex projects like UPG Database Upgrades or PAT Database patching). As soon as the request is approved, the Ansible control node executes it using the information the user provided. For example, the business user may have requested the creation of or resetting a password for user JHUANG in 4 specific databases. The control node then updates the JIRA task/request with run notes, uploads the logs and transitions the JIRA task to either "Done" or "Failed" state, depending on the outcome. If the request fails, the Ansible control node opens a follow up JIRA for the DBA team to investigate and repair the defect.

Installation:
1) Download this code
2) Import the JIRA site export into your URL. https://support.atlassian.com/atlassian-cloud/kb/partial-or-selective-import-of-a-jira-backup-export-into-jira-cloud/
3) Deploy the remaining files and folders to your Ansible control node's /etc/ansible directory.
4) Change the following files to match your environment: ./hosts, ./inventory, ./ansible.cfg, ./vars/main.yml, all ./*.sh shell scripts.
5) Create the cron entries so the LINUX control node will be able to poll your JIRA cloud for new work, and execute it.
The following is an example of the crontab file.
############################JIRA############################################
# Data Change Request (DCR) polling JIRA for new tasks every 5 minutes
#*/1 * * * * /etc/ansible/DCR_jira_cron_wrapper.sh >> /tmp/cron.JIRA.DCR.log 2>&1
# CAU Create New Database User polling JIRA every 5 minutes
#*/1 * * * * /etc/ansible/CAU_jira_cron_wrapper.sh >> /tmp/cron.JIRA.CAU.log 2>&1
# CDP Reset Own Oracle Password polling JIRA every 5 minutes
#*/1 * * * * /etc/ansible/CDP_jira_cron_wrapper.sh >> /tmp/cron.JIRA.CDP.log 2>&1
# REF Refresh Oracle Databases polling JIRA every 5 minutes
#*/1 * * * * /etc/ansible/REF_jira_cron_wrapper.sh >> /tmp/cron.JIRA.REF.log 2>&1
# PAT Patch Oracle Database polling JIRA every hour
#0 * * * * /etc/ansible/PAT_jira_cron_wrapper.sh >> /tmp/cron.JIRA.PAT.log 2>&1
# UPG Upgrade Oracle the Requested Oracle Databases polling JIRA every midnight
#0 0 * * * /etc/ansible/UPG_jira_cron_wrapper.sh  >> /tmp/cron.JIRA.UPG.log 2>&1
###########################END OF JIRA######################################
###########################SNOW#############################################
#*/1 * * * * /etc/ansible/UPG_snow_cron_wrapper.sh >> /tmp/cron.SNOW.UPG.log 2>&1
0 * * * * /etc/ansible/UPG_snow_cron_wrapper.sh >> /tmp/cron.SNOW.UPG.log 2>&1
*/1 * * * * /etc/ansible/REF_snow_cron_wrapper.sh >> /tmp/cron.SNOW.REF.log 2>&1
0 * * * * /etc/ansible/PAT_snow_cron_wrapper.sh >> /tmp/cron.SNOW.PAT.log 2>&1
#*/1 * * * * /etc/ansible/PAT_snow_cron_wrapper.sh >> /tmp/cron.SNOW.PAT.log 2>&1
*/1 * * * * /etc/ansible/DCR_snow_cron_wrapper.sh >> /tmp/cron.SNOW.DCR.log 2>&1
*/1 * * * * /etc/ansible/CDP_snow_cron_wrapper.sh >> /tmp/cron.SNOW.CDP.log 2>&1
*/1 * * * * /etc/ansible/CAU_snow_cron_wrapper.sh >> /tmp/cron.SNOW.CAU.log 2>&1
*/1 * * * * /etc/ansible/PDB_snow_cron_wrapper.sh >> /tmp/cron.SNOW.PDB.log 2>&1
*/1 * * * * /etc/ansible/DDP_snow_cron_wrapper.sh >> /tmp/cron.SNOW.DDP.log 2>&1
*/5 * * * * /etc/ansible/PRF_snow_cron_wrapper.sh >> /tmp/cron.SNOW.PRF.log 2>&1
###########################END OF SNOW######################################
6) After testing, it is recommended to encrypt the credentials/variables file ./vars/main.yml with Ansible vault. In such cases the cron entries will have to be changed.
For example, the unencrypted DCR cron entry
# DCR Migration Data Change Request polling JIRA for new tasks every 5 minutes
*/1 * * * * /etc/ansible/DCR_jira_cron_wrapper.sh >> /tmp/cron.DCR.log 2>&1
should be change to as follows (if you are inclined to store the Vault password on disk):
*/1 * * * * ansible-playbook jira_oracle_password_reset.yml --vault-password-file /etc/ansible/.vault_pass >> /tmp/cron.DCR.log 2>&1

ServiceNow implementation:
Name your Change Requests as follows to kick off the auto-execution:
##### ServiceNow conversion settings ################################
# The change_request table is shared; each project finds its work by
# short_description prefix "<TAG> | <spec...>" (see COMMON_snow_intake.yml).
# Spec formats after the tag:
#   REF | PROD:DEV                     (or legacy PRO:HR=>UAT:HR_COPY)
#   PAT | lnx001:CDB1 | 234234234      (target | patch number)
#   CAU | Vlad Grigorian | PROD,DEV,SIT
#   CDP | Vlad Grigorian
#   UPG | CDB1
#   DCR | <free title>                 (.sql scripts as attachments)
#   PDB | lnx001 | CDB1 | TSTPDB01      (provision a new database)
#   PDB | lnx001 | CDB1 | TSTPDB01      (provision a new database)
#   DDP | lnx001 | CDB1 | TSTPDB01      (drop a database: double SNOW confirmation, needs a literal CONFIRM DROP <PDB_NAME>, pre-drop snapshot, single-target, not a loop over all six — CDP provisions across all six PDBs; dropping shouldn't ever be a batch operation, so DDP only ever acts on the one PDB named in the ticket.)
#####################################################################

Logging tree:

[ansible_admin@HPsuperdome ~]$  pwd
/home/ansible_admin
[ansible_admin@HPsuperdome ~]$ tree -d
.
+-- jira_cau
ï¿½ï¿½ï¿½ +-- logs
+-- jira_cdp
ï¿½ï¿½ï¿½ +-- logs
+-- jira_dcr
ï¿½ï¿½ï¿½ +-- logs
+-- jira_pat
ï¿½ï¿½ï¿½ +-- logs
+-- jira_ref
ï¿½ï¿½ï¿½ +-- logs
+-- jira_upg
ï¿½ï¿½ï¿½ +-- logs


JIRA statuses transition:

"To Do" => "Pending Approval" => "In Progress" if approved, "Rejected" if rejected => "Done" if successful, "Failed" if failed

Authors:
Vlad von Grigorian
@GRIGORIANV
grigorianvlad@gmail

Version History:
0.2

License:
MIT License
Copyright (c) 2026 Vlad von Grigorian
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.