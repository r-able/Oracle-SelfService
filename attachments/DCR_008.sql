column current_scn format 99999999999;
alter session set container=ORCLPDB;
truncate table source.data;
insert into source.data values (10);
insert into source.data values (20);
insert into source.data values (30);
INSERT INTO SOURCE.DATA (SELECT * FROM SOURCE.DATA);
COMMIT;
EXIT;

