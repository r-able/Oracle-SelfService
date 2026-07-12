
ACCEPT target_user PROMPT 'Enter the Oracle Database username to drop: '
alter session set container=UAT;
drop user &target_user cascade;
alter session set container=SIT;
drop user &target_user cascade;
alter session set container=CER;
drop user &target_user cascade;
alter session set container=STG;
drop user &target_user cascade;
alter session set container=PRO;
drop user &target_user cascade;
alter session set container=DEV;
drop user &target_user cascade;
[oracle@lnx001 ~]$
