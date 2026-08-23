
CREATE PLUGGABLE DATABASE dev ADMIN USER supersystem IDENTIFIED BY "oracle" ROLES = (DBA);
CREATE PLUGGABLE DATABASE uat ADMIN USER supersystem IDENTIFIED BY "oracle" ROLES = (DBA);
CREATE PLUGGABLE DATABASE sit ADMIN USER supersystem IDENTIFIED BY "oracle" ROLES = (DBA);
CREATE PLUGGABLE DATABASE stg ADMIN USER supersystem IDENTIFIED BY "oracle" ROLES = (DBA);
CREATE PLUGGABLE DATABASE pro ADMIN USER supersystem IDENTIFIED BY "oracle" ROLES = (DBA);
CREATE PLUGGABLE DATABASE cer ADMIN USER supersystem IDENTIFIED BY "oracle" ROLES = (DBA);
alter pluggable database ORCLPDB open;
alter pluggable database DEV open;
alter pluggable database UAT  open;
alter pluggable database SIT open;
alter pluggable database STG open;
alter pluggable database pro open;
alter pluggable database cer open;
alter pluggable database ORCLPDB save state;
alter pluggable database DEV  save state;
alter pluggable database DEV save state;
alter pluggable database SIT save state;
alter pluggable database UAT save state;
alter pluggable database STG save state;
alter pluggable database PRO save state;
alter pluggable database CER save state;
alter session set container=OLTP1_PERF;
create directory REFRESH as '/refresh";

connect / as sysdba
alter session set container=OLTP1_PERF;
create directory REFRESH as '/refresh';
grant read, write on directory REFRESH to PUBLIC;
create user source identified by oracle;
grant resource, connect, sysdba to source;
connect source/oracle@OLTP1_PERF;
create table data (data number(20));
insert into data values (1);
insert into data values (2);
insert into data values (4);
select * from source.data;
commit;
connect / as sysdba
alter session set container=OLTP2_PERF;
create directory REFRESH as '/refresh';
grant read, write on directory REFRESH to PUBLIC;
create user source identified by oracle;
grant resource, connect, sysdba to source;
connect source/oracle@OLTP2_PERF;
create table data (data number(20));
insert into data values (1);
insert into data values (2);
insert into data values (4);
select * from source.data;
commit;
connect / as sysdba
alter session set container=OLTP3_PERF;
create directory REFRESH as '/refresh';
grant read, write on directory REFRESH to PUBLIC;
create user source identified by oracle;
grant resource, connect, sysdba to source;
connect source/oracle@OLTP3_PERF;
create table data (data number(20));
insert into data values (1);
insert into data values (2);
insert into data values (4);
select * from source.data;
commit;
connect / as sysdba

alter session set container=OLTP4_PERF;
create directory REFRESH as '/refresh';
grant read, write on directory REFRESH to PUBLIC;
create user source identified by oracle;
grant resource, connect, sysdba to source;
connect source/oracle@OLTP4_PERF;
create table data (data number(20));
insert into data values (1);
insert into data values (2);
insert into data values (4);
select * from source.data;
commit;
connect / as sysdba

alter session set container=DW1_PERF;
create directory REFRESH as '/refresh';
grant read, write on directory REFRESH to PUBLIC;
create user source identified by oracle;
grant resource, connect, sysdba to source;
connect source/oracle@DW1_PERF;
create table data (data number(20));
insert into data values (1);
insert into data values (2);
insert into data values (4);
select * from source.data;
commit;

connect / as sysdba
alter session set container=DW2_PERF;
create directory REFRESH as '/refresh';
grant read, write on directory REFRESH to PUBLIC;
create user source identified by oracle;
grant resource, connect, sysdba to source;
connect source/oracle@DW2_PERF;
create table data (data number(20));
insert into data values (1);
insert into data values (2);
insert into data values (4);
select * from source.data;
commit;



