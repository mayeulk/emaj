-- adm1.sql : complex scenario executed by an emaj_adm role
--            playing with both myGroup1 and myGroup2 tables groups
--
SET datestyle TO ymd;
-----------------------------
-- grant emaj_adm role 
-----------------------------
grant emaj_adm to emaj_regression_tests_adm_user;
--
set role emaj_regression_tests_adm_user;
-----------------------------
-- authorized table accesses
-----------------------------
select count(*) from emaj.emaj_param;
select count(*) from emaj.emaj_hist;
select count(*) from emaj.emaj_group_def;
select count(*) from emaj.emaj_group;
select count(*) from emaj.emaj_relation;
select count(*) from emaj.emaj_mark;
select count(*) from emaj.emaj_sequence;
select count(*) from emaj.emaj_seq_hole;
select count(*) from emaj.emaj_rlbk_stat;
select count(*) from emaj.emaj_fk;
select count(*) from emaj.mySchema1_myTbl1_log;

-----------------------------
-- stop and drop groups
-----------------------------
select emaj.emaj_stop_group('myGroup1');
select emaj.emaj_drop_group('myGroup1');
select emaj.emaj_force_drop_group('myGroup2');
select emaj.emaj_stop_group('phil''s group#3",');
select emaj.emaj_drop_group('phil''s group#3",');
-- emaj tables
select * from emaj.emaj_group;
select * from emaj.emaj_relation;
select * from emaj.emaj_mark;
select * from emaj.emaj_sequence;
select * from emaj.emaj_fk;
select * from emaj.emaj_seq_hole;
select count(*) from emaj.emaj_rlbk_stat;

-----------------------------
-- cleanup application tables
-----------------------------
reset role;
truncate mySchema1.myTbl1, mySchema1.myTbl2, mySchema1."myTbl3", mySchema1.myTbl4, mySchema1.myTbl2b; 
truncate mySchema2.myTbl1, mySchema2.myTbl2, mySchema2."myTbl3", mySchema2.myTbl4, mySchema2.myTbl5, mySchema2.myTbl6;
alter sequence mySchema2.mySeq1 restart 1000;

-- starting from this point, disable the trigger on myTbl2
alter table mySchema1.myTbl2 disable trigger myTbl2trg;

set role emaj_regression_tests_adm_user;

-----------------------------
-- recreate and start groups
-----------------------------
select emaj.emaj_create_group('myGroup1');
select emaj.emaj_comment_group('myGroup1','This is group #1');
select emaj.emaj_create_group('myGroup2',true);

select emaj.emaj_start_group('myGroup1','M1');
select emaj.emaj_start_group('myGroup2','M1');

-----------------------------
-- Step 1 : for myGroup1, update tables and set 2 marks
-----------------------------
-- check how truncate reacts (must be blocked in pg 8.4+) - tables are empty anyway
truncate myschema1.mytbl1 cascade;
-- 
set search_path=myschema1;
insert into myTbl1 select i, 'ABC', E'\\014'::bytea from generate_series (1,11) as i;
update myTbl1 set col13=E'\\034'::bytea where col11 <= 3;
insert into myTbl2 values (1,'ABC','2010-12-31');
delete from myTbl1 where col11 > 10;
insert into myTbl2 values (2,'DEF',NULL);
insert into "myTbl3" (col33) select generate_series(1000,1039,4)/100;
--
select emaj.emaj_set_mark_group('myGroup1','M2');
--
set search_path=myschema1;
insert into myTbl4 values (1,'FK...',1,1,'ABC');
insert into myTbl4 values (2,'FK...',1,1,'ABC');
update myTbl4 set col43 = 2;
insert into myTbl4 values (3,'FK...',1,10,'ABC');
-- the 2 next statements activate fkey on delete and on update clauses 
delete from myTbl1 where col11 = 10;
update myTbl1 set col12='DEF' where col11 <= 2;
--
select emaj.emaj_set_mark_group('myGroup1','M3');
select emaj.emaj_comment_mark_group('myGroup1','M3','Third mark set');

-----------------------------
-- Checking step 1
-----------------------------
-- emaj tables
select group_name, group_state, group_nb_table, group_nb_sequence, group_is_rollbackable, group_comment 
from emaj.emaj_group order by group_nb_table;
select mark_id, mark_group, regexp_replace(mark_name,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), mark_global_seq, mark_state, mark_comment, mark_last_seq_hole_id, mark_last_sequence_id, mark_log_rows_before_next from emaj.emaj_mark order by mark_id;
select sequ_id,sequ_schema, sequ_name, regexp_replace(sequ_mark,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), sequ_last_val, sequ_is_called from emaj.emaj_sequence order by sequ_id;
-- user tables
select * from mySchema1.myTbl1 order by col11,col12;
select * from mySchema1.myTbl2 order by col21;
select * from mySchema1.myTbl2b order by col20;
select col31,col33 from mySchema1."myTbl3" order by col31;
select * from mySchema1.myTbl4 order by col41;
-- log tables
select col11, col12, col13, emaj_verb, emaj_tuple, emaj_gid, emaj_user, emaj_user_ip from emaj.mySchema1_myTbl1_log order by emaj_gid, emaj_tuple desc;
select col21, col22, col23, emaj_verb, emaj_tuple, emaj_gid, emaj_user, emaj_user_ip from emaj.mySchema1_myTbl2_log order by emaj_gid, emaj_tuple desc;
select col20, col21, emaj_verb, emaj_tuple, emaj_gid, emaj_user, emaj_user_ip from emaj.mySchema1_myTbl2b_log order by emaj_gid, emaj_tuple desc;
select col31, col33, emaj_verb, emaj_tuple, emaj_gid, emaj_user, emaj_user_ip from emaj."myschema1_myTbl3_log" order by emaj_gid, emaj_tuple desc;
select col41, col42, col43, col44, col45, emaj_verb, emaj_tuple, emaj_gid, emaj_user, emaj_user_ip from emaj.mySchema1_myTbl4_log order by emaj_gid, emaj_tuple desc;
-----------------------------
-- Step 2 : for myGroup2, start, update tables and set 2 marks 
-----------------------------
set search_path=myschema2;
insert into myTbl1 select i, 'ABC', E'\\014'::bytea from generate_series (1,11) as i;
update myTbl1 set col13=E'\\034'::bytea where col11 <= 3;
insert into myTbl2 values (1,'ABC','2010-01-01');
delete from myTbl1 where col11 > 10;
select nextval('myschema2.myseq1');
insert into myTbl2 values (2,'DEF',NULL);
insert into "myTbl3" (col33) select generate_series(1000,1039,4)/100;
insert into myTbl5 values (1,'{"abc","def","ghi"}','{1,2,3}',NULL);
insert into myTbl5 values (2,array['abc','def','ghi'],array[3,4,5],array['2000/02/01'::date,'2000/02/28'::date]);
update myTbl5 set col54 = '{"2010/11/28","2010/12/03"}' where col54 is null;
insert into myTbl6 select i, point(i,1.3), '((0,0),(2,2))', circle(point(5,5),i),'((-2,-2),(3,0),(1,4))','10.20.30.40/27' from generate_series (1,8) as i;
update myTbl6 set col64 = '<(5,6),3.5>', col65 = null where col61 <= 3;
--
select emaj.emaj_set_mark_group('myGroup2','M2');
--
set search_path=myschema2;
select nextval('myschema2.myseq1');
select nextval('myschema2.myseq1');
select nextval('myschema2.myseq1');
--
reset role;
alter sequence mySeq1 NO MAXVALUE NO CYCLE;
set role emaj_regression_tests_adm_user;
--
insert into myTbl4 values (1,'FK...',1,1,'ABC');
insert into myTbl4 values (2,'FK...',1,1,'ABC');
update myTbl4 set col43 = 2;
delete from mytbl5 where 4 = any(col53);
delete from myTbl6 where col65 is null;
--
select emaj.emaj_set_mark_group('myGroup2','M3');
-----------------------------
-- Checking step 2
-----------------------------
-- emaj tables
select mark_id, mark_group, regexp_replace(mark_name,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), mark_global_seq, mark_state, mark_comment, mark_last_seq_hole_id, mark_last_sequence_id, mark_log_rows_before_next from emaj.emaj_mark order by mark_id;
select sequ_id,sequ_schema, sequ_name, regexp_replace(sequ_mark,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), sequ_last_val, sequ_is_called from emaj.emaj_sequence order by sequ_id;
-- user tables
select * from mySchema2.myTbl1 order by col11,col12;
select * from mySchema2.myTbl2 order by col21;
select col31,col33 from mySchema2."myTbl3" order by col31;
select * from mySchema2.myTbl4 order by col41;
select * from mySchema2.myTbl5 order by col51;
select * from mySchema2.myTbl6 order by col61;
-- log tables
select col11, col12, col13, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl1_log order by emaj_gid, emaj_tuple desc;
select col21, col22, col23, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl2_log order by emaj_gid, emaj_tuple desc;
select col31, col33, emaj_verb, emaj_tuple, emaj_gid from emaj."myschema2_myTbl3_log" order by emaj_gid, emaj_tuple desc;
select col41, col42, col43, col44, col45, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl4_log order by emaj_gid, emaj_tuple desc;
select col51, col52, col53, col54, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl5_log order by emaj_gid, emaj_tuple desc;
select col61, col62, col63, col64, col65, col66, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl6_log order by emaj_gid, emaj_tuple desc;
-----------------------------
-- Step 3 : for myGroup2, double logged rollback then delete first mark 
-----------------------------
reset role;
analyze mytbl4;
set role emaj_regression_tests_adm_user;
select emaj.emaj_logged_rollback_group('myGroup2','M2');
select emaj.emaj_logged_rollback_group('myGroup2','M3');
-----------------------------
-- Checking step 3
-----------------------------
-- emaj tables
select mark_id, mark_group, regexp_replace(mark_name,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), mark_global_seq, mark_state, mark_comment, mark_last_seq_hole_id, mark_last_sequence_id, mark_log_rows_before_next from emaj.emaj_mark order by mark_id;
select sequ_id,sequ_schema, sequ_name, regexp_replace(sequ_mark,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), sequ_last_val, sequ_is_called from emaj.emaj_sequence order by sequ_id;
-- user tables
select * from mySchema2.myTbl1 order by col11,col12;
select * from mySchema2.myTbl2 order by col21;
select col31,col33 from mySchema2."myTbl3" order by col31;
select * from mySchema2.myTbl4 order by col41;
select * from mySchema2.myTbl5 order by col51;
select * from mySchema2.myTbl6 order by col61;
-- log tables
select col11, col12, col13, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl1_log order by emaj_gid, emaj_tuple desc;
select col21, col22, col23, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl2_log order by emaj_gid, emaj_tuple desc;
select col31, col33, emaj_verb, emaj_tuple, emaj_gid from emaj."myschema2_myTbl3_log" order by emaj_gid, emaj_tuple desc;
select col41, col42, col43, col44, col45, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl4_log order by emaj_gid, emaj_tuple desc;
select col51, col52, col53, col54, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl5_log order by emaj_gid, emaj_tuple desc;
select col61, col62, col63, col64, col65, col66, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl6_log order by emaj_gid, emaj_tuple desc;
-----------------------------
-- Step 4 : for myGroup1, rollback then update tables then set 3 marks
-----------------------------
select emaj.emaj_rollback_group('myGroup1','M2');
--
set search_path=myschema1;
insert into myTbl1 select i, 'DEF', E'\\000'::bytea from generate_series (100,110) as i;
insert into myTbl2 values (3,'GHI','2010-01-02');
delete from myTbl1 where col11 = 1;
--
select emaj.emaj_set_mark_group('myGroup1','M4');
--
update "myTbl3" set col33 = col33 / 2;
--
select emaj.emaj_set_mark_group('myGroup1','M5');
--
update myTbl1 set col11 = 99 where col11 = 1;
--
select emaj.emaj_set_mark_group('myGroup1','M6');
-----------------------------
-- Checking step 4
-----------------------------
-- emaj tables
select mark_id, mark_group, regexp_replace(mark_name,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), mark_global_seq, mark_state, mark_comment, mark_last_seq_hole_id, mark_last_sequence_id, mark_log_rows_before_next from emaj.emaj_mark order by mark_id;
select sequ_id,sequ_schema, sequ_name, regexp_replace(sequ_mark,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), sequ_last_val, sequ_is_called from emaj.emaj_sequence order by sequ_id;
-- user tables
select * from mySchema1.myTbl1 order by col11,col12;
select * from mySchema1.myTbl2 order by col21;
select * from mySchema1.myTbl2b order by col20;
select col31,col33 from mySchema1."myTbl3" order by col31;
select * from mySchema1.myTbl4 order by col41;
-- log tables
select col11, col12, col13, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema1_myTbl1_log order by emaj_gid, emaj_tuple desc;
select col21, col22, col23, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema1_myTbl2_log order by emaj_gid, emaj_tuple desc;
select col20, col21, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema1_myTbl2b_log order by emaj_gid, emaj_tuple desc;
select col31, col33, emaj_verb, emaj_tuple, emaj_gid from emaj."myschema1_myTbl3_log" order by emaj_gid, emaj_tuple desc;
select col41, col42, col43, col44, col45, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema1_myTbl4_log order by emaj_gid, emaj_tuple desc;
-----------------------------
-- Step 5 : for myGroup2, logged rollback again then unlogged rollback 
-----------------------------
select emaj.emaj_logged_rollback_group('myGroup2','M2');
--
select emaj.emaj_rollback_group('myGroup2','M3');
-----------------------------
-- Checking step 5
-----------------------------
-- emaj tables
select mark_id, mark_group, regexp_replace(mark_name,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), mark_global_seq, mark_state, mark_comment, mark_last_seq_hole_id, mark_last_sequence_id, mark_log_rows_before_next from emaj.emaj_mark order by mark_id;
select sequ_id,sequ_schema, sequ_name, regexp_replace(sequ_mark,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), sequ_last_val, sequ_is_called from emaj.emaj_sequence order by sequ_id;
select * from emaj.emaj_fk order by fk_groups, fk_session, fk_name;
select sqhl_id, sqhl_schema, sqhl_table, sqhl_hole_size from emaj.emaj_seq_hole order by sqhl_id;
-- user tables
select * from mySchema2.myTbl1 order by col11,col12;
select * from mySchema2.myTbl2 order by col21;
select col31,col33 from mySchema2."myTbl3" order by col31;
select * from mySchema2.myTbl4 order by col41;
select * from mySchema2.myTbl5 order by col51;
select * from mySchema2.myTbl6 order by col61;
-- log tables
select col11, col12, col13, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl1_log order by emaj_gid, emaj_tuple desc;
select col21, col22, col23, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl2_log order by emaj_gid, emaj_tuple desc;
select col31, col33, emaj_verb, emaj_tuple, emaj_gid from emaj."myschema2_myTbl3_log" order by emaj_gid, emaj_tuple desc;
select col41, col42, col43, col44, col45, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl4_log order by emaj_gid, emaj_tuple desc;
select col51, col52, col53, col54, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl5_log order by emaj_gid, emaj_tuple desc;
select col61, col62, col63, col64, col65, col66, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema2_myTbl6_log order by emaj_gid, emaj_tuple desc;
-----------------------------
-- Step 6 : for myGroup1, update tables, rollback, other updates, then logged rollback
-----------------------------
set search_path=myschema1;
--
insert into myTbl1 values (1, 'Step 6', E'\\000'::bytea);
insert into myTbl4 values (11,'FK...',1,1,'Step 6');
insert into myTbl4 values (12,'FK...',1,1,'Step 6');
--
select emaj.emaj_rollback_group('myGroup1','M5');
--
insert into myTbl1 values (1, 'Step 6', E'\\001'::bytea);
insert into myTbl4 values (11,'',1,1,'Step 6');
insert into myTbl4 values (12,'',1,1,'Step 6');
--
select emaj.emaj_logged_rollback_group('myGroup1','M4');
-----------------------------
-- Checking step 6
-----------------------------
-- emaj tables
select mark_id, mark_group, regexp_replace(mark_name,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), mark_global_seq, mark_state, mark_comment, mark_last_seq_hole_id, mark_last_sequence_id, mark_log_rows_before_next from emaj.emaj_mark order by mark_id;
select sequ_id,sequ_schema, sequ_name, regexp_replace(sequ_mark,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), sequ_last_val, sequ_is_called from emaj.emaj_sequence order by sequ_id;
-- check that mark_log_stat_before_next column is always equal to either NULL or the emaj_log_stat_rows() function's result
-- this should always return 0 row
select * from 
  (select mark_id, mark_group, mark_name, mark_log_rows_before_next - 
    (select sum(stat_rows) from emaj.emaj_log_stat_group(mark_group, mark_name, 
      (select mark_name from emaj.emaj_mark m2 where m2.mark_group = m1.mark_group and m2.mark_id > m1.mark_id order by mark_id limit 1))
    ) as checked_stat_rows from emaj.emaj_mark m1 where mark_log_rows_before_next is not null
  ) as t 
  where checked_stat_rows <> 0;
--
select * from emaj.emaj_fk order by fk_groups, fk_session, fk_name;
select sqhl_id, sqhl_schema, sqhl_table, sqhl_hole_size from emaj.emaj_seq_hole order by sqhl_id;
-- user tables
select * from mySchema1.myTbl1 order by col11,col12;
select * from mySchema1.myTbl2 order by col21;
select * from mySchema1.myTbl2b order by col20;
select col31,col33 from mySchema1."myTbl3" order by col31;
select * from mySchema1.myTbl4 order by col41;
-- log tables
select col11, col12, col13, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema1_myTbl1_log order by emaj_gid, emaj_tuple desc;
select col21, col22, col23, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema1_myTbl2_log order by emaj_gid, emaj_tuple desc;
select col20, col21, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema1_myTbl2b_log order by emaj_gid, emaj_tuple desc;
select col31, col33, emaj_verb, emaj_tuple, emaj_gid from emaj."myschema1_myTbl3_log" order by emaj_gid, emaj_tuple desc;
select col41, col42, col43, col44, col45, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema1_myTbl4_log order by emaj_gid, emaj_tuple desc;
-----------------------------
-- Step 7 : for myGroup1, update tables, rename a mark, then delete 2 marks then delete all before a mark 
-----------------------------
set search_path=myschema1;
--
delete from "myTbl3" where col31 = 14;
delete from "myTbl3" where col31 = 15;
delete from "myTbl3" where col31 = 16;
delete from "myTbl3" where col31 = 17;
delete from "myTbl3" where col31 = 18;
--
select emaj.emaj_rename_mark_group('myGroup1',mark_name,'Before logged rollback to M4') from emaj.emaj_mark where mark_name like 'RLBK_M4_%_START';
-- 
select emaj.emaj_delete_mark_group('myGroup1',mark_name) from emaj.emaj_mark where mark_name like 'RLBK_M4_%_DONE';
select emaj.emaj_delete_mark_group('myGroup1','M1');
--
select emaj.emaj_delete_before_mark_group('myGroup1','M4');
-----------------------------
-- Checking step 7
-----------------------------
-- emaj tables
select mark_id, mark_group, regexp_replace(mark_name,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), mark_global_seq, mark_state, mark_comment, mark_last_seq_hole_id, mark_last_sequence_id, mark_log_rows_before_next from emaj.emaj_mark order by mark_id;
select sequ_id,sequ_schema, sequ_name, regexp_replace(sequ_mark,E'\\d\\d\.\\d\\d\\.\\d\\d\\.\\d\\d\\d','%','g'), sequ_last_val, sequ_is_called from emaj.emaj_sequence order by sequ_id;
select * from emaj.emaj_fk order by fk_groups, fk_session, fk_name;
select sqhl_id, sqhl_schema, sqhl_table, sqhl_hole_size from emaj.emaj_seq_hole order by sqhl_id;
select rlbk_operation, rlbk_schema, rlbk_tbl_fk, rlbk_nb_rows from emaj.emaj_rlbk_stat 
  order by rlbk_datetime, rlbk_schema, rlbk_tbl_fk, rlbk_operation;
-- user tables
select * from mySchema1.myTbl1 order by col11,col12;
select * from mySchema1.myTbl2 order by col21;
select * from mySchema1.myTbl2b order by col20;
select col31,col33 from mySchema1."myTbl3" order by col31;
select * from mySchema1.myTbl4 order by col41;
-- log tables
select col11, col12, col13, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema1_myTbl1_log order by emaj_gid, emaj_tuple desc;
select col21, col22, col23, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema1_myTbl2_log order by emaj_gid, emaj_tuple desc;
select col20, col21, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema1_myTbl2b_log order by emaj_gid, emaj_tuple desc;
select col31, col33, emaj_verb, emaj_tuple, emaj_gid from emaj."myschema1_myTbl3_log" order by emaj_gid, emaj_tuple desc;
select col41, col42, col43, col44, col45, emaj_verb, emaj_tuple, emaj_gid from emaj.mySchema1_myTbl4_log order by emaj_gid, emaj_tuple desc;

--
--		grp1									grp2
--1	M1 up M2 up M3 
--2											M1 up M2 up M3
--3											LR-M2 (->M2%S+M2%E) LR-M3 (->M3%S+M3%E)
--4	R-M2 up M4 up M5 up M6
--5											LR-M2 (->M2%S+M2%E) R-M3
--6	up R-M5 up LR-M4(->M4S+M4E)
--7	up M7 REN-M4S DEL-M4E DEL-M1 DELBEF-M4
--
-----------------------------
-- check grants on other functions to emaj_adm role
-----------------------------
select * from emaj.emaj_verify_all();
select emaj.emaj_create_group('dummyGroup');
select emaj.emaj_drop_group('dummyGroup');
select emaj.emaj_force_drop_group('dummyGroup');
select emaj.emaj_get_previous_mark_group('dummyGroup', '2010-01-01');
select emaj.emaj_get_previous_mark_group('dummyGroup', 'EMAJ_LAST_MARK');
select emaj.emaj_reset_group('dummyGroup');
select * from emaj.emaj_log_stat_group('dummyGroup', 'dummyMark', NULL); 
select * from emaj.emaj_detailed_log_stat_group('dummyGroup', 'dummyMark', NULL);
select emaj.emaj_estimate_rollback_duration('dummyGroup', 'dummyMark');
select substr(pg_size_pretty(pg_database_size(current_database())),1,0);
