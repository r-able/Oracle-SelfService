column current_scn format 99999999999;
alter session set container=ORCLPDB;
column current_scn format 99999999999;
SELECT & from table;
COMMIT;
EXIT;
