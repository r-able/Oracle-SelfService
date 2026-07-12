column current_scn format 99999999999;
alter session set container=ORCLPDB;
startup immediate;
COMMIT;
EXIT;
