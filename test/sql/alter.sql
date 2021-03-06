-- alter.sql : test emaj_alter_group() and emaj_alter_groups() functions
--
-- set sequence restart value
alter sequence emaj.emaj_hist_hist_id_seq restart 6000;
alter sequence emaj.emaj_time_stamp_time_id_seq restart 6000;
alter sequence emaj.emaj_mark_mark_id_seq restart 6000;
alter sequence emaj.emaj_rlbk_rlbk_id_seq restart 6000;

-----------------------------
-- stop, reset and drop groups
-----------------------------
select emaj.emaj_stop_group('myGroup1');
select emaj.emaj_reset_group('myGroup1');
select emaj.emaj_drop_group('myGroup1');
select emaj.emaj_force_drop_group('myGroup2');
select emaj.emaj_stop_group('phil''s group#3",','Simple stop mark');
select emaj.emaj_drop_group('phil''s group#3",');
select emaj.emaj_force_stop_group('myGroup4');
select emaj.emaj_drop_group('myGroup4');
select emaj.emaj_force_stop_group('emptyGroup');
select emaj.emaj_drop_group('emptyGroup');

-----------------------------
-- emaj_alter_group() tests on IDLE groups
-----------------------------
select emaj.emaj_create_group('myGroup1');
select emaj.emaj_create_group('myGroup2');
select emaj.emaj_create_group('emptyGroup',true,true);
select emaj.emaj_create_group('myGroup4');

-- unknown group
select emaj.emaj_alter_group(NULL);
select emaj.emaj_alter_group('unknownGroup');
-- group in logging state (2 tables need to be repaired)
begin;
  select emaj.emaj_start_group('myGroup1','');
  select emaj.emaj_disable_protection_by_event_triggers();
  drop table emaj.myschema1_mytbl1_log;
  drop table emaj.myschema1_mytbl4_log;
  select emaj.emaj_enable_protection_by_event_triggers();
  select emaj.emaj_alter_group('myGroup1');
rollback;
-- alter a group with a table now already belonging to another group
begin;
  insert into emaj.emaj_group_def values ('myGroup1','myschema2','mytbl1');
  select emaj.emaj_alter_group('myGroup1');
rollback;
-- schema suffix cannot be changed for sequence
begin;
  update emaj.emaj_group_def set grpdef_log_schema_suffix = 'dummy' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3_col31_seq';
  select emaj.emaj_alter_group('myGroup1');
rollback;
-- object names prefix cannot be changed for sequence
begin;
  update emaj.emaj_group_def set grpdef_emaj_names_prefix = 'dummy' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3_col31_seq';
  select emaj.emaj_alter_group('myGroup1');
rollback;
-- log tablespace cannot be changed for sequence
begin;
  update emaj.emaj_group_def set grpdef_log_dat_tsp = 'b' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3_col31_seq';
  select emaj.emaj_alter_group('myGroup1');
rollback;
begin;
  update emaj.emaj_group_def set grpdef_log_idx_tsp = 'b' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3_col31_seq';
  select emaj.emaj_alter_group('myGroup1');
rollback;
-- dropped application table
begin;
  select emaj.emaj_disable_protection_by_event_triggers();
  drop table myschema1.mytbl2b;
  select emaj.emaj_enable_protection_by_event_triggers();
  select emaj.emaj_alter_group('myGroup1');
rollback;

-- should be OK
-- nothing to change
select emaj.emaj_alter_group('emptyGroup');
select group_name, group_is_logging, group_is_rlbk_protected, group_nb_table, group_nb_sequence, group_is_rollbackable,
       group_creation_time_id, group_last_alter_time_id, group_comment
 from emaj.emaj_group where group_name = 'myGroup1';
select emaj.emaj_alter_group('myGroup1');
select group_name, group_is_logging, group_is_rlbk_protected, group_nb_table, group_nb_sequence, group_is_rollbackable,
       group_creation_time_id, group_last_alter_time_id, group_comment
 from emaj.emaj_group where group_name = 'myGroup1';
select nspname from pg_namespace where nspname like 'emaj%' order by nspname;
-- only 3 tables to remove (+ log schemas emajb)
delete from emaj.emaj_group_def where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl2b';
delete from emaj.emaj_group_def where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3';
delete from emaj.emaj_group_def where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl4';
select emaj.emaj_alter_group('myGroup1');
select group_nb_table, group_nb_sequence from emaj.emaj_group where group_name = 'myGroup1';
select nspname from pg_namespace where nspname like 'emaj%' order by nspname;
-- only 1 sequence to remove
delete from emaj.emaj_group_def where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3_col31_seq';
select emaj.emaj_alter_group('myGroup1');
select group_nb_table, group_nb_sequence from emaj.emaj_group where group_name = 'myGroup1';
-- 3 tables to add (+ log schemas emajb)
insert into emaj.emaj_group_def values ('myGroup1','myschema1','mytbl2b',NULL,'b',NULL,'tsp log''2','tsp log''2');
insert into emaj.emaj_group_def values ('myGroup1','myschema1','myTbl3',10,'C',NULL,'tsplog1');
insert into emaj.emaj_group_def values ('myGroup1','myschema1','mytbl4',20,NULL,NULL,'tsplog1','tsp log''2');
select emaj.emaj_alter_group('myGroup1');
select group_nb_table, group_nb_sequence from emaj.emaj_group where group_name = 'myGroup1';
select nspname from pg_namespace where nspname like 'emaj%' order by nspname;
-- only 1 sequence to add
insert into emaj.emaj_group_def values ('myGroup1','myschema1','myTbl3_col31_seq',1);
select emaj.emaj_alter_group('myGroup1');
select group_nb_table, group_nb_sequence from emaj.emaj_group where group_name = 'myGroup1';
-- only change the log schema
update emaj.emaj_group_def set grpdef_log_schema_suffix = NULL where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3';
select emaj.emaj_alter_group('myGroup1');
select nspname from pg_namespace, pg_class where relnamespace = pg_namespace.oid and relname = 'myschema1_myTbl3_log';
update emaj.emaj_group_def set grpdef_log_schema_suffix = 'C' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3';
select emaj.emaj_alter_group('myGroup1');
select nspname from pg_namespace, pg_class where relnamespace = pg_namespace.oid and relname = 'myschema1_myTbl3_log';
-- only change the emaj_names_prefix for 1 table
update emaj.emaj_group_def set grpdef_emaj_names_prefix = 's1t3' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3';
select emaj.emaj_alter_group('myGroup1');
select count(*) from "emajC".s1t3_log;
update emaj.emaj_group_def set grpdef_emaj_names_prefix = NULL where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3';
select emaj.emaj_alter_group('myGroup1');
select count(*) from "emajC"."myschema1_myTbl3_log";
-- only change the log data tablespace for 1 table
update emaj.emaj_group_def set grpdef_log_dat_tsp = NULL where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl2b';
select emaj.emaj_alter_group('myGroup1');
select spcname from pg_tablespace, pg_class where reltablespace = pg_tablespace.oid and relname = 'myschema1_mytbl2b_log';
update emaj.emaj_group_def set grpdef_log_dat_tsp = 'tsp log''2' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl2b';
select emaj.emaj_alter_group('myGroup1');
select spcname from pg_tablespace, pg_class where reltablespace = pg_tablespace.oid and relname = 'myschema1_mytbl2b_log';
-- change the log data tablespace for all tables of a group
update emaj.emaj_group_def set grpdef_log_dat_tsp = case when grpdef_log_dat_tsp is NULL then 'tsplog1' when grpdef_log_dat_tsp = 'tsplog1' then 'tsp log''2' else NULL end where grpdef_schema = 'myschema1' and grpdef_tblseq not like '%seq';
select emaj.emaj_alter_group('myGroup1');
update emaj.emaj_group_def set grpdef_log_dat_tsp = case when grpdef_log_dat_tsp = 'tsplog1' then NULL when grpdef_log_dat_tsp = 'tsp log''2' then 'tsplog1' else 'tsp log''2' end where grpdef_schema = 'myschema1' and grpdef_tblseq not like '%seq';
select emaj.emaj_alter_group('myGroup1');
-- only change the log index tablespace, using a session default tablespace
update emaj.emaj_group_def set grpdef_log_idx_tsp = NULL where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl2b';
set default_tablespace = tspemaj_renamed;
select emaj.emaj_alter_group('myGroup1');
reset default_tablespace;
select spcname from pg_tablespace, pg_class where reltablespace = pg_tablespace.oid and relname = 'myschema1_mytbl2b_log_idx';
update emaj.emaj_group_def set grpdef_log_idx_tsp = 'tsp log''2' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl2b';
select emaj.emaj_alter_group('myGroup1');
select spcname from pg_tablespace, pg_class where reltablespace = pg_tablespace.oid and relname = 'myschema1_mytbl2b_log_idx';
-- only change the priority
update emaj.emaj_group_def set grpdef_priority = 30 where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl1';
select emaj.emaj_alter_group('myGroup1');
select rel_priority from emaj.emaj_relation where rel_schema = 'myschema1' and rel_tblseq = 'mytbl1' and upper_inf(rel_time_range);
update emaj.emaj_group_def set grpdef_priority = NULL where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl1';
select emaj.emaj_alter_group('myGroup1');
select rel_priority from emaj.emaj_relation where rel_schema = 'myschema1' and rel_tblseq = 'mytbl1' and upper_inf(rel_time_range);
update emaj.emaj_group_def set grpdef_priority = 20 where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl1';
select emaj.emaj_alter_group('myGroup1');
select rel_priority from emaj.emaj_relation where rel_schema = 'myschema1' and rel_tblseq = 'mytbl1' and upper_inf(rel_time_range);

-- change the table structure
alter table myschema1.mytbl1 add column newcol int;
select emaj.emaj_alter_group('myGroup1');
alter table myschema1.mytbl1 rename newcol to newcol2;
select emaj.emaj_alter_group('myGroup1');
alter table myschema1.mytbl1 alter column newcol2 type bigint;
select emaj.emaj_alter_group('myGroup1');
alter table myschema1.mytbl1 alter column newcol2 set default 0;
-- NB: changing default has no impact on emaj component 
select emaj.emaj_alter_group('myGroup1');
alter table myschema1.mytbl1 drop column newcol2;
select emaj.emaj_alter_group('myGroup1');

-- rename a table and/or change its schema
alter table myschema1.mytbl1 rename to mytbl1_new_name;
update emaj.emaj_group_def set grpdef_tblseq = 'mytbl1_new_name' 
  where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl1';
select emaj.emaj_alter_group('myGroup1');
alter table myschema1.mytbl1_new_name set schema public;
update emaj.emaj_group_def set grpdef_schema = 'public'
  where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl1_new_name';
select emaj.emaj_alter_group('myGroup1');
alter table public.mytbl1_new_name rename to mytbl1;
alter table public.mytbl1 set schema myschema1;
update emaj.emaj_group_def set grpdef_schema = 'myschema1', grpdef_tblseq = 'mytbl1'
  where grpdef_schema = 'public' and grpdef_tblseq = 'mytbl1_new_name';
-- the next call gives a useless mark name parameter (the group is in idle state)
select emaj.emaj_alter_group('myGroup1','useless_mark_name');

-- missing emaj components
select emaj.emaj_disable_protection_by_event_triggers();
drop trigger emaj_log_trg on myschema1.mytbl1;
select emaj.emaj_alter_group('myGroup1');
drop function emaj.myschema1_mytbl1_log_fnct() cascade;
select emaj.emaj_alter_group('myGroup1');
drop table emaj.myschema1_mytbl1_log;
select emaj.emaj_alter_group('myGroup1');
select emaj.emaj_enable_protection_by_event_triggers();

-- multiple emaj_alter_group() on a logging group => fails
-- this test is commented because the generated error message differs from one run to another
--begin;
--  select emaj.emaj_start_group('myGroup4');
--  select emaj.emaj_alter_group('myGroup4');
--  select emaj.emaj_alter_group('myGroup4');
--rollback;

-----------------------------
-- emaj_alter_groups() tests on IDLE groups
-----------------------------

-- unknown groups
select emaj.emaj_alter_groups('{NULL,"unknownGroup"}');
select emaj.emaj_alter_groups('{"myGroup1","unknownGroup"}');
-- groups in logging state
begin;
  select emaj.emaj_start_groups('{"myGroup1","myGroup2"}','');
  select emaj.emaj_disable_protection_by_event_triggers();
  drop table emaj.myschema1_mytbl1_log;
  drop table emaj.myschema2_mytbl1_log;
  select emaj.emaj_enable_protection_by_event_triggers();
  select emaj.emaj_alter_groups('{"myGroup2","myGroup1","myGroup4"}');
rollback;
-- alter groups with a table now already belonging to another group
begin;
  insert into emaj.emaj_group_def values ('myGroup1','myschema2','mytbl1');
  select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
rollback;
-- schema suffix cannot be changed for sequence (this covers other cases of forbidden changes for sequences)
begin;
  update emaj.emaj_group_def set grpdef_log_schema_suffix = 'dummy' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3_col31_seq';
  select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
rollback;
-- a PRIMARY KEY is missing
begin;
  alter table myschema1.mytbl4 drop constraint mytbl4_pkey;
  select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
rollback;

-- should be OK
-- 3 tables and 1 sequence to remove (+ log schemas emajb)
select group_name, group_nb_table, group_nb_sequence from emaj.emaj_group where group_name = 'myGroup1' or group_name = 'myGroup2' order by 1;
delete from emaj.emaj_group_def where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl2b';
delete from emaj.emaj_group_def where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3';
delete from emaj.emaj_group_def where grpdef_schema = 'myschema2' and grpdef_tblseq = 'mytbl4';
delete from emaj.emaj_group_def where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3_col31_seq';
select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
select group_name, group_nb_table, group_nb_sequence from emaj.emaj_group where group_name = 'myGroup1' or group_name = 'myGroup2' order by 1;
select nspname from pg_namespace where nspname like 'emaj%' order by nspname;

-- 3 tables and 1 sequence to add (+ log schemas emajb)
insert into emaj.emaj_group_def values ('myGroup1','myschema1','mytbl2b',NULL,'b',NULL,'tsp log''2','tsp log''2');
insert into emaj.emaj_group_def values ('myGroup1','myschema1','myTbl3',10,'C',NULL,'tsplog1');
insert into emaj.emaj_group_def values ('myGroup2','myschema2','mytbl4',NULL,NULL,'myschema2_mytbl4');
insert into emaj.emaj_group_def values ('myGroup1','myschema1','myTbl3_col31_seq',1);
select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
select group_name, group_nb_table, group_nb_sequence from emaj.emaj_group where group_name = 'myGroup1' or group_name = 'myGroup2' order by 1;
select nspname from pg_namespace where nspname like 'emaj%' order by nspname;

-- change a log schema and the emaj_names_prefix for 2 tables
update emaj.emaj_group_def set grpdef_log_schema_suffix = 'tmp' where grpdef_schema = 'myschema2' and grpdef_tblseq = 'myTbl3';
update emaj.emaj_group_def set grpdef_emaj_names_prefix = 's1t3' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3';
select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
select nspname from pg_namespace, pg_class where relnamespace = pg_namespace.oid and relname = 'myschema2_myTbl3_log';
select count(*) from "emajC".s1t3_log;
--
update emaj.emaj_group_def set grpdef_log_schema_suffix = 'C' where grpdef_schema = 'myschema2' and grpdef_tblseq = 'myTbl3';
update emaj.emaj_group_def set grpdef_emaj_names_prefix = NULL where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3';
select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
select nspname from pg_namespace, pg_class where relnamespace = pg_namespace.oid and relname = 'myschema2_myTbl3_log';
select count(*) from "emajC"."myschema1_myTbl3_log";

-- only change the log data tablespace for 1 table, the log index tablespace for another table and the priority for a third one
update emaj.emaj_group_def set grpdef_log_dat_tsp = NULL where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl2b';
update emaj.emaj_group_def set grpdef_log_idx_tsp = 'tsplog1' where grpdef_schema = 'myschema2' and grpdef_tblseq = 'mytbl6';
update emaj.emaj_group_def set grpdef_priority = 30 where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl1';
set default_tablespace = tspemaj_renamed;
select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
reset default_tablespace;
select spcname from pg_tablespace, pg_class where reltablespace = pg_tablespace.oid and relname = 'myschema1_mytbl2b_log';
select spcname from pg_tablespace, pg_class where reltablespace = pg_tablespace.oid and relname = 'myschema2_mytbl6_log_idx';
select rel_priority from emaj.emaj_relation where rel_schema = 'myschema1' and rel_tblseq = 'mytbl1' and upper_inf(rel_time_range);
--
update emaj.emaj_group_def set grpdef_log_dat_tsp = 'tsp log''2' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl2b';
update emaj.emaj_group_def set grpdef_log_idx_tsp = NULL where grpdef_schema = 'myschema2' and grpdef_tblseq = 'mytbl6';
update emaj.emaj_group_def set grpdef_priority = 20 where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl1';
select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
select spcname from pg_tablespace, pg_class where reltablespace = pg_tablespace.oid and relname = 'myschema1_mytbl2b_log';
select spcname from pg_tablespace, pg_class where reltablespace = pg_tablespace.oid and relname = 'myschema2_mytbl6_log_idx';
select rel_priority from emaj.emaj_relation where rel_schema = 'myschema1' and rel_tblseq = 'mytbl1' and upper_inf(rel_time_range);

-- move 1 table and 1 sequence from a group to another
update emaj.emaj_group_def set grpdef_group = 'myGroup1' where grpdef_schema = 'myschema2' and grpdef_tblseq = 'myTbl3';
update emaj.emaj_group_def set grpdef_group = 'myGroup1' where grpdef_schema = 'myschema2' and grpdef_tblseq = 'myTbl3_col31_seq';
select rel_group, count(*) from emaj.emaj_relation where rel_group like 'myGroup%' and upper_inf(rel_time_range) group by 1 order by 1;
select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
select rel_group, count(*) from emaj.emaj_relation where rel_group like 'myGroup%' and upper_inf(rel_time_range) group by 1 order by 1;
update emaj.emaj_group_def set grpdef_group = 'myGroup2' where grpdef_schema = 'myschema2' and grpdef_tblseq = 'myTbl3';
update emaj.emaj_group_def set grpdef_group = 'myGroup2' where grpdef_schema = 'myschema2' and grpdef_tblseq = 'myTbl3_col31_seq';
-- the next call gives a useless mark name parameter (the group is in idle state)
select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}','useless_mark_name_%');
select rel_group, count(*) from emaj.emaj_relation where rel_group like 'myGroup%' and upper_inf(rel_time_range) group by 1 order by 1;

-- empty idle groups
begin;
  delete from emaj.emaj_group_def where grpdef_group IN ('myGroup1','myGroup2');
  select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
-- add one table or sequence to the empty groups
  insert into emaj.emaj_group_def values ('myGroup1','myschema1','mytbl1',20);
  insert into emaj.emaj_group_def values ('myGroup2','myschema2','myseq1');
  select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
rollback;

-----------------------------
-- emaj_alter_group() and emaj_alter_groups() tests on LOGGING groups with rollbacks
-----------------------------
select emaj.emaj_start_groups('{"myGroup1","myGroup2"}','Mk1');

-- change the priority
update emaj.emaj_group_def set grpdef_priority = 30 where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl1';
select emaj.emaj_alter_group('myGroup1','Priority Changed');

-- change the emaj names prefix, the log schema, the log data tablespace and the log index tablespace for different tables
update emaj.emaj_group_def set grpdef_log_schema_suffix = NULL where grpdef_schema = 'myschema2' and grpdef_tblseq = 'myTbl3';
update emaj.emaj_group_def set grpdef_emaj_names_prefix = 's1t3' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3';
update emaj.emaj_group_def set grpdef_log_dat_tsp = NULL where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl2b';
update emaj.emaj_group_def set grpdef_log_idx_tsp = 'tsplog1' where grpdef_schema = 'myschema2' and grpdef_tblseq = 'mytbl6';
set default_tablespace = tspemaj_renamed;
select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}','Attributes_changed');
reset default_tablespace;

-- set an intermediate mark
select emaj.emaj_set_mark_groups('{"myGroup1","myGroup2"}','Mk2');

-- change the priority back
update emaj.emaj_group_def set grpdef_priority = 20 where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl1';
select emaj.emaj_alter_groups(array['myGroup1','myGroup2']);

-- change the other attributes back
update emaj.emaj_group_def set grpdef_log_schema_suffix = 'C' where grpdef_schema = 'myschema2' and grpdef_tblseq = 'myTbl3';
update emaj.emaj_group_def set grpdef_emaj_names_prefix = NULL where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3';
update emaj.emaj_group_def set grpdef_log_dat_tsp = 'tsp log''2' where grpdef_schema = 'myschema1' and grpdef_tblseq = 'mytbl2b';
update emaj.emaj_group_def set grpdef_log_idx_tsp = NULL where grpdef_schema = 'myschema2' and grpdef_tblseq = 'mytbl6';
select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');

-- remove a sequence
--TODO: remove the transaction when adding a sequence will be possible and move the rollbacks later
select emaj.emaj_set_mark_group('myGroup1','Mk2b');
begin;
  delete from emaj.emaj_group_def where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3_col31_seq';
  select emaj.emaj_alter_group('myGroup1');
  select group_nb_table, group_nb_sequence from emaj.emaj_group where group_name = 'myGroup1';
  select * from emaj.emaj_relation where rel_schema = 'myschema1' and rel_tblseq = 'myTbl3_col31_seq';
  select * from emaj.emaj_verify_all();
  --testing snap and sql generation
\! mkdir -p /tmp/emaj_test/alter
\! rm -R /tmp/emaj_test/alter
\! mkdir /tmp/emaj_test/alter
  select emaj.emaj_snap_group('myGroup1','/tmp/emaj_test/alter','');
\! ls /tmp/emaj_test/alter
\! rm -R /tmp/emaj_test/alter/*
  select emaj.emaj_snap_log_group('myGroup1','Mk1',NULL,'/tmp/emaj_test/alter',NULL);
\! cat /tmp/emaj_test/alter/myGroup1_sequences_at_Mk1
\! rm -R /tmp/emaj_test/alter/*
  savepoint gen;
    select emaj.emaj_gen_sql_group('myGroup1', NULL, NULL, '/tmp/emaj_test/alter/myFile',array['myschema1.myTbl3_col31_seq']);
  rollback to gen;
\! rm -R /tmp/emaj_test
  -- testing rollback
--select * from emaj.emaj_alter_plan where altr_time_id = (select max(altr_time_id) from emaj.emaj_alter_plan);
  select * from emaj.emaj_logged_rollback_group('myGroup1','Mk2b',true) order by 1,2;
  select * from emaj.emaj_rollback_group('myGroup1','Mk2b',true) order by 1,2;
--select * from emaj.emaj_alter_plan where altr_time_id = (select max(altr_time_id) from emaj.emaj_alter_plan);
  savepoint svp1;
  -- testing group's reset
  select emaj.emaj_stop_group('myGroup1');
  select * from emaj.emaj_relation where rel_group = 'myGroup1' and not upper_inf(rel_time_range) order by 1,2;
  select emaj.emaj_reset_group('myGroup1');
  select * from emaj.emaj_relation where rel_group = 'myGroup1' and not upper_inf(rel_time_range) order by 1,2;
  rollback to svp1;
  -- testing marks deletion
  select emaj.emaj_set_mark_group('myGroup1','Mk2c');
  select emaj.emaj_delete_before_mark_group('myGroup1','Mk2b');
  select * from emaj.emaj_relation where rel_group = 'myGroup1' and not upper_inf(rel_time_range) order by 1,2;
  select emaj.emaj_delete_before_mark_group('myGroup1','Mk2c');
  select * from emaj.emaj_relation where rel_group = 'myGroup1' and not upper_inf(rel_time_range) order by 1,2;
  -- testing the sequence drop
  drop sequence mySchema1."myTbl3_col31_seq" cascade;
--select * from emaj.emaj_hist order by hist_id desc limit 50;
rollback;

-- remove a table
--TODO: remove the transaction when adding a sequence will be possible and move the rollbacks later
begin;
  insert into myschema1."myTbl3" (col33) values (1.);
--select group_nb_table, group_nb_sequence from emaj.emaj_group where group_name = 'myGroup1';
  delete from emaj.emaj_group_def where grpdef_schema = 'myschema1' and (grpdef_tblseq = 'myTbl3' or grpdef_tblseq = 'mytbl2b');
  select emaj.emaj_alter_group('myGroup1');
  select group_nb_table, group_nb_sequence from emaj.emaj_group where group_name = 'myGroup1';
  select * from emaj.emaj_relation where rel_schema = 'myschema1' and (rel_tblseq = 'myTbl3' or rel_tblseq = 'mytbl2b') order by 1,2;
  delete from myschema1."myTbl3" where col33 = 1.;
  select count(*) from "emajC"."myschema1_myTbl3_log";
  select * from emaj.emaj_verify_all();
  -- testing log stat
  select * from emaj.emaj_log_stat_group('myGroup1',NULL,NULL);
  select * from emaj.emaj_detailed_log_stat_group('myGroup1',NULL,NULL);
  --testing snap and sql generation
\! mkdir -p /tmp/emaj_test/alter
\! rm -R /tmp/emaj_test/alter
\! mkdir /tmp/emaj_test/alter
  select emaj.emaj_snap_group('myGroup1','/tmp/emaj_test/alter','');
\! ls /tmp/emaj_test/alter
\! rm -R /tmp/emaj_test/alter/*
  select emaj.emaj_snap_log_group('myGroup1',NULL,NULL,'/tmp/emaj_test/alter',NULL);
\! ls /tmp/emaj_test/alter/myschema1*
\! rm -R /tmp/emaj_test/alter/*
  savepoint gen;
    select emaj.emaj_gen_sql_group('myGroup1', NULL, NULL, '/tmp/emaj_test/alter/myFile',array['myschema1.myTbl3']);
  rollback to gen;
\! rm -R /tmp/emaj_test
  savepoint svp1;
  -- testing marks deletion (delete all marks before the alter_group)
  select emaj.emaj_delete_before_mark_group('myGroup1','EMAJ_LAST_MARK');
  select 'should not exist' from pg_namespace where nspname = 'emajb';
  select 'should not exist' from pg_class, pg_namespace where relnamespace = pg_namespace.oid and relname = 'myschema1_mytbl2b_log' and nspname = 'emajb';
  rollback to svp1;
  -- testing marks deletion (other cases)
  select emaj.emaj_set_mark_group('myGroup1','Mk2c');
  select emaj.emaj_delete_before_mark_group('myGroup1','Mk2b');
  select * from emaj.emaj_relation where rel_group = 'myGroup1' and not upper_inf(rel_time_range) order by 1,2;
  select 'found' from pg_class, pg_namespace where relnamespace = pg_namespace.oid and relname = 'myschema1_mytbl2b_log' and nspname = 'emajb';
  select emaj.emaj_delete_before_mark_group('myGroup1','Mk2c');
  select * from emaj.emaj_relation where rel_group = 'myGroup1' and not upper_inf(rel_time_range) order by 1,2;
  select 'should not exist' from pg_class, pg_namespace where relnamespace = pg_namespace.oid and relname = 'myschema1_mytbl2b_log' and nspname = 'emajb';
  rollback to svp1;
  -- testing rollback
  delete from emaj.emaj_param where param_key = 'dblink_user_password';
--select * from emaj.emaj_alter_plan where altr_time_id = (select max(altr_time_id) from emaj.emaj_alter_plan);
  select * from emaj.emaj_logged_rollback_group('myGroup1','Mk2b',true) order by 1,2;
  select * from emaj.emaj_rollback_group('myGroup1','Mk2b',true) order by 1,2;
--select * from emaj.emaj_alter_plan where altr_time_id = (select max(altr_time_id) from emaj.emaj_alter_plan);
  savepoint svp1;
  -- testing group's reset
  select emaj.emaj_stop_group('myGroup1');
  select emaj.emaj_reset_group('myGroup1');
  select * from emaj.emaj_relation where rel_group = 'myGroup1' and not upper_inf(rel_time_range) order by 1,2;
  select 'should not exist' from pg_namespace where nspname = 'emajb';
  select 'should not exist' from pg_class, pg_namespace where relnamespace = pg_namespace.oid and relname = 'myschema1_mytbl2b_log' and nspname = 'emajb';
  rollback to svp1;
  -- testing group's stop and start
  select emaj.emaj_stop_group('myGroup1');
  select emaj.emaj_start_group('myGroup1');
  select * from emaj.emaj_relation where rel_group = 'myGroup1' and not upper_inf(rel_time_range) order by 1,2;
  select 'should not exist' from pg_namespace where nspname = 'emajb';
  select 'should not exist' from pg_class, pg_namespace where relnamespace = pg_namespace.oid and relname = 'myschema1_mytbl2b_log' and nspname = 'emajb';
  rollback to svp1;
  -- testing the table drop (remove first the sequence linked to the table, otherwise an event triger fires)
  delete from emaj.emaj_group_def where grpdef_schema = 'myschema1' and grpdef_tblseq = 'myTbl3_col31_seq';
  select emaj.emaj_alter_group('myGroup1');
  drop table mySchema1."myTbl3";
--select * from emaj.emaj_hist order by hist_id desc limit 50;
rollback;
select emaj.emaj_cleanup_rollback_state();

-- set an intermediate mark
select emaj.emaj_set_mark_groups('{"myGroup1","myGroup2"}','Mk3');

select mark_id, mark_group, regexp_replace(mark_name,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), mark_time_id, mark_is_deleted, mark_is_rlbk_protected, mark_comment, mark_log_rows_before_next, mark_logged_rlbk_target_mark from emaj.emaj_mark where mark_id > 6000 order by mark_id;

-- estimate a rollback crossing alter group operations
select emaj.emaj_estimate_rollback_groups('{"myGroup1","myGroup2"}','Mk1',false);

-- execute a rollback not crossing any alter group operation
select * from emaj.emaj_rollback_groups('{"myGroup1","myGroup2"}','Mk3',false) order by 1,2;

-- execute rollbacks crossing alter group operations
select emaj.emaj_logged_rollback_groups('{"myGroup1","myGroup2"}','Mk2');
select * from emaj.emaj_logged_rollback_groups('{"myGroup1","myGroup2"}','Mk2',false) order by 1,2;
select * from emaj.emaj_logged_rollback_groups('{"myGroup1","myGroup2"}','Mk2',true) order by 1,2;
select * from emaj.emaj_rollback_groups('{"myGroup1","myGroup2"}','Mk2',false) order by 1,2;
select * from emaj.emaj_rollback_groups('{"myGroup1","myGroup2"}','Mk1',true) order by 1,2;

-- execute additional rollback not crossing alter operations anymore
select * from emaj.emaj_logged_rollback_groups('{"myGroup1","myGroup2"}','Mk1',false) order by 1,2;
select * from emaj.emaj_rollback_groups('{"myGroup1","myGroup2"}','Mk1',false) order by 1,2;

-- empty logging groups
begin;
  delete from emaj.emaj_group_def where grpdef_group IN ('myGroup1','myGroup2');
  select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
-- add one table or sequence to the empty groups
-- TODO: remove the stop_groups() call once it will be possible to add a table/sequence to a logging group
  select emaj.emaj_stop_groups('{"myGroup1","myGroup2"}');
  insert into emaj.emaj_group_def values ('myGroup1','myschema1','mytbl1',20);
  insert into emaj.emaj_group_def values ('myGroup2','myschema2','myseq1');
  select emaj.emaj_alter_groups('{"myGroup1","myGroup2"}');
rollback;

-----------------------------
-- test end: check and force sequences id
-----------------------------

select emaj.emaj_force_drop_group('myGroup1');
select emaj.emaj_force_drop_group('myGroup2');
select emaj.emaj_force_drop_group('myGroup4');
select nspname from pg_namespace where nspname like 'emaj%' order by nspname;
select sch_name from emaj.emaj_schema order by 1;
select hist_function, hist_event, hist_object, 
       regexp_replace(regexp_replace(hist_wording,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'),E'\\[.+\\]','(timestamp)','g'), 
       hist_user 
  from emaj.emaj_hist where hist_id > 6000 order by hist_id;
select time_id, time_last_emaj_gid, time_event from emaj.emaj_time_stamp where time_id > 6000 order by time_id;
select * from emaj.emaj_alter_plan order by 1,2,3,4,5;

truncate emaj.emaj_hist;

