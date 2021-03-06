--
-- E-Maj: upgrade from 0.11.1 to 1.0.0
-- 
-- This software is distributed under the GNU General Public License.
--
-- This script upgrades an existing installation of E-Maj extension.
-- If version 0.11.1 version has not been yet installed, use emaj.sql script. 
--

\set ON_ERROR_STOP ON
\set QUIET ON
SET client_min_messages TO WARNING;
--SET client_min_messages TO NOTICE;
\echo 'E-maj upgrade from version 0.11.1 to version 1.0.0'
\echo 'Checking...'
------------------------------------
--                                --
-- checks                         --
--                                --
------------------------------------
-- Creation of a specific function to check the upgrade conditions are met.
-- The function generates an exception if at least one condition is not met.
DROP FUNCTION IF EXISTS emaj.tmp();
CREATE FUNCTION emaj.tmp() 
RETURNS VOID LANGUAGE plpgsql AS
$tmp$
  DECLARE
    v_emajVersion        TEXT;
  BEGIN
-- the emaj version registered in emaj_param must be '0.11.1'
    SELECT param_value_text INTO v_emajVersion FROM emaj.emaj_param WHERE param_key = 'emaj_version';
    IF v_emajVersion <> '0.11.1' THEN
      RAISE EXCEPTION 'The current E-Maj version (%) is not 0.11.1',v_emajVersion;
    END IF;
-- check the current role is a superuser
    PERFORM 0 FROM pg_roles WHERE rolname = current_user AND rolsuper;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'E-Maj installation: the current user (%) is not a superuser.', current_user;
    END IF;
--
    RETURN;
  END;
$tmp$;
SELECT emaj.tmp();
DROP FUNCTION emaj.tmp();

-- OK, upgrade...
\echo '... OK, upgrade start...'

BEGIN TRANSACTION;

-- lock emaj_group table to avoid any concurrent E-Maj activity
LOCK TABLE emaj.emaj_group IN EXCLUSIVE MODE;

CREATE OR REPLACE FUNCTION emaj.tmp() 
RETURNS VOID LANGUAGE plpgsql AS
$tmp$
  DECLARE
  BEGIN
-- if tspemaj tablespace exists, (actualy, it should exist at that time!)
--   use it as default_tablespace for emaj tables creation
--   and grant the create rights on it to emaj_adm
    PERFORM 0 FROM pg_tablespace WHERE spcname = 'tspemaj';
    IF FOUND THEN
      SET LOCAL default_tablespace TO tspemaj;
      GRANT CREATE ON TABLESPACE tspemaj TO emaj_adm;
    END IF;
    RETURN;
  END;
$tmp$;
SELECT emaj.tmp();
DROP FUNCTION emaj.tmp();

\echo 'Updating E-Maj internal objects ...'

------------------------------------
--                                --
-- emaj tables and sequences      --
--                                --
------------------------------------

--
-- process emaj_group_def table
--
ALTER TABLE emaj.emaj_group_def 
  ADD COLUMN grpdef_log_schema_suffix TEXT,
  ADD COLUMN grpdef_log_dat_tsp       TEXT,
  ADD COLUMN grpdef_log_idx_tsp       TEXT
;

--
-- process emaj_group table
--
-- create a temporary emaj_group table with the old structure
CREATE TABLE emaj.emaj_group_old (
    group_name                TEXT        NOT NULL,
    group_state               TEXT        NOT NULL,
    group_nb_table            INT,
    group_nb_sequence         INT,
    group_is_rollbackable     BOOLEAN,
    group_creation_datetime   TIMESTAMPTZ NOT NULL
                              DEFAULT transaction_timestamp(),
    group_pg_version          TEXT        NOT NULL
                              DEFAULT substring (version() from E'PostgreSQL\\s([.,0-9,A-Z,a-z]*)'),
    group_comment             TEXT
    );

-- copy the old emaj_group's content into the temporary table
INSERT INTO emaj.emaj_group_old SELECT * FROM emaj.emaj_group;

-- drop the foreign keys just before the old table
ALTER TABLE emaj.emaj_relation DROP CONSTRAINT emaj_relation_rel_group_fkey;
ALTER TABLE emaj.emaj_mark DROP CONSTRAINT emaj_mark_mark_group_fkey;

DROP TABLE emaj.emaj_group;

-- create the new emaj_group table
CREATE TABLE emaj.emaj_group (
    group_name                TEXT        NOT NULL,
    group_state               TEXT        NOT NULL,      -- 2 possibles states:
                                                         --   'LOGGING' between emaj_start_group and emaj_stop_group
                                                         --   'IDLE' in other cases
    group_nb_table            INT,                       -- number of tables at emaj_create_group time
    group_nb_sequence         INT,                       -- number of sequences at emaj_create_group time
    group_is_rollbackable     BOOLEAN,                   -- false for 'AUDIT_ONLY' groups, true for 'ROLLBACKABLE' groups
    group_creation_datetime   TIMESTAMPTZ NOT NULL       -- start time of the transaction that created the group
                              DEFAULT transaction_timestamp(),
    group_last_alter_datetime TIMESTAMPTZ,               -- date and time of the last emaj_alter_group() exec,
                                                         -- set to NULL at emaj_create_group() time
    group_pg_version          TEXT        NOT NULL       -- postgres version at emaj_create_group() time
                              DEFAULT substring (version() from E'PostgreSQL\\s([.,0-9,A-Z,a-z]*)'),
    group_comment             TEXT,                      -- optional user comment
    PRIMARY KEY (group_name)
    );
COMMENT ON TABLE emaj.emaj_group IS
$$Contains created E-Maj groups.$$;

-- populate the new emaj_group table
INSERT INTO emaj.emaj_group (group_name, group_state, group_nb_table, group_nb_sequence, group_is_rollbackable,
                            group_creation_datetime, group_pg_version, group_comment)
  SELECT * FROM emaj.emaj_group_old;

-- recreate the foreign keys
ALTER TABLE emaj.emaj_relation ADD FOREIGN KEY (rel_group) REFERENCES emaj.emaj_group (group_name) ON DELETE CASCADE;
ALTER TABLE emaj.emaj_mark ADD FOREIGN KEY (mark_group) REFERENCES emaj.emaj_group (group_name) ON DELETE CASCADE;

-- and drop the temporary table
DROP TABLE emaj.emaj_group_old;

--
-- process emaj_relation table
--
-- create a temporary emaj_relation table with the old structure
CREATE TABLE emaj.emaj_relation_old (
    rel_schema               TEXT        NOT NULL,
    rel_tblseq               TEXT        NOT NULL,
    rel_group                TEXT        NOT NULL,
    rel_priority             INTEGER,
    rel_kind                 TEXT,
    rel_session              INT,
    rel_rows                 BIGINT
    );

-- copy the old emaj_relation's content into the temporary table and drop the old table
INSERT INTO emaj.emaj_relation_old SELECT * FROM emaj.emaj_relation;

DROP TABLE emaj.emaj_relation;

-- create the new emaj_relation table and its indexes

CREATE TABLE emaj.emaj_relation (
    rel_schema               TEXT        NOT NULL,       -- schema name containing the relation
    rel_tblseq               TEXT        NOT NULL,       -- table or sequence name
    rel_group                TEXT        NOT NULL,       -- name of the group that owns the relation
    rel_priority             INTEGER,                    -- priority level of processing inside the group
    rel_log_schema           TEXT,                       -- schema for the log table, functions and sequence
    rel_log_dat_tsp          TEXT,                       -- tablespace for the log table (NULL for sequences)
    rel_log_idx_tsp          TEXT,                       -- tablespace for the log index (NULL for sequences)
    rel_kind                 TEXT,                       -- similar to the relkind column of pg_class table
                                                         --   ('r' = table, 'S' = sequence)
    rel_session              INT,                        -- rollback session id
    rel_rows                 BIGINT,                     -- number of rows to rollback, computed at rollback time
    PRIMARY KEY (rel_schema, rel_tblseq),
    FOREIGN KEY (rel_group) REFERENCES emaj.emaj_group (group_name) ON DELETE CASCADE
    );
COMMENT ON TABLE emaj.emaj_relation IS
$$Contains the content (tables and sequences) of created E-Maj groups.$$;
CREATE INDEX emaj_relation_idx1 ON emaj.emaj_relation (rel_group, rel_kind);
CREATE INDEX emaj_relation_idx2 ON emaj.emaj_relation (rel_log_schema);

-- populate the new emaj_relation table
-- for tables
--   the new rel_log_schema is set to 'emaj'
--   the new rel_log_dat_tsp, rel_log_idx_tsp columns are retrieved for pg_catalog
INSERT INTO emaj.emaj_relation (rel_schema, rel_tblseq, rel_group, rel_priority, rel_log_schema, 
                            rel_log_dat_tsp, rel_log_idx_tsp, rel_kind, rel_session, rel_rows)
  SELECT rel_schema, rel_tblseq, rel_group, rel_priority, 'emaj',
         t1.spcname,
         t2.spcname,
         rel_kind, rel_session, rel_rows
    FROM emaj.emaj_relation_old,
         pg_catalog.pg_namespace n1, pg_catalog.pg_class c1
           left outer join pg_catalog.pg_tablespace t1 on (c1.reltablespace = t1.oid),
         pg_catalog.pg_namespace n2, pg_catalog.pg_class c2
           left outer join pg_catalog.pg_tablespace t2 on (c2.reltablespace = t2.oid)
    WHERE rel_kind = 'r'
      and c1.relname = rel_schema || '_' || rel_tblseq || '_log' and n1.nspname = 'emaj'
      and c1.relnamespace = n1.oid
      and c2.relname = rel_schema || '_' || rel_tblseq || '_log_idx' and n2.nspname = 'emaj'
      and c2.relnamespace = n2.oid
;
-- for sequences, all new columns are set to null
INSERT INTO emaj.emaj_relation (rel_schema, rel_tblseq, rel_group, rel_priority, rel_log_schema, 
                            rel_log_dat_tsp, rel_log_idx_tsp, rel_kind, rel_session, rel_rows)
  SELECT rel_schema, rel_tblseq, rel_group, rel_priority, NULL, NULL, NULL, rel_kind, rel_session, rel_rows
    FROM emaj.emaj_relation_old
    WHERE rel_kind = 'S'
;

-- suppress the previous already renamed emaj_relation table
DROP TABLE emaj.emaj_relation_old;

------------------------------------
--                                --
-- emaj types                 --
--                                --
------------------------------------

CREATE TYPE emaj._verify_groups_type AS (
    ver_schema    TEXT,
    ver_tblseq    TEXT,
    ver_msg       TEXT
    );
COMMENT ON TYPE emaj._verify_groups_type IS
$$Represents the structure of rows returned by the internal _verify_groups() function.$$;

------------------------------------
--                                --
-- emaj functions                 --
--                                --
------------------------------------

DROP FUNCTION emaj._verify_group(v_groupName TEXT, v_onErrorStop boolean);

CREATE OR REPLACE FUNCTION emaj._purge_hist() RETURNS VOID LANGUAGE sql as
$$
-- This function purges the emaj history by deleting all rows prior the 'history_retention' parameter
--   but not deleting rows generated by groups that are currently in logging state.
-- It is called at start group time and when oldest marks are deleted.
    DELETE FROM emaj.emaj_hist WHERE hist_datetime <
      (SELECT MIN(datetime) FROM
        (
                 -- compute the oldest active mark for all groups
          (SELECT MIN(mark_datetime) FROM emaj.emaj_mark WHERE mark_state = 'ACTIVE')
         UNION
                 -- compute the timestamp of now minus the history_retention (1 month by default)
          (SELECT current_timestamp -
                  coalesce((SELECT param_value_interval FROM emaj.emaj_param WHERE param_key = 'history_retention'),'1 MONTH'))
        ) AS tmst(datetime));
$$;

CREATE OR REPLACE FUNCTION emaj._get_mark_name(TEXT, TEXT) RETURNS TEXT LANGUAGE sql as
$$
-- This function returns a mark name if exists for a group, processing the EMAJ_LAST_MARK keyword.
-- input: group name and mark name
-- output: mark name or NULL
SELECT case
         when $2 = 'EMAJ_LAST_MARK' then
              (SELECT mark_name FROM emaj.emaj_mark WHERE mark_group = $1 ORDER BY mark_id DESC LIMIT 1)
         else (SELECT mark_name FROM emaj.emaj_mark WHERE mark_group = $1 AND mark_name = $2)
       end
$$;

CREATE OR REPLACE FUNCTION emaj._get_mark_datetime(TEXT, TEXT) RETURNS TIMESTAMPTZ LANGUAGE sql as
$$
-- This function returns the creation timestamp of a mark if exists for a group,
--   processing the EMAJ_LAST_MARK keyword.
-- input: group name and mark name
-- output: mark date-time or NULL
SELECT case
         when $2 = 'EMAJ_LAST_MARK' then
              (SELECT mark_datetime FROM emaj.emaj_mark WHERE mark_group = $1 ORDER BY mark_id DESC LIMIT 1)
         else (SELECT mark_datetime FROM emaj.emaj_mark WHERE mark_group = $1 AND mark_name = $2)
       end
$$;

CREATE OR REPLACE FUNCTION emaj._check_class(v_schemaName TEXT, v_className TEXT)
RETURNS TEXT LANGUAGE plpgsql AS
$_check_class$
-- This function verifies that an application table or sequence exists in pg_class
-- It also protects from a recursive use : tables or sequences from emaj schema cannot be managed by EMAJ
-- Input: the names of the schema and the class (table or sequence)
-- Output: the relkind of the class : 'r' for a table and 's' for a sequence
-- If the schema or the class is not known, the function stops.
  DECLARE
    v_relKind      TEXT;
    v_schemaOid    OID;
  BEGIN
    IF v_schemaName = 'emaj' THEN
      RAISE EXCEPTION '_check_class: object from schema % cannot be managed by EMAJ.', v_schemaName;
    END IF;
    SELECT oid INTO v_schemaOid FROM pg_catalog.pg_namespace WHERE nspname = v_schemaName;
    IF NOT FOUND THEN
      RAISE EXCEPTION '_check_class: schema % doesn''t exist.', v_schemaName;
    END IF;
    SELECT relkind INTO v_relKind FROM pg_catalog.pg_class
      WHERE relnamespace = v_schemaOid AND relname = v_className AND relkind in ('r','S');
    IF NOT FOUND THEN
      RAISE EXCEPTION '_check_class: table or sequence % doesn''t exist.', v_className;
    END IF;
    RETURN v_relKind;
  END;
$_check_class$;

CREATE OR REPLACE FUNCTION emaj._check_new_mark(v_mark TEXT, v_groupNames TEXT[])
RETURNS TEXT LANGUAGE plpgsql AS
$_check_new_mark$
-- This function verifies that a new mark name supplied the user is valid.
-- It processes the possible NULL mark value and the replacement of % wild characters.
-- It also checks that the mark name do not already exist for any group.
-- Input: name of the mark to set, array of group names
--        The array of group names may be NULL to avoid the check against groups
-- Output: internal name of the mark
  DECLARE
    v_i             INT;
    v_markName      TEXT := v_mark;
  BEGIN
-- check the mark name is not 'EMAJ_LAST_MARK'
    IF v_mark = 'EMAJ_LAST_MARK' THEN
       RAISE EXCEPTION '_check_new_mark: % is not an allowed name for a new mark.', v_mark;
    END IF;
-- process null or empty supplied mark name
    IF v_markName = '' OR v_markName IS NULL THEN
      v_markName = 'MARK_%';
    END IF;
-- process % wild characters in mark name
    v_markName = replace(v_markName, '%', to_char(current_timestamp, 'HH24.MI.SS.MS'));
-- if requested, check the existence of the mark in groups
    IF v_groupNames IS NOT NULL THEN
-- for each group of the array,
      FOR v_i in 1 .. array_upper(v_groupNames,1) LOOP
-- ... if a mark with the same name already exists for the group, stop
        PERFORM 0 FROM emaj.emaj_mark
          WHERE mark_group = v_groupNames[v_i] AND mark_name = v_markName;
        IF FOUND THEN
           RAISE EXCEPTION '_check_new_mark: Group % already contains a mark named %.', v_groupNames[v_i], v_markName;
        END IF;
      END LOOP;
    END IF;
    RETURN v_markName;
  END;
$_check_new_mark$;

CREATE OR REPLACE FUNCTION emaj._log_truncate_fnct() RETURNS TRIGGER AS
$_log_truncate_fnct$
-- The function is triggered by the execution of TRUNCATE SQL verb on tables of an audit_only group
-- in logging mode.
-- It can only be called with postgresql in a version greater or equal 8.4
  DECLARE
    v_logSchema      TEXT;
    v_logTableName   TEXT;
  BEGIN
    IF (TG_OP = 'TRUNCATE') THEN
      SELECT rel_log_schema INTO v_logSchema FROM emaj.emaj_relation
        WHERE rel_schema = TG_TABLE_SCHEMA AND rel_tblseq = TG_TABLE_NAME;
      v_logTableName := quote_ident(v_logSchema) || '.' || quote_ident(TG_TABLE_SCHEMA || '_' || TG_TABLE_NAME || '_log');
      EXECUTE 'INSERT INTO ' || v_logTableName || ' (emaj_verb) VALUES (''TRU'')';
    END IF;
    RETURN NULL;
  END;
$_log_truncate_fnct$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION emaj._create_log_schema(v_logSchemaName TEXT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS
$_create_log_schema$
-- The function creates a log schema and gives the appropriate rights to emaj users
-- Input: log schema name
-- The function is created as SECURITY DEFINER so that secondary schemas can be owned by superuser
  DECLARE
  BEGIN
-- check that the schema doesn't already exist
    PERFORM 0 FROM pg_catalog.pg_namespace WHERE nspname = v_logSchemaName;
    IF FOUND THEN
      RAISE EXCEPTION '_create_log_schema: schema % should not exist. Drop it manually, or modify emaj_group_def table''s content.',v_logSchemaName;
    END IF;
-- create the schema and give the appropriate rights
    EXECUTE 'CREATE SCHEMA ' || quote_ident(v_logSchemaName);
    EXECUTE 'GRANT ALL ON SCHEMA ' || quote_ident(v_logSchemaName) || ' TO emaj_adm';
    EXECUTE 'GRANT USAGE ON SCHEMA ' || quote_ident(v_logSchemaName) || ' TO emaj_viewer';
    RETURN;
  END;
$_create_log_schema$;

CREATE OR REPLACE FUNCTION emaj._drop_log_schema(v_logSchemaName TEXT, v_isForced BOOLEAN)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS
$_drop_log_schema$
-- The function drops a log schema
-- Input: log schema name, boolean telling whether the schema to drop may contain residual objects
-- The function is created as SECURITY DEFINER so that secondary schemas can be dropped in any case
  DECLARE
  BEGIN
-- check that the schema doesn't already exist
    PERFORM 0 FROM pg_catalog.pg_namespace WHERE nspname = v_logSchemaName;
    IF NOT FOUND THEN
      RAISE EXCEPTION '_drop_log_schema: schema % doesn''t exist.',v_logSchemaName;
    END IF;
    IF v_isForced THEN
-- drop cascade when called by emaj_force_xxx_group()
      EXECUTE 'DROP SCHEMA ' || quote_ident(v_logSchemaName) || ' CASCADE';
    ELSE
-- otherwise, drop restrict with a trap on the potential error
      BEGIN
        EXECUTE 'DROP SCHEMA ' || quote_ident(v_logSchemaName);
        EXCEPTION
-- trap the 2BP01 exception to generate a more understandable error message
          WHEN DEPENDENT_OBJECTS_STILL_EXIST THEN         -- SQLSTATE '2BP01'
            RAISE EXCEPTION '_drop_log_schema: cannot drop schema %. It probably owns unattended objects. Use the emaj_verify_all() function to get details', quote_ident(v_logSchemaName);
      END;
    END IF;
    RETURN;
  END;
$_drop_log_schema$;

DROP FUNCTION emaj._create_tbl(v_schemaName TEXT, v_tableName TEXT, v_isRollbackable BOOLEAN);
CREATE OR REPLACE FUNCTION emaj._create_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_logDatTsp TEXT, v_logIdxTsp TEXT, v_isRollbackable BOOLEAN)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS
$_create_tbl$
-- This function creates all what is needed to manage the log and rollback operations for an application table
-- Input: schema name (mandatory even for the 'public' schema), table name, schema holding log objects, data and index tablespaces for the log table, boolean indicating whether the table belongs to a rollbackable group
-- Are created in the log schema:
--    - the associated log table, with its own sequence
--    - the function that logs the tables updates, defined as a trigger
--    - the rollback function (one per table and only if the group is rollbackable)
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of the application table.
  DECLARE
-- variables for the name of tables, functions, triggers,...
    v_fullTableName         TEXT;
    v_dataTblSpace          TEXT;
    v_idxTblSpace           TEXT;
    v_logTableName          TEXT;
    v_logIdxName            TEXT;
    v_logFnctName           TEXT;
    v_rlbkFnctName          TEXT;
    v_exceptionRlbkFnctName TEXT;
    v_logTriggerName        TEXT;
    v_truncTriggerName      TEXT;
    v_sequenceName          TEXT;
-- variables to hold pieces of SQL
    v_pkCondList            TEXT;
    v_colList               TEXT;
    v_valList               TEXT;
    v_setList               TEXT;
-- other variables
    v_attname               TEXT;
    v_relhaspkey            BOOLEAN;
    v_pgVersion             TEXT := emaj._pg_version();
    v_stmt                  TEXT := '';
    v_triggerList           TEXT := '';
    r_column                RECORD;
    r_trigger               RECORD;
-- cursor to retrieve all columns of the application table
    col1_curs CURSOR (tbl regclass) FOR
      SELECT attname FROM pg_catalog.pg_attribute
        WHERE attrelid = tbl
          AND attnum > 0
          AND attisdropped = false
      ORDER BY attnum;
-- cursor to retrieve all columns of table's primary key
-- (taking column names in pg_attribute from the table's definition instead of index definition is mandatory
--  starting from pg9.0, joining tables with indkey instead of indexrelid)
    col2_curs CURSOR (tbl regclass) FOR
      SELECT attname FROM pg_catalog.pg_attribute, pg_catalog.pg_index
        WHERE pg_attribute.attrelid = pg_index.indrelid
          AND attnum = ANY (indkey)
          AND indrelid = tbl AND indisprimary
          AND attnum > 0 AND attisdropped = false;
  BEGIN
-- check the table has a primary key
    SELECT true INTO v_relhaspkey FROM pg_catalog.pg_class, pg_catalog.pg_namespace, pg_catalog.pg_constraint
      WHERE relnamespace = pg_namespace.oid AND connamespace = pg_namespace.oid AND conrelid = pg_class.oid
        AND contype = 'p' AND nspname = v_schemaName AND relname = v_tableName;
    IF NOT FOUND THEN
      v_relhaspkey = false;
    END IF;
    IF v_isRollbackable AND v_relhaspkey = FALSE THEN
      RAISE EXCEPTION '_create_tbl: table % has no PRIMARY KEY.', v_tableName;
    END IF;
-- prepare TABLESPACE clauses for data and index
    IF v_logDatTsp IS NOT NULL THEN
      v_dataTblSpace = 'TABLESPACE ' || quote_ident(v_logDatTsp);
    ELSE
      v_dataTblSpace = '';
    END IF;
    IF v_logIdxTsp IS NOT NULL THEN
      v_idxTblSpace = 'TABLESPACE ' || quote_ident(v_logIdxTsp);
    ELSE
      v_idxTblSpace = '';
    END IF;
-- build the different name for table, trigger, functions,...
    v_fullTableName    := quote_ident(v_schemaName) || '.' || quote_ident(v_tableName);
    v_logTableName     := quote_ident(v_logSchema) || '.' || quote_ident(v_schemaName || '_' || v_tableName || '_log');
    v_logIdxName       := quote_ident(v_schemaName || '_' || v_tableName || '_log_idx');
    v_logFnctName      := quote_ident(v_logSchema) || '.' || quote_ident(v_schemaName || '_' || v_tableName || '_log_fnct');
    v_rlbkFnctName     := quote_ident(v_logSchema) || '.' || quote_ident(v_schemaName || '_' || v_tableName || '_rlbk_fnct');
    v_exceptionRlbkFnctName=substring(quote_literal(v_rlbkFnctName) FROM '^(.*).$');   -- suppress last character
    v_logTriggerName   := quote_ident(v_schemaName || '_' || v_tableName || '_emaj_log_trg');
    v_truncTriggerName := quote_ident(v_schemaName || '_' || v_tableName || '_emaj_trunc_trg');
    v_sequenceName     := quote_ident(v_logSchema) || '.' || quote_ident(emaj._build_log_seq_name(v_schemaName, v_tableName));
-- creation of the log table: the log table looks like the application table, with some additional technical columns
    EXECUTE 'DROP TABLE IF EXISTS ' || v_logTableName;
    EXECUTE 'CREATE TABLE ' || v_logTableName
         || ' ( LIKE ' || v_fullTableName || ') ' || v_dataTblSpace;
    EXECUTE 'ALTER TABLE ' || v_logTableName
         || ' ADD COLUMN emaj_verb    VARCHAR(3),'
         || ' ADD COLUMN emaj_tuple   VARCHAR(3),'
         || ' ADD COLUMN emaj_gid     BIGINT      NOT NULL   DEFAULT nextval(''emaj.emaj_global_seq''),'
         || ' ADD COLUMN emaj_changed TIMESTAMPTZ DEFAULT clock_timestamp(),'
         || ' ADD COLUMN emaj_txid    BIGINT      DEFAULT emaj._txid_current(),'
         || ' ADD COLUMN emaj_user    VARCHAR(32) DEFAULT session_user,'
         || ' ADD COLUMN emaj_user_ip INET        DEFAULT inet_client_addr()';
-- creation of the index on the log table
    IF v_pgVersion >= '8.3' THEN
      EXECUTE 'CREATE UNIQUE INDEX ' || v_logIdxName || ' ON '
           ||  v_logTableName || ' (emaj_gid, emaj_tuple DESC) ' || v_idxTblSpace;
    ELSE
--   in 8.2, DESC clause doesn't exist. So the index cannot be used at rollback time.
--   It only enforces the uniqueness of (emaj_gid, emaj_tuple)
      EXECUTE 'CREATE UNIQUE INDEX ' || v_logIdxName || ' ON '
           ||  v_logTableName || ' (emaj_gid, emaj_tuple) ' || v_idxTblSpace;
    END IF;
-- remove the NOT NULL constraints of application columns.
--   They are useless and blocking to store truncate event for tables belonging to audit_only tables
    FOR r_column IN
      SELECT ' ALTER COLUMN ' || quote_ident(attname) || ' DROP NOT NULL' AS action
        FROM pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
        WHERE relnamespace = pg_namespace.oid AND attrelid = pg_class.oid
          AND nspname = v_logSchema AND relname = v_schemaName || '_' || v_tableName || '_log'
          AND attnum > 0 AND attnotnull AND attisdropped = false AND attname NOT LIKE E'emaj\\_%'
    LOOP
      IF v_stmt = '' THEN
        v_stmt = v_stmt || r_column.action;
      ELSE
        v_stmt = v_stmt || ',' || r_column.action;
      END IF;
    END LOOP;
    IF v_stmt <> '' THEN
      EXECUTE 'ALTER TABLE ' || v_logTableName || v_stmt;
    END IF;
-- create the sequence associated to the log table
    EXECUTE 'CREATE SEQUENCE ' || v_sequenceName;
-- creation of the log fonction that will be mapped to the log trigger later
-- The new row is logged for each INSERT, the old row is logged for each DELETE
-- and the old and the new rows are logged for each UPDATE.
    EXECUTE 'CREATE OR REPLACE FUNCTION ' || v_logFnctName || '() RETURNS trigger AS $logfnct$'
         || 'BEGIN'
-- The sequence associated to the log table is incremented at the beginning of the function ...
         || '  PERFORM NEXTVAL(' || quote_literal(v_sequenceName) || ');'
-- ... and the global id sequence is incremented by the first/only INSERT into the log table.
         || '  IF (TG_OP = ''DELETE'') THEN'
         || '    INSERT INTO ' || v_logTableName || ' SELECT OLD.*, ''DEL'', ''OLD'';'
         || '    RETURN OLD;'
         || '  ELSIF (TG_OP = ''UPDATE'') THEN'
         || '    INSERT INTO ' || v_logTableName || ' SELECT OLD.*, ''UPD'', ''OLD'';'
         || '    INSERT INTO ' || v_logTableName || ' SELECT NEW.*, ''UPD'', ''NEW'', lastval();'
         || '    RETURN NEW;'
         || '  ELSIF (TG_OP = ''INSERT'') THEN'
         || '    INSERT INTO ' || v_logTableName || ' SELECT NEW.*, ''INS'', ''NEW'';'
         || '    RETURN NEW;'
         || '  END IF;'
         || '  RETURN NULL;'
         || 'END;'
         || '$logfnct$ LANGUAGE plpgsql SECURITY DEFINER;';
-- creation of the log trigger on the application table, using the previously created log function
-- But the trigger is not immediately activated (it will be at emaj_start_group time)
    EXECUTE 'DROP TRIGGER IF EXISTS ' || v_logTriggerName || ' ON ' || v_fullTableName;
    EXECUTE 'CREATE TRIGGER ' || v_logTriggerName
         || ' AFTER INSERT OR UPDATE OR DELETE ON ' || v_fullTableName
         || '  FOR EACH ROW EXECUTE PROCEDURE ' || v_logFnctName || '()';
    EXECUTE 'ALTER TABLE ' || v_fullTableName || ' DISABLE TRIGGER ' || v_logTriggerName;
-- creation of the trigger that manage any TRUNCATE on the application table
-- But the trigger is not immediately activated (it will be at emaj_start_group time)
    IF v_pgVersion >= '8.4' THEN
      EXECUTE 'DROP TRIGGER IF EXISTS ' || v_truncTriggerName || ' ON ' || v_fullTableName;
      IF v_isRollbackable THEN
-- For rollbackable groups, use the common _forbid_truncate_fnct() function that blocks the operation
        EXECUTE 'CREATE TRIGGER ' || v_truncTriggerName
             || ' BEFORE TRUNCATE ON ' || v_fullTableName
             || '  FOR EACH STATEMENT EXECUTE PROCEDURE emaj._forbid_truncate_fnct()';
      ELSE
-- For audit_only groups, use the common _log_truncate_fnct() function that records the operation into the log table
        EXECUTE 'CREATE TRIGGER ' || v_truncTriggerName
             || ' BEFORE TRUNCATE ON ' || v_fullTableName
             || '  FOR EACH STATEMENT EXECUTE PROCEDURE emaj._log_truncate_fnct()';
      END IF;
      EXECUTE 'ALTER TABLE ' || v_fullTableName || ' DISABLE TRIGGER ' || v_truncTriggerName;
    END IF;
--
-- create the rollback function, if the table belongs to a rollbackable group
--
    IF v_isRollbackable THEN
-- First build some pieces of the CREATE FUNCTION statement
--   build the tables's columns list
--     and the SET clause for the UPDATE, from the same columns list
      v_colList := '';
      v_valList := '';
      v_setList := '';
      OPEN col1_curs (v_fullTableName);
      LOOP
        FETCH col1_curs INTO v_attname;
        EXIT WHEN NOT FOUND;
        IF v_colList = '' THEN
           v_colList := quote_ident(v_attname);
           v_valList := 'rec_log.' || quote_ident(v_attname);
           v_setList := quote_ident(v_attname) || ' = rec_old_log.' || quote_ident(v_attname);
        ELSE
           v_colList := v_colList || ', ' || quote_ident(v_attname);
           v_valList := v_valList || ', rec_log.' || quote_ident(v_attname);
           v_setList := v_setList || ', ' || quote_ident(v_attname) || ' = rec_old_log.' || quote_ident(v_attname);
        END IF;
      END LOOP;
      CLOSE col1_curs;
--   build "equality on the primary key" conditions, from the list of the primary key's columns
      v_pkCondList := '';
      OPEN col2_curs (v_fullTableName);
      LOOP
        FETCH col2_curs INTO v_attname;
        EXIT WHEN NOT FOUND;
        IF v_pkCondList = '' THEN
           v_pkCondList := quote_ident(v_attname) || ' = rec_log.' || quote_ident(v_attname);
        ELSE
           v_pkCondList := v_pkCondList || ' AND ' || quote_ident(v_attname) || ' = rec_log.' || quote_ident(v_attname);
        END IF;
      END LOOP;
      CLOSE col2_curs;
-- Then create the rollback function associated to the table
-- At execution, it will loop on each row from the log table in reverse order
--  It will insert the old deleted rows, delete the new inserted row
--  and update the new rows by setting back the old rows
-- The function returns the number of rollbacked elementary operations or rows
-- All these functions will be called by the emaj_rlbk_tbl function, which is activated by the
--  emaj_rollback_group function
      EXECUTE 'CREATE OR REPLACE FUNCTION ' || v_rlbkFnctName || ' (v_lastGlobalSeq BIGINT)'
           || ' RETURNS BIGINT AS $rlbkfnct$'
           || '  DECLARE'
           || '    v_nb_rows       BIGINT := 0;'
           || '    v_nb_proc_rows  INTEGER;'
           || '    rec_log     ' || v_logTableName || '%ROWTYPE;'
           || '    rec_old_log ' || v_logTableName || '%ROWTYPE;'
           || '    log_curs CURSOR FOR '
           || '      SELECT * FROM ' || v_logTableName
           || '        WHERE emaj_gid > v_lastGlobalSeq '
           || '        ORDER BY emaj_gid DESC, emaj_tuple;'
           || '  BEGIN'
           || '    OPEN log_curs;'
           || '    LOOP '
           || '      FETCH log_curs INTO rec_log;'
           || '      EXIT WHEN NOT FOUND;'
           || '      IF rec_log.emaj_verb = ''INS'' THEN'
--         || '          RAISE NOTICE ''emaj_gid = % ; INS'', rec_log.emaj_gid;'
           || '          DELETE FROM ONLY ' || v_fullTableName || ' WHERE ' || v_pkCondList || ';'
           || '      ELSIF rec_log.emaj_verb = ''UPD'' THEN'
--         || '          RAISE NOTICE ''emaj_gid = % ; UPD ; %'', rec_log.emaj_gid,rec_log.emaj_tuple;'
           || '          FETCH log_curs into rec_old_log;'
--         || '          RAISE NOTICE ''emaj_gid = % ; UPD ; %'', rec_old_log.emaj_gid,rec_old_log.emaj_tuple;'
           || '          UPDATE ONLY ' || v_fullTableName || ' SET ' || v_setList || ' WHERE ' || v_pkCondList || ';'
           || '      ELSIF rec_log.emaj_verb = ''DEL'' THEN'
--         || '          RAISE NOTICE ''emaj_gid = % ; DEL'', rec_log.emaj_gid;'
           || '          INSERT INTO ' || v_fullTableName || ' (' || v_colList || ') VALUES (' || v_valList || ');'
           || '      ELSE'
           || '          RAISE EXCEPTION ' || v_exceptionRlbkFnctName || ': internal error - emaj_verb = % is unknown, emaj_gid = %.'','
           || '            rec_log.emaj_verb, rec_log.emaj_gid;'
           || '      END IF;'
           || '      GET DIAGNOSTICS v_nb_proc_rows = ROW_COUNT;'
           || '      IF v_nb_proc_rows <> 1 THEN'
           || '        RAISE EXCEPTION ' || v_exceptionRlbkFnctName || ': internal error - emaj_verb = %, emaj_gid = %, # processed rows = % .'''
           || '           ,rec_log.emaj_verb, rec_log.emaj_gid, v_nb_proc_rows;'
           || '      END IF;'
           || '      v_nb_rows := v_nb_rows + 1;'
           || '    END LOOP;'
           || '    CLOSE log_curs;'
--         || '    RAISE NOTICE ''Table ' || v_fullTableName || ' -> % rollbacked rows.'', v_nb_rows;'
           || '    RETURN v_nb_rows;'
           || '  END;'
           || '$rlbkfnct$ LANGUAGE plpgsql;';
      END IF;
-- check if the table has (neither internal - ie. created for fk - nor previously created by emaj) trigger,
-- This check is not done for postgres 8.2 because column tgconstraint doesn't exist
    IF v_pgVersion >= '8.3' THEN
      FOR r_trigger IN
        SELECT tgname FROM pg_catalog.pg_trigger
          WHERE tgrelid = v_fullTableName::regclass AND tgconstraint = 0 AND tgname NOT LIKE E'%emaj\\_%\\_trg'
      LOOP
        IF v_triggerList = '' THEN
          v_triggerList = v_triggerList || r_trigger.tgname;
        ELSE
          v_triggerList = v_triggerList || ', ' || r_trigger.tgname;
        END IF;
      END LOOP;
-- if yes, issue a warning (if a trigger updates another table in the same table group or outside) it could generate problem at rollback time)
      IF v_triggerList <> '' THEN
        RAISE WARNING '_create_tbl: table % has triggers (%). Verify the compatibility with emaj rollback operations (in particular if triggers update one or several other tables). Triggers may have to be manualy disabled before rollback.', v_fullTableName, v_triggerList;
      END IF;
    END IF;
-- grant appropriate rights to both emaj roles
    EXECUTE 'GRANT SELECT ON TABLE ' || v_logTableName || ' TO emaj_viewer';
    EXECUTE 'GRANT ALL PRIVILEGES ON TABLE ' || v_logTableName || ' TO emaj_adm';
    EXECUTE 'GRANT SELECT ON SEQUENCE ' || v_sequenceName || ' TO emaj_viewer';
    EXECUTE 'GRANT ALL PRIVILEGES ON SEQUENCE ' || v_sequenceName || ' TO emaj_adm';
    RETURN;
  END;
$_create_tbl$;

DROP FUNCTION emaj._drop_tbl(v_schemaName TEXT, v_tableName TEXT, v_isRollbackable BOOLEAN);
CREATE OR REPLACE FUNCTION emaj._drop_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_isRollbackable BOOLEAN)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS
$_drop_tbl$
-- The function deletes all what has been created by _create_tbl function
-- Required inputs: schema name, table name, log schema and a boolean indicating whether the related group was created as rollbackable
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of the application table.
  DECLARE
    v_pgVersion        TEXT := emaj._pg_version();
    v_fullTableName    TEXT;
    v_logTableName     TEXT;
    v_logFnctName      TEXT;
    v_rlbkFnctName     TEXT;
    v_logTriggerName   TEXT;
    v_truncTriggerName TEXT;
    v_seqName          TEXT;
    v_fullSeqName      TEXT;
  BEGIN
    v_fullTableName    := quote_ident(v_schemaName) || '.' || quote_ident(v_tableName);
    v_logTableName     := quote_ident(v_logSchema) || '.' || quote_ident(v_schemaName || '_' || v_tableName || '_log');
    v_logFnctName      := quote_ident(v_logSchema) || '.' || quote_ident(v_schemaName || '_' || v_tableName || '_log_fnct');
    v_rlbkFnctName     := quote_ident(v_logSchema) || '.' || quote_ident(v_schemaName || '_' || v_tableName || '_rlbk_fnct');
    v_logTriggerName   := quote_ident(v_schemaName || '_' || v_tableName || '_emaj_log_trg');
    v_truncTriggerName := quote_ident(v_schemaName || '_' || v_tableName || '_emaj_trunc_trg');
    v_seqName          := emaj._build_log_seq_name(v_schemaName, v_tableName);
    v_fullSeqName      := quote_ident(v_logSchema) || '.' || quote_ident(v_seqName);
-- check the table exists before dropping its triggers
    PERFORM 0 FROM pg_catalog.pg_class, pg_catalog.pg_namespace
      WHERE relnamespace = pg_namespace.oid
        AND nspname = v_schemaName AND relname = v_tableName AND relkind = 'r';
    IF FOUND THEN
-- delete the log trigger on the application table
      EXECUTE 'DROP TRIGGER IF EXISTS ' || v_logTriggerName || ' ON ' || v_fullTableName;
-- delete the truncate trigger on the application table
      IF v_pgVersion >= '8.4' THEN
        EXECUTE 'DROP TRIGGER IF EXISTS ' || v_truncTriggerName || ' ON ' || v_fullTableName;
      END IF;
    END IF;
-- delete log and rollback functions,
    EXECUTE 'DROP FUNCTION IF EXISTS ' || v_logFnctName || '()';
    IF v_isRollbackable THEN
      EXECUTE 'DROP FUNCTION IF EXISTS ' || v_rlbkFnctName || '(bigint)';
    END IF;
-- delete the sequence associated to the log table
    EXECUTE 'DROP SEQUENCE IF EXISTS ' || v_fullSeqName;
-- delete the log table
    EXECUTE 'DROP TABLE IF EXISTS ' || v_logTableName || ' CASCADE';
-- delete rows related to the log sequence from emaj_sequence table
    DELETE FROM emaj.emaj_sequence WHERE sequ_schema = v_logSchema AND sequ_name = v_seqName;
-- delete rows related to the table from emaj_seq_hole table
    DELETE FROM emaj.emaj_seq_hole WHERE sqhl_schema = quote_ident(v_schemaName) AND sqhl_table = quote_ident(v_tableName);
    RETURN;
  END;
$_drop_tbl$;

CREATE OR REPLACE FUNCTION emaj._create_seq(v_schemaName TEXT, v_seqName TEXT, v_groupName TEXT)
RETURNS void LANGUAGE plpgsql AS
$_create_seq$
-- The function checks whether the sequence is related to a serial column of an application table.
-- If yes, it verifies that this table also belong to the same group
-- Required inputs: schema name and sequence name
  DECLARE
    v_tableSchema    TEXT;
    v_tableName      TEXT;
    v_tableGroup     TEXT;
  BEGIN
-- get the schema and the name of the table that contains a serial column this sequence is linked to, if one exists
    SELECT nt.nspname, ct.relname INTO v_tableSchema, v_tableName
      FROM pg_catalog.pg_class cs, pg_catalog.pg_namespace ns, pg_depend, 
           pg_catalog.pg_class ct, pg_catalog.pg_namespace nt
      WHERE cs.relname = v_seqName AND ns.nspname = v_schemaName -- the selected sequence
        AND cs.relnamespace = ns.oid                             -- join condition for sequence schema name
        AND ct.relnamespace = nt.oid                             -- join condition for linked table schema name
        AND pg_depend.objid = cs.oid                             -- join condition for the pg_depend table
        AND pg_depend.refobjid = ct.oid                          -- join conditions for depended table schema name
        AND pg_depend.classid = pg_depend.refclassid             -- the classid et refclassid must be 'pg_class'
        AND pg_depend.classid = (SELECT oid FROM pg_catalog.pg_class WHERE relname = 'pg_class');
    IF FOUND THEN
      SELECT grpdef_group INTO v_tableGroup FROM emaj.emaj_group_def 
        WHERE grpdef_schema = v_tableSchema AND grpdef_tblseq = v_tableName;
      IF NOT FOUND THEN
        RAISE WARNING '_create_seq: Sequence %.% is linked to table %.% but this table does not belong to any tables group.', v_schemaName, v_seqName, v_tableSchema, v_tableName;
      ELSE
        IF v_tableGroup <> v_groupName THEN
          RAISE WARNING '_create_seq: Sequence %.% is linked to table %.% but this table belong to another tables group (%).', v_schemaName, v_seqName, v_tableSchema, v_tableName, v_tableGroup;
        END IF;
      END IF;
    END IF;
    RETURN;
  END;
$_create_seq$;

DROP FUNCTION emaj._rlbk_tbl(v_schemaName TEXT, v_tableName TEXT, v_lastGlobalSeq BIGINT, v_timestamp TIMESTAMPTZ, v_deleteLog BOOLEAN, v_lastSequenceId BIGINT, v_lastSeqHoleId BIGINT);
CREATE OR REPLACE FUNCTION emaj._rlbk_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_lastGlobalSeq BIGINT, v_timestamp TIMESTAMPTZ, v_deleteLog BOOLEAN, v_lastSequenceId BIGINT, v_lastSeqHoleId BIGINT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS
$_rlbk_tbl$
-- This function rollbacks one table to a given timestamp
-- The function is called by emaj._rlbk_groups_step5()
-- Input: schema name and table name, log schema, global sequence value limit for rollback, mark timestamp,
--        flag to specify if rollbacked log rows must be deleted,
--        last sequence and last hole identifiers to keep (greater ones being to be deleted)
-- The v_deleteLog flag must be set to true for common (unlogged) rollback and false for logged rollback
-- For unlogged rollback, the log triggers have been disabled previously and will be enabled later.
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of the application table.
  DECLARE
    v_fullTableName  TEXT;
    v_logTableName   TEXT;
    v_rlbkFnctName   TEXT;
    v_seqName        TEXT;
    v_fullSeqName    TEXT;
    v_nb_rows        BIGINT;
    v_tsrlbk_start   TIMESTAMP;
    v_tsrlbk_end     TIMESTAMP;
    v_tsdel_start    TIMESTAMP;
    v_tsdel_end      TIMESTAMP;
  BEGIN
    v_fullTableName  := quote_ident(v_schemaName) || '.' || quote_ident(v_tableName);
    v_logTableName   := quote_ident(v_logSchema) || '.' || quote_ident(v_schemaName || '_' || v_tableName || '_log');
    v_rlbkFnctName   := quote_ident(v_logSchema) || '.' ||
                        quote_ident(v_schemaName || '_' || v_tableName || '_rlbk_fnct');
    v_seqName        := emaj._build_log_seq_name(v_schemaName, v_tableName);
    v_fullSeqName    := quote_ident(v_logSchema) || '.' || quote_ident(v_seqName);
-- insert begin event in history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('ROLLBACK_TABLE', 'BEGIN', v_fullTableName, 'All log rows with emaj_gid > ' || v_lastGlobalSeq);
-- record the time at the rollback start
    SELECT clock_timestamp() INTO v_tsrlbk_start;
-- rollback the table
    EXECUTE 'SELECT ' || v_rlbkFnctName || '(' || v_lastGlobalSeq || ')' INTO v_nb_rows;
-- record the time at the rollback
    SELECT clock_timestamp() INTO v_tsrlbk_end;
-- insert rollback duration into the emaj_rlbk_stat table, if at least 1 row has been processed
    IF v_nb_rows > 0 THEN
      INSERT INTO emaj.emaj_rlbk_stat (rlbk_operation, rlbk_schema, rlbk_tbl_fk, rlbk_datetime, rlbk_nb_rows, rlbk_duration)
         VALUES ('rlbk', v_schemaName, v_tableName, v_tsrlbk_start, v_nb_rows, v_tsrlbk_end - v_tsrlbk_start);
    END IF;
-- if the caller requires it, suppress the rollbacked log part
    IF v_deleteLog THEN
-- record the time at the delete start
      SELECT clock_timestamp() INTO v_tsdel_start;
-- delete obsolete log rows
      EXECUTE 'DELETE FROM ' || v_logTableName || ' WHERE emaj_gid > ' || v_lastGlobalSeq;
-- ... and suppress from emaj_sequence table the rows regarding the emaj log sequence for this application table
--     corresponding to potential later intermediate marks that disappear with the rollback operation
      DELETE FROM emaj.emaj_sequence
        WHERE sequ_schema = v_logSchema AND sequ_name = v_seqName AND sequ_id > v_lastSequenceId;
-- record the sequence holes generated by the delete operation
-- this is due to the fact that log sequences are not rollbacked, this information will be used by the emaj_log_stat_group
--   function (and indirectly by emaj_estimate_rollback_duration())
-- first delete, if exist, sequence holes that have disappeared with the rollback
      DELETE FROM emaj.emaj_seq_hole
        WHERE sqhl_schema = v_schemaName AND sqhl_table = v_tableName AND sqhl_id > v_lastSeqHoleId;
-- and then insert the new sequence hole
      EXECUTE 'INSERT INTO emaj.emaj_seq_hole (sqhl_schema, sqhl_table, sqhl_hole_size) VALUES ('
        || quote_literal(v_schemaName) || ',' || quote_literal(v_tableName) || ', ('
        || ' SELECT CASE WHEN is_called THEN last_value + increment_by ELSE last_value END FROM ' || v_fullSeqName
        || ')-('
        || ' SELECT CASE WHEN sequ_is_called THEN sequ_last_val + sequ_increment ELSE sequ_last_val END FROM '
        || ' emaj.emaj_sequence WHERE'
        || ' sequ_schema = ' || quote_literal(v_logSchema)
        || ' AND sequ_name = ' || quote_literal(v_seqName)
        || ' AND sequ_datetime = ' || quote_literal(v_timestamp) || '))';
-- record the time at the delete
      SELECT clock_timestamp() INTO v_tsdel_end;
-- insert delete duration into the emaj_rlbk_stat table, if at least 1 row has been processed
      IF v_nb_rows > 0 THEN
        INSERT INTO emaj.emaj_rlbk_stat (rlbk_operation, rlbk_schema, rlbk_tbl_fk, rlbk_datetime, rlbk_nb_rows, rlbk_duration)
           VALUES ('del_log', v_schemaName, v_tableName, v_tsrlbk_start, v_nb_rows, v_tsdel_end - v_tsdel_start);
      END IF;
    END IF;
-- insert end event in history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('ROLLBACK_TABLE', 'END', v_fullTableName, v_nb_rows || ' rollbacked rows');
    RETURN;
  END;
$_rlbk_tbl$;

DROP FUNCTION emaj._log_stat_table(v_schemaName TEXT, v_tableName TEXT, v_tsFirstMark TIMESTAMPTZ, v_tsLastMark TIMESTAMPTZ, v_firstLastSeqHoleId BIGINT, v_lastLastSeqHoleId BIGINT);
CREATE OR REPLACE FUNCTION emaj._log_stat_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_tsFirstMark TIMESTAMPTZ, v_tsLastMark TIMESTAMPTZ, v_firstLastSeqHoleId BIGINT, v_lastLastSeqHoleId BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS
$_log_stat_tbl$
-- This function returns the number of log rows for a single table between 2 marks or between a mark and the current situation.
-- It is called by emaj_log_stat_group function
-- These statistics are computed using the serial id of log tables and holes is sequences recorded into emaj_seq_hole at rollback time
-- Input: schema name and table name, log schema, the timestamps of both marks, the emaj_seq_hole last id of both marks
--   a NULL value as last timestamp mark indicates the current situation
-- Output: number of log rows between both marks for the table
  DECLARE
    v_fullSeqName     TEXT;
    v_beginLastValue  BIGINT;
    v_endLastValue    BIGINT;
    v_sumHole         BIGINT;
  BEGIN
-- get the log table id at first mark time
    SELECT CASE WHEN sequ_is_called THEN sequ_last_val ELSE sequ_last_val - sequ_increment END INTO v_beginLastValue
       FROM emaj.emaj_sequence
       WHERE sequ_schema = v_logSchema
         AND sequ_name = emaj._build_log_seq_name(v_schemaName,v_tableName)
         AND sequ_datetime = v_tsFirstMark;
    IF v_tsLastMark IS NULL THEN
-- last mark is NULL, so examine the current state of the log table id
      v_fullSeqName := quote_ident(v_logSchema) || '.' || quote_ident(emaj._build_log_seq_name(v_schemaName, v_tableName));
      EXECUTE 'SELECT CASE WHEN is_called THEN last_value ELSE last_value - increment_by END FROM ' || v_fullSeqName INTO v_endLastValue;
--   and count the sum of hole from the start mark time until now
      SELECT coalesce(sum(sqhl_hole_size),0) INTO v_sumHole FROM emaj.emaj_seq_hole
        WHERE sqhl_schema = v_schemaName AND sqhl_table = v_tableName
          AND sqhl_id > v_firstLastSeqHoleId;
    ELSE
-- last mark is not NULL, so get the log table id at last mark time
      SELECT CASE WHEN sequ_is_called THEN sequ_last_val ELSE sequ_last_val - sequ_increment END INTO v_endLastValue
         FROM emaj.emaj_sequence
         WHERE sequ_schema = v_logSchema
           AND sequ_name = emaj._build_log_seq_name(v_schemaName,v_tableName)
           AND sequ_datetime = v_tsLastMark;
--   and count the sum of hole from the start mark time to the end mark time
      SELECT coalesce(sum(sqhl_hole_size),0) INTO v_sumHole FROM emaj.emaj_seq_hole
        WHERE sqhl_schema = v_schemaName AND sqhl_table = v_tableName
          AND sqhl_id > v_firstLastSeqHoleId AND sqhl_id <= v_lastLastSeqHoleId;
    END IF;
-- return the stat row for the table
    RETURN (v_endLastValue - v_beginLastValue - v_sumHole);
  END;
$_log_stat_tbl$;

CREATE OR REPLACE FUNCTION emaj._verify_groups(v_groups TEXT[], v_onErrorStop BOOLEAN)
RETURNS SETOF emaj._verify_groups_type LANGUAGE plpgsql AS
$_verify_groups$
-- The function verifies the consistency of a tables groups array.
-- Input: - tables groups array,
--        - a boolean indicating whether the function has to raise an exception in case of detected unconsistency.
-- If onErrorStop boolean is false, it returns a set of _verify_groups_type records, one row per detected unconsistency, including the faulting schema and table or sequence names and a detailed message. 
-- If no error is detected, no row is returned.
  DECLARE
    v_pgVersion      TEXT := emaj._pg_version();
    v_emajSchema     TEXT := 'emaj';
    v_hint           TEXT := 'You may use "SELECT * FROM emaj.emaj_verify_all()" to look for other issues.';
    r_object         RECORD;
  BEGIN
-- Note that there is no check that the supplied groups exist. This has already been done by all calling functions.
-- Let's start with some global checks that always raise an exception if an issue is detected
-- check the postgres version: E-Maj is not compatible with 8.1-
    IF v_pgVersion < '8.2' THEN
      RAISE EXCEPTION 'The current postgres version (%) is not compatible with E-Maj.', version();
    END IF;
-- check the postgres version at groups creation time is compatible with the current version
-- Warning: comparisons on version numbers are alphanumeric.
--          But we suppose these tests will not be useful any more when pg 10.0 will appear!
--   for 8.2 and 8.3, both major versions must be the same
    FOR r_object IN
      SELECT 'The group "' || group_name || '" has been created with a non compatible postgresql version (' ||
               group_pg_version || '). It must be dropped and recreated.' AS msg
        FROM emaj.emaj_group
        WHERE group_name = ANY (v_groups)
          AND ((v_pgVersion = '8.2' OR v_pgVersion = '8.3') 
               AND substring (group_pg_version FROM E'(\\d+\\.\\d+)') <> v_pgVersion) OR
--   for 8.4+, both major versions must be 8.4+
              (v_pgVersion >= '8.4' AND substring (group_pg_version FROM E'(\\d+\\.\\d+)') < '8.4')
        ORDER BY msg
    LOOP
      RAISE EXCEPTION '_verify_groups: %',r_object.msg;
    END LOOP;
-- OK, now look for groups unconsistency
-- Unlike emaj_verify_all(), there is no direct check that application schemas exist
-- check all application relations referenced in the emaj_relation table still exist
    FOR r_object IN
      SELECT t.rel_schema, t.rel_tblseq, 
             'In group "' || r.rel_group || '", the ' ||
               CASE WHEN t.rel_kind = 'r' THEN 'table "' ELSE 'sequence "' END || 
               t.rel_schema || '"."' || t.rel_tblseq || '" does not exist any more.' AS msg
        FROM (                                    -- all relations known by E-Maj
          SELECT rel_schema, rel_tblseq, rel_kind FROM emaj.emaj_relation WHERE rel_group = ANY (v_groups)
            EXCEPT                                -- all relations known by postgres
          SELECT nspname, relname, relkind FROM pg_catalog.pg_class, pg_catalog.pg_namespace 
            WHERE relnamespace = pg_namespace.oid AND relkind IN ('r','S')
             ) AS t, emaj.emaj_relation r         -- join with emaj_relation to get the group name
        WHERE t.rel_schema = r.rel_schema AND t.rel_tblseq = r.rel_tblseq
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_group: % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
-- check the log table for all tables referenced in the emaj_relation table still exist
    FOR r_object IN
      SELECT rel_schema, rel_tblseq,
             'In group "' || rel_group || '", the log table "' || 
               rel_log_schema || '"."' || rel_schema || '_' || rel_tblseq || '_log" is not found.' AS msg
        FROM emaj.emaj_relation
        WHERE rel_group = ANY (v_groups)
          AND rel_kind = 'r'
          AND (rel_log_schema, rel_schema || '_' || rel_tblseq || '_log') NOT IN
              (SELECT nspname, relname FROM pg_catalog.pg_namespace, pg_catalog.pg_class
                 WHERE relnamespace = pg_namespace.oid AND relname LIKE E'%\_%\_log')
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_group: % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
-- check log and rollback functions for all tables referenced in the emaj_relation table still exist
    FOR r_object IN
                                                  -- the schema and table names are rebuilt from the returned function name
      SELECT substring(fnct FROM '^(.*)_.*_.*_fnct') AS sch, substring(fnct FROM '^.*_(.*)_.*_fnct') AS tbl,
             'In group "' || r.rel_group || '", the ' || 
               CASE WHEN substring(fnct FROM '^.*_.*_(.*)_fnct') = 'log' THEN 'log' ELSE 'rollback' END || 
               ' function "' || t.rel_log_schema || '"."' || fnct || '" is not found.' AS msg
        FROM (                                    -- all expected log functions 
         (SELECT rel_log_schema, rel_schema || '_' || rel_tblseq || '_log_fnct' AS fnct 
            FROM emaj.emaj_relation 
            WHERE rel_group = ANY (v_groups) AND rel_kind = 'r'
          UNION ALL                               -- plus all expected rollback functions
          SELECT rel_log_schema, rel_schema || '_' || rel_tblseq || '_rlbk_fnct' AS fnct 
            FROM emaj.emaj_relation, emaj.emaj_group
            WHERE group_name = rel_group AND group_is_rollbackable 
              AND rel_group = ANY (v_groups) AND rel_kind = 'r' 
         ) EXCEPT                                 -- minus functions known by postgres
         SELECT nspname, proname FROM pg_catalog.pg_proc, pg_catalog.pg_namespace
           WHERE pronamespace = pg_namespace.oid AND proname LIKE E'%\_%\_%\_fnct'
             ) AS t, emaj.emaj_relation r         -- join with emaj_relation to get the group name
        WHERE r.rel_schema = substring(fnct FROM '^(.*)_.*_.*_fnct') AND r.rel_tblseq = substring(fnct FROM '^.*_(.*)_.*_fnct')
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_group: % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
-- check log and truncate triggers for all tables referenced in the emaj_relation table still exist
--   start with log trigger
    FOR r_object IN
      SELECT rel_schema, rel_tblseq,
             'In group "' || rel_group || '", the log trigger "' || 
               rel_schema || '_' || rel_tblseq || '_emaj_log_trg" is not found.' AS msg
        FROM emaj.emaj_relation
        WHERE rel_group = ANY (v_groups) AND rel_kind = 'r'
          AND (rel_schema, rel_tblseq, rel_schema || '_' || rel_tblseq || '_emaj_log_trg') NOT IN
              (SELECT nspname, relname, tgname 
                 FROM pg_catalog.pg_trigger, pg_catalog.pg_namespace, pg_catalog.pg_class
                 WHERE tgrelid = pg_class.oid AND relnamespace = pg_namespace.oid 
                   AND tgname LIKE E'%\_%\_emaj\_log\_trg')
        ORDER BY 1,2,3
    LOOP
      IF v_onErrorStop THEN RAISE EXCEPTION '_verify_group: % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
--   then truncate trigger if pg 8.4+
    IF v_pgVersion >= '8.4' THEN
      FOR r_object IN
        SELECT rel_schema, rel_tblseq,
               'In group "' || rel_group || '", the truncate trigger "' || 
                 rel_schema || '_' || rel_tblseq || '_emaj_trunc_trg" is not found.' AS msg
          FROM emaj.emaj_relation
        WHERE rel_group = ANY (v_groups) AND rel_kind = 'r'
            AND (rel_schema, rel_tblseq, rel_schema || '_' || rel_tblseq || '_emaj_trunc_trg') NOT IN
                (SELECT nspname, relname, tgname 
                   FROM pg_catalog.pg_trigger, pg_catalog.pg_namespace, pg_catalog.pg_class
                   WHERE tgrelid = pg_class.oid AND relnamespace = pg_namespace.oid 
                     AND tgname LIKE E'%\_%\_emaj\_trunc\_trg')
        ORDER BY 1,2,3
      LOOP
        IF v_onErrorStop THEN RAISE EXCEPTION '_verify_group: % %',r_object.msg,v_hint; END IF;
        RETURN NEXT r_object;
      END LOOP;
-- TODO : merge both triggers check when pg 8.3 will not be supported any more
    END IF;
-- check all log tables have a structure consistent with the application tables they reference
--      (same columns and same formats). It only returns one row per faulting table.
    FOR r_object IN
      SELECT DISTINCT rel_schema, rel_tblseq,
             'In group "' || rel_group || '", the structure of the application table "' || 
               rel_schema || '"."' || rel_tblseq || '" is not coherent with its log table ("' || 
             rel_log_schema || '"."' || rel_schema || '_' || rel_tblseq || '_log").' AS msg
        FROM (
          (                                       -- application table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, attname, atttypid, attlen, atttypmod
            FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE relnamespace = pg_namespace.oid AND nspname = rel_schema AND relname = rel_tblseq
              AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = false
              AND rel_group = ANY (v_groups) AND rel_kind = 'r'
          EXCEPT                                   -- minus log table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, attname, atttypid, attlen, atttypmod
            FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE relnamespace = pg_namespace.oid AND nspname = rel_log_schema 
              AND relname = rel_schema || '_' || rel_tblseq || '_log'
              AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = false AND attname NOT LIKE 'emaj%'
              AND rel_group = ANY (v_groups) AND rel_kind = 'r'
          )
          UNION
          (                                         -- log table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, attname, atttypid, attlen, atttypmod
            FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE relnamespace = pg_namespace.oid AND nspname = rel_log_schema 
              AND relname = rel_schema || '_' || rel_tblseq || '_log'
              AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = false AND attname NOT LIKE 'emaj%'
              AND rel_group = ANY (v_groups) AND rel_kind = 'r'
          EXCEPT                                    -- minus application table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, attname, atttypid, attlen, atttypmod
            FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE relnamespace = pg_namespace.oid AND nspname = rel_schema AND relname = rel_tblseq
              AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = false
              AND rel_group = ANY (v_groups) AND rel_kind = 'r'
          )) AS t
        ORDER BY 1,2,3
-- TODO : use CTE to improve performance, when pg 8.3 will not be supported any more
    LOOP
      if v_onErrorStop THEN RAISE EXCEPTION '_verify_group: % %',r_object.msg,v_hint; END IF;
      RETURN NEXT r_object;
    END LOOP;
    RETURN;
  END;
$_verify_groups$;

CREATE OR REPLACE FUNCTION emaj._check_fk_groups(v_groupNames TEXT[])
RETURNS void LANGUAGE plpgsql AS
$_check_fk_groups$
-- this function checks foreign key constraints for tables of a groups array.
-- tables from audit_only groups are ignored in this check because they will never be rollbacked.
-- Input: group names array
  DECLARE
    r_fk             RECORD;
  BEGIN
-- issue a warning if a table of the groups has a foreign key that references a table outside the groups
    FOR r_fk IN
      SELECT c.conname,r.rel_schema,r.rel_tblseq,nf.nspname,tf.relname
        FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_class t,
             pg_catalog.pg_namespace nf, pg_catalog.pg_class tf, emaj.emaj_relation r, emaj.emaj_group g
        WHERE contype = 'f'                                         -- FK constraints only
          AND c.conrelid  = t.oid  AND t.relnamespace  = n.oid      -- join for table and namespace
          AND c.confrelid = tf.oid AND tf.relnamespace = nf.oid     -- join for referenced table and namespace
          AND n.nspname = r.rel_schema AND t.relname = r.rel_tblseq -- join on emaj_relation table
          AND r.rel_group = g.group_name                            -- join on emaj_group table
          AND r.rel_group = ANY (v_groupNames)                      -- only tables of the selected groups
          AND g.group_is_rollbackable                               -- only tables from rollbackable groups
          AND (nf.nspname,tf.relname) NOT IN                        -- referenced table outside the groups
              (SELECT rel_schema,rel_tblseq FROM emaj.emaj_relation WHERE rel_group = ANY (v_groupNames))
      LOOP
      RAISE WARNING '_check_fk_groups: Foreign key %, from table %.%, references %.% that is outside groups (%).',
                r_fk.conname,r_fk.rel_schema,r_fk.rel_tblseq,r_fk.nspname,r_fk.relname,array_to_string(v_groupNames,',');
    END LOOP;
-- issue a warning if a table of the groups is referenced by a table outside the groups
    FOR r_fk IN
      SELECT c.conname,n.nspname,t.relname,r.rel_schema,r.rel_tblseq
        FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_class t,
             pg_catalog.pg_namespace nf, pg_catalog.pg_class tf, emaj.emaj_relation r, emaj.emaj_group g
        WHERE contype = 'f'                                           -- FK constraints only
          AND c.conrelid  = t.oid  AND t.relnamespace  = n.oid        -- join for table and namespace
          AND c.confrelid = tf.oid AND tf.relnamespace = nf.oid       -- join for referenced table and namespace
          AND nf.nspname = r.rel_schema AND tf.relname = r.rel_tblseq -- join with emaj_relation table
          AND r.rel_group = g.group_name                              -- join on emaj_group table
          AND r.rel_group = ANY (v_groupNames)                        -- only tables of the selected groups
          AND g.group_is_rollbackable                                 -- only tables from rollbackable groups
          AND (n.nspname,t.relname) NOT IN                            -- referenced table outside the groups
              (SELECT rel_schema,rel_tblseq FROM emaj.emaj_relation WHERE rel_group = ANY (v_groupNames))
      LOOP
      RAISE WARNING '_check_fk_groups: table %.% is referenced by foreign key % from table %.% that is outside groups (%).',
                r_fk.rel_schema,r_fk.rel_tblseq,r_fk.conname,r_fk.nspname,r_fk.relname,array_to_string(v_groupNames,',');
    END LOOP;
    RETURN;
  END;
$_check_fk_groups$;

CREATE OR REPLACE FUNCTION emaj._lock_groups(v_groupNames TEXT[], v_lockMode TEXT, v_multiGroup BOOLEAN)
RETURNS void LANGUAGE plpgsql AS
$_lock_groups$
-- This function locks all tables of a groups array.
-- The lock mode is provided by the calling function.
-- It only locks existing tables. It is calling function's responsability to handle cases when application tables are missing.
-- Input: array of group names, lock mode, flag indicating whether the function is called to processed several groups
  DECLARE
    v_nbRetry       SMALLINT := 0;
    v_nbTbl         INT;
    v_ok            BOOLEAN := false;
    v_fullTableName TEXT;
    v_mode          TEXT;
    r_tblsq         RECORD;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES (CASE WHEN v_multiGroup THEN 'LOCK_GROUPS' ELSE 'LOCK_GROUP' END,'BEGIN', array_to_string(v_groupNames,','));
-- set the value for the lock mode that will be used in the LOCK statement
    IF v_lockMode = '' THEN
      v_mode = 'ACCESS EXCLUSIVE';
    ELSE
      v_mode = v_lockMode;
    END IF;
-- acquire lock on all tables
-- in case of deadlock, retry up to 5 times
    WHILE NOT v_ok AND v_nbRetry < 5 LOOP
      BEGIN
-- scan all existing tables of the group
        v_nbTbl = 0;
        FOR r_tblsq IN
            SELECT rel_priority, rel_schema, rel_tblseq
               FROM emaj.emaj_relation, pg_catalog.pg_class, pg_catalog.pg_namespace
               WHERE rel_group = ANY (v_groupNames) AND rel_kind = 'r'
                 AND relnamespace = pg_namespace.oid AND nspname = rel_schema AND relname = rel_tblseq
               ORDER BY rel_priority, rel_schema, rel_tblseq
            LOOP
-- lock the table
          v_fullTableName := quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
          EXECUTE 'LOCK TABLE ' || v_fullTableName || ' IN ' || v_mode || ' MODE';
          v_nbTbl = v_nbTbl + 1;
        END LOOP;
-- ok, all tables locked
        v_ok = true;
      EXCEPTION
        WHEN deadlock_detected THEN
          v_nbRetry = v_nbRetry + 1;
          RAISE NOTICE '_lock_groups: a deadlock has been trapped while locking tables of group %.', v_groupNames;
      END;
    END LOOP;
    IF NOT v_ok THEN
      RAISE EXCEPTION '_lock_groups: too many (5) deadlocks encountered while locking tables of group %.',v_groupNames;
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'LOCK_GROUPS' ELSE 'LOCK_GROUP' END, 'END', array_to_string(v_groupNames,','), v_nbTbl || ' tables locked, ' || v_nbRetry || ' deadlock(s)');
    RETURN;
  END;
$_lock_groups$;

CREATE OR REPLACE FUNCTION emaj.emaj_create_group(v_groupName TEXT, v_isRollbackable BOOLEAN)
RETURNS INT LANGUAGE plpgsql AS
$emaj_create_group$
-- This function creates emaj objects for all tables of a group
-- It also creates the secondary E-Maj schemas when needed
-- Input: group name, boolean indicating wether the group is rollbackable or not
-- Output: number of processed tables and sequences
  DECLARE
    v_nbTbl         INT := 0;
    v_nbSeq         INT := 0;
    v_emajSchema    TEXT := 'emaj';
    v_schemaPrefix  TEXT := 'emaj';
    v_logSchema     TEXT;
    v_msg           TEXT;
    v_relkind       TEXT;
    v_logDatTsp     TEXT;
    v_logIdxTsp     TEXT;
    v_defTsp        TEXT;
    v_stmt          TEXT;
    v_nb_trg        INT;
    r_tblsq         RECORD;
    r_schema        RECORD;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('CREATE_GROUP', 'BEGIN', v_groupName, CASE WHEN v_isRollbackable THEN 'rollbackable' ELSE 'audit_only' END);
-- check that the group name is valid
    IF v_groupName IS NULL THEN
      RAISE EXCEPTION 'emaj_create_group: group name can''t be NULL.';
    END IF;
    IF v_groupName = '' THEN
      RAISE EXCEPTION 'emaj_create_group: group name must at least contain 1 character.';
    END IF;
-- check the group is known in emaj_group_def table
    PERFORM 0 FROM emaj.emaj_group_def WHERE grpdef_group = v_groupName LIMIT 1;
    IF NOT FOUND THEN
       RAISE EXCEPTION 'emaj_create_group: Group % is unknown in emaj_group_def table.', v_groupName;
    END IF;
-- check that the group is not yet recorded in emaj_group table
    PERFORM 0 FROM emaj.emaj_group WHERE group_name = v_groupName;
    IF FOUND THEN
      RAISE EXCEPTION 'emaj_create_group: group % is already created.', v_groupName;
    END IF;
-- check that no table or sequence of the new group already belongs to another created group
    v_msg = '';
    FOR r_tblsq IN
        SELECT grpdef_schema, grpdef_tblseq, rel_group FROM emaj.emaj_group_def, emaj.emaj_relation
          WHERE grpdef_schema = rel_schema AND grpdef_tblseq = rel_tblseq AND grpdef_group = v_groupName
      LOOP
      IF v_msg <> '' THEN
        v_msg = v_msg || ', ';
      END IF;
      v_msg = v_msg || r_tblsq.grpdef_schema || '.' || r_tblsq.grpdef_tblseq || ' in ' || r_tblsq.rel_group;
    END LOOP;
    IF v_msg <> '' THEN
      RAISE EXCEPTION 'emaj_create_group: one or several tables already belong to another group (%).', v_msg;
    END IF;
-- OK, insert group row in the emaj_group table
    INSERT INTO emaj.emaj_group (group_name, group_state, group_is_rollbackable) VALUES (v_groupName, 'IDLE',v_isRollbackable);
-- look for new E-Maj secondary schemas to create
    FOR r_schema IN
      SELECT DISTINCT v_schemaPrefix || grpdef_log_schema_suffix AS log_schema FROM emaj.emaj_group_def
        WHERE grpdef_group = v_groupName
          AND grpdef_log_schema_suffix IS NOT NULL AND grpdef_log_schema_suffix <> ''
      EXCEPT
      SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation
      ORDER BY 1
      LOOP
-- create the schema
      PERFORM emaj._create_log_schema(r_schema.log_schema);
-- and record the schema creation in emaj_hist table
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
        VALUES ('CREATE_GROUP','SCHEMA CREATED',quote_ident(r_schema.log_schema));
    END LOOP;
-- define the default tablespace, NULL if tspemaj tablespace doesn't exist
    SELECT 'tspemaj' INTO v_defTsp FROM pg_catalog.pg_tablespace WHERE spcname = 'tspemaj';
-- scan all classes of the group (in priority order, NULLS being processed last)
    FOR r_tblsq IN
        SELECT grpdef_priority, grpdef_schema, grpdef_tblseq, grpdef_log_schema_suffix, grpdef_log_dat_tsp, grpdef_log_idx_tsp
          FROM emaj.emaj_group_def
          WHERE grpdef_group = v_groupName
          ORDER BY grpdef_priority, grpdef_schema, grpdef_tblseq
        LOOP
-- check the class is valid
      v_relkind = emaj._check_class(r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq);
      IF v_relkind = 'r' THEN
-- if it is a table, build the log schema name
        v_logSchema = coalesce(v_schemaPrefix || r_tblsq.grpdef_log_schema_suffix, v_emajSchema);
-- create the related emaj objects
        PERFORM emaj._create_tbl(r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq, v_logSchema, coalesce(r_tblsq.grpdef_log_dat_tsp, v_defTsp), coalesce(r_tblsq.grpdef_log_idx_tsp, v_defTsp), v_isRollbackable);
-- and record the table in the emaj_relation table
        INSERT INTO emaj.emaj_relation (rel_schema, rel_tblseq, rel_group, rel_priority, rel_log_schema, rel_log_dat_tsp, rel_log_idx_tsp, rel_kind)
            VALUES (r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq, v_groupName, r_tblsq.grpdef_priority, v_logSchema, coalesce(r_tblsq.grpdef_log_dat_tsp, v_defTsp), coalesce(r_tblsq.grpdef_log_idx_tsp, v_defTsp), v_relkind);
        v_nbTbl = v_nbTbl + 1;
      ELSEIF v_relkind = 'S' THEN
-- if it is a sequence, check no log schema has been set as parameter in the emaj_group_def table
        IF r_tblsq.grpdef_log_schema_suffix IS NOT NULL THEN
          RAISE EXCEPTION 'emaj_create_group: Defining a secondary log schema is not allowed for a sequence (%.%).', r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq;
        END IF;
--   check no tablespace has been set as parameter in the emaj_group_def table
        IF r_tblsq.grpdef_log_dat_tsp IS NOT NULL OR r_tblsq.grpdef_log_idx_tsp IS NOT NULL THEN
          RAISE EXCEPTION 'emaj_create_group: Defining log tablespaces is not allowed for a sequence (%.%).', r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq;
        END IF;
--   perform specific processing for sequences  
        PERFORM emaj._create_seq(r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq, v_groupName);
--   and record it in the emaj_relation table
        INSERT INTO emaj.emaj_relation (rel_schema, rel_tblseq, rel_group, rel_priority, rel_kind)
            VALUES (r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq, v_groupName, r_tblsq.grpdef_priority, v_relkind);
        v_nbSeq = v_nbSeq + 1;
      END IF;
    END LOOP;
-- update tables and sequences counters in the emaj_group table
    UPDATE emaj.emaj_group SET group_nb_table = v_nbTbl, group_nb_sequence = v_nbSeq
      WHERE group_name = v_groupName;
-- check foreign keys with tables outside the group
    PERFORM emaj._check_fk_groups (array[v_groupName]);
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('CREATE_GROUP', 'END', v_groupName, v_nbTbl + v_nbSeq || ' tables/sequences processed');
    RETURN v_nbTbl + v_nbSeq;
  END;
$emaj_create_group$;

COMMENT ON FUNCTION emaj.emaj_create_group(TEXT, BOOLEAN) IS
$$Creates an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_drop_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_drop_group$
-- This function deletes the emaj objects for all tables of a group
-- Input: group name
-- Output: number of processed tables and sequences
  DECLARE
    v_nbTb          INT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('DROP_GROUP', 'BEGIN', v_groupName);
-- effectively drop the group
    SELECT emaj._drop_group(v_groupName, FALSE) INTO v_nbTb;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('DROP_GROUP', 'END', v_groupName, v_nbTb || ' tables/sequences processed');
    RETURN v_nbTb;
  END;
$emaj_drop_group$;
COMMENT ON FUNCTION emaj.emaj_drop_group(TEXT) IS
$$Drops an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_force_drop_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_force_drop_group$
-- This function deletes the emaj objects for all tables of a group.
-- It differs from emaj_drop_group by the fact that:
--   - the group may be in LOGGING state
--   - a missing component in the drop processing does not generate any error
-- This allows to drop a group that is not consistent, following hasardeous operations.
-- This function should not be used, except if the emaj_drop_group fails.
-- Input: group name
-- Output: number of processed tables and sequences
  DECLARE
    v_nbTb          INT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('FORCE_DROP_GROUP', 'BEGIN', v_groupName);
-- effectively drop the group
    SELECT emaj._drop_group(v_groupName, TRUE) INTO v_nbTb;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('FORCE_DROP_GROUP', 'END', v_groupName, v_nbTb || ' tables/sequences processed');
    RETURN v_nbTb;
  END;
$emaj_force_drop_group$;
COMMENT ON FUNCTION emaj.emaj_force_drop_group(TEXT) IS
$$Drops an E-Maj group, even in LOGGING state.$$;

DROP FUNCTION emaj._drop_group(v_groupName TEXT, v_checkState BOOLEAN);
CREATE OR REPLACE FUNCTION emaj._drop_group(v_groupName TEXT, v_isForced BOOLEAN)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS
$_drop_group$
-- This function effectively deletes the emaj objects for all tables of a group
-- It also drops secondary schemas that are not useful any more
-- Input: group name, and a boolean indicating whether the group's state has to be checked
-- Output: number of processed tables and sequences
-- The function is defined as SECURITY DEFINER so that secondary schemas can be dropped
  DECLARE
    v_groupState     TEXT;
    v_isRollbackable BOOLEAN;
    v_nbTb           INT := 0;
    v_schemaPrefix   TEXT := 'emaj';
    r_tblsq          RECORD;
    r_schema         RECORD;
  BEGIN
-- check that the group is recorded in emaj_group table
    SELECT group_state, group_is_rollbackable INTO v_groupState, v_isRollbackable FROM emaj.emaj_group WHERE group_name = v_groupName FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '_drop_group: group % has not been created.', v_groupName;
    END IF;
-- if the state of the group has to be checked,
    IF NOT v_isForced THEN
--   check that the group is IDLE (i.e. not in a LOGGING) state
      IF v_groupState <> 'IDLE' THEN
        RAISE EXCEPTION '_drop_group: The group % cannot be deleted because it is not in idle state.', v_groupName;
      END IF;
    END IF;
-- OK, delete the emaj objets for each table of the group
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, rel_log_schema, rel_kind FROM emaj.emaj_relation
          WHERE rel_group = v_groupName ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
      IF r_tblsq.rel_kind = 'r' THEN
-- if it is a table, delete the related emaj objects
        PERFORM emaj._drop_tbl(r_tblsq.rel_schema, r_tblsq.rel_tblseq, r_tblsq.rel_log_schema, v_isRollbackable);
        ELSEIF r_tblsq.rel_kind = 'S' THEN
-- if it is a sequence, delete all related data from emaj_sequence table
          PERFORM emaj._drop_seq(r_tblsq.rel_schema, r_tblsq.rel_tblseq);
      END IF;
      v_nbTb = v_nbTb + 1;
    END LOOP;
-- look for E-Maj secondary schemas to drop (i.e. not used by any other created group)
    FOR r_schema IN
      SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation
        WHERE rel_group = v_groupName AND rel_log_schema <>  v_schemaPrefix
      EXCEPT
      SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation
        WHERE rel_group <> v_groupName AND rel_log_schema <>  v_schemaPrefix
      ORDER BY 1
      LOOP
-- drop the schema
      PERFORM emaj._drop_log_schema(r_schema.rel_log_schema, v_isForced);
-- and record the schema suppression in emaj_hist table
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
        VALUES (CASE WHEN v_isForced THEN 'FORCE_DROP_GROUP' ELSE 'DROP_GROUP' END,'SCHEMA DROPPED',quote_ident(r_schema.rel_log_schema));
    END LOOP;
-- delete group rows from the emaj_fk table.
    DELETE FROM emaj.emaj_fk WHERE v_groupName = ANY (fk_groups);
-- delete group row from the emaj_group table.
--   By cascade, it also deletes rows from emaj_relation and emaj_mark
    DELETE FROM emaj.emaj_group WHERE group_name = v_groupName;
    RETURN v_nbTb;
  END;
$_drop_group$;

CREATE OR REPLACE FUNCTION emaj.emaj_alter_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_alter_group$
-- This function alters a tables group.
-- It takes into account the changes recorded in the emaj_group_def table since the group has been created.
-- Executing emaj_alter_group() is equivalent to chaining emaj_drop_group() and emaj_create_group().
-- But only emaj objects that need to be dropped or created are processed.
-- Input: group name
-- Output: number of tables and sequences belonging to the group after the operation
  DECLARE
    v_emajSchema        TEXT := 'emaj';
    v_schemaPrefix      TEXT := 'emaj';
    v_nbCreate          INT := 0;
    v_nbDrop            INT := 0;
    v_nbTbl             INT;
    v_nbSeq             INT;
    v_groupState        TEXT;
    v_isRollbackable    BOOLEAN;
    v_logSchema         TEXT;
    v_logSchemasArray   TEXT[];
    v_msg               TEXT;
    v_relkind           TEXT;
    v_logDatTsp         TEXT;
    v_logIdxTsp         TEXT;
    v_defTsp            TEXT;
    v_nbMsg             INT;
    v_stmt              TEXT;
    v_nb_trg            INT;
    r_tblsq             RECORD;
    r_schema            RECORD;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('ALTER_GROUP', 'BEGIN', v_groupName);
-- check that the group is recorded in emaj_group table
    SELECT group_state, group_is_rollbackable INTO v_groupState, v_isRollbackable FROM emaj.emaj_group WHERE group_name = v_groupName FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_alter_group: group % has not been created.', v_groupName;
    END IF;
-- check that the group is IDLE (i.e. not in a LOGGING) state
    IF v_groupState <> 'IDLE' THEN
      RAISE EXCEPTION 'emaj_alter_group: The group % cannot be altered because it is not in idle state.', v_groupName;
    END IF;
-- check there are remaining rows for the group in emaj_group_def table
    PERFORM 0 FROM emaj.emaj_group_def WHERE grpdef_group = v_groupName LIMIT 1;
    IF NOT FOUND THEN
       RAISE EXCEPTION 'emaj_alter_group: Group % is unknown in emaj_group_def table.', v_groupName;
    END IF;
-- check that no table or sequence of the new group already belongs to another created group
    v_msg = '';
    FOR r_tblsq IN
        SELECT grpdef_schema, grpdef_tblseq, rel_group FROM emaj.emaj_group_def, emaj.emaj_relation
          WHERE grpdef_schema = rel_schema AND grpdef_tblseq = rel_tblseq
            AND grpdef_group = v_groupName AND rel_group <> v_groupName
      LOOP
      IF v_msg <> '' THEN
        v_msg = v_msg || ', ';
      END IF;
      v_msg = v_msg || r_tblsq.grpdef_schema || '.' || r_tblsq.grpdef_tblseq || ' in ' || r_tblsq.rel_group;
    END LOOP;
    IF v_msg <> '' THEN
      RAISE EXCEPTION 'emaj_alter_group: one or several tables already belong to another group (%).', v_msg;
    END IF;
-- define the default tablespace, NULL if tspemaj tablespace doesn't exist
    SELECT 'tspemaj' INTO v_defTsp FROM pg_catalog.pg_tablespace WHERE spcname = 'tspemaj';
-- OK, we can now process:
--   - relations that do not belong to the tables group any more, by dropping their emaj components
--   - relations that continue to belong to the tables group but with different characteristics,
--     by first dropping their emaj components and letting the last step recreate them
--   - new relations in the tables group, by (re)creating their emaj components
--
-- list all relations that do not belong to the tables group any more
    FOR r_tblsq IN
      SELECT rel_priority, rel_schema, rel_tblseq, rel_kind, rel_log_schema
        FROM emaj.emaj_relation
        WHERE rel_group = v_groupName
          AND (rel_schema, rel_tblseq) NOT IN (
              SELECT grpdef_schema, grpdef_tblseq
                FROM emaj.emaj_group_def
                WHERE grpdef_group = v_groupName)
      UNION
-- ... and all relations that are damaged or whose log table is not synchronised with them any more
      SELECT rel_priority, rel_schema, rel_tblseq, rel_kind, rel_log_schema
        FROM (                                   -- all damaged or out of sync tables
          SELECT DISTINCT ver_schema, ver_tblseq FROM emaj._verify_groups(ARRAY[v_groupName], false) 
             ) AS t, emaj.emaj_relation
        WHERE rel_schema = ver_schema AND rel_tblseq = ver_tblseq
      ORDER BY rel_priority, rel_schema, rel_tblseq
      LOOP
      IF r_tblsq.rel_kind = 'r' THEN
-- if it is a table, delete the related emaj objects
        PERFORM emaj._drop_tbl(r_tblsq.rel_schema, r_tblsq.rel_tblseq, r_tblsq.rel_log_schema, v_isRollbackable);
-- add the log schema to the array of log schemas to potentialy drop at the end of the function
        IF r_tblsq.rel_log_schema <> v_emajSchema AND
           (v_logSchemasArray IS NULL OR r_tblsq.rel_log_schema <> ALL (v_logSchemasArray)) THEN
          v_logSchemasArray = array_append(v_logSchemasArray,r_tblsq.rel_log_schema);
        END IF;
      ELSEIF r_tblsq.rel_kind = 'S' THEN
-- if it is a sequence, delete all related data from emaj_sequence table
        PERFORM emaj._drop_seq(r_tblsq.rel_schema, r_tblsq.rel_tblseq);
      END IF;
-- delete the related row in emaj_relation
      DELETE FROM emaj.emaj_relation WHERE rel_schema = r_tblsq.rel_schema AND rel_tblseq = r_tblsq.rel_tblseq;
      v_nbDrop = v_nbDrop + 1;
    END LOOP;
--
-- list relations that still belong to the tables group
    FOR r_tblsq IN
      SELECT rel_priority, rel_schema, rel_tblseq, rel_kind, rel_log_schema, rel_log_dat_tsp, rel_log_idx_tsp, grpdef_priority, grpdef_schema, grpdef_tblseq, grpdef_log_schema_suffix, grpdef_log_dat_tsp, grpdef_log_idx_tsp
        FROM emaj.emaj_relation, emaj.emaj_group_def
        WHERE rel_schema = grpdef_schema AND rel_tblseq = grpdef_tblseq
          AND rel_group = v_groupName
          AND grpdef_group = v_groupName
      ORDER BY rel_priority, rel_schema, rel_tblseq
      LOOP
-- now detect other changes that justify to drop and recreate the relation
-- detect if the log data tablespace in emaj_group_def has changed
      IF (r_tblsq.rel_kind = 'r' AND coalesce(r_tblsq.rel_log_dat_tsp,'') <> coalesce(r_tblsq.grpdef_log_dat_tsp, v_defTsp,''))
        OR (r_tblsq.rel_kind = 'S' AND r_tblsq.grpdef_log_dat_tsp IS NOT NULL)
-- or if the log index tablespace in emaj_group_def has changed
        OR (r_tblsq.rel_kind = 'r' AND coalesce(r_tblsq.rel_log_idx_tsp,'') <> coalesce(r_tblsq.grpdef_log_idx_tsp, v_defTsp,'')) 
        OR (r_tblsq.rel_kind = 'S' AND r_tblsq.grpdef_log_idx_tsp IS NOT NULL)
-- or if the log schema in emaj_group_def has changed
        OR (r_tblsq.rel_kind = 'r' AND r_tblsq.rel_log_schema <> (v_schemaPrefix || coalesce(r_tblsq.grpdef_log_schema_suffix, '')))
        OR (r_tblsq.rel_kind = 'S' AND r_tblsq.grpdef_log_schema_suffix IS NOT NULL) THEN
-- then drop the relation (it will be recreated later)
        IF r_tblsq.rel_kind = 'r' THEN
-- if it is a table, delete the related emaj objects
          PERFORM emaj._drop_tbl (r_tblsq.rel_schema, r_tblsq.rel_tblseq, r_tblsq.rel_log_schema, v_isRollbackable);
-- and add the log schema to the list of log schemas to potentialy drop at the end of the function
        IF r_tblsq.rel_log_schema <> v_emajSchema AND
           (v_logSchemasArray IS NULL OR r_tblsq.rel_log_schema <> ALL (v_logSchemasArray)) THEN
            v_logSchemasArray = array_append(v_logSchemasArray,r_tblsq.rel_log_schema);
          END IF;
        ELSEIF r_tblsq.rel_kind = 'S' THEN
-- if it is a sequence, delete all related data from emaj_sequence table
          PERFORM emaj._drop_seq (r_tblsq.rel_schema, r_tblsq.rel_tblseq);
        END IF;
-- delete the related row in emaj_relation
        DELETE FROM emaj.emaj_relation WHERE rel_schema = r_tblsq.grpdef_schema AND rel_tblseq = r_tblsq.grpdef_tblseq;
        v_nbDrop = v_nbDrop + 1;
-- other case ?
-- has the priority changed in emaj_group_def ? If yes, just report the change into emaj_relation
      ELSEIF (r_tblsq.rel_priority IS NULL AND r_tblsq.grpdef_priority IS NOT NULL) OR
             (r_tblsq.rel_priority IS NOT NULL AND r_tblsq.grpdef_priority IS NULL) OR
             (r_tblsq.rel_priority <> r_tblsq.grpdef_priority) THEN
        UPDATE emaj.emaj_relation SET rel_priority = r_tblsq.grpdef_priority
          WHERE rel_schema = r_tblsq.grpdef_schema AND rel_tblseq = r_tblsq.grpdef_tblseq;
      END IF;
    END LOOP;
--
-- cleanup all remaining log tables
    PERFORM emaj._reset_group(v_groupName);
-- drop useless log schemas, using the list of potential schemas to drop built previously
    IF v_logSchemasArray IS NOT NULL THEN
      FOR v_i IN 1 .. array_upper(v_logSchemasArray,1)
        LOOP
        PERFORM 0 FROM emaj.emaj_relation WHERE rel_log_schema = v_logSchemasArray [v_i] LIMIT 1;
        IF NOT FOUND THEN
-- drop the log schema
          PERFORM emaj._drop_log_schema(v_logSchemasArray [v_i], false);
-- and record the schema drop in emaj_hist table
          INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
            VALUES ('ALTER_GROUP','SCHEMA DROPPED',quote_ident(v_logSchemasArray [v_i]));
        END IF;
      END LOOP;
    END IF;
-- look for new E-Maj secondary schemas to create
    FOR r_schema IN
      SELECT DISTINCT v_schemaPrefix || grpdef_log_schema_suffix AS log_schema FROM emaj.emaj_group_def
        WHERE grpdef_group = v_groupName
          AND grpdef_log_schema_suffix IS NOT NULL AND grpdef_log_schema_suffix <> ''
      EXCEPT
      SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation
      ORDER BY 1
      LOOP
-- create the schema
      PERFORM emaj._create_log_schema(r_schema.log_schema);
-- and record the schema creation in emaj_hist table
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
        VALUES ('ALTER_GROUP','SCHEMA CREATED',quote_ident(r_schema.log_schema));
    END LOOP;
--
-- list new relations in the tables group (really new or intentionaly dropped in the preceeding steps)
    FOR r_tblsq IN
      SELECT grpdef_priority, grpdef_schema, grpdef_tblseq, grpdef_log_schema_suffix, grpdef_log_dat_tsp, grpdef_log_idx_tsp
        FROM emaj.emaj_group_def
        WHERE grpdef_group = v_groupName
          AND (grpdef_schema, grpdef_tblseq) NOT IN (
              SELECT rel_schema, rel_tblseq
                FROM emaj.emaj_relation
                WHERE rel_group = v_groupName)
      ORDER BY grpdef_priority, grpdef_schema, grpdef_tblseq
      LOOP
--
-- check the class is valid
      v_relkind = emaj._check_class(r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq);
      IF v_relkind = 'r' THEN
-- if it is a table, build the log schema name
        v_logSchema = coalesce(v_schemaPrefix ||  r_tblsq.grpdef_log_schema_suffix, v_emajSchema);
-- create the related emaj objects
        PERFORM emaj._create_tbl(r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq, v_logSchema, coalesce(r_tblsq.grpdef_log_dat_tsp, v_defTsp), coalesce(r_tblsq.grpdef_log_idx_tsp, v_defTsp), v_isRollbackable);
-- and record the table in the emaj_relation table
        INSERT INTO emaj.emaj_relation (rel_schema, rel_tblseq, rel_group, rel_priority, rel_log_schema, rel_log_dat_tsp, rel_log_idx_tsp, rel_kind)
            VALUES (r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq, v_groupName, r_tblsq.grpdef_priority, v_logSchema, coalesce(r_tblsq.grpdef_log_dat_tsp, v_defTsp), coalesce(r_tblsq.grpdef_log_idx_tsp, v_defTsp), v_relkind);
      ELSEIF v_relkind = 'S' THEN
-- if it is a sequence, check no log schema has been set as parameter in the emaj_group_def table
        IF r_tblsq.grpdef_log_schema_suffix IS NOT NULL THEN
          RAISE EXCEPTION 'emaj_alter_group: Defining a secondary log schema is not allowed for a sequence (%.%).', r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq;
        END IF;
--   check no tablespace has been set as parameter in the emaj_group_def table
        IF r_tblsq.grpdef_log_dat_tsp IS NOT NULL OR r_tblsq.grpdef_log_idx_tsp IS NOT NULL THEN
          RAISE EXCEPTION 'emaj_alter_group: Defining log tablespaces is not allowed for a sequence (%.%).', r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq;
        END IF;
--   perform specific processing for sequences  
        PERFORM emaj._create_seq(r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq, v_groupName);
--   and record it in the emaj_relation table
        INSERT INTO emaj.emaj_relation (rel_schema, rel_tblseq, rel_group, rel_priority, rel_kind)
            VALUES (r_tblsq.grpdef_schema, r_tblsq.grpdef_tblseq, v_groupName, r_tblsq.grpdef_priority, v_relkind);
      END IF;
      v_nbCreate = v_nbCreate + 1;
    END LOOP;
-- update tables and sequences counters and the last alter timestamp in the emaj_group table
    SELECT count(*) INTO v_nbTbl FROM emaj.emaj_relation WHERE rel_group = v_groupName AND rel_kind = 'r';
    SELECT count(*) INTO v_nbSeq FROM emaj.emaj_relation WHERE rel_group = v_groupName AND rel_kind = 'S';
    UPDATE emaj.emaj_group SET group_last_alter_datetime = transaction_timestamp(),
                               group_nb_table = v_nbTbl, group_nb_sequence = v_nbSeq
      WHERE group_name = v_groupName;
--	delete old marks of the tables group from emaj_mark
    DELETE FROM emaj.emaj_mark WHERE mark_group = v_groupName;
-- check foreign keys with tables outside the group
    PERFORM emaj._check_fk_groups(array[v_groupName]);
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('ALTER_GROUP', 'END', v_groupName, v_nbDrop || ' dropped relations and ' || v_nbCreate || ' (re)created relations');
    RETURN v_nbTbl + v_nbSeq;
  END;
$emaj_alter_group$;
COMMENT ON FUNCTION emaj.emaj_alter_group(TEXT) IS
$$Alter an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj._start_groups(v_groupNames TEXT[], v_mark TEXT, v_multiGroup BOOLEAN, v_resetLog BOOLEAN)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS
$_start_groups$
-- This function activates the log triggers of all the tables for one or several groups and set a first mark
-- It also delete oldest rows in emaj_hist table
-- Input: array of group names, name of the mark to set, boolean indicating whether the function is called by a multi group function, boolean indicating whether the function must reset the group at start time
-- Output: number of processed tables
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of application tables and sequences.
  DECLARE
    v_pgVersion        TEXT := emaj._pg_version();
    v_i                INT;
    v_groupState       TEXT;
    v_nbTb             INT := 0;
    v_markName         TEXT;
    v_logTableName     TEXT;
    v_fullTableName    TEXT;
    v_logTriggerName   TEXT;
    v_truncTriggerName TEXT;
    v_cpt              BIGINT;
    r_tblsq            RECORD;
  BEGIN
-- purge the emaj history, if needed
    PERFORM emaj._purge_hist();
-- if the group names array is null, immediately return 0
    IF v_groupNames IS NULL THEN
      RETURN 0;
    END IF;
-- check that each group is recorded in emaj_group table
    FOR v_i in 1 .. array_upper(v_groupNames,1) LOOP
      SELECT group_state INTO v_groupState FROM emaj.emaj_group WHERE group_name = v_groupNames[v_i] FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION '_start_group: group % has not been created.', v_groupNames[v_i];
      END IF;
-- ... and is in IDLE (i.e. not in a LOGGING) state
      IF v_groupState <> 'IDLE' THEN
        RAISE EXCEPTION '_start_group: The group % cannot be started because it is not in idle state. An emaj_stop_group function must be previously executed.', v_groupNames[v_i];
      END IF;
    END LOOP;
-- check that no group is damaged
    PERFORM 0 FROM emaj._verify_groups(v_groupNames, true);
-- for each group,
    FOR v_i in 1 .. array_upper(v_groupNames,1) LOOP
      if v_resetLog THEN
-- ... if requested by the user, call the emaj_reset_group function to erase remaining traces from previous logs
        SELECT emaj._reset_group(v_groupNames[v_i]) INTO v_nbTb;
      END IF;
-- ... and check foreign keys with tables outside the group
      PERFORM emaj._check_fk_groups(array[v_groupNames[v_i]]);
    END LOOP;
-- check and process the supplied mark name
    SELECT emaj._check_new_mark(v_mark, v_groupNames) INTO v_markName;
-- OK, lock all tables to get a stable point ...
-- (the ALTER TABLE statements will also set EXCLUSIVE locks, but doing this for all tables at the beginning of the operation decreases the risk for deadlock)
    PERFORM emaj._lock_groups(v_groupNames,'',v_multiGroup);
-- ... and enable all log triggers for the groups
    v_nbTb = 0;
-- for each relation of the group,
    FOR r_tblsq IN
       SELECT rel_priority, rel_schema, rel_tblseq, rel_kind FROM emaj.emaj_relation
         WHERE rel_group = ANY (v_groupNames) ORDER BY rel_priority, rel_schema, rel_tblseq
       LOOP
      IF r_tblsq.rel_kind = 'r' THEN
-- if it is a table, enable the emaj log and truncate triggers
        v_fullTableName  := quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
        v_logTriggerName := quote_ident(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_emaj_log_trg');
        v_truncTriggerName := quote_ident(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_emaj_trunc_trg');
        EXECUTE 'ALTER TABLE ' || v_fullTableName || ' ENABLE TRIGGER ' || v_logTriggerName;
        IF v_pgVersion >= '8.4' THEN
          EXECUTE 'ALTER TABLE ' || v_fullTableName || ' ENABLE TRIGGER ' || v_truncTriggerName;
        END IF;
        ELSEIF r_tblsq.rel_kind = 'S' THEN
-- if it is a sequence, nothing to do
      END IF;
      v_nbTb = v_nbTb + 1;
    END LOOP;
-- update the state of the group row from the emaj_group table
    UPDATE emaj.emaj_group SET group_state = 'LOGGING' WHERE group_name = ANY (v_groupNames);
-- Set the first mark for each group
    PERFORM emaj._set_mark_groups(v_groupNames, v_markName, v_multiGroup, true);
--
    RETURN v_nbTb;
  END;
$_start_groups$;

CREATE OR REPLACE FUNCTION emaj.emaj_stop_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_stop_group$
-- This function de-activates the log triggers of all the tables for a group.
-- Execute several emaj_stop_group functions for the same group doesn't produce any error.
-- Input: group name
-- Output: number of processed tables and sequences
  DECLARE
    v_nbTblSeq         INT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('STOP_GROUP', 'BEGIN', v_groupName);
-- call the common _stop_groups function
    SELECT emaj._stop_groups(array[v_groupName], 'STOP_%', false, false) INTO v_nbTblSeq;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('STOP_GROUP', 'END', v_groupName, v_nbTblSeq || ' tables/sequences processed');
    RETURN v_nbTblSeq;
  END;
$emaj_stop_group$;
COMMENT ON FUNCTION emaj.emaj_stop_group(TEXT) IS
$$Stops an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_stop_group(v_groupName TEXT, v_mark TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_stop_group$
-- This function de-activates the log triggers of all the tables for a group.
-- Execute several emaj_stop_group functions for the same group doesn't produce any error.
-- Input: group name, stop mark name to set
-- Output: number of processed tables and sequences
  DECLARE
    v_nbTblSeq         INT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('STOP_GROUP', 'BEGIN', v_groupName);
-- call the common _stop_groups function
    SELECT emaj._stop_groups(array[v_groupName], v_mark, false, false) INTO v_nbTblSeq;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('STOP_GROUP', 'END', v_groupName, v_nbTblSeq || ' tables/sequences processed');
    RETURN v_nbTblSeq;
  END;
$emaj_stop_group$;
COMMENT ON FUNCTION emaj.emaj_stop_group(TEXT,TEXT) IS
$$Stops an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_stop_groups(v_groupNames TEXT[])
RETURNS INT LANGUAGE plpgsql AS
$emaj_stop_groups$
-- This function de-activates the log triggers of all the tables for a groups array.
-- Groups already in IDLE state are simply not processed.
-- Input: array of group names
-- Output: number of processed tables and sequences
  DECLARE
    v_nbTblSeq         INT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('STOP_GROUPS', 'BEGIN', array_to_string(v_groupNames,','));
-- call the common _stop_groups function
    SELECT emaj._stop_groups(emaj._check_group_names_array(v_groupNames), 'STOP_%', true, false) INTO v_nbTblSeq;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('STOP_GROUPS', 'END', array_to_string(v_groupNames,','), v_nbTblSeq || ' tables/sequences processed');
    RETURN v_nbTblSeq;
  END;
$emaj_stop_groups$;
COMMENT ON FUNCTION emaj.emaj_stop_groups(TEXT[]) IS
$$Stops several E-Maj groups.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_stop_groups(v_groupNames TEXT[], v_mark TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_stop_groups$
-- This function de-activates the log triggers of all the tables for a groups array.
-- Groups already in IDLE state are simply not processed.
-- Input: array of group names, stop mark name to set
-- Output: number of processed tables and sequences
  DECLARE
    v_nbTblSeq         INT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('STOP_GROUPS', 'BEGIN', array_to_string(v_groupNames,','));
-- call the common _stop_groups function
    SELECT emaj._stop_groups(emaj._check_group_names_array(v_groupNames), v_mark, true, false) INTO v_nbTblSeq;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('STOP_GROUPS', 'END', array_to_string(v_groupNames,','), v_nbTblSeq || ' tables/sequences processed');
    RETURN v_nbTblSeq;
  END;
$emaj_stop_groups$;
COMMENT ON FUNCTION emaj.emaj_stop_groups(TEXT[], TEXT) IS
$$Stops several E-Maj groups.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_force_stop_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql AS
$emaj_force_stop_group$
-- This function forces a tables group stop.
-- The differences with the standart emaj_stop_group() function are :
--   - it silently ignores errors when an application table or one of its triggers is missing
--   - no stop mark is set (to avoid error)
-- Input: group name
-- Output: number of processed tables and sequences
  DECLARE
    v_nbTblSeq         INT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('FORCE_STOP_GROUP', 'BEGIN', v_groupName);
-- call the common _stop_groups function
    SELECT emaj._stop_groups(array[v_groupName], NULL, false, true) INTO v_nbTblSeq;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('FORCE_STOP_GROUP', 'END', v_groupName, v_nbTblSeq || ' tables/sequences processed');
    RETURN v_nbTblSeq;
  END;
$emaj_force_stop_group$;
COMMENT ON FUNCTION emaj.emaj_force_stop_group(TEXT) IS
$$Forces an E-Maj group stop.$$;

DROP FUNCTION emaj._stop_groups(v_groupNames TEXT[], v_mark TEXT, v_multiGroup BOOLEAN);
CREATE OR REPLACE FUNCTION emaj._stop_groups(v_groupNames TEXT[], v_mark TEXT, v_multiGroup BOOLEAN, v_isForced BOOLEAN)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS
$_stop_groups$
-- This function effectively de-activates the log triggers of all the tables for a group.
-- Input: array of group names, a mark name to set, and a boolean indicating if the function is called by a multi group function
-- Output: number of processed tables and sequences
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of application tables and sequences.
  DECLARE
    v_pgVersion        TEXT := emaj._pg_version();
    v_validGroupNames  TEXT[];
    v_i                INT;
    v_groupState       TEXT;
    v_nbTb             INT := 0;
    v_markName         TEXT;
    v_fullTableName    TEXT;
    v_logTriggerName   TEXT;
    v_truncTriggerName TEXT;
    r_tblsq            RECORD;
  BEGIN
-- if the group names array is null, immediately return 0
    IF v_groupNames IS NULL THEN
      RETURN 0;
    END IF;
-- for each group of the array,
    FOR v_i in 1 .. array_upper(v_groupNames,1) LOOP
-- ... check that the group is recorded in emaj_group table
      SELECT group_state INTO v_groupState FROM emaj.emaj_group WHERE group_name = v_groupNames[v_i] FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION '_stop_group: group % has not been created.', v_groupNames[v_i];
      END IF;
-- ... check that the group is in LOGGING state
      IF v_groupState <> 'LOGGING' THEN
        RAISE WARNING '_stop_group: Group % cannot be stopped because it is not in logging state.', v_groupNames[v_i];
      ELSE
-- ... if OK, add the group into the array of groups to process
        v_validGroupNames = v_validGroupNames || array[v_groupNames[v_i]];
      END IF;
    END LOOP;
-- check and process the supplied mark name (except if the function is called by emaj_force_stop_group())
    IF NOT v_isForced THEN
      SELECT emaj._check_new_mark(v_mark, v_groupNames) INTO v_markName;
    END IF;
--
    IF v_validGroupNames IS NOT NULL THEN
-- OK (no error detected and at least one group in logging state)
-- lock all tables to get a stable point ...
-- (the ALTER TABLE statements will also set EXCLUSIVE locks, but doing this for all tables at the beginning of the operation decreases the risk for deadlock)
      PERFORM emaj._lock_groups(v_validGroupNames,'',v_multiGroup);
-- for each relation of the groups to process,
      FOR r_tblsq IN
          SELECT rel_priority, rel_schema, rel_tblseq, rel_kind FROM emaj.emaj_relation
            WHERE rel_group = ANY (v_validGroupNames) ORDER BY rel_priority, rel_schema, rel_tblseq
          LOOP
        IF r_tblsq.rel_kind = 'r' THEN
-- if it is a table, disable the emaj log and truncate triggers
--   errors are captured so that emaj_force_stop_group() can be silently executed
          v_fullTableName  := quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
          v_logTriggerName := quote_ident(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_emaj_log_trg');
          v_truncTriggerName := quote_ident(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_emaj_trunc_trg');
          BEGIN
            EXECUTE 'ALTER TABLE ' || v_fullTableName || ' DISABLE TRIGGER ' || v_logTriggerName;
          EXCEPTION
            WHEN invalid_schema_name THEN
              IF v_isForced THEN
                RAISE WARNING '_stop_group: Schema % does not exist any more.', quote_ident(r_tblsq.rel_schema);
              ELSE
                RAISE EXCEPTION '_stop_group: Schema % does not exist any more.', quote_ident(r_tblsq.rel_schema);
              END IF;
            WHEN undefined_table THEN
              IF v_isForced THEN
                RAISE WARNING '_stop_group: Table % does not exist any more.', v_fullTableName;
              ELSE
                RAISE EXCEPTION '_stop_group: Table % does not exist any more.', v_fullTableName;
              END IF;
            WHEN undefined_object THEN
              IF v_isForced THEN
                RAISE WARNING '_stop_group: Trigger % on table % does not exist any more.', v_logTriggerName, v_fullTableName;
              ELSE
                RAISE EXCEPTION '_stop_group: Trigger % on table % does not exist any more.', v_logTriggerName, v_fullTableName;
              END IF;
          END;
          IF v_pgVersion >= '8.4' THEN
            BEGIN
              EXECUTE 'ALTER TABLE ' || v_fullTableName || ' DISABLE TRIGGER ' || v_truncTriggerName;
            EXCEPTION
              WHEN invalid_schema_name THEN
                IF v_isForced THEN
                  RAISE WARNING '_stop_group: Schema % does not exist any more.', quote_ident(r_tblsq.rel_schema);
                ELSE
                  RAISE EXCEPTION '_stop_group: Schema % does not exist any more.', quote_ident(r_tblsq.rel_schema);
                END IF;
              WHEN undefined_table THEN
                IF v_isForced THEN
                  RAISE WARNING '_stop_group: Table % does not exist any more.', v_fullTableName;
                ELSE
                  RAISE EXCEPTION '_stop_group: Table % does not exist any more.', v_fullTableName;
                END IF;
              WHEN undefined_object THEN
                IF v_isForced THEN
                  RAISE WARNING '_stop_group: Trigger % on table % does not exist any more.', v_truncTriggerName, v_fullTableName;
                ELSE
                  RAISE EXCEPTION '_stop_group: Trigger % on table % does not exist any more.', v_truncTriggerName, v_fullTableName;
                END IF;
            END;
          END IF;
          ELSEIF r_tblsq.rel_kind = 'S' THEN
-- if it is a sequence, nothing to do
        END IF;
        v_nbTb = v_nbTb + 1;
      END LOOP;
      IF NOT v_isForced THEN
-- if the function is not called by emaj_force_stop_group(), set the stop mark for each group
        PERFORM emaj._set_mark_groups(v_validGroupNames, v_markName, v_multiGroup, true);
-- and set the number of log rows to 0 for these marks
        UPDATE emaj.emaj_mark m SET mark_log_rows_before_next = 0
          WHERE mark_group = ANY (v_validGroupNames)
            AND (mark_group, mark_id) IN                        -- select only last mark of each concerned group
                (SELECT mark_group, MAX(mark_id) FROM emaj.emaj_mark
                 WHERE mark_group = ANY (v_validGroupNames) AND mark_state = 'ACTIVE' GROUP BY mark_group);
      END IF;
-- set all marks for the groups from the emaj_mark table in 'DELETED' state to avoid any further rollback
      UPDATE emaj.emaj_mark SET mark_state = 'DELETED' WHERE mark_group = ANY (v_validGroupNames) AND mark_state <> 'DELETED';
-- update the state of the groups rows from the emaj_group table
      UPDATE emaj.emaj_group SET group_state = 'IDLE' WHERE group_name = ANY (v_validGroupNames);
    END IF;
    RETURN v_nbTb;
  END;
$_stop_groups$;

CREATE OR REPLACE FUNCTION emaj.emaj_set_mark_group(v_groupName TEXT, v_mark TEXT)
RETURNS int LANGUAGE plpgsql AS
$emaj_set_mark_group$
-- This function inserts a mark in the emaj_mark table and takes an image of the sequences definitions for the group
-- Input: group name, mark to set
--        '%' wild characters in mark name are transformed into a characters sequence built from the current timestamp
--        a null or '' mark is transformed into 'MARK_%'
-- Output: number of processed tables and sequences
  DECLARE
    v_groupState    TEXT;
    v_markName      TEXT;
    v_nbTb          INT;
  BEGIN
-- insert begin into the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SET_MARK_GROUP', 'BEGIN', v_groupName, v_markName);
-- check that the group is recorded in emaj_group table
-- (the SELECT is coded FOR UPDATE to lock the accessed group, avoiding any operation on this group at the same time)
    SELECT group_state INTO v_groupState FROM emaj.emaj_group WHERE group_name = v_groupName FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_set_mark_group: group % has not been created.', v_groupName;
    END IF;
-- check that the group is in LOGGING state
    IF v_groupState <> 'LOGGING' THEN
      RAISE EXCEPTION 'emaj_set_mark_group: A mark cannot be set for group % because it is not in logging state. An emaj_start_group function must be previously executed.', v_groupName;
    END IF;
-- check if the emaj group is OK
    PERFORM 0 FROM emaj._verify_groups(array[v_groupName], true);
-- check and process the supplied mark name
    SELECT emaj._check_new_mark(v_mark, array[v_groupName]) INTO v_markName;
-- OK, lock all tables to get a stable point ...
-- use a ROW EXCLUSIVE lock mode, preventing for a transaction currently updating data, but not conflicting with simple read access or vacuum operation.
    PERFORM emaj._lock_groups(array[v_groupName],'ROW EXCLUSIVE',false);
-- Effectively set the mark using the internal _set_mark_groups() function
    SELECT emaj._set_mark_groups(array[v_groupName], v_markName, false, false) INTO v_nbTb;
-- insert end into the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SET_MARK_GROUP', 'END', v_groupName, v_markName);
--
    RETURN v_nbTb;
  END;
$emaj_set_mark_group$;
COMMENT ON FUNCTION emaj.emaj_set_mark_group(TEXT,TEXT) IS
$$Sets a mark on an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_set_mark_groups(v_groupNames TEXT[], v_mark TEXT)
RETURNS int LANGUAGE plpgsql AS
$emaj_set_mark_groups$
-- This function inserts a mark in the emaj_mark table and takes an image of the sequences definitions for several groups at a time
-- Input: array of group names, mark to set
--        '%' wild characters in mark name are transformed into a characters sequence built from the current timestamp
--        a null or '' mark is transformed into 'MARK_%'
-- Output: number of processed tables and sequences
  DECLARE
    v_validGroupNames TEXT[];
    v_groupState      TEXT;
    v_markName        TEXT;
    v_nbTb            INT;
  BEGIN
-- validate the group names array
    v_validGroupNames=emaj._check_group_names_array(v_groupNames);
-- if the group names array is null, immediately return 0
    IF v_validGroupNames IS NULL THEN
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
        VALUES ('SET_MARK_GROUPS', 'BEGIN', NULL, v_mark);
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
        VALUES ('SET_MARK_GROUPS', 'END', NULL, v_mark);
      RETURN 0;
    END IF;
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SET_MARK_GROUPS', 'BEGIN', array_to_string(v_groupNames,','), v_mark);
-- for each group...
    FOR v_i in 1 .. array_upper(v_validGroupNames,1) LOOP
-- ... check that the group is recorded in emaj_group table
-- (the SELECT is coded FOR UPDATE to lock the accessed group, avoiding any operation on this group at the same time)
      SELECT group_state INTO v_groupState FROM emaj.emaj_group WHERE group_name = v_validGroupNames[v_i] FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'emaj_set_mark_groups: group % has not been created.', v_validGroupNames[v_i];
      END IF;
-- ... check that the group is in LOGGING state
      IF v_groupState <> 'LOGGING' THEN
        RAISE EXCEPTION 'emaj_set_mark_groups: A mark cannot be set for group % because it is not in logging state. An emaj_start_group function must be previously executed.', v_validGroupNames[v_i];
      END IF;
    END LOOP;
-- check that no group is damaged
    PERFORM 0 FROM emaj._verify_groups(v_validGroupNames, true);
-- check and process the supplied mark name
    SELECT emaj._check_new_mark(v_mark, v_validGroupNames) INTO v_markName;
-- OK, lock all tables to get a stable point ...
-- use a ROW EXCLUSIVE lock mode, preventing for a transaction currently updating data, but not conflicting with simple read access or vacuum operation.
    PERFORM emaj._lock_groups(v_validGroupNames,'ROW EXCLUSIVE',true);
-- Effectively set the mark using the internal _set_mark_groups() function
    SELECT emaj._set_mark_groups(v_validGroupNames, v_markName, true, false) into v_nbTb;
-- insert end into the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SET_MARK_GROUPS', 'END', array_to_string(v_groupNames,','), v_mark);
--
    RETURN v_nbTb;
  END;
$emaj_set_mark_groups$;
COMMENT ON FUNCTION emaj.emaj_set_mark_groups(TEXT[],TEXT) IS
$$Sets a mark on several E-Maj groups.$$;

CREATE OR REPLACE FUNCTION emaj._set_mark_groups(v_groupNames TEXT[], v_mark TEXT, v_multiGroup BOOLEAN, v_eventToRecord BOOLEAN)
RETURNS int LANGUAGE plpgsql AS
$_set_mark_groups$
-- This function effectively inserts a mark in the emaj_mark table and takes an image of the sequences definitions for the array of groups.
-- It also updates the previous mark of each group to setup the mark_log_rows_before_next column with the number of rows recorded into all log tables between this previous mark and the new mark.
-- It is called by emaj_set_mark_group and emaj_set_mark_groups functions but also by other functions that set internal marks, like functions that start or rollback groups.
-- Input: group names array, mark to set,
--        boolean indicating whether the function is called by a multi group function
--        boolean indicating whether the event has to be recorded into the emaj_hist table
-- Output: number of processed tables and sequences
-- The insertion of the corresponding event in the emaj_hist table is performed by callers.
  DECLARE
    v_pgVersion       TEXT := emaj._pg_version();
    v_nbTb            INT := 0;
    v_timestamp       TIMESTAMPTZ;
    v_lastSequenceId  BIGINT;
    v_lastSeqHoleId   BIGINT;
    v_lastGlobalSeq   BIGINT;
    v_fullSeqName     TEXT;
    v_seqName         TEXT;
    v_stmt            TEXT;
    r_tblsq           RECORD;
  BEGIN
-- if requested, record the set mark begin in emaj_hist
    IF v_eventToRecord THEN
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
        VALUES (CASE WHEN v_multiGroup THEN 'SET_MARK_GROUPS' ELSE 'SET_MARK_GROUP' END, 'BEGIN', array_to_string(v_groupNames,','), v_mark);
    END IF;
-- look at the clock to get the 'official' timestamp representing the mark
    v_timestamp = clock_timestamp();
-- process sequences as early as possible (no lock protect them from other transactions activity)
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, rel_log_schema FROM emaj.emaj_relation
          WHERE rel_group = ANY (v_groupNames) AND rel_kind = 'S' 
          ORDER BY rel_priority, rel_schema, rel_tblseq
      LOOP
-- for each sequence of the groups, record the sequence parameters into the emaj_sequence table
      v_fullSeqName := quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
      v_stmt = 'INSERT INTO emaj.emaj_sequence (' ||
               'sequ_schema, sequ_name, sequ_datetime, sequ_mark, sequ_last_val, sequ_start_val, ' ||
               'sequ_increment, sequ_max_val, sequ_min_val, sequ_cache_val, sequ_is_cycled, sequ_is_called ' ||
               ') SELECT ' || quote_literal(r_tblsq.rel_schema) || ', ' ||
               quote_literal(r_tblsq.rel_tblseq) || ', ' || quote_literal(v_timestamp) ||
               ', ' || quote_literal(v_mark) || ', last_value, ';
      IF v_pgVersion <= '8.3' THEN
         v_stmt = v_stmt || '0, ';
      ELSE
         v_stmt = v_stmt || 'start_value, ';
      END IF;
      v_stmt = v_stmt ||
               'increment_by, max_value, min_value, cache_value, is_cycled, is_called ' ||
               'FROM ' || v_fullSeqName;
      EXECUTE v_stmt;
      v_nbTb = v_nbTb + 1;
    END LOOP;
-- record the number of log rows for the old last mark of each group
--   the statement returns no row in case of emaj_start_group(s)
    UPDATE emaj.emaj_mark m SET mark_log_rows_before_next =
      coalesce( (SELECT sum(stat_rows) FROM emaj.emaj_log_stat_group(m.mark_group,'EMAJ_LAST_MARK',NULL)) ,0)
      WHERE mark_group = ANY (v_groupNames)
        AND (mark_group, mark_id) IN                        -- select only last mark of each concerned group
            (SELECT mark_group, MAX(mark_id) FROM emaj.emaj_mark
             WHERE mark_group = ANY (v_groupNames) AND mark_state = 'ACTIVE' GROUP BY mark_group);
-- for each table of the groups, ...
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, rel_log_schema FROM emaj.emaj_relation
          WHERE rel_group = ANY (v_groupNames) AND rel_kind = 'r'
		  ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
-- ... record the associated sequence parameters in the emaj sequence table
      v_seqName := emaj._build_log_seq_name(r_tblsq.rel_schema, r_tblsq.rel_tblseq);
      v_fullSeqName := quote_ident(r_tblsq.rel_log_schema) || '.' || quote_ident(v_seqName);
      v_stmt = 'INSERT INTO emaj.emaj_sequence (' ||
               'sequ_schema, sequ_name, sequ_datetime, sequ_mark, sequ_last_val, sequ_start_val, ' ||
               'sequ_increment, sequ_max_val, sequ_min_val, sequ_cache_val, sequ_is_cycled, sequ_is_called ' ||
               ') SELECT '|| quote_literal(r_tblsq.rel_log_schema) || ', ' || quote_literal(v_seqName) || ', ' ||
               quote_literal(v_timestamp) || ', ' || quote_literal(v_mark) || ', ' || 'last_value, ';
      IF v_pgVersion <= '8.3' THEN
         v_stmt = v_stmt || '0, ';
      ELSE
         v_stmt = v_stmt || 'start_value, ';
      END IF;
      v_stmt = v_stmt ||
               'increment_by, max_value, min_value, cache_value, is_cycled, is_called ' ||
               'FROM ' || v_fullSeqName;
      EXECUTE v_stmt;
      v_nbTb = v_nbTb + 1;
    END LOOP;
-- record the marks
-- get the last id for emaj_sequence and emaj_seq_hole tables, and the last value for emaj_global_seq
    SELECT CASE WHEN is_called THEN last_value ELSE last_value - increment_by END INTO v_lastSequenceId
      FROM emaj.emaj_sequence_sequ_id_seq;
    SELECT CASE WHEN is_called THEN last_value ELSE last_value - increment_by END INTO v_lastSeqHoleId
      FROM emaj.emaj_seq_hole_sqhl_id_seq;
    SELECT CASE WHEN is_called THEN last_value ELSE last_value - increment_by END INTO v_lastGlobalSeq
      FROM emaj.emaj_global_seq;
-- insert the marks into the emaj_mark table
    FOR v_i in 1 .. array_upper(v_groupNames,1) LOOP
      INSERT INTO emaj.emaj_mark (mark_group, mark_name, mark_datetime, mark_global_seq, mark_state, mark_last_sequence_id, mark_last_seq_hole_id)
        VALUES (v_groupNames[v_i], v_mark, v_timestamp, v_lastGlobalSeq, 'ACTIVE', v_lastSequenceId, v_lastSeqHoleId);
    END LOOP;
-- if requested, record the set mark end in emaj_hist
    IF v_eventToRecord THEN
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
        VALUES (CASE WHEN v_multiGroup THEN 'SET_MARK_GROUPS' ELSE 'SET_MARK_GROUP' END, 'END', array_to_string(v_groupNames,','), v_mark);
    END IF;
--
    RETURN v_nbTb;
  END;
$_set_mark_groups$;

CREATE OR REPLACE FUNCTION emaj.emaj_comment_mark_group(v_groupName TEXT, v_mark TEXT, v_comment TEXT)
RETURNS void LANGUAGE plpgsql AS
$emaj_comment_mark_group$
-- This function sets or modifies a comment on a mark by updating the mark_comment of the emaj_mark table.
-- Input: group name, mark to comment, comment
--   The keyword 'EMAJ_LAST_MARK' can be used as mark to delete to specify the last set mark.
--   To reset an existing comment for a mark, the supplied comment can be NULL.
  DECLARE
    v_groupState     TEXT;
    v_realMark       TEXT;
  BEGIN
-- check that the group is recorded in emaj_group table
    PERFORM 0 FROM emaj.emaj_group WHERE group_name = v_groupName FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_comment_mark_group: group % has not been created.', v_groupName;
    END IF;
-- retrieve and check the mark name
    SELECT emaj._get_mark_name(v_groupName,v_mark) INTO v_realMark;
    IF v_realMark IS NULL THEN
      RAISE EXCEPTION 'emaj_comment_mark_group: % is not a known mark for group %.', v_mark, v_groupName;
    END IF;
-- OK, update the mark_comment from emaj_mark table
    UPDATE emaj.emaj_mark SET mark_comment = v_comment WHERE mark_group = v_groupName AND mark_name = v_realMark;
-- insert event in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording)
      VALUES ('COMMENT_MARK_GROUP', v_groupName, 'Mark ' || v_realMark);
    RETURN;
  END;
$emaj_comment_mark_group$;
COMMENT ON FUNCTION emaj.emaj_comment_mark_group(TEXT,TEXT,TEXT) IS
$$Sets a comment on a mark for an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_get_previous_mark_group(v_groupName TEXT, v_datetime TIMESTAMPTZ)
RETURNS text LANGUAGE plpgsql AS
$emaj_get_previous_mark_group$
-- This function returns the name of the mark that immediately precedes a given date and time.
-- It may return unpredictable result in case of system date or time change.
-- The function can be called by both emaj_adm and emaj_viewer roles.
-- Input: group name, date and time
-- Output: mark name, or NULL if there is no mark before the given date and time
  DECLARE
    v_markName      TEXT;
  BEGIN
-- check that the group is recorded in emaj_group table
    PERFORM 0 FROM emaj.emaj_group WHERE group_name = v_groupName;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_get_previous_mark_group: group % has not been created.', v_groupName;
    END IF;
-- find the requested mark
    SELECT mark_name INTO v_markName FROM emaj.emaj_mark
      WHERE mark_group = v_groupName AND mark_datetime < v_datetime
      ORDER BY mark_datetime DESC LIMIT 1;
    IF NOT FOUND THEN
      RETURN NULL;
    ELSE
      RETURN v_markName;
    END IF;
  END;
$emaj_get_previous_mark_group$;
COMMENT ON FUNCTION emaj.emaj_get_previous_mark_group(TEXT,TIMESTAMPTZ) IS
$$Returns the latest mark name preceeding a point in time.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_get_previous_mark_group(v_groupName TEXT, v_mark TEXT)
RETURNS text LANGUAGE plpgsql AS
$emaj_get_previous_mark_group$
-- This function returns the name of the mark that immediately precedes a given mark for a group.
-- The function can be called by both emaj_adm and emaj_viewer roles.
-- Input: group name, mark name
-- Output: mark name, or NULL if there is no mark before the given mark
  DECLARE
    v_realMark       TEXT;
    v_markName       TEXT;
  BEGIN
-- check that the group is recorded in emaj_group table
    PERFORM 0 FROM emaj.emaj_group WHERE group_name = v_groupName;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_get_previous_mark_group: group % has not been created.', v_groupName;
    END IF;
-- retrieve and check the given mark name
    SELECT emaj._get_mark_name(v_groupName,v_mark) INTO v_realMark;
    IF v_realMark IS NULL THEN
      RAISE EXCEPTION 'emaj_get_previous_mark_group: % is not a known mark for group %.', v_mark, v_groupName;
    END IF;
-- find the requested mark
    SELECT mark_name INTO v_markName FROM emaj.emaj_mark
      WHERE mark_group = v_groupName AND mark_datetime <
        (SELECT mark_datetime FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realMark)
      ORDER BY mark_datetime DESC LIMIT 1;
    IF NOT FOUND THEN
      RETURN NULL;
    ELSE
      RETURN v_markName;
    END IF;
  END;
$emaj_get_previous_mark_group$;
COMMENT ON FUNCTION emaj.emaj_get_previous_mark_group(TEXT,TEXT) IS
$$Returns the latest mark name preceeding a given mark for a group.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_delete_mark_group(v_groupName TEXT, v_mark TEXT)
RETURNS integer LANGUAGE plpgsql AS
$emaj_delete_mark_group$
-- This function deletes all traces from a previous set_mark_group(s) function.
-- Then, any rollback on the deleted mark will not be possible.
-- It deletes rows corresponding to the mark to delete from emaj_mark and emaj_sequence
-- If this mark is the first mark, it also deletes rows from all concerned log tables and holes from emaj_seq_hole.
-- The statistical mark_log_rows_before_next column's content of the previous mark is also maintained
-- At least one mark must remain after the operation (otherwise it is not worth having a group in LOGGING state !).
-- Input: group name, mark to delete
--   The keyword 'EMAJ_LAST_MARK' can be used as mark to delete to specify the last set mark.
-- Output: number of deleted marks, i.e. 1
  DECLARE
    v_groupState     TEXT;
    v_realMark       TEXT;
    v_markId         BIGINT;
    v_datetimeMark   TIMESTAMPTZ;
    v_idNewMin       BIGINT;
    v_markNewMin     TEXT;
    v_datetimeNewMin TIMESTAMPTZ;
    v_cpt            INT;
    v_previousMark   TEXT;
    v_nextMark       TEXT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('DELETE_MARK_GROUP', 'BEGIN', v_groupName, v_mark);
-- check that the group is recorded in emaj_group table
    SELECT group_state INTO v_groupState FROM emaj.emaj_group WHERE group_name = v_groupName FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_delete_mark_group: group % has not been created.', v_groupName;
    END IF;
-- retrieve and check the mark name
    SELECT emaj._get_mark_name(v_groupName,v_mark) INTO v_realMark;
    IF v_realMark IS NULL THEN
      RAISE EXCEPTION 'emaj_delete_mark_group: % is not a known mark for group %.', v_mark, v_groupName;
    END IF;
-- count the number of mark in the group
    SELECT count(*) INTO v_cpt FROM emaj.emaj_mark WHERE mark_group = v_groupName;
-- and check there are at least 2 marks for the group
    IF v_cpt < 2 THEN
       RAISE EXCEPTION 'emaj_delete_mark_group: % is the only mark. It cannot be deleted.', v_mark;
    END IF;
-- OK, now get the id and timestamp of the mark to delete
    SELECT mark_id, mark_datetime INTO v_markId, v_datetimeMark
      FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realMark;
-- ... and the id and timestamp of the future first mark
    SELECT mark_id, mark_name, mark_datetime INTO v_idNewMin, v_markNewMin, v_datetimeNewMin
      FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name <> v_realMark ORDER BY mark_id LIMIT 1;
    IF v_markId < v_idNewMin THEN
-- if the mark to delete is the first one,
--   ... process its deletion with _delete_before_mark_group(), as the first rows of log tables become useless
      PERFORM emaj._delete_before_mark_group(v_groupName, v_markNewMin);
    ELSE
-- otherwise,
--   ... the sequences related to the mark to delete can be suppressed
--         Delete first application sequences related data for the group
      DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
        WHERE sequ_mark = v_realMark AND sequ_datetime = v_datetimeMark
          AND rel_group = v_groupName AND rel_kind = 'S'
          AND sequ_schema = rel_schema AND sequ_name = rel_tblseq;
--         Delete then emaj sequences related data for the group
      DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
        WHERE sequ_mark = v_realMark AND sequ_datetime = v_datetimeMark
          AND rel_group = v_groupName AND rel_kind = 'r'
          AND sequ_schema = rel_log_schema AND sequ_name = emaj._build_log_seq_name(rel_schema,rel_tblseq);
--   ... the mark to delete can be physicaly deleted
      DELETE FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realMark;
--   ... adjust the mark_log_rows_before_next column of the previous mark
--       get the name of the mark immediately preceeding the mark to delete
      SELECT mark_name INTO v_previousMark FROM emaj.emaj_mark
        WHERE mark_group = v_groupName AND mark_id < v_markId ORDER BY mark_id DESC LIMIT 1;
--       get the name of the first mark succeeding the mark to delete
      SELECT mark_name INTO v_nextMark FROM emaj.emaj_mark
        WHERE mark_group = v_groupName AND mark_id > v_markId ORDER BY mark_id LIMIT 1;
      IF NOT FOUND THEN
--       no next mark, so update the previous mark with NULL
         UPDATE emaj.emaj_mark SET mark_log_rows_before_next = NULL
           WHERE mark_group = v_groupName AND mark_name = v_previousMark;
      ELSE
--       update the previous mark with the emaj_log_stat_group() call's result
         UPDATE emaj.emaj_mark SET mark_log_rows_before_next =
             (SELECT sum(stat_rows) FROM emaj.emaj_log_stat_group(v_groupName, v_previousMark, v_nextMark))
           WHERE mark_group = v_groupName AND mark_name = v_previousMark;
      END IF;
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('DELETE_MARK_GROUP', 'END', v_groupName, v_realMark);
    RETURN 1;
  END;
$emaj_delete_mark_group$;
COMMENT ON FUNCTION emaj.emaj_delete_mark_group(TEXT,TEXT) IS
$$Deletes a mark for an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj._delete_before_mark_group(v_groupName TEXT, v_mark TEXT)
RETURNS integer LANGUAGE plpgsql AS
$_delete_before_mark_group$
-- This function effectively deletes all marks set before a given mark.
-- It deletes rows corresponding to the marks to delete from emaj_mark, emaj_sequence, emaj_seq_hole.
-- It also deletes rows from all concerned log tables.
-- To complete, the function deletes oldest rows from emaj_hist 
-- Input: group name, name of the new first mark
-- Output: number of deleted marks
  DECLARE
    v_markId         BIGINT;
    v_markGlobalSeq  BIGINT;
    v_datetimeMark   TIMESTAMPTZ;
    v_logTableName   TEXT;
    v_nbMark         INT;
    r_tblsq          RECORD;
  BEGIN
-- retrieve the id and datetime of the new first mark
    SELECT mark_id, mark_global_seq, mark_datetime INTO v_markId, v_markGlobalSeq, v_datetimeMark
      FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_mark;
-- delete rows from all log tables
-- loop on all tables of the group
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, rel_log_schema FROM emaj.emaj_relation
          WHERE rel_group = v_groupName AND rel_kind = 'r' ORDER BY rel_priority, rel_schema, rel_tblseq
    LOOP
      v_logTableName := quote_ident(r_tblsq.rel_log_schema) || '.' || quote_ident(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_log');
-- delete log rows prior to the new first mark
      EXECUTE 'DELETE FROM ' || v_logTableName || ' WHERE emaj_gid <= ' || v_markGlobalSeq;
    END LOOP;
-- delete all sequence holes that are prior the new first mark for the tables of the group
    DELETE FROM emaj.emaj_seq_hole USING emaj.emaj_relation
      WHERE rel_group = v_groupName AND rel_kind = 'r' AND rel_schema = sqhl_schema AND rel_tblseq = sqhl_table
        AND sqhl_id <= (SELECT mark_last_seq_hole_id FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_mark);
-- now the sequences related to the mark to delete can be suppressed
--   Delete first application sequences related data for the group
    DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
      WHERE rel_group = v_groupName AND rel_kind = 'S'
        AND sequ_schema = rel_schema AND sequ_name = rel_tblseq
        AND (sequ_mark, sequ_datetime) IN
            (SELECT mark_name, mark_datetime FROM emaj.emaj_mark
              WHERE mark_group = v_groupName AND mark_id < v_markId);
--   Delete then emaj sequences related data for the group
    DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation
      WHERE rel_group = v_groupName AND rel_kind = 'r'
        AND sequ_schema = rel_log_schema AND sequ_name = emaj._build_log_seq_name(rel_schema,rel_tblseq)
        AND (sequ_mark, sequ_datetime) IN
            (SELECT mark_name, mark_datetime FROM emaj.emaj_mark
              WHERE mark_group = v_groupName AND mark_id < v_markId);
-- and finaly delete marks
    DELETE FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_id < v_markId;
    GET DIAGNOSTICS v_nbMark = ROW_COUNT;
-- purge the emaj history, if needed (even if no mark as been really dropped)
    PERFORM emaj._purge_hist();
    RETURN v_nbMark;
  END;
$_delete_before_mark_group$;

CREATE OR REPLACE FUNCTION emaj.emaj_rename_mark_group(v_groupName TEXT, v_mark TEXT, v_newName TEXT)
RETURNS void LANGUAGE plpgsql AS
$emaj_rename_mark_group$
-- This function renames an existing mark.
-- The group can be either in LOGGING or IDLE state.
-- Rows from emaj_mark and emaj_sequence tables are updated accordingly.
-- Input: group name, mark to rename, new name for the mark
--   The keyword 'EMAJ_LAST_MARK' can be used as mark to rename to specify the last set mark.
  DECLARE
    v_realMark       TEXT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('RENAME_MARK_GROUP', 'BEGIN', v_groupName, v_mark);
-- check that the group is recorded in emaj_group table
    PERFORM 0 FROM emaj.emaj_group WHERE group_name = v_groupName FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_rename_mark_group: group % has not been created.', v_groupName;
    END IF;
-- retrieve and check the mark name
    SELECT emaj._get_mark_name(v_groupName,v_mark) INTO v_realMark;
    IF v_realMark IS NULL THEN
      RAISE EXCEPTION 'emaj_rename_mark_group: mark % doesn''t exist for group %.', v_mark, v_groupName;
    END IF;
-- check the new mark name is not 'EMAJ_LAST_MARK' or NULL
    IF v_newName = 'EMAJ_LAST_MARK' OR v_newName IS NULL THEN
       RAISE EXCEPTION 'emaj_rename_mark_group: % is not an allowed name for a new mark.', v_newName;
    END IF;
-- check if the new mark name doesn't exist for the group
    PERFORM 0 FROM emaj.emaj_mark
      WHERE mark_group = v_groupName AND mark_name = v_newName;
    IF FOUND THEN
       RAISE EXCEPTION 'emaj_rename_mark_group: a mark % already exists for group %.', v_newName, v_groupName;
    END IF;
-- OK, update the sequences table as well
    UPDATE emaj.emaj_sequence SET sequ_mark = v_newName
      WHERE sequ_datetime =                                         -- the right mark date and time
            (SELECT mark_datetime FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realMark)
        AND (sequ_schema, sequ_name) IN 
            (SELECT rel_schema, rel_tblseq FROM emaj.emaj_relation  -- filter only application sequences of the group
               WHERE rel_group = v_groupName AND rel_kind = 'S'
             UNION ALL                                              -- filter only log sequences of the group
             SELECT rel_log_schema, emaj._build_log_seq_name(rel_schema, rel_tblseq) FROM emaj.emaj_relation
               WHERE rel_group = v_groupName AND rel_kind = 'r'
            );
-- and then update the emaj_mark table
    UPDATE emaj.emaj_mark SET mark_name = v_newName
      WHERE mark_group = v_groupName AND mark_name = v_realMark;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('RENAME_MARK_GROUP', 'END', v_groupName, v_realMark || ' renamed ' || v_newName);
    RETURN;
  END;
$emaj_rename_mark_group$;
COMMENT ON FUNCTION emaj.emaj_rename_mark_group(TEXT,TEXT,TEXT) IS
$$Renames a mark for an E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj._rlbk_groups_step1(v_groupNames TEXT[], v_mark TEXT, v_unloggedRlbk BOOLEAN, v_nbSession INT, v_multiGroup BOOLEAN)
RETURNS INT LANGUAGE plpgsql AS
$_rlbk_groups_step1$
-- This is the first step of a rollback group processing.
-- It tests the environment, the supplied parameters and the foreign key constraints.
-- It builds the requested number of sessions with the list of tables to process, trying to spread the load over all sessions.
-- It finaly inserts into the history the event about the rollback start
  DECLARE
    v_i                   INT;
    v_groupState          TEXT;
    v_isRollbackable      BOOLEAN;
    v_markName            TEXT;
    v_markState           TEXT;
    v_cpt                 INT;
    v_nbTblInGroup        INT;
    v_nbUnchangedTbl      INT;
    v_timestampMark       TIMESTAMPTZ;
    v_session             INT;
    v_sessionLoad         INT [];
    v_minSession          INT;
    v_minRows             INT;
    v_fullTableName       TEXT;
    v_msg                 TEXT;
    r_tbl                 RECORD;
    r_tbl2                RECORD;
  BEGIN
-- check that each group ...
-- ...is recorded in emaj_group table
    FOR v_i in 1 .. array_upper(v_groupNames,1) LOOP
      SELECT group_state, group_is_rollbackable INTO v_groupState, v_isRollbackable FROM emaj.emaj_group WHERE group_name = v_groupNames[v_i] FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION '_rlbk_groups_step1: group % has not been created.', v_groupNames[v_i];
      END IF;
-- ... is in LOGGING state
      IF v_groupState <> 'LOGGING' THEN
        RAISE EXCEPTION '_rlbk_groups_step1: Group % cannot be rollbacked because it is not in logging state.', v_groupNames[v_i];
      END IF;
-- ... is ROLLBACKABLE
      IF NOT v_isRollbackable THEN
        RAISE EXCEPTION '_rlbk_groups_step1: Group % has been created for audit only purpose. It cannot be rollbacked.', v_groupNames[v_i];
      END IF;
-- ... owns the requested mark
      SELECT emaj._get_mark_name(v_groupNames[v_i],v_mark) INTO v_markName;
      IF NOT FOUND OR v_markName IS NULL THEN
        RAISE EXCEPTION '_rlbk_groups_step1: No mark % exists for group %.', v_mark, v_groupNames[v_i];
      END IF;
-- ... and this mark is ACTIVE
      SELECT mark_state INTO v_markState FROM emaj.emaj_mark
        WHERE mark_group = v_groupNames[v_i] AND mark_name = v_markName;
      IF v_markState <> 'ACTIVE' THEN
        RAISE EXCEPTION '_rlbk_groups_step1: mark % for group % is not in ACTIVE state.', v_markName, v_groupNames[v_i];
      END IF;
    END LOOP;
-- check that no group is damaged
    PERFORM 0 FROM emaj._verify_groups(v_groupNames, true);
-- get the mark timestamp and check it is the same for all groups of the array
    SELECT count(DISTINCT emaj._get_mark_datetime(group_name,v_mark)) INTO v_cpt FROM emaj.emaj_group
      WHERE group_name = ANY (v_groupNames);
    IF v_cpt > 1 THEN
      RAISE EXCEPTION '_rlbk_groups_step1: Mark % does not represent the same point in time for all groups.', v_mark;
    END IF;
-- get the mark timestamp for the 1st group (as we know this timestamp is the same for all groups of the array)
    SELECT emaj._get_mark_datetime(v_groupNames[1],v_mark) INTO v_timestampMark;
-- insert begin in the history
    IF v_unloggedRlbk THEN
      v_msg = 'Unlogged';
    ELSE
      v_msg = 'Logged';
    END IF;
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'ROLLBACK_GROUPS' ELSE 'ROLLBACK_GROUP' END, 'BEGIN',
              array_to_string(v_groupNames,','), v_msg || ' rollback to mark ' || v_markName || ' [' || v_timestampMark || ']');
-- get the total number of tables for these groups
    SELECT sum(group_nb_table) INTO v_nbTblInGroup FROM emaj.emaj_group WHERE group_name = ANY (v_groupNames) ;
-- issue warnings in case of foreign keys with tables outside the groups
    PERFORM emaj._check_fk_groups(v_groupNames);
-- create sessions, using the number of sessions requested by the caller
-- session id for sequences will remain NULL
--   initialisation
--     accumulated counters of number of log rows to rollback for each parallel session
    FOR v_session IN 1 .. v_nbSession LOOP
      v_sessionLoad [v_session] = 0;
    END LOOP;
    FOR v_i in 1 .. array_upper(v_groupNames,1) LOOP
--     fkey table
      DELETE FROM emaj.emaj_fk WHERE v_groupNames[v_i] = ANY (fk_groups);
--     relation table: for each group, session set to NULL and
--       numbers of log rows computed by emaj_log_stat_group function
      UPDATE emaj.emaj_relation SET rel_session = NULL, rel_rows = stat_rows
        FROM emaj.emaj_log_stat_group (v_groupNames[v_i], v_mark, NULL) stat
        WHERE rel_group = v_groupNames[v_i]
          AND rel_group = stat_group AND rel_schema = stat_schema AND rel_tblseq = stat_table;
    END LOOP;
--   count the number of tables that have no update to rollback
    SELECT count(*) INTO v_nbUnchangedTbl FROM emaj.emaj_relation WHERE rel_group = ANY (v_groupNames) AND rel_rows = 0;
--   allocate tables with rows to rollback to sessions starting with the heaviest to rollback tables
--     as reported by emaj_log_stat_group function
    FOR r_tbl IN
        SELECT * FROM emaj.emaj_relation WHERE rel_group = ANY (v_groupNames) AND rel_kind = 'r' ORDER BY rel_rows DESC
        LOOP
--   is the table already allocated to a session (it may have been already allocated because of a fkey link) ?
      PERFORM 0 FROM emaj.emaj_relation
        WHERE rel_group = ANY (v_groupNames) AND rel_schema = r_tbl.rel_schema AND rel_tblseq = r_tbl.rel_tblseq
          AND rel_session IS NULL;
--   no,
      IF FOUND THEN
--   compute the least loaded session
        v_minSession=1; v_minRows = v_sessionLoad [1];
        FOR v_session IN 2 .. v_nbSession LOOP
          IF v_sessionLoad [v_session] < v_minRows THEN
            v_minSession = v_session;
            v_minRows = v_sessionLoad [v_session];
          END IF;
        END LOOP;
--   allocate the table to the session, with all other tables linked by foreign key constraints
        v_sessionLoad [v_minSession] = v_sessionLoad [v_minSession] +
                 emaj._rlbk_groups_set_session(v_groupNames, r_tbl.rel_schema, r_tbl.rel_tblseq, v_minSession, r_tbl.rel_rows);
      END IF;
    END LOOP;
    RETURN v_nbTblInGroup - v_nbUnchangedTbl;
  END;
$_rlbk_groups_step1$;

CREATE OR REPLACE FUNCTION emaj._rlbk_groups_set_session(v_groupNames TEXT[], v_schema TEXT, v_table TEXT, v_session INT, v_rows BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS
$_rlbk_groups_set_session$
-- This function updates the emaj_relation table and set the predefined session id for one table.
-- It also looks for all tables that are linked to this table by foreign keys to force them to be allocated to the same session.
-- As those linked table can also be linked to other tables by other foreign keys, the function has to be recursiley called.
-- The function returns the accumulated number of rows contained into all log tables of these linked by foreign keys tables.
  DECLARE
    v_cumRows       BIGINT;    -- accumulate the number of rows of the related log tables ; will be returned by the function
    v_fullTableName TEXT;
    r_tbl           RECORD;
  BEGIN
    v_cumRows=v_rows;
-- first set the session of the emaj_relation table for this application table
    UPDATE emaj.emaj_relation SET rel_session = v_session
      WHERE rel_group = ANY (v_groupNames) AND rel_schema = v_schema AND rel_tblseq = v_table;
-- then look for other application tables linked by foreign key relationships
    v_fullTableName := quote_ident(v_schema) || '.' || quote_ident(v_table);
    FOR r_tbl IN
        SELECT rel_schema, rel_tblseq, rel_rows FROM emaj.emaj_relation
          WHERE rel_group = ANY (v_groupNames)
            AND rel_session IS NULL                          -- not yet allocated
            AND (rel_schema, rel_tblseq) IN (                -- list of (schema,table) linked to the original table by foreign keys
            SELECT nspname, relname FROM pg_catalog.pg_constraint, pg_catalog.pg_class t, pg_catalog.pg_namespace n
              WHERE contype = 'f' AND confrelid = v_fullTableName::regclass
                AND t.oid = conrelid AND relnamespace = n.oid
            UNION
            SELECT nspname, relname FROM pg_catalog.pg_constraint, pg_catalog.pg_class t, pg_catalog.pg_namespace n
              WHERE contype = 'f' AND conrelid = v_fullTableName::regclass
                AND t.oid = confrelid AND relnamespace = n.oid
            )
        LOOP
-- recursive call to allocate these linked tables to the same session id and get the accumulated number of rows to rollback
      SELECT v_cumRows + emaj._rlbk_groups_set_session(v_groupNames, r_tbl.rel_schema, r_tbl.rel_tblseq, v_session, r_tbl.rel_rows) INTO v_cumRows;
    END LOOP;
    RETURN v_cumRows;
  END;
$_rlbk_groups_set_session$;

CREATE OR REPLACE FUNCTION emaj._rlbk_groups_step2(v_groupNames TEXT[], v_session INT, v_multiGroup BOOLEAN)
RETURNS void LANGUAGE plpgsql AS
$_rlbk_groups_step2$
-- This is the second step of a rollback group processing. It just locks the tables for a session.
  DECLARE
    v_nbRetry       SMALLINT := 0;
    v_ok            BOOLEAN := false;
    v_nbTbl         INT;
    r_tblsq         RECORD;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'LOCK_SESSIONS' ELSE 'LOCK_SESSION' END, 'BEGIN', array_to_string(v_groupNames,','), 'Session #' || v_session);
-- acquire lock on all tables
-- in case of deadlock, retry up to 5 times
    WHILE NOT v_ok AND v_nbRetry < 5 LOOP
      BEGIN
        v_nbTbl = 0;
-- scan all tables of the session
        FOR r_tblsq IN
            SELECT quote_ident(rel_schema) || '.' || quote_ident(rel_tblseq) AS fullName FROM emaj.emaj_relation
              WHERE rel_group = ANY (v_groupNames) AND rel_session = v_session AND rel_kind = 'r'
              ORDER BY rel_priority, rel_schema, rel_tblseq
            LOOP
--   lock each table
--     The locking level is EXCLUSIVE MODE. It blocks all concurrent update capabilities of all tables of the groups
--     (including table with no update to rollback in order to ensure a stable state of the group at the end of 
--     the rollback operation). But these tables can be accessed by SELECT statements
          EXECUTE 'LOCK TABLE ' || r_tblsq.fullName || ' IN EXCLUSIVE MODE';
          v_nbTbl = v_nbTbl + 1;
        END LOOP;
-- ok, all tables locked
        v_ok = true;
      EXCEPTION
        WHEN deadlock_detected THEN
          v_nbRetry = v_nbRetry + 1;
          RAISE NOTICE '_rlbk_group_step2: a deadlock has been trapped while locking tables for groups %.', array_to_string(v_groupNames,',');
      END;
    END LOOP;
    IF NOT v_ok THEN
      RAISE EXCEPTION '_rlbk_group_step2: too many (5) deadlocks encountered while locking tables of group %.',v_groupName;
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'LOCK_SESSIONS' ELSE 'LOCK_SESSION' END, 'END', array_to_string(v_groupNames,','), 'Session #' || v_session || ' : ' || v_nbTbl || ' tables locked, ' || v_nbRetry || ' deadlock(s)');
    RETURN;
  END;
$_rlbk_groups_step2$;

CREATE OR REPLACE FUNCTION emaj._rlbk_groups_step4(v_groupNames TEXT[], v_session INT, v_unloggedRlbk BOOLEAN)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS
$_rlbk_groups_step4$
-- This is the fourth step of a rollback group processing.
-- If the rollback is unlogged, it disables log triggers for tables involved in the rollback session.
-- Then, it processes all foreign keys involved in the rollback session.
--   Non deferrable fkeys and deferrable fkeys with an action for UPDATE or DELETE other than 'no action' are dropped
--   Others are just set deferred if needed
--   For all fkeys, the action do be performed at step 6 is recorded in emaj_fk table (with either 'add_fk' or 'set_fk_immediate' action).
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of application tables.
  DECLARE
    v_fullTableName     TEXT;
    v_logTriggerName    TEXT;
    r_tbl               RECORD;
    r_fk                RECORD;
  BEGIN
-- disable log triggers if unlogged rollback.
    IF v_unloggedRlbk THEN
      FOR r_tbl IN
        SELECT rel_priority, rel_schema, rel_tblseq FROM emaj.emaj_relation
          WHERE rel_group = ANY (v_groupNames) AND rel_session = v_session AND rel_kind = 'r' AND rel_rows > 0
          ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
        v_fullTableName  := quote_ident(r_tbl.rel_schema) || '.' || quote_ident(r_tbl.rel_tblseq);
        v_logTriggerName := quote_ident(r_tbl.rel_schema || '_' || r_tbl.rel_tblseq || '_emaj_log_trg');
        EXECUTE 'ALTER TABLE ' || v_fullTableName || ' DISABLE TRIGGER ' || v_logTriggerName;
      END LOOP;
    END IF;
-- select all foreign keys belonging to or referencing the session's tables of the group, if any
    FOR r_fk IN
      SELECT c.conname, n.nspname, t.relname, pg_get_constraintdef(c.oid) AS def, c.condeferrable, c.condeferred, c.confupdtype, c.confdeltype
        FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_class t, emaj.emaj_relation r
        WHERE c.contype = 'f'                                            -- FK constraints only
          AND r.rel_rows > 0                                             -- table to effectively rollback only
          AND c.conrelid  = t.oid AND t.relnamespace  = n.oid            -- joins for table and namespace
          AND n.nspname = r.rel_schema AND t.relname = r.rel_tblseq      -- join on groups table
          AND r.rel_group = ANY (v_groupNames) AND r.rel_session = v_session
      UNION
      SELECT c.conname, n.nspname, t.relname, pg_get_constraintdef(c.oid) AS def, c.condeferrable, c.condeferred, c.confupdtype, c.confdeltype
        FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_class t,
             pg_catalog.pg_namespace rn, pg_catalog.pg_class rt, emaj.emaj_relation r
        WHERE c.contype = 'f'                                            -- FK constraints only
          AND r.rel_rows > 0                                             -- table to effectively rollback only
          AND c.conrelid  = t.oid AND t.relnamespace  = n.oid            -- joins for table and namespace
          AND c.confrelid  = rt.oid AND rt.relnamespace  = rn.oid        -- joins for referenced table and namespace
          AND rn.nspname = r.rel_schema AND rt.relname = r.rel_tblseq    -- join on groups table
          AND r.rel_group = ANY (v_groupNames) AND r.rel_session = v_session
      ORDER BY nspname, relname, conname
      LOOP
-- depending on the foreign key characteristics, drop it or set it deffered or just record it as 'to be reset immediate'
      IF NOT r_fk.condeferrable OR r_fk.confupdtype <> 'a' OR r_fk.confdeltype <> 'a' THEN
-- non deferrable fkeys and deferrable fkeys with an action for UPDATE or DELETE other than 'no action' need to be dropped
        EXECUTE 'ALTER TABLE ' || quote_ident(r_fk.nspname) || '.' || quote_ident(r_fk.relname) || ' DROP CONSTRAINT ' || quote_ident(r_fk.conname);
        INSERT INTO emaj.emaj_fk (fk_groups, fk_session, fk_name, fk_schema, fk_table, fk_action, fk_def)
          VALUES (v_groupNames, v_session, r_fk.conname, r_fk.nspname, r_fk.relname, 'add_fk', r_fk.def);
      ELSE
-- other deferrable but not deferred fkeys need to be set deferred
        IF NOT r_fk.condeferred THEN
          EXECUTE 'SET CONSTRAINTS ' || quote_ident(r_fk.nspname) || '.' || quote_ident(r_fk.conname) || ' DEFERRED';
        END IF;
-- deferrable fkeys are recorded as 'to be set immediate at the end of the rollback operation'
        INSERT INTO emaj.emaj_fk (fk_groups, fk_session, fk_name, fk_schema, fk_table, fk_action, fk_def)
          VALUES (v_groupNames, v_session, r_fk.conname, r_fk.nspname, r_fk.relname, 'set_fk_immediate', r_fk.def);
      END IF;
    END LOOP;
  END;
$_rlbk_groups_step4$;

CREATE OR REPLACE FUNCTION emaj._rlbk_groups_step5(v_groupNames TEXT[], v_mark TEXT, v_session INT, v_unloggedRlbk BOOLEAN, v_deleteLog BOOLEAN)
RETURNS INT LANGUAGE plpgsql AS
$_rlbk_groups_step5$
-- This is the fifth step of a rollback group processing. It performs the rollback of all tables of a session.
  DECLARE
    v_nbTbl             INT := 0;
    v_timestampMark     TIMESTAMPTZ;
    v_lastGlobalSeq     BIGINT;
    v_lastSequenceId    BIGINT;
    v_lastSeqHoleId     BIGINT;
  BEGIN
-- fetch the timestamp mark again
    SELECT emaj._get_mark_datetime(v_groupNames[1],v_mark) INTO v_timestampMark;
    IF v_timestampMark IS NULL THEN
      RAISE EXCEPTION '_rlbk_groups_step5: Internal error - mark % not found for group %.', v_mark, v_groupNames[1];
    END IF;
-- fetch the last global sequence and the last id values of emaj_sequence and emaj_seq_hole tables at set mark time
    SELECT mark_global_seq, mark_last_sequence_id, mark_last_seq_hole_id
      INTO v_lastGlobalSeq, v_lastSequenceId, v_lastSeqHoleId FROM emaj.emaj_mark
      WHERE mark_group = v_groupNames[1] AND mark_name = emaj._get_mark_name(v_groupNames[1],v_mark);
-- rollback all tables of the session, having rows to rollback, in priority order (sequences are processed later)
    PERFORM emaj._rlbk_tbl(rel_schema, rel_tblseq, rel_log_schema, v_lastGlobalSeq, v_timestampMark, v_deleteLog, v_lastSequenceId, v_lastSeqHoleId)
      FROM (SELECT rel_priority, rel_schema, rel_tblseq, rel_log_schema FROM emaj.emaj_relation
              WHERE rel_group = ANY (v_groupNames) AND rel_session = v_session AND rel_kind = 'r' AND rel_rows > 0
              ORDER BY rel_priority, rel_schema, rel_tblseq) as t;
-- and return the number of processed tables
    GET DIAGNOSTICS v_nbTbl = ROW_COUNT;
    RETURN v_nbTbl;
  END;
$_rlbk_groups_step5$;

CREATE OR REPLACE FUNCTION emaj._rlbk_groups_step6(v_groupNames TEXT[], v_session INT, v_unloggedRlbk BOOLEAN)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS
$_rlbk_groups_step6$
-- This is the sixth step of a rollback group processing. It recreates the previously deleted foreign keys and 'set immediate' the others.
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of application tables.
  DECLARE
    v_ts_start          TIMESTAMP;
    v_ts_end            TIMESTAMP;
    v_fullTableName     TEXT;
    v_logTriggerName    TEXT;
    v_rows              BIGINT;
    r_fk                RECORD;
    r_tbl               RECORD;
  BEGIN
-- set recorded foreign keys as IMMEDIATE
    FOR r_fk IN
-- get all recorded fk
      SELECT fk_schema, fk_table, fk_name
        FROM emaj.emaj_fk
        WHERE fk_action = 'set_fk_immediate' AND fk_groups = v_groupNames AND fk_session = v_session
        ORDER BY fk_schema, fk_table, fk_name
      LOOP
-- record the time at the alter table start
        SELECT clock_timestamp() INTO v_ts_start;
-- set the fkey constraint as immediate
        EXECUTE 'SET CONSTRAINTS ' || quote_ident(r_fk.fk_schema) || '.' || quote_ident(r_fk.fk_name) || ' IMMEDIATE';
-- record the time after the alter table and insert FK creation duration into the emaj_rlbk_stat table
        SELECT clock_timestamp() INTO v_ts_end;
-- compute the total number of fk that has been checked.
-- (this is in fact overestimated because inserts in the referecing table and deletes in the referenced table should not be taken into account. But the required log table scan would be too costly).
        SELECT (
--   get the number of rollbacked rows in the referencing table
        SELECT rel_rows
          FROM emaj.emaj_relation
          WHERE rel_schema = r_fk.fk_schema AND rel_tblseq = r_fk.fk_table
               ) + (
--   get the number of rollbacked rows in the referenced table
        SELECT rel_rows
          FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_namespace rn,
               pg_catalog.pg_class rt, emaj.emaj_relation r
          WHERE c.conname = r_fk.fk_name                                   -- constraint id (name + schema)
            AND c.connamespace = n.oid AND n.nspname = r_fk.fk_schema
            AND c.confrelid  = rt.oid AND rt.relnamespace  = rn.oid        -- joins for referenced table and namespace
            AND rn.nspname = r.rel_schema AND rt.relname = r.rel_tblseq    -- join on groups table
               ) INTO v_rows;
-- record the set_fk_immediate duration into the rollbacks statistics table
        INSERT INTO emaj.emaj_rlbk_stat (rlbk_operation, rlbk_schema, rlbk_tbl_fk, rlbk_datetime, rlbk_nb_rows, rlbk_duration)
           VALUES ('set_fk_immediate', r_fk.fk_schema, r_fk.fk_name, v_ts_start, v_rows, v_ts_end - v_ts_start);
    END LOOP;
-- process foreign key recreation
    FOR r_fk IN
-- get all recorded fk to recreate, plus the number of rows of the related table as estimated by postgres (pg_class.reltuples)
      SELECT fk_schema, fk_table, fk_name, fk_def, pg_class.reltuples
        FROM emaj.emaj_fk, pg_catalog.pg_namespace, pg_catalog.pg_class
        WHERE fk_action = 'add_fk' AND
              fk_groups = v_groupNames AND fk_session = v_session AND                         -- restrictions
              pg_namespace.oid = relnamespace AND relname = fk_table AND nspname = fk_schema  -- joins
        ORDER BY fk_schema, fk_table, fk_name
      LOOP
-- record the time at the alter table start
        SELECT clock_timestamp() INTO v_ts_start;
-- ... recreate the foreign key
        EXECUTE 'ALTER TABLE ' || quote_ident(r_fk.fk_schema) || '.' || quote_ident(r_fk.fk_table) || ' ADD CONSTRAINT ' || quote_ident(r_fk.fk_name) || ' ' || r_fk.fk_def;
-- record the time after the alter table and insert FK creation duration into the emaj_rlbk_stat table
        SELECT clock_timestamp() INTO v_ts_end;
        INSERT INTO emaj.emaj_rlbk_stat (rlbk_operation, rlbk_schema, rlbk_tbl_fk, rlbk_datetime, rlbk_nb_rows, rlbk_duration)
           VALUES ('add_fk', r_fk.fk_schema, r_fk.fk_name, v_ts_start, r_fk.reltuples, v_ts_end - v_ts_start);
    END LOOP;
-- if unlogged rollback., enable log triggers that had been previously disabled
    IF v_unloggedRlbk THEN
      FOR r_tbl IN
        SELECT rel_priority, rel_schema, rel_tblseq FROM emaj.emaj_relation
          WHERE rel_group = ANY (v_groupNames) AND rel_session = v_session AND rel_kind = 'r' AND rel_rows > 0
          ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
        v_fullTableName  := quote_ident(r_tbl.rel_schema) || '.' || quote_ident(r_tbl.rel_tblseq);
        v_logTriggerName := quote_ident(r_tbl.rel_schema || '_' || r_tbl.rel_tblseq || '_emaj_log_trg');
        EXECUTE 'ALTER TABLE ' || v_fullTableName || ' ENABLE TRIGGER ' || v_logTriggerName;
      END LOOP;
    END IF;
    RETURN;
  END;
$_rlbk_groups_step6$;

CREATE OR REPLACE FUNCTION emaj._rlbk_groups_step7(v_groupNames TEXT[], v_mark TEXT, v_nbTb INT, v_unloggedRlbk BOOLEAN, v_deleteLog BOOLEAN, v_multiGroup BOOLEAN)
RETURNS INT LANGUAGE plpgsql AS
$_rlbk_groups_step7$
-- This is the last step of a rollback group processing. It :
--    - deletes the marks that are no longer available,
--    - rollbacks all sequences of the groups.
-- It returns the number of processed sequences.
  DECLARE
    v_realMark          TEXT;
    v_markId            BIGINT;
    v_timestampMark     TIMESTAMPTZ;
    v_lastSequenceId    BIGINT;
    v_nbSeq             INT;
    v_markName          TEXT;
  BEGIN
-- get the real mark name
    SELECT emaj._get_mark_name(v_groupNames[1],v_mark) INTO v_realMark;
    IF NOT FOUND OR v_realMark IS NULL THEN
      RAISE EXCEPTION '_rlbk_groups_step7: Internal error - mark % not found for group %.', v_mark, v_groupNames[1];
    END IF;
-- if "unlogged" rollback, delete all marks later than the now rollbacked mark
    IF v_unloggedRlbk THEN
-- get the highest mark id of the mark used for rollback, for all groups
      SELECT max(mark_id) INTO v_markId
        FROM emaj.emaj_mark WHERE mark_group = ANY (v_groupNames) AND mark_name = v_realMark;
-- log in the history the name of all marks that must be deleted due to the rollback
      INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
        SELECT CASE WHEN v_multiGroup THEN 'ROLLBACK_GROUPS' ELSE 'ROLLBACK_GROUP' END,
               'MARK DELETED', mark_group, 'mark ' || mark_name || ' has been deleted' FROM emaj.emaj_mark
          WHERE mark_group = ANY (v_groupNames) AND mark_id > v_markId ORDER BY mark_id;
-- delete these useless marks (the related sequences have been already deleted by rollback functions)
      DELETE FROM emaj.emaj_mark WHERE mark_group = ANY (v_groupNames) AND mark_id > v_markId;
-- and finaly reset the mark_log_rows_before_next column for the new last mark
      UPDATE emaj.emaj_mark set mark_log_rows_before_next = NULL
        WHERE mark_group = ANY (v_groupNames)
          AND (mark_group, mark_id) IN                        -- select only last mark of each concerned group
              (SELECT mark_group, MAX(mark_id) FROM emaj.emaj_mark
               WHERE mark_group = ANY (v_groupNames) AND mark_state = 'ACTIVE' GROUP BY mark_group);
    END IF;
-- rollback the application sequences belonging to the groups
-- warning, this operation is not transaction safe (that's why it is placed at the end of the operation)!
--   get the mark timestamp and last sequence id for the 1st group
    SELECT mark_datetime, mark_last_sequence_id INTO v_timestampMark, v_lastSequenceId FROM emaj.emaj_mark
      WHERE mark_group = v_groupNames[1] AND mark_name = v_realMark;
--   and rollback
    PERFORM emaj._rlbk_seq(rel_schema, rel_tblseq, v_timestampMark, v_deleteLog, v_lastSequenceId)
      FROM (SELECT rel_priority, rel_schema, rel_tblseq FROM emaj.emaj_relation
              WHERE rel_group = ANY (v_groupNames) AND rel_kind = 'S'
              ORDER BY rel_priority, rel_schema, rel_tblseq) as t;
    GET DIAGNOSTICS v_nbSeq = ROW_COUNT;
-- if rollback is "logged" rollback, automaticaly set a mark representing the tables state just after the rollback.
-- this mark is named 'RLBK_<mark name to rollback to>_%_DONE', where % represents the current time
    IF NOT v_unloggedRlbk THEN
-- get the mark name set at the beginning of the rollback operation (i.e. the last set mark)
      SELECT mark_name INTO v_markName
        FROM emaj.emaj_mark
        WHERE mark_group = v_groupNames[1] ORDER BY mark_id DESC LIMIT 1;
      IF NOT FOUND OR v_markName NOT LIKE 'RLBK%START' THEN
        RAISE EXCEPTION '_rlbk_groups_step7: Internal error - rollback start mark not found for group %.', v_groupNames[1];
      END IF;
-- compute the mark name that ends the rollback operation, replacing the '_START' suffix of the rollback start mark by '_DONE'
      v_markName = substring(v_markName FROM '(.*)_START$') || '_DONE';
-- ...  and set it
      PERFORM emaj._set_mark_groups(v_groupNames, v_markName, v_multiGroup, true);
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES (CASE WHEN v_multiGroup THEN 'ROLLBACK_GROUPS' ELSE 'ROLLBACK_GROUP' END, 'END',
              array_to_string(v_groupNames,','), v_nbTb || ' tables and ' || v_nbSeq || ' sequences effectively processed');
    RETURN v_nbSeq;
  END;
$_rlbk_groups_step7$;

CREATE OR REPLACE FUNCTION emaj.emaj_reset_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS
$emaj_reset_group$
-- This function empties the log tables for all tables of a group and deletes the sequences saves
-- It calls the emaj_rst_group function to do the job
-- Input: group name
-- Output: number of processed tables
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use it even if he is not the owner of application tables.
  DECLARE
    v_groupState  TEXT;
    v_nbTb        INT := 0;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object)
      VALUES ('RESET_GROUP', 'BEGIN', v_groupName);
-- check that the group is recorded in emaj_group table
    SELECT group_state INTO v_groupState FROM emaj.emaj_group WHERE group_name = v_groupName FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_reset_group: group % has not been created.', v_groupName;
    END IF;
-- check that the group is in IDLE state (i.e. not in LOGGING) state
    IF v_groupState <> 'IDLE' THEN
      RAISE EXCEPTION 'emaj_reset_group: Group % cannot be reset because it is not in idle state. An emaj_stop_group function must be previously executed.', v_groupName;
    END IF;
-- perform the reset operation
    SELECT emaj._reset_group(v_groupName) INTO v_nbTb;
    IF v_nbTb = 0 THEN
       RAISE EXCEPTION 'emaj_reset_group: Internal error (Group % is empty).', v_groupName;
    END IF;
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('RESET_GROUP', 'END', v_groupName, v_nbTb || ' tables/sequences processed');
    RETURN v_nbTb;
  END;
$emaj_reset_group$;
COMMENT ON FUNCTION emaj.emaj_reset_group(TEXT) IS
$$Resets all log tables content of a stopped E-Maj group.$$;

CREATE OR REPLACE FUNCTION emaj._reset_group(v_groupName TEXT)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS
$_reset_group$
-- This function empties the log tables for all tables of a group, using a TRUNCATE, and deletes the sequences saves
-- It is called by both emaj_reset_group and emaj_start_group functions
-- Input: group name
-- Output: number of processed tables
-- There is no check of the group state
-- The function is defined as SECURITY DEFINER so that an emaj_adm role can truncate log tables
  DECLARE
    v_nbTb          INT  := 0;
    v_logTableName  TEXT;
    r_tblsq         RECORD;
  BEGIN
-- delete all marks for the group from the emaj_mark table
    DELETE FROM emaj.emaj_mark WHERE mark_group = v_groupName;
-- delete all sequence holes for the tables of the group
    DELETE FROM emaj.emaj_seq_hole USING emaj.emaj_relation
      WHERE rel_group = v_groupName AND rel_kind = 'r' AND rel_schema = sqhl_schema AND rel_tblseq = sqhl_table;
-- then, truncate log tables
    FOR r_tblsq IN
        SELECT rel_schema, rel_tblseq, rel_log_schema, rel_kind FROM emaj.emaj_relation
          WHERE rel_group = v_groupName ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
      IF r_tblsq.rel_kind = 'r' THEN
-- if it is a table,
--   truncate the related log table
        v_logTableName := quote_ident(r_tblsq.rel_log_schema) || '.' || quote_ident(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_log');
        EXECUTE 'TRUNCATE ' || v_logTableName;
--   delete rows from emaj_sequence related to the associated log sequence
        DELETE FROM emaj.emaj_sequence 
          WHERE sequ_schema = r_tblsq.rel_log_schema 
            AND sequ_name = emaj._build_log_seq_name(r_tblsq.rel_schema, r_tblsq.rel_tblseq);
--   and reset the log sequence
        PERFORM setval(quote_ident(r_tblsq.rel_log_schema) || '.' || quote_ident(emaj._build_log_seq_name(r_tblsq.rel_schema, r_tblsq.rel_tblseq)), 1, false);
      ELSEIF r_tblsq.rel_kind = 'S' THEN
-- if it is a sequence, delete all related data from emaj_sequence table
        PERFORM emaj._drop_seq (r_tblsq.rel_schema, r_tblsq.rel_tblseq);
      END IF;
      v_nbTb = v_nbTb + 1;
    END LOOP;
    RETURN v_nbTb;
  END;
$_reset_group$;

CREATE OR REPLACE FUNCTION emaj.emaj_log_stat_group(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT)
RETURNS SETOF emaj.emaj_log_stat_type LANGUAGE plpgsql AS
$emaj_log_stat_group$
-- This function returns statistics on row updates executed between 2 marks or between a mark and the current situation.
-- It is used to quickly get simple statistics of updates logged between 2 marks (i.e. for one or several processing)
-- It is also used to estimate the cost of a rollback to a specified mark
-- These statistics are computed using the serial id of log tables and holes is sequences recorded into emaj_seq_hole at rollback time
-- Input: group name, the 2 mark names defining a range
--   a NULL value or an empty string as first_mark indicates the first recorded mark
--   a NULL value or an empty string as last_mark indicates the current situation
--   Use a NULL or an empty string as last_mark to know the number of rows to rollback to reach the mark specified by the first_mark parameter.
--   The keyword 'EMAJ_LAST_MARK' can be used as first or last mark to specify the last set mark.
-- Output: table of log rows by table (including tables with 0 rows to rollback)
  DECLARE
    v_groupState         TEXT;
    v_realFirstMark      TEXT;
    v_realLastMark       TEXT;
    v_firstMarkId        BIGINT;
    v_lastMarkId         BIGINT;
    v_tsFirstMark        TIMESTAMPTZ;
    v_tsLastMark         TIMESTAMPTZ;
    v_firstLastSeqHoleId BIGINT;
    v_lastLastSeqHoleId  BIGINT;
    v_fullSeqName        TEXT;
    v_beginLastValue     BIGINT;
    v_endLastValue       BIGINT;
    v_sumHole            BIGINT;
    r_tblsq              RECORD;
    r_stat               RECORD;
  BEGIN
-- check that the group is recorded in emaj_group table
    SELECT group_state INTO v_groupState FROM emaj.emaj_group WHERE group_name = v_groupName;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_log_stat_group: group % has not been created.', v_groupName;
    END IF;
-- if first mark is NULL or empty, retrieve the name, timestamp and last sequ_hole id of the first recorded mark for the group
    IF v_firstMark IS NULL OR v_firstMark = '' THEN
--   if no mark exists for the group (just after emaj_create_group() or emaj_reset_group() functions call),
--     v_realFirstMark remains NULL
      SELECT mark_id, mark_name, mark_datetime, mark_last_seq_hole_id INTO v_firstMarkId, v_realFirstMark, v_tsFirstMark, v_firstLastSeqHoleId
        FROM emaj.emaj_mark WHERE mark_group = v_groupName ORDER BY mark_id LIMIT 1;
    ELSE
-- else, check and retrieve the name, timestamp and last sequ_hole id of the supplied first mark for the group
      SELECT emaj._get_mark_name(v_groupName,v_firstMark) INTO v_realFirstMark;
      IF v_realFirstMark IS NULL THEN
        RAISE EXCEPTION 'emaj_log_stat_group: Start mark % is unknown for group %.', v_firstMark, v_groupName;
      END IF;
      SELECT mark_id, mark_datetime, mark_last_seq_hole_id INTO v_firstMarkId, v_tsFirstMark, v_firstLastSeqHoleId
        FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realFirstMark;
    END IF;
-- if a last mark name is supplied, check and retrieve the name, timestamp and last sequ_hole id of the supplied end mark for the group
    IF v_lastMark IS NOT NULL AND v_lastMark <> '' THEN
      SELECT emaj._get_mark_name(v_groupName,v_lastMark) INTO v_realLastMark;
      IF v_realLastMark IS NULL THEN
        RAISE EXCEPTION 'emaj_log_stat_group: End mark % is unknown for group %.', v_lastMark, v_groupName;
      END IF;
      SELECT mark_id, mark_datetime, mark_last_seq_hole_id INTO v_lastMarkId, v_tsLastMark, v_lastLastSeqHoleId
        FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realLastMark;
-- if last mark is null or empty, v_realLastMark, v_lastMarkId, v_tsLastMark and v_lastLastSeqHoleId remain NULL
    END IF;
-- check that the first_mark < end_mark
    IF v_lastMarkId IS NOT NULL AND v_firstMarkId > v_lastMarkId THEN
      RAISE EXCEPTION 'emaj_log_stat_group: mark id for % (% = %) is greater than mark id for % (% = %).', v_firstMark, v_firstMarkId, v_tsFirstMark, v_lastMark, v_lastMarkId, v_tsLastMark;
    END IF;
-- for each table of the emaj_relation table, get the number of log rows and return the statistic
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, 
               CASE WHEN v_tsFirstMark IS NULL THEN 0 ELSE emaj._log_stat_tbl(rel_schema, rel_tblseq, rel_log_schema, v_tsFirstMark, v_tsLastMark, v_firstLastSeqHoleId, v_lastLastSeqHoleId) END AS nb_rows 
          FROM emaj.emaj_relation
          WHERE rel_group = v_groupName AND rel_kind = 'r' ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
      SELECT v_groupName, r_tblsq.rel_schema, r_tblsq.rel_tblseq, r_tblsq.nb_rows INTO r_stat;
      RETURN NEXT r_stat;
    END LOOP;
    RETURN;
  END;
$emaj_log_stat_group$;
COMMENT ON FUNCTION emaj.emaj_log_stat_group(TEXT,TEXT,TEXT) IS
$$Returns global statistics about logged events for an E-Maj group between 2 marks.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_detailed_log_stat_group(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT)
RETURNS SETOF emaj.emaj_detailed_log_stat_type LANGUAGE plpgsql AS
$emaj_detailed_log_stat_group$
-- This function returns statistics on row updates executed between 2 marks as viewed through the log tables
-- It provides more information than emaj_log_stat_group but it needs to scan log tables in order to provide these data.
-- So the response time may be much longer.
-- Input: group name, the 2 marks names defining a range
--   a NULL value or an empty string as first_mark indicates the first recorded mark
--   a NULL value or an empty string as last_mark indicates the current situation
--   The keyword 'EMAJ_LAST_MARK' can be used as first or last mark to specify the last set mark.
-- Output: table of updates by user and table
  DECLARE
    v_groupState         TEXT;
    v_realFirstMark      TEXT;
    v_realLastMark       TEXT;
    v_firstMarkId        BIGINT;
    v_lastMarkId         BIGINT;
    v_tsFirstMark        TIMESTAMPTZ;
    v_tsLastMark         TIMESTAMPTZ;
    v_firstEmajGid       BIGINT;
    v_lastEmajGid        BIGINT;
    v_logTableName       TEXT;
    v_stmt               TEXT;
    r_tblsq              RECORD;
    r_stat               RECORD;
  BEGIN
-- check that the group is recorded in emaj_group table
    SELECT group_state INTO v_groupState FROM emaj.emaj_group WHERE group_name = v_groupName;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_detailed_log_stat_group: group % has not been created.', v_groupName;
    END IF;
-- catch the timestamp of the first mark
    IF v_firstMark IS NOT NULL AND v_firstMark <> '' THEN
-- check and retrieve the global sequence value and the timestamp of the start mark for the group
      SELECT emaj._get_mark_name(v_groupName,v_firstMark) INTO v_realFirstMark;
      IF v_realFirstMark IS NULL THEN
          RAISE EXCEPTION 'emaj_detailed_log_stat_group: Start mark % is unknown for group %.', v_firstMark, v_groupName;
      END IF;
      SELECT mark_id, mark_global_seq, mark_datetime INTO v_firstMarkId, v_firstEmajGid, v_tsFirstMark
        FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realFirstMark;
    END IF;
-- catch the timestamp of the last mark
    IF v_lastMark IS NOT NULL AND v_lastMark <> '' THEN
-- else, check and retrieve the global sequence value and the timestamp of the end mark for the group
      SELECT emaj._get_mark_name(v_groupName,v_lastMark) INTO v_realLastMark;
      IF v_realLastMark IS NULL THEN
        RAISE EXCEPTION 'emaj_detailed_log_stat_group: End mark % is unknown for group %.', v_lastMark, v_groupName;
      END IF;
      SELECT mark_id, mark_global_seq, mark_datetime INTO v_lastMarkId, v_lastEmajGid, v_tsLastMark
        FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realLastMark;
    END IF;
-- check that the first_mark < end_mark
    IF v_realFirstMark IS NOT NULL AND v_realLastMark IS NOT NULL AND v_firstMarkId > v_lastMarkId THEN
      RAISE EXCEPTION 'emaj_detailed_log_stat_group: mark id for % (% = %) is greater than mark id for % (% = %).', v_realFirstMark, v_firstMarkId, v_tsFirstMark, v_realLastMark, v_lastMarkId, v_tsLastMark;
    END IF;
-- for each table of the emaj_relation table
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, rel_log_schema, rel_kind FROM emaj.emaj_relation
          WHERE rel_group = v_groupName ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
      IF r_tblsq.rel_kind = 'r' THEN
-- if it is a table, count the number of operations per type (INSERT, UPDATE and DELETE) and role
-- compute the log table name and its sequence name for this table
        v_logTableName := quote_ident(r_tblsq.rel_log_schema) || '.' || quote_ident(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_log');
-- prepare and execute the statement
        v_stmt= 'SELECT ' || quote_literal(v_groupName) || '::TEXT as emaj_group,'
             || ' ' || quote_literal(r_tblsq.rel_schema) || '::TEXT as emaj_schema,'
             || ' ' || quote_literal(r_tblsq.rel_tblseq) || '::TEXT as emaj_table,'
             || ' emaj_user,'
             || ' CASE WHEN emaj_verb = ''INS'' THEN ''INSERT'''
             ||      ' WHEN emaj_verb = ''UPD'' THEN ''UPDATE'''
             ||      ' WHEN emaj_verb = ''DEL'' THEN ''DELETE'''
             ||      ' ELSE ''?'' END::VARCHAR(6) as emaj_verb,'
             || ' count(*) as emaj_rows'
             || ' FROM ' || v_logTableName
             || ' WHERE NOT (emaj_verb = ''UPD'' AND emaj_tuple = ''OLD'')';
        IF v_firstMark IS NOT NULL AND v_firstMark <> '' THEN v_stmt = v_stmt
             || ' AND emaj_gid > '|| v_firstEmajGid ;
        END IF;
        IF v_lastMark IS NOT NULL AND v_lastMark <> '' THEN v_stmt = v_stmt
             || ' AND emaj_gid <= '|| v_lastEmajGid ;
        END IF;
        v_stmt = v_stmt
             || ' GROUP BY emaj_group, emaj_schema, emaj_table, emaj_user, emaj_verb'
             || ' ORDER BY emaj_user, emaj_verb';
        FOR r_stat IN EXECUTE v_stmt LOOP
          RETURN NEXT r_stat;
        END LOOP;
      END IF;
    END LOOP;
    RETURN;
  END;
$emaj_detailed_log_stat_group$;
COMMENT ON FUNCTION emaj.emaj_detailed_log_stat_group(TEXT,TEXT,TEXT) IS
$$Returns detailed statistics about logged events for an E-Maj group between 2 marks.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_estimate_rollback_duration(v_groupName TEXT, v_mark TEXT)
RETURNS interval LANGUAGE plpgsql AS
$emaj_estimate_rollback_duration$
-- This function computes an approximate duration of a rollback to a predefined mark for a group.
-- It takes into account the content of emaj_rollback_stat table filled by previous rollback operations.
-- It also uses several parameters from emaj_param table.
-- "Logged" and "Unlogged" rollback durations are estimated with the same algorithm. (the cost of log insertion
-- for logged rollback balances the cost of log deletion of unlogged rollback)
-- Input: group name, the mark name of the rollback operation
-- Output: the approximate duration that the rollback would need as time interval
  DECLARE
    v_nbTblSeq              INTEGER;
    v_markName              TEXT;
    v_markState             TEXT;
    v_estim_duration        INTERVAL;
    v_avg_row_rlbk          INTERVAL;
    v_avg_row_del_log       INTERVAL;
    v_avg_fkey_check        INTERVAL;
    v_fixed_table_rlbk      INTERVAL;
    v_fixed_table_with_rlbk INTERVAL;
    v_estim                 INTERVAL;
    v_checks                BIGINT;
    r_tblsq                 RECORD;
    r_fkey		            RECORD;
  BEGIN
-- check that the group is recorded in emaj_group table and get the number of tables and sequences
    SELECT group_nb_table + group_nb_sequence INTO v_nbTblSeq FROM emaj.emaj_group
      WHERE group_name = v_groupName and group_state = 'LOGGING';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_estimate_rollback_duration: group % has not been created or is not in LOGGING state.', v_groupName;
    END IF;
-- check the mark exists
    SELECT emaj._get_mark_name(v_groupName,v_mark) INTO v_markName;
    IF NOT FOUND OR v_markName IS NULL THEN
      RAISE EXCEPTION 'emaj_estimate_rollback_duration: no mark % exists for group %.', v_mark, v_groupName;
    END IF;
-- check the mark is ACTIVE
    SELECT mark_state INTO v_markState FROM emaj.emaj_mark
      WHERE mark_group = v_groupName AND mark_name = v_markName;
    IF v_markState <> 'ACTIVE' THEN
      RAISE EXCEPTION 'emaj_estimate_rollback_duration: mark % for group % is not in ACTIVE state.', v_markName, v_groupName;
    END IF;
-- get all needed duration parameters from emaj_param table,
--   or get default values for rows that are not present in emaj_param table
    SELECT coalesce ((SELECT param_value_interval FROM emaj.emaj_param
                        WHERE param_key = 'avg_row_rollback_duration'),'100 microsecond'::interval),
           coalesce ((SELECT param_value_interval FROM emaj.emaj_param
                        WHERE param_key = 'avg_row_delete_log_duration'),'10 microsecond'::interval),
           coalesce ((SELECT param_value_interval FROM emaj.emaj_param
                        WHERE param_key = 'avg_fkey_check_duration'),'5 microsecond'::interval),
           coalesce ((SELECT param_value_interval FROM emaj.emaj_param
                        WHERE param_key = 'fixed_table_rollback_duration'),'5 millisecond'::interval),
           coalesce ((SELECT param_value_interval FROM emaj.emaj_param
                        WHERE param_key = 'fixed_table_with_rollback_duration'),'2.5 millisecond'::interval)
           INTO v_avg_row_rlbk, v_avg_row_del_log, v_avg_fkey_check, v_fixed_table_rlbk, v_fixed_table_with_rlbk;
-- compute the fixed cost for the group
    v_estim_duration = v_nbTblSeq * v_fixed_table_rlbk;
--
-- walk through the list of tables with their number of rows to rollback as returned by the emaj_log_stat_group function
--
-- for each table with content to rollback
    FOR r_tblsq IN
        SELECT stat_schema, stat_table, stat_rows FROM emaj.emaj_log_stat_group(v_groupName, v_mark, NULL) WHERE stat_rows > 0
        LOOP
--
-- compute the rollback duration estimate for the table
--
-- first look at the previous rollback durations for the table and with similar rollback volume (same order of magnitude)
      SELECT sum(rlbk_duration) * r_tblsq.stat_rows / sum(rlbk_nb_rows) INTO v_estim FROM emaj.emaj_rlbk_stat
        WHERE rlbk_operation = 'rlbk' AND rlbk_nb_rows > 0
          AND rlbk_schema = r_tblsq.stat_schema AND rlbk_tbl_fk = r_tblsq.stat_table
          AND rlbk_nb_rows / r_tblsq.stat_rows < 10 AND r_tblsq.stat_rows / rlbk_nb_rows < 10;
      IF v_estim IS NULL THEN
-- if there is no previous rollback operation with similar volume, take statistics for the table with all available volumes
        SELECT sum(rlbk_duration) * r_tblsq.stat_rows / sum(rlbk_nb_rows) INTO v_estim FROM emaj.emaj_rlbk_stat
          WHERE rlbk_operation = 'rlbk' AND rlbk_nb_rows > 0
            AND rlbk_schema = r_tblsq.stat_schema AND rlbk_tbl_fk = r_tblsq.stat_table;
        IF v_estim IS NULL THEN
-- if there is no previous rollback operation, use the avg_row_rollback_duration from the emaj_param table
          v_estim = v_avg_row_rlbk * r_tblsq.stat_rows;
        END IF;
      END IF;
      v_estim_duration = v_estim_duration + v_fixed_table_with_rlbk + v_estim;
--
-- compute the log rows delete duration for the table
--
-- first look at the previous rollback durations for the table and with similar rollback volume (same order of magnitude)
      SELECT sum(rlbk_duration) * r_tblsq.stat_rows / sum(rlbk_nb_rows) INTO v_estim FROM emaj.emaj_rlbk_stat
        WHERE rlbk_operation = 'del_log' AND rlbk_nb_rows > 0
          AND rlbk_schema = r_tblsq.stat_schema AND rlbk_tbl_fk = r_tblsq.stat_table
          AND rlbk_nb_rows / r_tblsq.stat_rows < 10 AND r_tblsq.stat_rows / rlbk_nb_rows < 10;
      IF v_estim IS NULL THEN
-- if there is no previous rollback operation with similar volume, take statistics for the table with all available volumes
        SELECT sum(rlbk_duration) * r_tblsq.stat_rows / sum(rlbk_nb_rows) INTO v_estim FROM emaj.emaj_rlbk_stat
          WHERE rlbk_operation = 'del_log' AND rlbk_nb_rows > 0
            AND rlbk_schema = r_tblsq.stat_schema AND rlbk_tbl_fk = r_tblsq.stat_table;
        IF v_estim IS NULL THEN
-- if there is no previous rollback operation, use the avg_row_rollback_duration from the emaj_param table
          v_estim = v_avg_row_del_log * r_tblsq.stat_rows;
        END IF;
      END IF;
      v_estim_duration = v_estim_duration + v_estim;
    END LOOP;
--
-- walk through the list of foreign key constraints concerned by the estimated rollback
--
-- for each foreign key referencing tables that are concerned by the rollback operation
    FOR r_fkey IN
      SELECT c.conname, n.nspname, t.relname, t.reltuples, c.condeferrable, c.condeferred, c.confupdtype, c.confdeltype
        FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_class t,
             emaj.emaj_log_stat_group(v_groupName, v_mark, NULL) s
        WHERE c.contype = 'f'                                            -- FK constraints only
          AND s.stat_rows > 0                                              -- table to effectively rollback only
          AND c.conrelid  = t.oid AND t.relnamespace  = n.oid            -- joins for table and namespace
          AND n.nspname = s.stat_schema AND t.relname = s.stat_table     -- join on log_stat results
      UNION
      SELECT c.conname, n.nspname, t.relname, t.reltuples, c.condeferrable, c.condeferred, c.confupdtype, c.confdeltype
        FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_class t,
             pg_catalog.pg_namespace rn, pg_catalog.pg_class rt, emaj.emaj_log_stat_group(v_groupName, v_mark, NULL) s
        WHERE c.contype = 'f'                                            -- FK constraints only
          AND s.stat_rows > 0                                            -- table to effectively rollback only
          AND c.conrelid  = t.oid AND t.relnamespace  = n.oid            -- joins for table and namespace
          AND c.confrelid  = rt.oid AND rt.relnamespace  = rn.oid        -- joins for referenced table and namespace
          AND rn.nspname = s.stat_schema AND rt.relname = s.stat_table   -- join on log_stat results
      ORDER BY nspname, relname, conname
        LOOP
      IF NOT r_fkey.condeferrable OR r_fkey.confupdtype <> 'a' OR r_fkey.confdeltype <> 'a' THEN
-- the fkey is non deferrable fkeys or has an action for UPDATE or DELETE other than 'no action'.
-- So estimate its re-creation duration.
        IF r_fkey.reltuples = 0 THEN
-- empty table (or table not analyzed) => duration = 0
          v_estim = 0;
	    ELSE
-- non empty table and statistics (with at least one row) are available
          SELECT sum(rlbk_duration) * r_fkey.reltuples / sum(rlbk_nb_rows) INTO v_estim FROM emaj.emaj_rlbk_stat
            WHERE rlbk_operation = 'add_fk' AND rlbk_nb_rows > 0
              AND rlbk_schema = r_fkey.nspname AND rlbk_tbl_fk = r_fkey.conname;
          IF v_estim IS NULL THEN
-- non empty table, but no statistics with at least one row are available => take the last duration for this fkey, if any
            SELECT rlbk_duration INTO v_estim FROM emaj.emaj_rlbk_stat
              WHERE rlbk_operation = 'add_fk' AND rlbk_schema = r_fkey.nspname AND rlbk_tbl_fk = r_fkey.conname AND rlbk_datetime =
               (SELECT max(rlbk_datetime) FROM emaj.emaj_rlbk_stat
                  WHERE rlbk_operation = 'add_fk' AND rlbk_schema = r_fkey.nspname AND rlbk_tbl_fk = r_fkey.conname);
            IF v_estim IS NULL THEN
-- definitely no statistics available, compute with the avg_fkey_check_duration parameter
              v_estim = r_fkey.reltuples * v_avg_fkey_check;
            END IF;
          END IF;
        END IF;
      ELSE
-- the fkey is really deferrable. So estimate the keys checks duration.
-- compute the total number of fk that would be checked
-- (this is in fact overestimated because inserts in the referecing table and deletes in the referenced table should not be taken into account. But the required log table scan would be too costly).
        SELECT (
--   get the number of rollbacked rows in the referencing table
        SELECT s.stat_rows
          FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_class r,
               emaj.emaj_log_stat_group(v_groupName, v_mark, NULL) s
          WHERE c.conname = r_fkey.conname                                 -- constraint id (name + schema)
            AND c.connamespace = n.oid AND n.nspname = r_fkey.nspname
            AND c.conrelid  = r.oid AND r.relnamespace  = n.oid            -- joins for referencing table and namespace
            AND n.nspname = s.stat_schema AND r.relname = s.stat_table     -- join on groups table
               ) + (
--   get the number of rollbacked rows in the referenced table
        SELECT s.stat_rows
          FROM pg_catalog.pg_constraint c, pg_catalog.pg_namespace n, pg_catalog.pg_namespace rn,
               pg_catalog.pg_class rt, emaj.emaj_log_stat_group(v_groupName, v_mark, NULL) s
          WHERE c.conname = r_fkey.conname                                 -- constraint id (name + schema)
            AND c.connamespace = n.oid AND n.nspname = r_fkey.nspname
            AND c.confrelid  = rt.oid AND rt.relnamespace  = rn.oid        -- joins for referenced table and namespace
            AND rn.nspname = s.stat_schema AND rt.relname = s.stat_table   -- join on groups table
               ) INTO v_checks;
        IF v_checks = 0 THEN
-- No check to perform
          RAISE EXCEPTION 'estimate_rollback_duration: no check to perform. One should not find this case !!!';
        ELSE
-- if fkey checks statistics are available for this fkey, compute an average cost
          SELECT sum(rlbk_duration) * v_checks / sum(rlbk_nb_rows) INTO v_estim FROM emaj.emaj_rlbk_stat
            WHERE rlbk_operation = 'set_fk_immediate' AND rlbk_nb_rows > 0
              AND rlbk_schema = r_fkey.nspname AND rlbk_tbl_fk = r_fkey.conname;
          IF v_estim IS NULL THEN
-- if no statistics are available for this fkey, use the avg_fkey_check parameter
            v_estim = v_checks * v_avg_fkey_check;
          END IF;
        END IF;
      END IF;
      v_estim_duration = v_estim_duration + v_estim;
    END LOOP;
    RETURN v_estim_duration;
  END;
$emaj_estimate_rollback_duration$;
COMMENT ON FUNCTION emaj.emaj_estimate_rollback_duration(TEXT,TEXT) IS
$$Estimates the duration of a potential rollback of an E-Maj group to a given mark.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_snap_group(v_groupName TEXT, v_dir TEXT, v_copyOptions TEXT)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS
$emaj_snap_group$
-- This function creates a file for each table and sequence belonging to the group.
-- For tables, these files contain all rows sorted on primary key.
-- For sequences, they contain a single row describing the sequence.
-- To do its job, the function performs COPY TO statement, with all default parameters.
-- For table without primary key, rows are sorted on all columns.
-- There is no need for the group to be in IDLE state.
-- As all COPY statements are executed inside a single transaction:
--   - the function can be called while other transactions are running,
--   - the snap files will present a coherent state of tables.
-- It's users responsability :
--   - to create the directory (with proper permissions allowing the cluster to write into) before
-- emaj_snap_group function call, and
--   - maintain its content outside E-maj.
-- Input: group name, the absolute pathname of the directory where the files are to be created and the options to used in the COPY TO statements
-- Output: number of processed tables and sequences
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use.
  DECLARE
    v_pgVersion       TEXT := emaj._pg_version();
    v_nbTb            INT := 0;
    r_tblsq           RECORD;
    v_fullTableName   TEXT;
    r_col             RECORD;
    v_colList         TEXT;
    v_fileName        TEXT;
    v_stmt            TEXT;
    v_seqCol          TEXT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SNAP_GROUP', 'BEGIN', v_groupName, v_dir);
-- check that the group is recorded in emaj_group table
    PERFORM 0 FROM emaj.emaj_group WHERE group_name = v_groupName;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_snap_group: group % has not been created.', v_groupName;
    END IF;
-- check the supplied directory is not null
    IF v_dir IS NULL THEN
      RAISE EXCEPTION 'emaj_snap_group: directory parameter cannot be NULL';
    END IF;
-- check the copy options parameter doesn't contain unquoted ; that could be used for sql injection
    IF regexp_replace(v_copyOptions,'''.*''','') LIKE '%;%' THEN
      RAISE EXCEPTION 'emaj_snap_group: invalid COPY options parameter format';
    END IF;
-- for each table/sequence of the emaj_relation table
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, rel_kind FROM emaj.emaj_relation
          WHERE rel_group = v_groupName ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
      v_fileName := v_dir || '/' || r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '.snap';
      v_fullTableName := quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
      IF r_tblsq.rel_kind = 'r' THEN
-- if it is a table,
--   first build the order by column list
        v_colList := '';
        PERFORM 0 FROM pg_catalog.pg_class, pg_catalog.pg_namespace, pg_catalog.pg_constraint
          WHERE relnamespace = pg_namespace.oid AND connamespace = pg_namespace.oid AND conrelid = pg_class.oid AND
                contype = 'p' AND nspname = r_tblsq.rel_schema AND relname = r_tblsq.rel_tblseq;
        IF FOUND THEN
--   the table has a pkey,
          FOR r_col IN
              SELECT attname FROM pg_catalog.pg_attribute, pg_catalog.pg_index
                WHERE pg_attribute.attrelid = pg_index.indrelid
                  AND attnum = ANY (indkey)
                  AND indrelid = v_fullTableName::regclass AND indisprimary
                  AND attnum > 0 AND attisdropped = false
              LOOP
            IF v_colList = '' THEN
               v_colList := quote_ident(r_col.attname);
            ELSE
               v_colList := v_colList || ',' || quote_ident(r_col.attname);
            END IF;
          END LOOP;
        ELSE
--   the table has no pkey
          FOR r_col IN
              SELECT attname FROM pg_catalog.pg_attribute
                WHERE attrelid = v_fullTableName::regclass
                  AND attnum > 0  AND attisdropped = false
              LOOP
            IF v_colList = '' THEN
               v_colList := quote_ident(r_col.attname);
            ELSE
               v_colList := v_colList || ',' || quote_ident(r_col.attname);
            END IF;
          END LOOP;
        END IF;
--   prepare the COPY statement
        v_stmt= 'COPY (SELECT * FROM ' || v_fullTableName || ' ORDER BY ' || v_colList || ') TO '
                || quote_literal(v_fileName) || ' ' || coalesce (v_copyOptions, '');
        ELSEIF r_tblsq.rel_kind = 'S' THEN
-- if it is a sequence, the statement has no order by
        IF v_pgVersion <= '8.3' THEN
          v_seqCol = 'sequence_name, last_value, 0, increment_by, max_value, min_value, cache_value, is_cycled, is_called';
        ELSE
          v_seqCol = 'sequence_name, last_value, start_value, increment_by, max_value, min_value, cache_value, is_cycled, is_called';
        END IF;
        v_stmt= 'COPY (SELECT ' || v_seqCol || ' FROM ' || v_fullTableName || ') TO '
                || quote_literal(v_fileName) || ' ' || coalesce (v_copyOptions, '');
      END IF;
-- and finaly perform the COPY
--    raise notice 'emaj_snap_group: Executing %',v_stmt;
      EXECUTE v_stmt;
      v_nbTb = v_nbTb + 1;
    END LOOP;
-- create the _INFO file to keep general information about the snap operation
    EXECUTE 'COPY (SELECT ' ||
            quote_literal('E-Maj snap of tables group ' || v_groupName ||
            ' at ' || transaction_timestamp()) ||
            ') TO ' || quote_literal(v_dir || '/_INFO');
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SNAP_GROUP', 'END', v_groupName, v_nbTb || ' tables/sequences processed');
    RETURN v_nbTb;
  END;
$emaj_snap_group$;
COMMENT ON FUNCTION emaj.emaj_snap_group(TEXT,TEXT,TEXT) IS
$$Snaps all application tables and sequences of an E-Maj group into a given directory.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_snap_log_group(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT, v_dir TEXT, v_copyOptions TEXT)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS
$emaj_snap_log_group$
-- This function creates a file for each log table belonging to the group.
-- It also creates 2 files containing the state of sequences respectively at start mark and end mark
-- For log tables, files contain all rows related to the time frame, sorted on emaj_gid.
-- For sequences, files are names <group>_sequences_at_<mark>, or <group>_sequences_at_<time> if no
--   end mark is specified. They contain one row per sequence.
-- To do its job, the function performs COPY TO statement, using the options provided by the caller.
-- There is no need for the group to be in IDLE state.
-- As all COPY statements are executed inside a single transaction:
--   - the function can be called while other transactions are running,
--   - the snap files will present a coherent state of tables.
-- It's users responsability :
--   - to create the directory (with proper permissions allowing the cluster to write into) before
-- emaj_snap_log_group function call, and
--   - maintain its content outside E-maj.
-- Input: group name, the 2 mark names defining a range, the absolute pathname of the directory where the files are to be created, options for COPY TO statements
--   a NULL value or an empty string as first_mark indicates the first recorded mark
--   a NULL value or an empty string can be used as last_mark indicating the current state
--   The keyword 'EMAJ_LAST_MARK' can be used as first or last mark to specify the last set mark.
-- Output: number of processed tables and sequences
-- The function is defined as SECURITY DEFINER so that emaj_adm role can use.
  DECLARE
    v_pgVersion       TEXT := emaj._pg_version();
    v_nbTb            INT := 0;
    r_tblsq           RECORD;
    v_realFirstMark   TEXT;
    v_realLastMark    TEXT;
    v_firstMarkId     BIGINT;
    v_lastMarkId      BIGINT;
    v_firstEmajGid    BIGINT;
    v_lastEmajGid     BIGINT;
    v_tsFirstMark     TIMESTAMPTZ;
    v_tsLastMark      TIMESTAMPTZ;
    v_logTableName    TEXT;
    v_fileName        TEXT;
    v_stmt            TEXT;
    v_timestamp       TIMESTAMPTZ;
    v_pseudoMark      TEXT;
    v_fullSeqName     TEXT;
  BEGIN
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SNAP_LOG_GROUP', 'BEGIN', v_groupName,
       CASE WHEN v_firstMark IS NULL OR v_firstMark = '' THEN 'From initial mark' ELSE 'From mark ' || v_firstMark END ||
       CASE WHEN v_lastMark IS NULL OR v_lastMark = '' THEN ' to current situation' ELSE ' to mark ' || v_lastMark END || ' towards '
       || v_dir);
-- check that the group is recorded in emaj_group table
    PERFORM 0 FROM emaj.emaj_group WHERE group_name = v_groupName;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_snap_log_group: group % has not been created.', v_groupName;
    END IF;
-- check the copy options parameter doesn't contain unquoted ; that could be used for sql injection
    IF regexp_replace(v_copyOptions,'''.*''','') LIKE '%;%'  THEN
      RAISE EXCEPTION 'emaj_snap_log_group: invalid COPY options parameter format';
    END IF;
-- catch the global sequence value and the timestamp of the first mark
    IF v_firstMark IS NOT NULL AND v_firstMark <> '' THEN
-- check and retrieve the global sequence value and the timestamp of the start mark for the group
      SELECT emaj._get_mark_name(v_groupName,v_firstMark) INTO v_realFirstMark;
      IF v_realFirstMark IS NULL THEN
          RAISE EXCEPTION 'emaj_snap_log_group: Start mark % is unknown for group %.', v_firstMark, v_groupName;
      END IF;
      SELECT mark_id, mark_global_seq, mark_datetime INTO v_firstMarkId, v_firstEmajGid, v_tsFirstMark
        FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realFirstMark;
    ELSE
      SELECT mark_name, mark_id, mark_global_seq, mark_datetime INTO v_realFirstMark, v_firstMarkId, v_firstEmajGid, v_tsFirstMark
        FROM emaj.emaj_mark WHERE mark_group = v_groupName ORDER BY mark_id LIMIT 1;
    END IF;
-- catch the global sequence value and timestamp of the last mark
    IF v_lastMark IS NOT NULL AND v_lastMark <> '' THEN
-- else, check and retrieve the global sequence value and the timestamp of the end mark for the group
      SELECT emaj._get_mark_name(v_groupName,v_lastMark) INTO v_realLastMark;
      IF v_realLastMark IS NULL THEN
        RAISE EXCEPTION 'emaj_snap_log_group: End mark % is unknown for group %.', v_lastMark, v_groupName;
      END IF;
      SELECT mark_id, mark_global_seq, mark_datetime INTO v_lastMarkId, v_lastEmajGid, v_tsLastMark
        FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realLastMark;
    ELSE
      v_lastMarkId = NULL;
      v_lastEmajGid = NULL;
      v_tsLastMark = NULL;
    END IF;
-- check that the first_mark < end_mark
    IF v_lastMarkId IS NOT NULL AND v_firstMarkId > v_lastMarkId THEN
      RAISE EXCEPTION 'emaj_snap_log_group: mark id for % (% = %) is greater than mark id for % (% = %).', v_realFirstMark, v_firstMarkId, v_tsFirstMark, v_realLastMark, v_lastMarkId, v_tsLastMark;
    END IF;
-- check the supplied directory is not null
    IF v_dir IS NULL THEN
      RAISE EXCEPTION 'emaj_snap_log_group: directory parameter cannot be NULL';
    END IF;
-- process all log tables of the emaj_relation table
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, rel_log_schema, rel_kind FROM emaj.emaj_relation
          WHERE rel_group = v_groupName ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
      IF r_tblsq.rel_kind = 'r' THEN
-- process tables
--   build names
        v_fileName     := v_dir || '/' || r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_log.snap';
        v_logTableName := quote_ident(r_tblsq.rel_log_schema) || '.' || quote_ident(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_log');
--   prepare the COPY statement
        v_stmt= 'COPY (SELECT * FROM ' || v_logTableName || ' WHERE TRUE';
        IF v_firstMark IS NOT NULL AND v_firstMark <> '' THEN
          v_stmt = v_stmt || ' AND emaj_gid > '|| v_firstEmajGid;
        END IF;
        IF v_lastMark IS NOT NULL AND v_lastMark <> '' THEN
          v_stmt = v_stmt || ' AND emaj_gid <= '|| v_lastEmajGid;
        END IF;
        v_stmt = v_stmt || ' ORDER BY emaj_gid ASC) TO ' || quote_literal(v_fileName) || ' '
                        || coalesce (v_copyOptions, '');
-- and finaly perform the COPY
        EXECUTE v_stmt;
      END IF;
-- for sequences, just adjust the counter
      v_nbTb = v_nbTb + 1;
    END LOOP;
-- generate the file for sequences state at start mark
    v_fileName := v_dir || '/' || v_groupName || '_sequences_at_' || v_realFirstMark;
    v_stmt= 'COPY (SELECT emaj_sequence.*' ||
            ' FROM emaj.emaj_sequence, emaj.emaj_relation' ||
            ' WHERE sequ_mark = ' || quote_literal(v_realFirstMark) || ' AND ' ||
            ' rel_kind = ''S'' AND rel_group = ' || quote_literal(v_groupName) || ' AND' ||
            ' sequ_schema = rel_schema AND sequ_name = rel_tblseq' ||
            ' ORDER BY sequ_schema, sequ_name) TO ' || quote_literal(v_fileName) || ' ' ||
            coalesce (v_copyOptions, '');
    EXECUTE v_stmt;
    IF v_lastMark IS NOT NULL AND v_lastMark <> '' THEN
-- generate the file for sequences state at end mark, if specified
      v_fileName := v_dir || '/' || v_groupName || '_sequences_at_' || v_realLastMark;
      v_stmt= 'COPY (SELECT emaj_sequence.*' ||
              ' FROM emaj.emaj_sequence, emaj.emaj_relation' ||
              ' WHERE sequ_mark = ' || quote_literal(v_realLastMark) || ' AND ' ||
              ' rel_kind = ''S'' AND rel_group = ' || quote_literal(v_groupName) || ' AND' ||
              ' sequ_schema = rel_schema AND sequ_name = rel_tblseq' ||
              ' ORDER BY sequ_schema, sequ_name) TO ' || quote_literal(v_fileName) || ' ' ||
              coalesce (v_copyOptions, '');
      EXECUTE v_stmt;
    ELSE
-- generate the file for sequences in their current state, if no end_mark is specified,
--   by using emaj_sequence table to create temporary rows as if a mark had been set
-- look at the clock to get the 'official' timestamp representing this point in time
--   and build a pseudo mark name with it
      v_timestamp = clock_timestamp();
      v_pseudoMark = to_char(v_timestamp,'HH24.MI.SS.MS');
-- for each sequence of the groups, ...
      FOR r_tblsq IN
          SELECT rel_priority, rel_schema, rel_tblseq FROM emaj.emaj_relation
            WHERE rel_group = v_groupName AND rel_kind = 'S' ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
-- ... temporary record the sequence parameters in the emaj sequence table
        v_fullSeqName := quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
        v_stmt = 'INSERT INTO emaj.emaj_sequence (' ||
                 'sequ_schema, sequ_name, sequ_datetime, sequ_mark, sequ_last_val, sequ_start_val, ' ||
                 'sequ_increment, sequ_max_val, sequ_min_val, sequ_cache_val, sequ_is_cycled, sequ_is_called ' ||
                 ') SELECT ' || quote_literal(r_tblsq.rel_schema) || ', ' ||
                 quote_literal(r_tblsq.rel_tblseq) || ', ' || quote_literal(v_timestamp) ||
                 ', ' || quote_literal(v_pseudoMark) || ', last_value, ';
        IF v_pgVersion <= '8.3' THEN
           v_stmt = v_stmt || '0, ';
        ELSE
           v_stmt = v_stmt || 'start_value, ';
        END IF;
        v_stmt = v_stmt ||
                 'increment_by, max_value, min_value, cache_value, is_cycled, is_called ' ||
                 'FROM ' || v_fullSeqName;
        EXECUTE v_stmt;
      END LOOP;
-- generate the file for sequences current state
      v_fileName := v_dir || '/' || v_groupName || '_sequences_at_' || to_char(v_timestamp,'HH24.MI.SS.MS');
      v_stmt= 'COPY (SELECT emaj_sequence.*' ||
              ' FROM emaj.emaj_sequence, emaj.emaj_relation' ||
              ' WHERE sequ_mark = ' || quote_literal(v_pseudoMark) || ' AND ' ||
              ' rel_kind = ''S'' AND rel_group = ' || quote_literal(v_groupName) || ' AND' ||
              ' sequ_schema = rel_schema AND sequ_name = rel_tblseq' ||
              ' ORDER BY sequ_schema, sequ_name) TO ' || quote_literal(v_fileName) || ' ' ||
              coalesce (v_copyOptions, '');
      EXECUTE v_stmt;
-- delete sequences state that have just been inserted into the emaj_sequence table.
      EXECUTE 'DELETE FROM emaj.emaj_sequence USING emaj.emaj_relation' ||
              ' WHERE sequ_mark = ' || quote_literal(v_pseudoMark) || ' AND' ||
              ' rel_kind = ''S'' AND rel_group = ' || quote_literal(v_groupName) || ' AND' ||
              ' sequ_schema = rel_schema AND sequ_name = rel_tblseq';
    END IF;
-- create the _INFO file to keep general information about the snap operation
    EXECUTE 'COPY (SELECT ' ||
            quote_literal('E-Maj log tables snap of group ' || v_groupName ||
            ' between marks ' || v_realFirstMark || ' and ' ||
            coalesce(v_realLastMark,'current state') || ' at ' || transaction_timestamp()) ||
            ') TO ' || quote_literal(v_dir || '/_INFO') || ' ' || coalesce (v_copyOptions, '');
-- insert end in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('SNAP_LOG_GROUP', 'END', v_groupName, v_nbTb || ' tables/sequences processed');
    RETURN v_nbTb;
  END;
$emaj_snap_log_group$;
COMMENT ON FUNCTION emaj.emaj_snap_log_group(TEXT,TEXT,TEXT,TEXT,TEXT) IS
$$Snaps all application tables and sequences of an E-Maj group into a given directory.$$;

CREATE OR REPLACE FUNCTION emaj.emaj_generate_sql(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT, v_location TEXT)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS
$emaj_generate_sql$
-- This function generates a SQL script representing all updates performed on a tables group between 2 marks
-- or beetween a mark and the current situation. The result is stored into an external file.
-- The function can process groups that are in IDLE state.
-- The sql statements are placed between a BEGIN TRANSACTION and a COMMIT statements.
-- The output file can be reused as input file to a psql command to replay the updates scenario. Just '\\'
-- character strings (double antislash), if any, must be replaced by '\' (single antislash) before feeding
-- the psql command.
-- Input: - tables group
--        - start mark, NULL representing the first mark
--        - end mark, NULL representing the current situation, and 'EMAJ_LAST_MARK' the last set mark for the group
--        - absolute pathname describing the file that will hold the result
-- Output: number of generated SQL statements (non counting comments and transaction management)
  DECLARE
    v_pgVersion             TEXT := emaj._pg_version();
    v_groupState            TEXT;
    v_cpt                   INT;
    v_realFirstMark         TEXT;
    v_realLastMark          TEXT;
    v_firstMarkId           BIGINT;
    v_lastMarkId            BIGINT;
    v_firstEmajGid          BIGINT;
    v_lastEmajGid           BIGINT;
    v_tsFirstMark           TIMESTAMPTZ;
    v_tsLastMark            TIMESTAMPTZ;
    v_nbSQL                 INT;
    v_nbSeq                 INT;
    v_cumNbSQL              INT;
    v_fullTableName         TEXT;
    v_logTableName          TEXT;
    v_fullSeqName           TEXT;
    v_unquotedType          TEXT[] := array['smallint','integer','bigint','numeric','decimal',
                                            'int2','int4','int8','serial','bigserial',
                                            'real','double precision','float','float4','float8','oid'];
    v_endComment            TEXT;
-- variables to hold pieces of SQL
    v_conditions            TEXT;
    v_rqInsert              TEXT;
    v_rqUpdate              TEXT;
    v_rqDelete              TEXT;
    v_rqTruncate            TEXT;
    v_valList               TEXT;
    v_setList               TEXT;
    v_pkCondList            TEXT;
    v_rqSeq                 TEXT;
-- other
    r_tblsq                 RECORD;
    r_col                   RECORD;
  BEGIN
-- this parameter should be moved in the create function clause once 8.2 will not be supported any more by E-Maj
    SET standard_conforming_strings = ON;
-- insert begin in the history
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
--      VALUES ('GENERATE_SQL', 'BEGIN', v_groupName, 'From mark ' || coalesce (v_firstMark, 'NULL') || ' to mark ' || coalesce (v_lastMark, 'NULL') || ' towards ' || v_location);
      VALUES ('GENERATE_SQL', 'BEGIN', v_groupName,
       CASE WHEN v_firstMark IS NULL OR v_firstMark = '' THEN 'From initial mark' ELSE 'From mark ' || v_firstMark END ||
       CASE WHEN v_lastMark IS NULL OR v_lastMark = '' THEN ' to current situation' ELSE ' to mark ' || v_lastMark END || ' towards '
       || v_location);
-- check postgres version is >= 8.3
--   (warning, the test is alphanumeric => to be adapted when pg 10.0 will appear!)
    IF v_pgVersion < '8.3' THEN
      RAISE EXCEPTION 'emaj_generate_sql: this function needs a PostgreSQL version 8.3+.';
    END IF;
-- check that the group is recorded in emaj_group table
    SELECT group_state INTO v_groupState
      FROM emaj.emaj_group WHERE group_name = v_groupName;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'emaj_generate_sql: group % has not been created.', v_groupName;
    END IF;
-- check all tables of the group have a pkey
    SELECT count(*) INTO v_cpt FROM pg_catalog.pg_class, pg_catalog.pg_namespace, emaj.emaj_relation
      WHERE relnamespace = pg_namespace.oid
        AND nspname = rel_schema AND relname =  rel_tblseq
        AND rel_group = v_groupName AND rel_kind = 'r'
        AND relhaspkey = false;
    IF v_cpt > 0 THEN
      RAISE EXCEPTION 'emaj_generate_sql: Tables group % contains % tables without pkey.', v_groupName, v_cpt;
    END IF;
-- if first mark is NULL or empty, retrieve the name, the global sequence value and the timestamp of the first recorded mark for the group
    IF v_firstMark IS NULL OR v_firstMark = '' THEN
      SELECT mark_id, mark_name, mark_global_seq, mark_datetime INTO v_firstMarkId, v_realFirstMark, v_firstEmajGid, v_tsFirstMark
        FROM emaj.emaj_mark WHERE mark_group = v_groupName ORDER BY mark_id LIMIT 1;
      IF NOT FOUND THEN
         RAISE EXCEPTION 'emaj_generate_sql: No initial mark can be found for group %.', v_groupName;
      END IF;
    ELSE
-- else, check and retrieve the name, the global sequence value and the timestamp of the supplied first mark for the group
      SELECT emaj._get_mark_name(v_groupName,v_firstMark) INTO v_realFirstMark;
      IF v_realFirstMark IS NULL THEN
        RAISE EXCEPTION 'emaj_generate_sql: Start mark % is unknown for group %.', v_firstMark, v_groupName;
      END IF;
      SELECT mark_id, mark_global_seq, mark_datetime INTO v_firstMarkId, v_firstEmajGid, v_tsFirstMark
        FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realFirstMark;
    END IF;
-- if last mark is NULL or empty, there is no timestamp to register
    IF v_lastMark IS NULL OR v_lastMark = '' THEN
      v_lastMarkId = NULL;
      v_lastEmajGid = NULL;
      v_tsLastMark = NULL;
    ELSE
-- else, check and retrieve the name, timestamp and last sequ_hole id of the supplied end mark for the group
      SELECT emaj._get_mark_name(v_groupName,v_lastMark) INTO v_realLastMark;
      IF v_realLastMark IS NULL THEN
        RAISE EXCEPTION 'emaj_generate_sql: End mark % is unknown for group %.', v_lastMark, v_groupName;
      END IF;
      SELECT mark_id, mark_global_seq, mark_datetime INTO v_lastMarkId, v_lastEmajGid, v_tsLastMark
        FROM emaj.emaj_mark WHERE mark_group = v_groupName AND mark_name = v_realLastMark;
    END IF;
-- check that the first_mark < end_mark
    IF v_lastMarkId IS NOT NULL AND v_firstMarkId > v_lastMarkId THEN
      RAISE EXCEPTION 'emaj_generate_sql: mark id for % (% = %) is greater than mark id for % (% = %).', v_firstMark, v_firstMarkId, v_tsFirstMark, v_lastMark, v_lastMarkId, v_tsLastMark;
    END IF;
-- test the supplied output file name by inserting a temporary line (trap NULL or bad file name)
    BEGIN
      EXECUTE 'COPY (SELECT ''-- emaj_generate_sql() function in progress - started at '
                     || statement_timestamp() || ''') TO ' || quote_literal(v_location);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE EXCEPTION 'emaj_generate_sql: file % cannot be used as script output file.', v_location;
    END;
-- create temporary table
    DROP TABLE IF EXISTS emaj_temp_script;
    CREATE TEMP TABLE emaj_temp_script (
--      scr_emaj_changed      TIMESTAMPTZ,
      scr_emaj_gid          BIGINT,              -- the emaj_gid of the corresponding log row,
                                                 --   0 for initial technical statements,
                                                 --   NULL for final technical statements
      scr_subid             INT,                 -- used to distinguish several generated sql per log row
      scr_emaj_txid         BIGINT,              -- for future use, to insert commit statement at each txid change
      scr_sql               TEXT                 -- the generated sql text
    );
-- for each application table referenced in the emaj_relation table, build SQL statements and process the related log table
    v_cumNbSQL = 0;
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq, rel_log_schema FROM emaj.emaj_relation
          WHERE rel_group = v_groupName AND rel_kind = 'r' ORDER BY rel_priority, rel_schema, rel_tblseq
        LOOP
-- process one application table
      v_fullTableName    := quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
      v_logTableName     := quote_ident(r_tblsq.rel_log_schema) || '.' || quote_ident(r_tblsq.rel_schema || '_' || r_tblsq.rel_tblseq || '_log');
-- build the restriction conditions on emaj_gid, depending on supplied mark range
      v_conditions = 'o.emaj_gid > ' || v_firstEmajGid;
      IF v_tsLastMark IS NOT NULL THEN
        v_conditions = v_conditions || ' AND o.emaj_gid <= ' || v_lastEmajGid;
      END IF;
-- retrieve from pg_attribute all columns of the application table and build :
-- - the VALUES list used in the INSERT statements
-- - the SET list used in the UPDATE statements
      v_valList = '';
      v_setList = '';
      FOR r_col IN
        SELECT attname, format_type(atttypid,atttypmod) FROM pg_catalog.pg_attribute
         WHERE attrelid = v_fullTableName ::regclass
           AND attnum > 0 AND NOT attisdropped
         ORDER BY attnum
      LOOP
-- test if the column format (up to the parenthesis) belongs to the list of formats that do not require any quotation (like numeric data types)
        IF regexp_replace (r_col.format_type,E'\\(.*$','') = ANY(v_unquotedType) THEN
-- literal for this column can remain as is
--          may be we will need to cast some column types in the future. So keep the comment for the moment...
--          v_valList = v_valList || ''' || coalesce(o.' || quote_ident(r_col.attname) || '::text,''NULL'') || ''::' || r_col.format_type || ', ';
          v_valList = v_valList || ''' || coalesce(o.' || quote_ident(r_col.attname) || '::text,''NULL'') || '', ';
--          v_setList = v_setList || quote_ident(replace(r_col.attname,'''','''''')) || ' = '' || coalesce(n.' || quote_ident(r_col.attname) || ' ::text,''NULL'') || ''::' || r_col.format_type || ', ';
          v_setList = v_setList || quote_ident(replace(r_col.attname,'''','''''')) || ' = '' || coalesce(n.' || quote_ident(r_col.attname) || ' ::text,''NULL'') || '', ';
        ELSE
-- literal for this column must be quoted
--          v_valList = v_valList || ''' || coalesce(quote_literal(o.' || quote_ident(r_col.attname) || '),''NULL'') || ''::' || r_col.format_type || ', ';
          v_valList = v_valList || ''' || coalesce(quote_literal(o.' || quote_ident(r_col.attname) || '),''NULL'') || '', ';
--          v_setList = v_setList || quote_ident(replace(r_col.attname,'''','''''')) || ' = '' || coalesce(quote_literal(n.' || quote_ident(r_col.attname) || '),''NULL'') || ''::' || r_col.format_type || ', ';
          v_setList = v_setList || quote_ident(replace(r_col.attname,'''','''''')) || ' = '' || coalesce(quote_literal(n.' || quote_ident(r_col.attname) || '),''NULL'') || '', ';
        END IF;
      END LOOP;
-- suppress the final separators
      v_valList = substring(v_valList FROM 1 FOR char_length(v_valList) - 2);
      v_setList = substring(v_setList FROM 1 FOR char_length(v_setList) - 2);
-- retrieve all columns that represents the pkey and build the "pkey equal" conditions set that will be used in UPDATE and DELETE statements
-- (taking column names in pg_attribute from the table's definition instead of index definition is mandatory
--  starting from pg9.0, joining tables with indkey instead of indexrelid)
      v_pkCondList = '';
      FOR r_col IN
        SELECT attname, format_type(atttypid,atttypmod) FROM pg_catalog.pg_attribute, pg_catalog.pg_index
          WHERE pg_attribute.attrelid = pg_index.indrelid
            AND attnum = ANY (indkey)
            AND indrelid = v_fullTableName ::regclass AND indisprimary
            AND attnum > 0 AND NOT attisdropped
      LOOP
-- test if the column format (at least up to the parenthesis) belongs to the list of formats that do not require any quotation (like numeric data types)
        IF regexp_replace (r_col.format_type,E'\\(.*$','') = ANY(v_unquotedType) THEN
-- literal for this column can remain as is
--          v_pkCondList = v_pkCondList || quote_ident(replace(r_col.attname,'''','''''')) || ' = '' || o.' || quote_ident(r_col.attname) || ' || ''::' || r_col.format_type || ' AND ';
          v_pkCondList = v_pkCondList || quote_ident(replace(r_col.attname,'''','''''')) || ' = '' || o.' || quote_ident(r_col.attname) || ' || '' AND ';
        ELSE
-- literal for this column must be quoted
--          v_pkCondList = v_pkCondList || quote_ident(replace(r_col.attname,'''','''''')) || ' = '' || quote_literal(o.' || quote_ident(r_col.attname) || ') || ''::' || r_col.format_type || ' AND ';
          v_pkCondList = v_pkCondList || quote_ident(replace(r_col.attname,'''','''''')) || ' = '' || quote_literal(o.' || quote_ident(r_col.attname) || ') || '' AND ';
        END IF;
      END LOOP;
-- suppress the final separator
      v_pkCondList = substring(v_pkCondList FROM 1 FOR char_length(v_pkCondList) - 5);
-- prepare sql skeletons for each statement type
      v_rqInsert = '''INSERT INTO ' || replace(v_fullTableName,'''','''''') || ' VALUES (' || v_valList || ');''';
      v_rqUpdate = '''UPDATE ONLY ' || replace(v_fullTableName,'''','''''') || ' SET ' || v_setList || ' WHERE ' || v_pkCondList || ';''';
      v_rqDelete = '''DELETE FROM ONLY ' || replace(v_fullTableName,'''','''''') || ' WHERE ' || v_pkCondList || ';''';
      v_rqTruncate = '''TRUNCATE ' || replace(v_fullTableName,'''','''''') || ';''';
-- now scan the log table to process all statement types at once
      EXECUTE 'INSERT INTO emaj_temp_script '
           || 'SELECT o.emaj_gid, 0, o.emaj_txid, CASE '
           ||   ' WHEN o.emaj_verb = ''INS'' THEN ' || v_rqInsert
           ||   ' WHEN o.emaj_verb = ''UPD'' AND o.emaj_tuple = ''OLD'' THEN ' || v_rqUpdate
           ||   ' WHEN o.emaj_verb = ''DEL'' THEN ' || v_rqDelete
           ||   ' WHEN o.emaj_verb = ''TRU'' THEN ' || v_rqTruncate
           || ' END '
           || ' FROM ' || v_logTableName || ' o'
           ||   ' LEFT OUTER JOIN ' || v_logTableName || ' n ON n.emaj_gid = o.emaj_gid'
           || '        AND (n.emaj_verb = ''UPD'' AND n.emaj_tuple = ''NEW'') '
           || ' WHERE NOT (o.emaj_verb = ''UPD'' AND o.emaj_tuple = ''NEW'')'
           || ' AND ' || v_conditions;
      GET DIAGNOSTICS v_nbSQL = ROW_COUNT;
      v_cumNbSQL = v_cumNbSQL + v_nbSQL;
    END LOOP;
-- process sequences
    v_nbSeq = 0;
    FOR r_tblsq IN
        SELECT rel_priority, rel_schema, rel_tblseq FROM emaj.emaj_relation
          WHERE rel_group = v_groupName AND rel_kind = 'S' ORDER BY rel_priority DESC, rel_schema DESC, rel_tblseq DESC
        LOOP
      v_fullSeqName := quote_ident(r_tblsq.rel_schema) || '.' || quote_ident(r_tblsq.rel_tblseq);
      IF v_tsLastMark IS NULL THEN
-- no supplied last mark, so get current sequence characteritics
        IF v_pgVersion <= '8.3' THEN
-- .. in pg 8.3-
          EXECUTE 'SELECT ''ALTER SEQUENCE ' || replace(v_fullSeqName,'''','''''')
               || ''' || '' RESTART '' || CASE WHEN is_called THEN last_value + increment_by ELSE last_value END || '' INCREMENT '' || increment_by  || '' MAXVALUE '' || max_value  || '' MINVALUE '' || min_value || '' CACHE '' || cache_value || CASE WHEN NOT is_cycled THEN '' NO'' ELSE '''' END || '' CYCLE;'' '
               || 'FROM ' || v_fullSeqName INTO v_rqSeq;
--raise notice '1 - sequence % -> %',v_fullSeqName,v_rqSeq;
        ELSE
-- .. in pg 8.4+
          EXECUTE 'SELECT ''ALTER SEQUENCE ' || replace(v_fullSeqName,'''','''''')
               || ''' || '' RESTART '' || CASE WHEN is_called THEN last_value + increment_by ELSE last_value END || '' START '' || start_value || '' INCREMENT '' || increment_by  || '' MAXVALUE '' || max_value  || '' MINVALUE '' || min_value || '' CACHE '' || cache_value || CASE WHEN NOT is_cycled THEN '' NO'' ELSE '''' END || '' CYCLE;'' '
               || 'FROM ' || v_fullSeqName INTO v_rqSeq;
--raise notice '2 - sequence % -> %',v_fullSeqName,v_rqSeq;
        END IF;
      ELSE
-- a last mark is supplied, so get sequence characteristics from emaj_sequence table
        IF v_pgVersion <= '8.3' THEN
-- .. in pg 8.3-
          EXECUTE 'SELECT ''ALTER SEQUENCE ' || replace(v_fullSeqName,'''','''''')
               || ''' || '' RESTART '' || CASE WHEN sequ_is_called THEN sequ_last_val + sequ_increment ELSE sequ_last_val END || '' INCREMENT '' || sequ_increment  || '' MAXVALUE '' || sequ_max_val  || '' MINVALUE '' || sequ_min_val || '' CACHE '' || sequ_cache_val || CASE WHEN NOT sequ_is_cycled THEN '' NO'' ELSE '''' END || '' CYCLE;'' '
               || 'FROM emaj.emaj_sequence '
               || 'WHERE sequ_schema = ' || quote_literal(r_tblsq.rel_schema)
               || '  AND sequ_name = ' || quote_literal(r_tblsq.rel_tblseq)
               || '  AND sequ_datetime = ''' || v_tsLastMark || '''' INTO v_rqSeq;
--raise notice '3 - sequence % -> %',v_fullSeqName,v_rqSeq;
        ELSE
-- .. in pg 8.4+
          EXECUTE 'SELECT ''ALTER SEQUENCE ' || replace(v_fullSeqName,'''','''''')
               || ''' || '' RESTART '' || CASE WHEN sequ_is_called THEN sequ_last_val + sequ_increment ELSE sequ_last_val END || '' START '' || sequ_start_val || '' INCREMENT '' || sequ_increment  || '' MAXVALUE '' || sequ_max_val  || '' MINVALUE '' || sequ_min_val || '' CACHE '' || sequ_cache_val || CASE WHEN NOT sequ_is_cycled THEN '' NO'' ELSE '''' END || '' CYCLE;'' '
               || 'FROM emaj.emaj_sequence '
               || 'WHERE sequ_schema = ' || quote_literal(r_tblsq.rel_schema)
               || '  AND sequ_name = ' || quote_literal(r_tblsq.rel_tblseq)
               || '  AND sequ_datetime = ''' || v_tsLastMark || '''' INTO v_rqSeq;
--raise notice '4 - sequence % -> %',v_fullSeqName,v_rqSeq;
        END IF;
      END IF;
-- insert into temp table
      v_nbSeq = v_nbSeq + 1;
      EXECUTE 'INSERT INTO emaj_temp_script '
           || 'SELECT NULL, -1 * ' || v_nbSeq || ', txid_current(), ' || quote_literal(v_rqSeq);
    END LOOP;
-- add an initial comment
    IF v_tsLastMark IS NOT NULL THEN
      v_endComment = ' and mark ' || v_realLastMark;
    ELSE
      v_endComment = ' and the current situation';
    END IF;
    INSERT INTO emaj_temp_script SELECT 0, 1, 0,
         '-- file generated at ' || statement_timestamp()
      || ' by the emaj_generate_sql() function, for tables group ' || v_groupName
      || ', processing logs between mark ' || v_realFirstMark || v_endComment;
-- encapsulate the sql statements inside a TRANSACTION
-- and manage the standard_conforming_strings option to properly handle special characters
    INSERT INTO emaj_temp_script SELECT 0, 2, 0, 'SET standard_conforming_strings = ON;';
    INSERT INTO emaj_temp_script SELECT 0, 3, 0, 'BEGIN TRANSACTION;';
    INSERT INTO emaj_temp_script SELECT NULL, 1, txid_current(), 'COMMIT;';
    INSERT INTO emaj_temp_script SELECT NULL, 2, txid_current(), 'RESET standard_conforming_strings;';
-- write the SQL script on the external file
    EXECUTE 'COPY (SELECT scr_sql FROM emaj_temp_script ORDER BY scr_emaj_gid NULLS LAST, scr_subid ) TO ' || quote_literal(v_location);
-- drop temporary table ?
--    DROP TABLE IF EXISTS emaj_temp_script;
-- this line should be removed once 8.2 will not be supported any more by E-Maj (and the SET will be put as create function clause
    RESET standard_conforming_strings;
-- insert end in the history and return
    v_cumNbSQL = v_cumNbSQL + v_nbSeq;
    INSERT INTO emaj.emaj_hist (hist_function, hist_event, hist_object, hist_wording)
      VALUES ('GENERATE_SQL', 'END', v_groupName, v_cumNbSQL || ' generated statements');
    RETURN v_cumNbSQL;
  END;
$emaj_generate_sql$;
COMMENT ON FUNCTION emaj.emaj_generate_sql(v_groupName TEXT, v_firstMark TEXT, v_lastMark TEXT, v_location TEXT) IS
$$Generates a sql script corresponding to all updates performed on a tables group between two marks and stores it into a given file.$$;

CREATE OR REPLACE FUNCTION emaj._verify_all_groups()
RETURNS SETOF TEXT LANGUAGE plpgsql AS
$_verify_all_groups$
-- The function verifies the consistency of all E-Maj groups.
-- It returns a set of warning messages for discovered discrepancies. If no error is detected, no row is returned.
  DECLARE
    v_pgVersion      TEXT := emaj._pg_version();
    v_emajSchema     TEXT := 'emaj';
    r_object         RECORD;
  BEGIN
-- check the postgres version at creation time is compatible with the current version
-- Warning: comparisons on version numbers are alphanumeric.
--          But we suppose these tests will not be useful any more when pg 10.0 will appear!
--   for 8.2 and 8.3, both major versions must be the same
    FOR r_object IN
      SELECT 'The group "' || group_name || '" has been created with a non compatible postgresql version (' ||
               group_pg_version || '). It must be dropped and recreated.' AS msg
        FROM emaj.emaj_group
        WHERE ((v_pgVersion = '8.2' OR v_pgVersion = '8.3') 
               AND substring (group_pg_version FROM E'(\\d+\\.\\d+)') <> v_pgVersion) OR
--   for 8.4+, both major versions must be 8.4+
              (v_pgVersion >= '8.4' AND substring (group_pg_version FROM E'(\\d+\\.\\d+)') < '8.4')
        ORDER BY msg
    LOOP
      RETURN NEXT r_object.msg;
    END LOOP;
-- check all application schemas referenced in the emaj_relation table still exist
    FOR r_object IN
      SELECT 'The application schema "' || rel_schema || '" does not exist any more.' AS msg
        FROM (
          SELECT DISTINCT rel_schema FROM emaj.emaj_relation 
            EXCEPT
          SELECT nspname FROM pg_catalog.pg_namespace
             ) AS t
        ORDER BY msg
    LOOP
      RETURN NEXT r_object.msg;
    END LOOP;
-- check all application relations referenced in the emaj_relation table still exist
    FOR r_object IN
      SELECT t.rel_schema, t.rel_tblseq, 
             'In group "' || r.rel_group || '", the ' ||
               CASE WHEN t.rel_kind = 'r' THEN 'table "' ELSE 'sequence "' END || 
               t.rel_schema || '"."' || t.rel_tblseq || '" does not exist any more.' AS msg
        FROM (                                        -- all expected application relations
          SELECT rel_schema, rel_tblseq, rel_kind FROM emaj.emaj_relation
            EXCEPT                                    -- minus relations known by postgres
          SELECT nspname, relname, relkind FROM pg_catalog.pg_class, pg_catalog.pg_namespace 
            WHERE relnamespace = pg_namespace.oid AND relkind IN ('r','S')
             ) AS t, emaj.emaj_relation r             -- join with emaj_relation to get the group name
        WHERE t.rel_schema = r.rel_schema AND t.rel_tblseq = r.rel_tblseq
        ORDER BY 1,2,3
    LOOP
      RETURN NEXT r_object.msg;
    END LOOP;
-- check the log table for all tables referenced in the emaj_relation table still exist
    FOR r_object IN
      SELECT rel_schema, rel_tblseq,
             'In group "' || rel_group || '", the log table "' || 
               rel_log_schema || '"."' || rel_schema || '_' || rel_tblseq || '_log" is not found.' AS msg
        FROM emaj.emaj_relation
        WHERE rel_kind = 'r'
          AND (rel_log_schema, rel_schema || '_' || rel_tblseq || '_log') NOT IN
              (SELECT nspname, relname FROM pg_catalog.pg_namespace, pg_catalog.pg_class
                 WHERE relnamespace = pg_namespace.oid AND relname LIKE E'%\_%\_log')
        ORDER BY 1,2,3
    LOOP
      RETURN NEXT r_object.msg;
    END LOOP;
-- check log and rollback functions for all tables referenced in the emaj_relation table still exist
    FOR r_object IN                                   -- schema and table names are rebuilt from the returned function name
      SELECT substring(fnct FROM '^(.*)_.*_.*_fnct') AS sch, substring(fnct FROM '^.*_(.*)_.*_fnct') AS tbl,
             'In group "' || r.rel_group || '", the ' || 
               CASE WHEN substring(fnct FROM '^.*_.*_(.*)_fnct') = 'log' THEN 'log' ELSE 'rollback' END || 
               ' function "' || t.rel_log_schema || '"."' || fnct || '" is not found.' AS msg
        FROM (                                        -- all expected log functions
         (SELECT rel_log_schema, rel_schema || '_' || rel_tblseq || '_log_fnct' AS fnct 
            FROM emaj.emaj_relation 
            WHERE rel_kind = 'r'
          UNION ALL                                   -- plus all expected rollback functions
          SELECT rel_log_schema, rel_schema || '_' || rel_tblseq || '_rlbk_fnct' AS fnct 
            FROM emaj.emaj_relation, emaj.emaj_group
            WHERE rel_group = group_name AND rel_kind = 'r' AND group_is_rollbackable
         ) EXCEPT                                     -- minus functions known by postgres
         SELECT nspname, proname FROM pg_catalog.pg_proc, pg_catalog.pg_namespace
           WHERE pronamespace = pg_namespace.oid AND proname LIKE E'%\_%\_%\_fnct'
             ) AS t, emaj.emaj_relation r             -- join with emaj_relation to get the group name 
        WHERE r.rel_schema = substring(fnct FROM '^(.*)_.*_.*_fnct') AND r.rel_tblseq = substring(fnct FROM '^.*_(.*)_.*_fnct')
        ORDER BY 1,2,3
    LOOP
      RETURN NEXT r_object.msg;
    END LOOP;
-- check log and truncate triggers for all tables referenced in the emaj_relation table still exist
--   start with log trigger
    FOR r_object IN
      SELECT rel_schema, rel_tblseq,
             'In group "' || rel_group || '", the log trigger "' || 
               rel_schema || '_' || rel_tblseq || '_emaj_log_trg" is not found.' AS msg
        FROM emaj.emaj_relation
        WHERE rel_kind = 'r'
          AND (rel_schema, rel_tblseq, rel_schema || '_' || rel_tblseq || '_emaj_log_trg') NOT IN
              (SELECT nspname, relname, tgname 
                 FROM pg_catalog.pg_trigger, pg_catalog.pg_namespace, pg_catalog.pg_class
                 WHERE tgrelid = pg_class.oid AND relnamespace = pg_namespace.oid 
                   AND tgname LIKE E'%\_%\_emaj\_log\_trg')
                         -- do not issue a row if the application table does not exist, 
                         -- this case has been already detected
          AND (rel_schema, rel_tblseq) IN
              (SELECT nspname, relname FROM pg_catalog.pg_class, pg_catalog.pg_namespace
                 WHERE relnamespace = pg_namespace.oid)
        ORDER BY 1,2,3
    LOOP
      RETURN NEXT r_object.msg;
    END LOOP;
--   then truncate trigger if pg 8.4+
    IF v_pgVersion >= '8.4' THEN
      FOR r_object IN
        SELECT rel_schema, rel_tblseq,
               'In group "' || rel_group || '", the truncate trigger "' || 
                 rel_schema || '_' || rel_tblseq || '_emaj_trunc_trg" is not found.' AS msg
          FROM emaj.emaj_relation
          WHERE rel_kind = 'r'
            AND (rel_schema, rel_tblseq, rel_schema || '_' || rel_tblseq || '_emaj_trunc_trg') NOT IN
                (SELECT nspname, relname, tgname 
                   FROM pg_catalog.pg_trigger, pg_catalog.pg_namespace, pg_catalog.pg_class
                   WHERE tgrelid = pg_class.oid AND relnamespace = pg_namespace.oid 
                     AND tgname LIKE E'%\_%\_emaj\_trunc\_trg')
                         -- do not issue a row if the application table does not exist, 
                         -- this case has been already detected
            AND (rel_schema, rel_tblseq) IN
                (SELECT nspname, relname FROM pg_catalog.pg_class, pg_catalog.pg_namespace
                   WHERE relnamespace = pg_namespace.oid)
          ORDER BY 1,2,3
      LOOP
        RETURN NEXT r_object.msg;
      END LOOP;
-- TODO : merge both triggers check when pg 8.3 will not be supported any more
    END IF;
-- check all log tables have a structure consistent with the application tables they reference
--      (same columns and same formats). It only returns one row per faulting table.
    FOR r_object IN
      SELECT DISTINCT rel_schema, rel_tblseq,
             'In group "' || rel_group || '", the structure of the application table "' || 
               rel_schema || '"."' || rel_tblseq || '" is not coherent with its log table ("' || 
             rel_log_schema || '"."' || rel_schema || '_' || rel_tblseq || '_log").' AS msg
        FROM (
          (                                           -- application table's columns 
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, attname, atttypid, attlen, atttypmod
            FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE relnamespace = pg_namespace.oid AND nspname = rel_schema AND relname = rel_tblseq
              AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = false
              AND rel_kind = 'r'
          EXCEPT                                      -- minus log table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, attname, atttypid, attlen, atttypmod
            FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE relnamespace = pg_namespace.oid AND nspname = rel_log_schema 
              AND relname = rel_schema || '_' || rel_tblseq || '_log'
              AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = false AND attname NOT LIKE 'emaj%'
              AND rel_kind = 'r'
          )
          UNION
          (                                           -- log table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, attname, atttypid, attlen, atttypmod
            FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE relnamespace = pg_namespace.oid AND nspname = rel_log_schema 
              AND relname = rel_schema || '_' || rel_tblseq || '_log'
              AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = false AND attname NOT LIKE 'emaj%'
              AND rel_kind = 'r'
          EXCEPT                                      --  minus application table's columns
          SELECT rel_group, rel_schema, rel_tblseq, rel_log_schema, attname, atttypid, attlen, atttypmod
            FROM emaj.emaj_relation, pg_catalog.pg_attribute, pg_catalog.pg_class, pg_catalog.pg_namespace
            WHERE relnamespace = pg_namespace.oid AND nspname = rel_schema AND relname = rel_tblseq
              AND attrelid = pg_class.oid AND attnum > 0 AND attisdropped = false
              AND rel_kind = 'r'
          )) AS t
                         -- do not issue a row if the log or application table does not exist, 
                         -- these cases have been already detected
      WHERE (rel_log_schema, rel_schema || '_' || rel_tblseq || '_log') IN
            (SELECT nspname, relname FROM pg_catalog.pg_class, pg_catalog.pg_namespace
               WHERE relnamespace = pg_namespace.oid)
        AND (rel_schema, rel_tblseq) IN
            (SELECT nspname, relname FROM pg_catalog.pg_class, pg_catalog.pg_namespace
               WHERE relnamespace = pg_namespace.oid)
      ORDER BY 1,2,3
-- TODO : use CTE to improve performance, when pg 8.3 will not be supported any more
    LOOP
      RETURN NEXT r_object.msg;
    END LOOP;
    RETURN;
  END;
$_verify_all_groups$;

CREATE OR REPLACE FUNCTION emaj._verify_all_schemas()
RETURNS SETOF TEXT LANGUAGE plpgsql AS
$_verify_all_schemas$
-- The function verifies that all E-Maj schemas only contains E-Maj objects.
-- It returns a set of warning messages for discovered discrepancies. If no error is detected, no row is returned.
  DECLARE
    v_emajSchema     TEXT := 'emaj';
    r_object         RECORD;
  BEGIN
-- verify that the expected E-Maj schemas still exist
    FOR r_object IN
      SELECT DISTINCT 'The E-Maj schema "' || rel_log_schema || '" does not exist any more.' AS msg
        FROM emaj.emaj_relation
        WHERE rel_log_schema NOT IN (SELECT nspname FROM pg_catalog.pg_namespace)
        ORDER BY msg
    LOOP
      RETURN NEXT r_object.msg;
    END LOOP;
-- detect all objects that are not directly linked to a known table groups in all E-Maj schemas
-- scan pg_class, pg_proc, pg_type, pg_conversion, pg_operator, pg_opclass
    FOR r_object IN
-- look for unexpected tables
      SELECT nspname, 1, 'In schema "' || nspname || 
             '", the table "' || nspname || '"."' || relname || '" is not linked to any created tables group.' AS msg
         FROM pg_catalog.pg_class, pg_catalog.pg_namespace
         WHERE relnamespace = pg_namespace.oid AND relkind = 'r'
           AND (nspname <> v_emajSchema OR relname NOT LIKE E'emaj\\_%')    -- exclude emaj internal tables
           AND (nspname, relname) NOT IN                                    -- exclude emaj log tables
              (SELECT rel_log_schema, rel_schema || '_' || rel_tblseq || '_log' FROM emaj.emaj_relation)
           AND nspname IN (SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation)
      UNION ALL
-- look for unexpected sequences
      SELECT nspname, 2, 'In schema "' || nspname || 
             '", the sequence "' || nspname || '"."' || relname || '" is not linked to any created tables group.' AS msg
         FROM pg_catalog.pg_class, pg_catalog.pg_namespace
         WHERE relnamespace = pg_namespace.oid AND relkind = 'S'
           AND (nspname <> v_emajSchema OR relname NOT LIKE E'emaj\\_%')    -- exclude emaj internal sequences
           AND (nspname, relname) NOT IN                                    -- exclude emaj log table sequences 
              (SELECT rel_log_schema, emaj._build_log_seq_name(rel_schema, rel_tblseq) FROM emaj.emaj_relation)
           AND nspname IN (SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation)
      UNION ALL
-- look for unexpected functions
      SELECT nspname, 3, 'In schema "' || nspname || 
             '", the function "' || nspname || '"."' || proname  || '" is not linked to any created tables group.' AS msg
         FROM pg_catalog.pg_proc, pg_catalog.pg_namespace
         WHERE pronamespace = pg_namespace.oid 
           AND (nspname <> v_emajSchema OR (proname NOT LIKE E'emaj\\_%' AND proname NOT LIKE E'\\_%'))
                                                                            -- exclude emaj internal functions
           AND (nspname, proname) NOT IN (                                  -- exclude emaj log functions
             SELECT rel_log_schema, rel_schema || '_' || rel_tblseq || '_log_fnct' FROM emaj.emaj_relation)
           AND (nspname, proname) NOT IN (                                  -- exclude emaj rollback functions
             SELECT rel_log_schema, rel_schema || '_' || rel_tblseq || '_rlbk_fnct' FROM emaj.emaj_relation)
           AND nspname IN (SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation)
      UNION ALL
-- look for unexpected composite types
      SELECT nspname, 4, 'In schema "' || nspname || 
             '", the type "' || nspname || '"."' || relname || '" is not an E-Maj component.' AS msg
         FROM pg_catalog.pg_class, pg_catalog.pg_namespace
         WHERE relnamespace = pg_namespace.oid AND relkind = 'c'
           AND (nspname <> v_emajSchema OR (relname NOT LIKE E'emaj\\_%' AND relname NOT LIKE E'\\_%'))
                                                                            -- exclude emaj internal types
           AND nspname IN (SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation)
      UNION ALL
-- look for unexpected views
      SELECT nspname, 5, 'In schema "' || nspname || 
             '", the view "' || nspname || '"."' || relname || '" is not an E-Maj component.' AS msg
         FROM pg_catalog.pg_class, pg_catalog.pg_namespace
         WHERE relnamespace = pg_namespace.oid  AND relkind = 'v'
           AND nspname IN (SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation)
      UNION ALL
-- look for unexpected foreign tables
      SELECT nspname, 6, 'In schema "' || nspname || 
             '", the foreign table "' || nspname || '"."' || relname || '" is not an E-Maj component.' AS msg
         FROM pg_catalog.pg_class, pg_catalog.pg_namespace
         WHERE relnamespace = pg_namespace.oid  AND relkind = 'f'
           AND nspname IN (SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation)
      UNION ALL
-- look for unexpected domains
      SELECT nspname, 7, 'In schema "' || nspname || 
             '", the domain "' || nspname || '"."' || typname || '" is not an E-Maj component.' AS msg
         FROM pg_catalog.pg_type, pg_catalog.pg_namespace
         WHERE typnamespace = pg_namespace.oid AND typisdefined and typtype = 'd'
           AND nspname IN (SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation)
      UNION ALL
-- look for unexpected conversions
      SELECT nspname, 8, 'In schema "' || nspname || 
             '", the conversion "' || nspname || '"."' || conname || '" is not an E-Maj component.' AS msg
         FROM pg_catalog.pg_conversion, pg_catalog.pg_namespace
         WHERE connamespace = pg_namespace.oid 
           AND nspname IN (SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation)
      UNION ALL
-- look for unexpected operators
      SELECT nspname, 9, 'In schema "' || nspname || 
             '", the operator "' || nspname || '"."' || oprname || '" is not an E-Maj component.' AS msg
         FROM pg_catalog.pg_operator, pg_catalog.pg_namespace
         WHERE oprnamespace = pg_namespace.oid 
           AND nspname IN (SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation)
      UNION ALL
-- look for unexpected operator classes
      SELECT nspname, 10, 'In schema "' || nspname || 
             '", the operator class "' || nspname || '"."' || opcname || '" is not an E-Maj component.' AS msg
         FROM pg_catalog.pg_opclass, pg_catalog.pg_namespace
         WHERE opcnamespace = pg_namespace.oid 
           AND nspname IN (SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation)
      ORDER BY 1, 2, 3
-- Todo: when pg version 8.3- will not be supported, the following CTE could be used to minimize the number of emaj_relation scan to build the schemas list
--        WITH logschemas AS ( SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation )
--  replacing all "AND nspname IN (SELECT DISTINCT rel_log_schema FROM emaj.emaj_relation)" conditions by
--                "AND nspname IN (SELECT rel_log_schema FROM logschemas)"
    LOOP
      RETURN NEXT r_object.msg;
    END LOOP;
    RETURN;
  END;
$_verify_all_schemas$;

CREATE OR REPLACE FUNCTION emaj.emaj_verify_all()
RETURNS SETOF TEXT LANGUAGE plpgsql AS
$emaj_verify_all$
-- The function verifies the consistency between all emaj objects present inside emaj schema and
-- emaj objects related to tables and sequences referenced in emaj_relation table.
-- It returns a set of warning messages for discovered discrepancies. If no error is detected, a single row is returned.
  DECLARE
    v_pgVersion      TEXT := emaj._pg_version();
    v_errorFound     BOOLEAN = FALSE;
    r_object         RECORD;
  BEGIN
-- Global checks
-- detect if the current postgres version is at least 8.1
    IF v_pgVersion < '8.2' THEN
      RETURN NEXT 'The current postgres version (' || version() || ') is not compatible with E-Maj.';
      v_errorFound = TRUE;
    END IF;
-- check all E-Maj primary and secondary schemas
    FOR r_object IN
      SELECT msg FROM emaj._verify_all_schemas() msg
    LOOP
      RETURN NEXT r_object.msg;
      v_errorFound = TRUE;
    END LOOP;
-- check all groups components
    FOR r_object IN
      SELECT msg FROM emaj._verify_all_groups() msg
    LOOP
      RETURN NEXT r_object.msg;
      v_errorFound = TRUE;
    END LOOP;
-- final message if no error has been yet detected
    IF NOT v_errorFound THEN
      RETURN NEXT 'No error detected';
    END IF;
    RETURN;
  END;
$emaj_verify_all$;
COMMENT ON FUNCTION emaj.emaj_verify_all() IS
$$Verifies the consistency between existing E-Maj and application objects.$$;

-- Set comments for all internal functions,
-- by directly inserting a row in the pg_description table for all emaj functions that do not have yet a recorded comment
INSERT INTO pg_catalog.pg_description (objoid, classoid, objsubid, description)
  SELECT pg_proc.oid, pg_class.oid, 0 , 'E-Maj internal function'
    FROM pg_catalog.pg_proc, pg_catalog.pg_class
    WHERE pg_class.relname = 'pg_proc'
      AND pg_proc.oid IN               -- list all emaj functions that do not have yet a comment in pg_description
       (SELECT pg_proc.oid
          FROM pg_catalog.pg_proc
               JOIN pg_catalog.pg_namespace ON (pronamespace=pg_namespace.oid)
               LEFT OUTER JOIN pg_catalog.pg_description ON (pg_description.objoid = pg_proc.oid
                                     AND classoid = (SELECT oid FROM pg_catalog.pg_class WHERE relname = 'pg_proc')
                                     AND objsubid = 0)
          WHERE nspname = 'emaj' AND (proname LIKE E'emaj\\_%' OR proname LIKE E'\\_%')
            AND pg_description.description IS NULL
       );

------------------------------------
--                                --
-- emaj roles and rights          --
--                                --
------------------------------------
-- grants on tables and sequences

GRANT SELECT,INSERT,UPDATE,DELETE ON emaj.emaj_group_def TO emaj_adm;
GRANT SELECT,INSERT,UPDATE,DELETE ON emaj.emaj_group TO emaj_adm;
GRANT SELECT,INSERT,UPDATE,DELETE ON emaj.emaj_relation TO emaj_adm;

GRANT SELECT ON emaj.emaj_group_def TO emaj_viewer;
GRANT SELECT ON emaj.emaj_group TO emaj_viewer;
GRANT SELECT ON emaj.emaj_relation TO emaj_viewer;

GRANT SELECT ON SEQUENCE emaj.emaj_hist_hist_id_seq TO emaj_viewer;
GRANT SELECT ON SEQUENCE emaj.emaj_mark_mark_id_seq TO emaj_viewer;
GRANT SELECT ON SEQUENCE emaj.emaj_seq_hole_sqhl_id_seq TO emaj_viewer;
GRANT SELECT ON SEQUENCE emaj.emaj_sequence_sequ_id_seq TO emaj_viewer;

-- revoke grants on all functions from PUBLIC
REVOKE ALL ON FUNCTION emaj._create_log_schema(v_logSchemaName TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj._drop_log_schema(v_logSchemaName TEXT, v_isForced BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj._create_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_logDatTsp TEXT, v_logIdxTsp TEXT, v_isRollbackable BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj._drop_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_isRollbackable BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj._create_seq(v_schemaName TEXT, v_seqName TEXT, v_groupName TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj._rlbk_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_lastGlobalSeq BIGINT, v_timestamp TIMESTAMPTZ, v_deleteLog BOOLEAN, v_lastSequenceId BIGINT, v_lastSeqHoleId BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj._log_stat_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_tsFirstMark TIMESTAMPTZ, v_tsLastMark TIMESTAMPTZ, v_firstLastSeqHoleId BIGINT, v_lastLastSeqHoleId BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj._verify_groups(v_groupNames TEXT[], v_onErrorStop boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj._drop_group(v_groupName TEXT, v_isForced BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj.emaj_alter_group(v_groupName TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj.emaj_stop_group(v_groupName TEXT, v_mark TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj.emaj_stop_groups(v_groupNames TEXT[], v_mark TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj.emaj_force_stop_group(v_groupName TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj._stop_groups(v_groupNames TEXT[], v_mark TEXT, v_multiGroup BOOLEAN, v_isForced BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj.emaj_get_previous_mark_group(v_groupName TEXT, v_mark TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj._reset_group(v_groupName TEXT) FROM PUBLIC; 
REVOKE ALL ON FUNCTION emaj._verify_all_groups() FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj._verify_all_schemas() FROM PUBLIC;
REVOKE ALL ON FUNCTION emaj.emaj_verify_all() FROM PUBLIC;

-- give appropriate rights on functions to emaj_adm role
GRANT EXECUTE ON FUNCTION emaj._create_log_schema(v_logSchemaName TEXT) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._drop_log_schema(v_logSchemaName TEXT, v_isForced BOOLEAN) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._create_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_logDatTsp TEXT, v_logIdxTsp TEXT, v_isRollbackable BOOLEAN) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._drop_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_isRollbackable BOOLEAN) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._create_seq(v_schemaName TEXT, v_seqName TEXT, v_groupName TEXT) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._rlbk_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_lastGlobalSeq BIGINT, v_timestamp TIMESTAMPTZ, v_deleteLog BOOLEAN, v_lastSequenceId BIGINT, v_lastSeqHoleId BIGINT) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._log_stat_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_tsFirstMark TIMESTAMPTZ, v_tsLastMark TIMESTAMPTZ, v_firstLastSeqHoleId BIGINT, v_lastLastSeqHoleId BIGINT) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._verify_groups(v_groupNames TEXT[], v_onErrorStop boolean) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._drop_group(v_groupName TEXT, v_isForced BOOLEAN) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj.emaj_alter_group(v_groupName TEXT) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj.emaj_stop_group(v_groupName TEXT, v_mark TEXT) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj.emaj_stop_groups(v_groupNames TEXT[], v_mark TEXT) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj.emaj_force_stop_group(v_groupName TEXT) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._stop_groups(v_groupNames TEXT[], v_mark TEXT, v_multiGroup BOOLEAN, v_isForced BOOLEAN) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj.emaj_get_previous_mark_group(v_groupName TEXT, v_mark TEXT) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._reset_group(v_groupName TEXT) TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._verify_all_groups() TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj._verify_all_schemas() TO emaj_adm;
GRANT EXECUTE ON FUNCTION emaj.emaj_verify_all() TO emaj_adm;

-- give appropriate rights on functions to emaj_viewer role
GRANT EXECUTE ON FUNCTION emaj._log_stat_tbl(v_schemaName TEXT, v_tableName TEXT, v_logSchema TEXT, v_tsFirstMark TIMESTAMPTZ, v_tsLastMark TIMESTAMPTZ, v_firstLastSeqHoleId BIGINT, v_lastLastSeqHoleId BIGINT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._verify_groups(v_groupNames TEXT[], v_onErrorStop boolean) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_get_previous_mark_group(v_groupName TEXT, v_mark TEXT) TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._verify_all_groups() TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj._verify_all_schemas() TO emaj_viewer;
GRANT EXECUTE ON FUNCTION emaj.emaj_verify_all() TO emaj_viewer;

------------------------------------
--                                --
-- Rebuild rollback functions     --
--                                --
------------------------------------

CREATE OR REPLACE FUNCTION emaj.tmp() 
RETURNS VOID LANGUAGE plpgsql AS
$tmp$
  DECLARE
-- variables for the name of tables, functions, triggers,...
    v_fullTableName         TEXT;
    v_logTableName          TEXT;
    v_rlbkFnctName          TEXT;
    v_exceptionRlbkFnctName TEXT;
-- variables to hold pieces of SQL
    v_pkCondList            TEXT;
    v_colList               TEXT;
    v_valList               TEXT;
    v_setList               TEXT;
-- other variables
    v_attname               TEXT;
    r_table                 RECORD;
-- cursor to retrieve all columns of the application table
    col1_curs CURSOR (tbl regclass) FOR
      SELECT attname FROM pg_catalog.pg_attribute
        WHERE attrelid = tbl
          AND attnum > 0
          AND attisdropped = false
      ORDER BY attnum;
-- cursor to retrieve all columns of table's primary key
-- (taking column names in pg_attribute from the table's definition instead of index definition is mandatory
--  starting from pg9.0, joining tables with indkey instead of indexrelid)
    col2_curs CURSOR (tbl regclass) FOR
      SELECT attname FROM pg_catalog.pg_attribute, pg_catalog.pg_index
        WHERE pg_attribute.attrelid = pg_index.indrelid
          AND attnum = ANY (indkey)
          AND indrelid = tbl AND indisprimary
          AND attnum > 0 AND attisdropped = false;
  BEGIN
-- For each application table known in emaj_relation and linked to a rollbackable group
    FOR r_table IN
      SELECT rel_schema, rel_tblseq, rel_log_schema
        FROM emaj.emaj_relation, emaj.emaj_group
        WHERE rel_group = group_name AND rel_kind = 'r' AND group_is_rollbackable
    LOOP
-- build the different name for table, trigger, functions,...
      v_fullTableName    := quote_ident(r_table.rel_schema) || '.' || quote_ident(r_table.rel_tblSeq);
      v_logTableName     := quote_ident(r_table.rel_log_schema) || '.' || quote_ident(r_table.rel_schema || '_' || r_table.rel_tblSeq || '_log');
      v_rlbkFnctName     := quote_ident(r_table.rel_log_schema) || '.' || quote_ident(r_table.rel_schema || '_' || r_table.rel_tblSeq || '_rlbk_fnct');
      v_exceptionRlbkFnctName=substring(quote_literal(v_rlbkFnctName) FROM '^(.*).$');   -- suppress last character
-- build the different pieces of SQL
      v_colList := '';
      v_valList := '';
      v_setList := '';
      OPEN col1_curs (v_fullTableName);
      LOOP
        FETCH col1_curs INTO v_attname;
        EXIT WHEN NOT FOUND;
        IF v_colList = '' THEN
           v_colList := quote_ident(v_attname);
           v_valList := 'rec_log.' || quote_ident(v_attname);
           v_setList := quote_ident(v_attname) || ' = rec_old_log.' || quote_ident(v_attname);
        ELSE
           v_colList := v_colList || ', ' || quote_ident(v_attname);
           v_valList := v_valList || ', rec_log.' || quote_ident(v_attname);
           v_setList := v_setList || ', ' || quote_ident(v_attname) || ' = rec_old_log.' || quote_ident(v_attname);
        END IF;
      END LOOP;
      CLOSE col1_curs;
--   build "equality on the primary key" conditions, from the list of the primary key's columns
      v_pkCondList := '';
      OPEN col2_curs (v_fullTableName);
      LOOP
        FETCH col2_curs INTO v_attname;
        EXIT WHEN NOT FOUND;
        IF v_pkCondList = '' THEN
           v_pkCondList := quote_ident(v_attname) || ' = rec_log.' || quote_ident(v_attname);
        ELSE
           v_pkCondList := v_pkCondList || ' AND ' || quote_ident(v_attname) || ' = rec_log.' || quote_ident(v_attname);
        END IF;
      END LOOP;
      CLOSE col2_curs;
-- Then recreate the rollback function associated to the table
      EXECUTE 'CREATE OR REPLACE FUNCTION ' || v_rlbkFnctName || ' (v_lastGlobalSeq BIGINT)'
           || ' RETURNS BIGINT AS $rlbkfnct$'
           || '  DECLARE'
           || '    v_nb_rows       BIGINT := 0;'
           || '    v_nb_proc_rows  INTEGER;'
           || '    rec_log     ' || v_logTableName || '%ROWTYPE;'
           || '    rec_old_log ' || v_logTableName || '%ROWTYPE;'
           || '    log_curs CURSOR FOR '
           || '      SELECT * FROM ' || v_logTableName
           || '        WHERE emaj_gid > v_lastGlobalSeq '
           || '        ORDER BY emaj_gid DESC, emaj_tuple;'
           || '  BEGIN'
           || '    OPEN log_curs;'
           || '    LOOP '
           || '      FETCH log_curs INTO rec_log;'
           || '      EXIT WHEN NOT FOUND;'
           || '      IF rec_log.emaj_verb = ''INS'' THEN'
           || '          DELETE FROM ONLY ' || v_fullTableName || ' WHERE ' || v_pkCondList || ';'
           || '      ELSIF rec_log.emaj_verb = ''UPD'' THEN'
           || '          FETCH log_curs into rec_old_log;'
           || '          UPDATE ONLY ' || v_fullTableName || ' SET ' || v_setList || ' WHERE ' || v_pkCondList || ';'
           || '      ELSIF rec_log.emaj_verb = ''DEL'' THEN'
           || '          INSERT INTO ' || v_fullTableName || ' (' || v_colList || ') VALUES (' || v_valList || ');'
           || '      ELSE'
           || '          RAISE EXCEPTION ' || v_exceptionRlbkFnctName || ': internal error - emaj_verb = % is unknown, emaj_gid = %.'','
           || '            rec_log.emaj_verb, rec_log.emaj_gid;'
           || '      END IF;'
           || '      GET DIAGNOSTICS v_nb_proc_rows = ROW_COUNT;'
           || '      IF v_nb_proc_rows <> 1 THEN'
           || '        RAISE EXCEPTION ' || v_exceptionRlbkFnctName || ': internal error - emaj_verb = %, emaj_gid = %, # processed rows = % .'''
           || '           ,rec_log.emaj_verb, rec_log.emaj_gid, v_nb_proc_rows;'
           || '      END IF;'
           || '      v_nb_rows := v_nb_rows + 1;'
           || '    END LOOP;'
           || '    CLOSE log_curs;'
           || '    RETURN v_nb_rows;'
           || '  END;'
           || '$rlbkfnct$ LANGUAGE plpgsql;';
      END LOOP;
    RETURN;
  END;
$tmp$;
SELECT emaj.tmp();
DROP FUNCTION emaj.tmp();

------------------------------------
--                                --
-- commit upgrade                 --
--                                --
------------------------------------

UPDATE emaj.emaj_param SET param_value_text = '1.0.0' WHERE param_key = 'emaj_version';

-- and insert the init record in the operation history
INSERT INTO emaj.emaj_hist (hist_function, hist_object, hist_wording) VALUES ('EMAJ_INSTALL','E-Maj 1.0.0', 'Upgrade from 0.11.1 completed');

COMMIT;

SET client_min_messages TO default;
\echo '>>> E-Maj successfully upgraded to 1.0.0'

