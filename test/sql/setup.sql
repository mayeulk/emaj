-- setup.sql: Create and setup all application objects that will be needed for regression tests
--            Also perform some checks about emaj functions rights and commments
--
SET client_min_messages TO WARNING;

------------------------------------------------------------
-- create 3 application schemas with tables, sequences, triggers
------------------------------------------------------------
--
-- First schema
--
DROP SCHEMA IF EXISTS mySchema1 CASCADE;
CREATE SCHEMA mySchema1;

SET search_path=mySchema1;

DROP TABLE IF EXISTS myTbl1 ;
CREATE TABLE myTbl1 (
  badName     DECIMAL (7)      NOT NULL,
  col12       CHAR (10)        NOT NULL,
  col13       BYTEA            ,
  PRIMARY KEY (badName,col12)
);
ALTER TABLE myTbl1 RENAME badName TO col11;
CREATE INDEX myTbl1_idx on myTbl1 (col13);

DROP TABLE IF EXISTS myTbl2 ;
CREATE TABLE myTbl2 (
  col21       INT              NOT NULL,
  col22       TEXT             ,
  col23       DATE             ,
  PRIMARY KEY (col21)
);

DROP TABLE IF EXISTS "myTbl3" ;
CREATE TABLE "myTbl3" (
  col31       SERIAL           NOT NULL,
  col32       TIMESTAMP        DEFAULT now(),
  col33       DECIMAL (12,2)   ,
  PRIMARY KEY (col31)
);
CREATE INDEX myIdx3 ON "myTbl3" (col32,col33);

DROP TABLE IF EXISTS myTbl4 ;
CREATE TABLE myTbl4 (
  col41       INT              NOT NULL,
  col42       TEXT             ,
  col43       INT              ,
  col44       DECIMAL(7)       ,
  col45       CHAR(10)         ,
  PRIMARY KEY (col41),
  FOREIGN KEY (col43) REFERENCES myTbl2 (col21) DEFERRABLE INITIALLY IMMEDIATE,
  FOREIGN KEY (col44,col45) REFERENCES myTbl1 (col11,col12) ON DELETE CASCADE ON UPDATE SET NULL DEFERRABLE INITIALLY DEFERRED
);

DROP TABLE IF EXISTS myTbl2b ;
CREATE TABLE myTbl2b (
  col20       SERIAL           NOT NULL,
  col21       INT              NOT NULL,
  PRIMARY KEY (col20)
);

CREATE or REPLACE FUNCTION myTbl2trgfct () RETURNS trigger AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    INSERT INTO mySchema1.myTbl2b (col21) SELECT OLD.col21;
    RETURN OLD;
  ELSIF (TG_OP = 'UPDATE') THEN
    INSERT INTO mySchema1.myTbl2b (col21) SELECT NEW.col21;
    RETURN NEW;
  ELSIF (TG_OP = 'INSERT') THEN
    INSERT INTO mySchema1.myTbl2b (col21) SELECT NEW.col21;
    RETURN NEW;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
CREATE TRIGGER myTbl2trg
  AFTER INSERT OR UPDATE OR DELETE ON myTbl2
  FOR EACH ROW EXECUTE PROCEDURE myTbl2trgfct ();

-- Second schema

DROP SCHEMA IF EXISTS mySchema2 CASCADE;
CREATE SCHEMA mySchema2;

SET search_path=mySchema2;

DROP TABLE IF EXISTS myTbl1 ;
CREATE TABLE myTbl1 (
  col11       DECIMAL (7)      NOT NULL,
  col12       CHAR (10)        NOT NULL,
  col13       BYTEA            ,
  PRIMARY KEY (col11,col12)
);

DROP TABLE IF EXISTS myTbl2 ;
CREATE TABLE myTbl2 (
  col21       INT              NOT NULL,
  col22       TEXT             ,
  col23       DATE             ,
  PRIMARY KEY (col21)
);

DROP TABLE IF EXISTS "myTbl3" ;
CREATE TABLE "myTbl3" (
  col31       SERIAL           NOT NULL,
  col32       TIMESTAMP        DEFAULT now(),
  col33       DECIMAL (12,2)   ,
  PRIMARY KEY (col31)
);
CREATE INDEX myIdx3 ON "myTbl3" (col32,col33);

DROP TABLE IF EXISTS myTbl4 ;
CREATE TABLE myTbl4 (
  col41       INT              NOT NULL,
  col42       TEXT             ,
  col43       INT              ,
  col44       DECIMAL(7)       ,
  col45       CHAR(10)         ,
  PRIMARY KEY (col41),
  FOREIGN KEY (col43) REFERENCES myTbl2 (col21) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (col44,col45) REFERENCES myTbl1 (col11,col12) ON DELETE CASCADE ON UPDATE SET NULL
);

DROP TABLE IF EXISTS myTbl5 ;
CREATE TABLE myTbl5 (
  col51       INT              NOT NULL,
  col52       TEXT[]           ,
  col53       INT[]            ,
  col54       DATE[]           ,
  PRIMARY KEY (col51)
);

DROP TABLE IF EXISTS myTbl6 ;
CREATE TABLE myTbl6 (
  col61       INT4             NOT NULL,
  col62       POINT            ,
  col63       BOX              ,
  col64       CIRCLE           ,
  col65       PATH             ,
  col66       inet             ,
  PRIMARY KEY (col61)
);

CREATE SEQUENCE mySeq1 MINVALUE 1000 MAXVALUE 2000 CYCLE;

-- Third schema (for an audit_only group)

DROP SCHEMA IF EXISTS "phil's schema3" CASCADE;
CREATE SCHEMA "phil's schema3";

SET search_path="phil's schema3";

DROP TABLE IF EXISTS "phil's tbl1" ;
CREATE TABLE "phil's tbl1" (
  "phil's col11" DECIMAL (7)      NOT NULL,
  "phil's col12" CHAR (10)        NOT NULL,
  "phil\s col13" BYTEA            ,
  PRIMARY KEY ("phil's col11","phil's col12")
);

DROP TABLE IF EXISTS "myTbl2\" ;
CREATE TABLE "myTbl2\" (
  col21       SERIAL           NOT NULL,
  col22       TEXT             ,
  col23       DATE
);

DROP TABLE IF EXISTS myTbl4 ;
CREATE TABLE myTbl4 (
  col41       INT              NOT NULL,
  col42       TEXT             ,
  col43       INT              ,
  col44       DECIMAL(7)       ,
  col45       CHAR(10)         ,
  PRIMARY KEY (col41),
  FOREIGN KEY (col44,col45) REFERENCES "phil's tbl1" ("phil's col11","phil's col12") ON DELETE CASCADE ON UPDATE SET NULL
);
ALTER TABLE "myTbl2\" ADD CONSTRAINT mytbl2_col21_fkey FOREIGN KEY (col21) REFERENCES myTbl4 (col41);

CREATE SEQUENCE "phil's seq\1" MINVALUE 1000 MAXVALUE 2000 CYCLE;

-- Fourth schema (for partitioning)

DROP SCHEMA IF EXISTS mySchema4 CASCADE;
CREATE SCHEMA mySchema4;

SET search_path=mySchema4;

DROP TABLE IF EXISTS myTblM ;
CREATE TABLE myTblM (
  col1       DATE             NOT NULL,
  col2       INT              ,
  col3       VARCHAR          ,
  PRIMARY KEY (col1)
);

DROP TABLE IF EXISTS myTblC1 ;
CREATE TABLE myTblC1 (CHECK (col1 BETWEEN '2000-01-01' AND '2009-12-31'), PRIMARY KEY (col1, col2)) INHERITS (myTblM);

DROP TABLE IF EXISTS myTblC2 ;
CREATE TABLE myTblC2 (CHECK (col1 BETWEEN '2010-01-01' AND '2019-12-31'), PRIMARY KEY (col1, col2)) INHERITS (myTblM);

DROP TRIGGER IF EXISTS myTblM_insert_trigger ON myTblM; 
CREATE OR REPLACE FUNCTION myTblM_insert_trigger() RETURNS TRIGGER AS $trigger$ 
BEGIN 
  IF NEW.col1 BETWEEN '2000-01-01' AND '2009-12-31' THEN
    INSERT INTO myschema4.myTblC1 VALUES (NEW.*);
    RETURN NULL;
  ELSEIF NEW.col1 BETWEEN '2010-01-01' AND '2019-12-31' THEN
    INSERT INTO myschema4.myTblC2 VALUES (NEW.*);
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$trigger$ LANGUAGE PLPGSQL;
CREATE TRIGGER myTblM_insert_trigger BEFORE INSERT ON myTblM FOR EACH ROW EXECUTE PROCEDURE mySchema4.myTblM_insert_trigger();

-----------------------------
-- create roles and give rigths on application objects
-----------------------------
create role emaj_regression_tests_adm_user login password 'adm';
create role emaj_regression_tests_viewer_user login password 'viewer';
create role emaj_regression_tests_anonym_user login password 'anonym';
--
grant all on schema mySchema1, mySchema2, "phil's schema3", mySchema4 to emaj_regression_tests_adm_user, emaj_regression_tests_viewer_user;
--
grant select on mySchema1.myTbl1, mySchema1.myTbl2, mySchema1."myTbl3", mySchema1.myTbl4, mySchema1.myTbl2b to emaj_regression_tests_viewer_user;
grant select on mySchema2.myTbl1, mySchema2.myTbl2, mySchema2."myTbl3", mySchema2.myTbl4, mySchema2.myTbl5, mySchema2.myTbl6 to emaj_regression_tests_viewer_user;
grant select on "phil's schema3"."phil's tbl1", "phil's schema3"."myTbl2\" to emaj_regression_tests_viewer_user;
grant select on sequence mySchema1."myTbl3_col31_seq" to emaj_regression_tests_viewer_user;
grant select on sequence mySchema2."myTbl3_col31_seq" to emaj_regression_tests_viewer_user;
grant select on sequence "phil's schema3"."myTbl2\_col21_seq" to emaj_regression_tests_viewer_user;
grant select on mySchema4.myTblM, mySchema4.myTblC1, mySchema4.myTblC2 to emaj_regression_tests_viewer_user;
--
grant all on mySchema1.myTbl1, mySchema1.myTbl2, mySchema1."myTbl3", mySchema1.myTbl4, mySchema1.myTbl2b to emaj_regression_tests_adm_user;
grant all on mySchema2.myTbl1, mySchema2.myTbl2, mySchema2."myTbl3", mySchema2.myTbl4, mySchema2.myTbl5, mySchema2.myTbl6 to emaj_regression_tests_adm_user;
grant all on "phil's schema3"."phil's tbl1", "phil's schema3"."myTbl2\", "phil's schema3".myTbl4 to emaj_regression_tests_adm_user;
grant all on sequence mySchema1."myTbl3_col31_seq" to emaj_regression_tests_adm_user;
grant all on sequence mySchema2."myTbl3_col31_seq" to emaj_regression_tests_adm_user;
grant all on sequence mySchema2.mySeq1 to emaj_regression_tests_adm_user;
grant all on sequence "phil's schema3"."myTbl2\_col21_seq" to emaj_regression_tests_adm_user;
grant all on sequence "phil's schema3"."phil's seq\1" to emaj_regression_tests_adm_user;
grant all on mySchema4.myTblM, mySchema4.myTblC1, mySchema4.myTblC2 to emaj_regression_tests_adm_user;

-----------------------------
-- check that no function has kept its default rights to public
-----------------------------
-- should return no row
select proname, proacl from pg_proc, pg_namespace 
  where pg_namespace.oid=pronamespace and nspname = 'emaj' and proacl is null;

-----------------------------
-- check that no user function has the default comment
-----------------------------
-- should return no row
SELECT pg_proc.proname
  FROM pg_proc
    JOIN pg_namespace ON (pronamespace=pg_namespace.oid)
    LEFT OUTER JOIN pg_description ON (pg_description.objoid = pg_proc.oid 
                     AND classoid = (SELECT oid FROM pg_class WHERE relname = 'pg_proc')
                     AND objsubid=0)
  WHERE nspname = 'emaj' AND proname LIKE E'emaj\\_%' AND 
        pg_description.description='E-Maj internal function';

