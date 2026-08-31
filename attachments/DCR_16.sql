column current_scn format 99999999999;
delete from table source.data;
insert into source.data values (10);
COMMIT;
EXIT;
