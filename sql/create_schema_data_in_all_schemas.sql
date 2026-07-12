
alter session set container=dev;
create user source identified by oracle;
grant resource, connect, sysdba to source;
connect source/oracle@dev;
create table data (data number(20));
insert into data values (1);
insert into data values (2);
insert into data values (4);
commit;
select * from source.data;
connect / as sysdba
alter session set container=sit;
create user source identified by oracle;
grant resource, connect, sysdba to source;
connect source/oracle@sit;
create table data (data number(20));
insert into data values (1);
insert into data values (2);
insert into data values (4);
commit;
select * from source.data;
connect / as sysdba
alter session set container=uat;
create user source identified by oracle;
grant resource, connect, sysdba to source;
connect source/oracle@uat;
create table data (data number(20));
insert into data values (1);
insert into data values (2);
insert into data values (4);
commit;
select * from source.data;
connect / as sysdba
alter session set container=stg;
create user source identified by oracle;
ALTER USER source  QUOTA UNLIMITED ON USERS;
connect source/oracle@stg;
create table data (data number(20));
insert into data values (1);
insert into data values (2);
insert into data values (4);
commit;
select * from source.data;
connect / as sysdba
alter session set container=pro;
create user source identified by oracle;
grant resource, connect, sysdba to source;
connect source/oracle@pro;
create table data (data number(20));
insert into data values (1);
insert into data values (2);
insert into data values (4);
commit;
select * from source.data;
connect / as sysdba
alter session set container=cer;
create user source identified by oracle;
grant resource, connect, sysdba to source;
connect source/oracle@cer;
create table data (data number(20));
insert into data values (1);
insert into data values (2);
insert into data values (4);
commit;
select * from source.data;

