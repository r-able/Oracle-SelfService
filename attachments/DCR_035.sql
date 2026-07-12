column current_scn format 99999999999;
alter session set container=ORCLPDB;
SELECT REPLACE(CURRENT_SCN, ' ', '') FROM V\$DATABASE;
EXIT;
