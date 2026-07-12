column current_scn format 99999999999;
alter session set container=ORCLPDB;
delete from table source.data;
insert into source.data values (10);
COMMIT;
EXIT;
