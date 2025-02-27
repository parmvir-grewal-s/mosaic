--
-- PostgreSQL database dump
--

-- Dumped from database version 16.2
-- Dumped by pg_dump version 16.2

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: app_hidden; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA app_hidden;


--
-- Name: app_private; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA app_private;


--
-- Name: app_public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA app_public;


--
-- Name: ax_define; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ax_define;


--
-- Name: ax_utils; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ax_utils;


--
-- Name: postgraphile_watch; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA postgraphile_watch;


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: video_stream_type_enum; Type: DOMAIN; Schema: app_public; Owner: -
--

CREATE DOMAIN app_public.video_stream_type_enum AS text;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: inbox; Type: TABLE; Schema: app_hidden; Owner: -
--

CREATE TABLE app_hidden.inbox (
    id uuid NOT NULL,
    aggregate_type text NOT NULL,
    aggregate_id text NOT NULL,
    message_type text NOT NULL,
    segment text,
    concurrency text DEFAULT 'sequential'::text NOT NULL,
    payload jsonb NOT NULL,
    metadata jsonb,
    locked_until timestamp with time zone DEFAULT to_timestamp((0)::double precision) NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    processed_at timestamp with time zone,
    abandoned_at timestamp with time zone,
    started_attempts smallint DEFAULT 0 NOT NULL,
    finished_attempts smallint DEFAULT 0 NOT NULL,
    CONSTRAINT inbox_concurrency_check CHECK ((concurrency = ANY (ARRAY['sequential'::text, 'parallel'::text])))
);


--
-- Name: next_inbox_messages(integer, integer); Type: FUNCTION; Schema: app_hidden; Owner: -
--

CREATE FUNCTION app_hidden.next_inbox_messages(max_size integer, lock_ms integer) RETURNS SETOF app_hidden.inbox
    LANGUAGE plpgsql
    AS $$
DECLARE 
  loop_row app_hidden.inbox%ROWTYPE;
  message_row app_hidden.inbox%ROWTYPE;
  ids uuid[] := '{}';
BEGIN

  IF max_size < 1 THEN
    RAISE EXCEPTION 'The max_size for the next messages batch must be at least one.' using errcode = 'MAXNR';
  END IF;

  -- get (only) the oldest message of every segment but only return it if it is not locked
  FOR loop_row IN
    SELECT * FROM app_hidden.inbox m WHERE m.id in (SELECT DISTINCT ON (segment) id
      FROM app_hidden.inbox
      WHERE processed_at IS NULL AND abandoned_at IS NULL
      ORDER BY segment, created_at) order by created_at
  LOOP
    BEGIN
      EXIT WHEN cardinality(ids) >= max_size;
    
      SELECT *
        INTO message_row
        FROM app_hidden.inbox
        WHERE id = loop_row.id
        FOR NO KEY UPDATE NOWAIT;-- throw/catch error when locked
      
      IF message_row.locked_until > NOW() THEN
        CONTINUE;
      END IF;
      
      ids := array_append(ids, message_row.id);
    EXCEPTION 
      WHEN lock_not_available THEN
        CONTINUE;
      WHEN serialization_failure THEN
        CONTINUE;
    END;
  END LOOP;
  
  -- if max_size not reached: get the oldest parallelizable message independent of segment
  IF cardinality(ids) < max_size THEN
    FOR loop_row IN
      SELECT * FROM app_hidden.inbox
        WHERE concurrency = 'parallel' AND processed_at IS NULL AND abandoned_at IS NULL AND locked_until < NOW() 
          AND id NOT IN (SELECT UNNEST(ids))
        order by created_at
    LOOP
      BEGIN
        EXIT WHEN cardinality(ids) >= max_size;

        SELECT *
          INTO message_row
          FROM app_hidden.inbox
          WHERE id = loop_row.id
          FOR NO KEY UPDATE NOWAIT;-- throw/catch error when locked

        ids := array_append(ids, message_row.id);
      EXCEPTION 
        WHEN lock_not_available THEN
          CONTINUE;
        WHEN serialization_failure THEN
          CONTINUE;
      END;
    END LOOP;
  END IF;
  
  -- set a short lock value so the the workers can each process a message
  IF cardinality(ids) > 0 THEN

    RETURN QUERY 
      UPDATE app_hidden.inbox
        SET locked_until = clock_timestamp() + (lock_ms || ' milliseconds')::INTERVAL, started_attempts = started_attempts + 1
        WHERE ID = ANY(ids)
        RETURNING *;

  END IF;
END;
$$;


--
-- Name: tg__locales_inserted(); Type: FUNCTION; Schema: app_hidden; Owner: -
--

CREATE FUNCTION app_hidden.tg__locales_inserted() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NOTIFY notify_locale_inserted;
  RETURN NEW;
END;
$$;


--
-- Name: add_default_placeholder_localizations(text); Type: FUNCTION; Schema: app_private; Owner: -
--

CREATE FUNCTION app_private.add_default_placeholder_localizations(newlocale text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    tableName text;
    columnNames text[];
    columnNamesStr text;
    foreignKey text;
BEGIN
    FOR tableName IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'app_public' AND table_name LIKE '%_localizations'
    LOOP
        SELECT array_agg(column_name)
        INTO columnNames
        FROM information_schema.columns
        WHERE table_schema = 'app_public' AND table_name = tableName AND column_name != 'locale' AND column_name != 'id' AND column_name != 'is_default_locale';
        
        SELECT columnName
        INTO foreignKey
        FROM UNNEST(columnNames) AS columnName
        WHERE columnName ILIKE '%_id';

        columnNamesStr := array_to_string(columnNames, ', ');
        EXECUTE 'INSERT INTO app_public.' || tableName || ' (' || columnNamesStr || ', locale, is_default_locale) ' ||
            'SELECT ' || columnNamesStr || ', ''' || newLocale || ''', FALSE ' ||
            'FROM app_public.' || tableName || ' ' ||
            'WHERE is_default_locale = TRUE ' ||
            'ON CONFLICT (' || foreignKey || ', locale) DO NOTHING;';
    END LOOP;
END;
$$;


--
-- Name: define_localization_view(text, text, text); Type: FUNCTION; Schema: app_private; Owner: -
--

CREATE FUNCTION app_private.define_localization_view(tablename text, localizationstablename text, fkcolumn text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  localizableFieldsSelect text;
BEGIN
  SELECT 'l.' || string_agg(column_name, ', l.')
  INTO localizableFieldsSelect
  FROM information_schema.columns
  WHERE table_schema = 'app_public' AND table_name = localizationsTableName AND column_name != 'locale' AND column_name != 'id' AND column_name != 'is_default_locale' AND column_name != fkColumn;
        
  EXECUTE 'DROP VIEW IF EXISTS app_public.' || tableName || '_view CASCADE;';
  EXECUTE 'CREATE VIEW app_public.' || tableName || '_view AS ' ||
          'SELECT p.*, ' || localizableFieldsSelect || ' FROM app_public.' || localizationsTableName || ' as l ' ||
          'JOIN app_public.' || tableName || ' AS p ON l.' || fkColumn || ' = p.id ' ||
          'WHERE l.locale = (SELECT pg_catalog.current_setting(''mosaic.locale'', true));';

  EXECUTE 'GRANT SELECT ON app_public.' || tableName || '_view TO "catalog_service_gql_role";';

  EXECUTE 'COMMENT ON TABLE app_public.' || tableName || ' IS E''@omit\n@name ' || tableName || '_data'';';
  EXECUTE 'COMMENT ON TABLE app_public.' || localizationsTableName || ' IS E''@omit'';';
  EXECUTE 'COMMENT ON VIEW app_public.' || tableName || '_view IS E''@name ' || tableName || '\n@primaryKey id'';';
END;
$$;


--
-- Name: set_initial_locales(); Type: FUNCTION; Schema: app_private; Owner: -
--

CREATE FUNCTION app_private.set_initial_locales() RETURNS text[]
    LANGUAGE plpgsql
    AS $$
DECLARE
    tableName text;
    localeRecord RECORD;
    localesFound text[] := '{}';
    query text;
BEGIN
    FOR tableName IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'app_public' AND table_name LIKE '%_localizations'
    LOOP
        IF localesFound != '{}' THEN
            -- If locales have been found in a previous iteration, exit the loop
            EXIT;
        END IF;

        query := 'SELECT DISTINCT locale, is_default_locale FROM app_public.' || tableName || ';';
        FOR localeRecord IN EXECUTE query
        LOOP
          IF localesFound = '{}' THEN
            -- If something is found and this is the first locale to be
            -- processed - drop existing locales
            DELETE FROM app_public.locales;
          END IF;

          INSERT INTO app_public.locales (locale, is_default)
          VALUES (localeRecord.locale, localeRecord.is_default_locale)
          ON CONFLICT (locale) DO NOTHING;

          localesFound := array_append(localesFound, localeRecord.locale);
        END LOOP;
    END LOOP;

    RETURN localesFound;
END;
$$;


--
-- Name: column_exists(text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.column_exists(columnname text, tablename text, schemaname text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
  found_column text;
begin
  EXECUTE '
    SELECT column_name
    FROM information_schema.columns
    WHERE table_schema='''||schemaName||''' and table_name='''||tableName||''' and column_name='''||columnName||''';
  ' INTO found_column;

    IF found_column IS NULL THEN
      RETURN false;
    END IF;
    RETURN true;
end;
$$;


--
-- Name: create_enum_table(text, text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.create_enum_table(enumname text, schemaname text, loginroleplaceholder text, enumvalues text, enumdesriptions text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN

  EXECUTE 'DROP TABLE IF EXISTS ' || schemaName || '.' || enumName || ' CASCADE;';

  -- Define an enum table. The value field is the enum key and the description will be used for GraphQL type annotations.
  EXECUTE '
  CREATE TABLE ' || schemaName || '.' || enumName || ' (
    value text primary key,
    description text
  );
  ';

  -- Insert the enum values. This needs to be done here - otherwise migrating existing tables will throw FK errors.
  IF enumDesriptions IS NULL THEN
    EXECUTE '
      INSERT INTO ' || schemaName || '.' || enumName || ' (value)
      SELECT * FROM unnest(''' || enumValues || '''::text[]);
    ';
  ELSE
    EXECUTE '
      INSERT INTO ' || schemaName || '.' || enumName || ' (value, description)
      SELECT * FROM unnest(''' || enumValues || '''::text[], ''' || enumDesriptions || '''::text[]);
    ';
  END IF;

  -- This is needed for Postgraphile introspection to retrieve the values from enum table and use those values to construct a GraphQL enum type
  EXECUTE 'GRANT SELECT ON ' || schemaName || '.' || enumName || ' TO ' || loginRolePlaceholder || ';';

  -- Put a smart comment on an enum table so that Postgraphile introspection is able to find it
  EXECUTE 'COMMENT ON TABLE ' || schemaName || '.' || enumName || '  IS E''@enum'';';
END;
$$;


--
-- Name: create_messaging_counter_table(); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.create_messaging_counter_table() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN

  EXECUTE 'DROP TABLE IF EXISTS app_private.messaging_counter CASCADE;';
  EXECUTE '
  CREATE TABLE app_private.messaging_counter (
    key text primary key,
    counter INT DEFAULT 1,
    expiration_date timestamptz NOT NULL DEFAULT ((now() + INTERVAL ''1 days'') at time zone ''utc'')
  );
  ';

END;
$$;


--
-- Name: create_messaging_health_monitoring(); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.create_messaging_health_monitoring() RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN

  EXECUTE 'DROP TABLE IF EXISTS app_private.messaging_health CASCADE;';
  EXECUTE '
  CREATE TABLE app_private.messaging_health (
    key TEXT PRIMARY KEY,
    success BOOLEAN
  );';
  
  EXECUTE 'CREATE OR REPLACE FUNCTION app_private.messaging_health_notify()
    RETURNS trigger
    LANGUAGE plpgsql
  AS $function$
  BEGIN
    PERFORM pg_notify(''messaging_health_handled'', row_to_json(NEW)::text);
    RETURN NULL;
  END;
  $function$ ';

  EXECUTE  'DROP TRIGGER IF EXISTS _500_messaging_health_trigger ON app_private.messaging_health;';
  EXECUTE  'CREATE trigger _500_messaging_health_trigger
              AFTER UPDATE ON app_private.messaging_health
              FOR EACH ROW EXECUTE PROCEDURE app_private.messaging_health_notify();';

END;
$_$;


--
-- Name: create_trx_next_messages_function(text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.create_trx_next_messages_function(trx_next_message_function_schema text, trx_table_schema text, trx_table_name text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  EXECUTE 'DROP FUNCTION IF EXISTS ' || trx_next_message_function_schema || '.next_'|| trx_table_name ||'_messages(integer, integer);';
  EXECUTE 'CREATE OR REPLACE FUNCTION ' || trx_next_message_function_schema || '.next_'|| trx_table_name ||'_messages(
  max_size integer, lock_ms integer)
    RETURNS SETOF ' || trx_table_schema || '.'|| trx_table_name ||' 
    LANGUAGE ''plpgsql''

AS $BODY$
DECLARE 
  loop_row ' || trx_table_schema || '.'|| trx_table_name ||'%ROWTYPE;
  message_row ' || trx_table_schema || '.'|| trx_table_name ||'%ROWTYPE;
  ids uuid[] := ''{}'';
BEGIN

  IF max_size < 1 THEN
    RAISE EXCEPTION ''The max_size for the next messages batch must be at least one.'' using errcode = ''MAXNR'';
  END IF;

  -- get (only) the oldest message of every segment but only return it if it is not locked
  FOR loop_row IN
    SELECT * FROM ' || trx_table_schema || '.'|| trx_table_name ||' m WHERE m.id in (SELECT DISTINCT ON (segment) id
      FROM ' || trx_table_schema || '.'|| trx_table_name ||'
      WHERE processed_at IS NULL AND abandoned_at IS NULL
      ORDER BY segment, created_at) order by created_at
  LOOP
    BEGIN
      EXIT WHEN cardinality(ids) >= max_size;
    
      SELECT *
        INTO message_row
        FROM ' || trx_table_schema || '.'|| trx_table_name ||'
        WHERE id = loop_row.id
        FOR NO KEY UPDATE NOWAIT; -- throw/catch error when locked
      
      IF message_row.locked_until > NOW() THEN
        CONTINUE;
      END IF;
      
      ids := array_append(ids, message_row.id);
    EXCEPTION 
      WHEN lock_not_available THEN
        CONTINUE;
      WHEN serialization_failure THEN
        CONTINUE;
    END;
  END LOOP;
  
  -- if max_size not reached: get the oldest parallelizable message independent of segment
  IF cardinality(ids) < max_size THEN
    FOR loop_row IN
      SELECT * FROM ' || trx_table_schema || '.'|| trx_table_name ||'
        WHERE concurrency = ''parallel'' AND processed_at IS NULL AND abandoned_at IS NULL AND locked_until < NOW() 
          AND id NOT IN (SELECT UNNEST(ids))
        order by created_at
    LOOP
      BEGIN
        EXIT WHEN cardinality(ids) >= max_size;

        SELECT *
          INTO message_row
          FROM ' || trx_table_schema || '.'|| trx_table_name ||'
          WHERE id = loop_row.id
          FOR NO KEY UPDATE NOWAIT; -- throw/catch error when locked

        ids := array_append(ids, message_row.id);
      EXCEPTION 
        WHEN lock_not_available THEN
          CONTINUE;
        WHEN serialization_failure THEN
          CONTINUE;
      END;
    END LOOP;
  END IF;
  
  -- set a short lock value so the the workers can each process a message
  IF cardinality(ids) > 0 THEN

    RETURN QUERY 
      UPDATE ' || trx_table_schema || '.'|| trx_table_name ||'
        SET locked_until = clock_timestamp() + (lock_ms || '' milliseconds'')::INTERVAL, started_attempts = started_attempts + 1
        WHERE ID = ANY(ids)
        RETURNING *;

  END IF;
END;
$BODY$;';
END;
$_$;


--
-- Name: create_trx_table(text, text, text[], text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.create_trx_table(trx_schema text, trx_table_name text, additional_roles_to_grant text[], concurrency text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE 
  role_ TEXT;
BEGIN
  EXECUTE 'DROP TABLE IF EXISTS ' || trx_schema || '.'|| trx_table_name ||' CASCADE;';
  EXECUTE 'CREATE TABLE ' || trx_schema || '.'|| trx_table_name ||' (
            id uuid PRIMARY KEY,
            aggregate_type TEXT NOT NULL,
            aggregate_id TEXT NOT NULL, 
            message_type TEXT NOT NULL,
            payload JSONB NOT NULL,
            metadata JSONB,
            created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
            processed_at TIMESTAMPTZ,
            started_attempts smallint NOT NULL DEFAULT 0,
            finished_attempts smallint NOT NULL DEFAULT 0,
            segment TEXT,
            locked_until TIMESTAMPTZ NOT NULL DEFAULT to_timestamp(0),
            concurrency TEXT NOT NULL DEFAULT ''' || concurrency || ''',
            abandoned_at TIMESTAMPTZ
          );';
  EXECUTE 'ALTER TABLE ' || trx_schema || '.'|| trx_table_name ||' ADD CONSTRAINT '|| trx_table_name ||'_concurrency_check
            CHECK (concurrency IN (''sequential'', ''parallel''));';
  
  -- The owner role has full access - no grants needed
  -- Grants for additional roles are given here
  FOREACH role_ IN ARRAY additional_roles_to_grant LOOP
    EXECUTE 'GRANT SELECT, INSERT, DELETE ON ' || trx_schema || '.'|| trx_table_name ||' TO ' || role_ || ';';
    EXECUTE 'GRANT UPDATE (locked_until, processed_at, abandoned_at, started_attempts, finished_attempts) ON ' || trx_schema || '.'|| trx_table_name ||' TO ' || role_ || ';';
  END LOOP;  

  EXECUTE 'SELECT ax_define.define_index(''segment'', '''|| trx_table_name ||''', '''||trx_schema||''');';
  EXECUTE 'SELECT ax_define.define_index(''created_at'', '''|| trx_table_name ||''', ''' || trx_schema || ''');';
  EXECUTE 'SELECT ax_define.define_index(''processed_at'', '''|| trx_table_name ||''', ''' || trx_schema || ''');';
  EXECUTE 'SELECT ax_define.define_index(''abandoned_at'', '''|| trx_table_name ||''', ''' || trx_schema || ''');';
  EXECUTE 'SELECT ax_define.define_index(''locked_until'', '''|| trx_table_name ||''', ''' || trx_schema || ''');';
END;
$$;


--
-- Name: define_audit_date_fields_on_table(text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_audit_date_fields_on_table(tablename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  EXECUTE '
    DO $do$ BEGIN
      BEGIN
          ALTER TABLE ' || schemaName || '.' || tableName || ' ADD COLUMN created_date timestamptz NOT NULL DEFAULT (now() at time zone ''utc'');
          ALTER TABLE ' || schemaName || '.' || tableName || ' ADD COLUMN updated_date timestamptz NOT NULL DEFAULT (now() at time zone ''utc'');
      EXCEPTION
          WHEN duplicate_column THEN RAISE NOTICE ''The column created_date already exists in the ' || schemaName || '.' || tableName || ' table.'';
      END;
    END $do$;
  ';
  PERFORM ax_define.define_timestamps_trigger(tableName, schemaName);
END;
$_$;


--
-- Name: define_audit_user_fields_on_table(text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_audit_user_fields_on_table(tablename text, schemaname text, defaultusername text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  EXECUTE '
    DO $do$ BEGIN
      BEGIN
          ALTER TABLE ' || schemaName || '.' || tableName || ' ADD COLUMN created_user text NOT NULL DEFAULT ''' || defaultUserName || ''';
          ALTER TABLE ' || schemaName || '.' || tableName || ' ADD COLUMN updated_user text NOT NULL DEFAULT ''' || defaultUserName || ''';
      EXCEPTION
          WHEN duplicate_column THEN RAISE NOTICE ''The column created_user already exists in the ' || schemaName || '.' || tableName || ' table.'';
      END;
    END $do$;
  ';
  PERFORM ax_define.define_users_trigger(tableName, schemaName);
END;
$_$;


--
-- Name: define_authentication(text, text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_authentication(readpermissions text, modifypermissions text, tablename text, schemaname text, additionalrls text DEFAULT '1=1'::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  EXECUTE 'ALTER TABLE ' || schemaName || '.' || tableName || ' ENABLE ROW LEVEL SECURITY;';
  EXECUTE 'DROP POLICY IF EXISTS ' || tableName || '_authorization ON ' || schemaName || '.' || tableName || ';';

  if (readPermissions <> '' and modifyPermissions <> '') then
    EXECUTE 'CREATE POLICY ' || tableName || '_authorization ON ' || schemaName || '.' || tableName || ' FOR ALL
      USING ((SELECT ax_utils.user_has_permission(''' || readPermissions || ''')) AND ' || additionalRls || ')
      WITH CHECK ((SELECT ax_utils.user_has_permission(''' || modifyPermissions || ''')) AND ' || additionalRls || ');';
    EXECUTE 'DROP POLICY IF EXISTS ' || tableName || '_authorization_delete ON ' || schemaName || '.' || tableName || ';';
    EXECUTE 'CREATE POLICY ' || tableName || '_authorization_delete ON ' || schemaName || '.' || tableName || ' AS restrictive FOR DELETE
    USING ((SELECT ax_utils.user_has_permission(''' || modifyPermissions || ''')));';
  elsif (readPermissions <> '') then
    EXECUTE 'CREATE POLICY ' || tableName || '_authorization ON ' || schemaName || '.' || tableName || ' FOR SELECT
      USING ((SELECT ax_utils.user_has_permission(''' || readPermissions || ''')) AND ' || additionalRls || ');';
  elsif (additionalRls <> '') then
    EXECUTE 'CREATE POLICY ' || tableName || '_authorization ON ' || schemaName || '.' || tableName || ' FOR ALL
      USING (' || additionalRls || ');';
  else
    perform ax_utils.raise_error('Invalid parameters provided to "define_authentication". At least the "readPermissions" or "additionalRls" must be provided.', 'SETUP');
  end if;

END;
$$;


--
-- Name: define_deferred_unique_constraint(text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_deferred_unique_constraint(fieldname text, tablename text, schemaname text, constraintname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
SELECT COALESCE(constraintName, tableName || '_' || fieldName || '_is_unique') INTO constraintName;
  PERFORM ax_utils.validate_identifier_length(constraintName, 'If the auto-generated name is too long then a "constraintName" argument must be provided.');
  PERFORM ax_define.drop_unique_constraint(fieldName, tableName, schemaName, constraintName);
  EXECUTE 'ALTER TABLE ' || schemaName || '.' || tableName || ' ADD CONSTRAINT ' || constraintName || ' UNIQUE (' || fieldName || ') DEFERRABLE INITIALLY DEFERRED;';
END;
$$;


--
-- Name: define_end_user_authentication(text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_end_user_authentication(tablename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  end_user_rls_string TEXT := '((user_id = (SELECT ax_utils.current_user_id()) OR (SELECT ax_utils.current_user_id()) = uuid_nil()))';
BEGIN
  EXECUTE 'ALTER TABLE ' || schemaName || '.' || tableName || ' ENABLE ROW LEVEL SECURITY;';
  EXECUTE 'DROP POLICY IF EXISTS ' || tableName || '_end_user_authorization ON ' || schemaName || '.' || tableName || ';';


  EXECUTE 'CREATE POLICY ' || tableName || '_end_user_authorization ON ' || schemaName || '.' || tableName || ' AS RESTRICTIVE FOR ALL
    USING (' || end_user_rls_string || ');';


END;
$$;


--
-- Name: define_index(text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_index(fieldname text, tablename text, schemaname text, indexname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  SELECT COALESCE(indexName, 'idx_' || tableName || '_' || fieldName) INTO indexName;
  PERFORM ax_utils.validate_identifier_length(indexName, 'If the auto-generated name is too long then an "indexName" argument must be provided.');
  PERFORM ax_define.drop_index(fieldName, tableName, indexName);
  EXECUTE 'CREATE INDEX ' || indexName || ' ON ' || schemaName || '.' || tableName || ' (' || fieldName || ');';
END;
$$;


--
-- Name: define_indexes_with_id(text, text, text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_indexes_with_id(fieldname text, tablename text, schemaname text, indexnameasc text DEFAULT NULL::text, indexnamedesc text DEFAULT NULL::text, idfieldname text DEFAULT 'id'::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  SELECT COALESCE(indexNameAsc, 'idx_' || tableName || '_' || fieldName || '_asc_with_id') INTO indexNameAsc;
  SELECT COALESCE(indexNameDesc, 'idx_' || tableName || '_' || fieldName || '_desc_with_id') INTO indexNameDesc;
  PERFORM ax_utils.validate_identifier_length(indexNameAsc, 'If the auto-generated name is too long then an "indexNameAsc" argument must be provided.');
  PERFORM ax_utils.validate_identifier_length(indexNameDesc, 'If the auto-generated name is too long then an "indexNameDesc" argument must be provided.');
  PERFORM ax_define.drop_indexes_with_id(fieldName, tableName, indexNameAsc, indexNameDesc);
  EXECUTE 'CREATE INDEX idx_' || tableName || '_' || fieldName || '_asc_with_id ON ' || schemaName || '.' || tableName || ' (' || fieldName || ' ASC, ' || idFieldName || ' ASC);';
  EXECUTE 'CREATE INDEX idx_' || tableName || '_' || fieldName || '_desc_with_id ON ' || schemaName || '.' || tableName || ' (' || fieldName || ' DESC, ' || idFieldName || ' ASC);';
END;
$$;


--
-- Name: define_like_index(text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_like_index(fieldname text, tablename text, schemaname text, indexname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  SELECT COALESCE(indexName, 'idx_trgm_' || tableName || '_' || fieldName) INTO indexName;
  PERFORM ax_utils.validate_identifier_length(indexName, 'If the auto-generated name is too long then an "indexName" argument must be provided.');
  PERFORM ax_define.drop_like_index(fieldName, tableName, indexName);
  EXECUTE 'CREATE INDEX ' || indexName || ' ON ' || schemaName || '.' || tableName || ' USING gin (' || fieldName || ' gin_trgm_ops);';
END;
$$;


--
-- Name: define_multiple_field_index(text[], text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_multiple_field_index(fieldnames text[], tablename text, schemaname text, indexname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  fieldNamesConcat text = array_to_string(array_agg(fieldNames), '_');
  fieldList text = array_to_string(array_agg(fieldNames), ', ');
BEGIN
  SELECT COALESCE(indexName, 'idx_' || tableName || '_' || fieldNamesConcat) INTO indexName;
  PERFORM ax_utils.validate_identifier_length(indexName, 'If the auto-generated name is too long then an "indexName" argument must be provided.');
  PERFORM ax_define.drop_multiple_field_index(fieldNames, tableName, indexName);
  EXECUTE 'CREATE INDEX ' || indexName || ' ON ' || schemaName || '.' || tableName || ' (' || fieldList || ');';
END;
$$;


--
-- Name: define_readonly_authentication(text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_readonly_authentication(readpermissions text, tablename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  perform ax_define.define_authentication(readPermissions, '', tableName, schemaName);
END;
$$;


--
-- Name: define_subscription_triggers(text, text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_subscription_triggers(idcolumn text, tablename text, schemaname text, maintablename text, eventtype text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  createEvent text = eventType || '_CREATED';
  changeEvent text = eventType || '_CHANGED';
  deleteEvent text = eventType || '_DELETED';
BEGIN
  EXECUTE 'COMMENT ON TABLE ' || schemaName || '.' || tableName || '  IS E''@subscription_events_' || mainTableName || ' ' || createEvent || ',' || changeEvent || ',' || deleteEvent || ''';';
  
  EXECUTE 'DROP TRIGGER IF EXISTS _500_gql_' || tableName || '_inserted ON ' || schemaName || '.' || tableName;
  EXECUTE 'CREATE TRIGGER _500_gql_' || tableName || '_inserted after insert on ' || schemaName || '.' || tableName || ' ' ||
          'for each row execute procedure ax_utils.tg__graphql_subscription(''' || createEvent || ''',''graphql:' || mainTableName || ''',''' || idColumn || ''');';

  EXECUTE 'DROP TRIGGER IF EXISTS _500_gql_' || tableName || '_updated ON ' || schemaName || '.' || tableName;
  EXECUTE 'CREATE TRIGGER _500_gql_' || tableName || '_updated after update on ' || schemaName || '.' || tableName || ' ' ||
          'for each row execute procedure ax_utils.tg__graphql_subscription(''' || changeEvent || ''',''graphql:' || mainTableName || ''',''' || idColumn || ''');';

  EXECUTE 'DROP TRIGGER IF EXISTS _500_gql_' || tableName || '_deleted ON ' || schemaName || '.' || tableName;
  EXECUTE 'CREATE TRIGGER _500_gql_' || tableName || '_deleted before delete on ' || schemaName || '.' || tableName || ' ' ||
          'for each row execute procedure ax_utils.tg__graphql_subscription(''' || deleteEvent || ''',''graphql:' || mainTableName || ''',''' || idColumn || ''');';
END;
$$;


--
-- Name: define_tenant_environment_trigger(text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_tenant_environment_trigger(tablename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM ax_define.drop_tenant_environment_trigger(tableName, schemaName);
  EXECUTE 'CREATE trigger _200_tenant_environment BEFORE INSERT OR UPDATE ON ' || schemaName || '.' || tableName ||
          ' for each ROW EXECUTE PROCEDURE ax_utils.tg__tenant_environment();';
  EXECUTE 'CREATE trigger _200_tenant_environment_on_delete BEFORE DELETE ON ' || schemaName || '.' || tableName ||
          ' for each ROW EXECUTE PROCEDURE ax_utils.tg__tenant_environment_on_delete();';
END;
$$;


--
-- Name: define_timestamp_propagation(text, text, text, text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_timestamp_propagation(idcolumnname text, tablename text, schemaname text, foreignidcolumnname text, foreigntablename text, foreignschemaname text, functionname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  SELECT COALESCE(functionName, 'tg_' || tableName || '__' || foreignTableName || '_ts_propagation') INTO functionName;
  PERFORM ax_utils.validate_identifier_length(functionName, 'If the auto-generated name is too long then a "functionName" argument must be provided.');
  -- Set updated_date=now() on the foreign table. This will propogate UPDATE triggers.
  --
  -- A new function is created for each table to do this.
  --     It *may* be possible to use a stock function with trigger arguments but its not easy as NEW and OLD cannot be accessed with dynamic column names. A possible
  --     solution to that is described here: https://itectec.com/database/postgresql-assignment-of-a-column-with-dynamic-column-name/. But even there the advise is
  --     to: "Just write a new trigger function for each table. Less hassle, better performance. Byte the bullet on code duplication:"
  --
  -- WARNING: This function uses "SECURITY DEFINER". This is required to ensure that update to the target table is allowed. This means that the function is
  --          executed with role "DB_OWNER". Any propogated trigger functions will also execute with role "DB_OWNER".
  EXECUTE  '
            CREATE OR REPLACE FUNCTION ' || schemaName || '.' || functionName || '() RETURNS TRIGGER
            LANGUAGE plpgsql
            SECURITY DEFINER
            SET search_path = pg_temp
            AS $b$
            BEGIN
                -- if updated_date exists on source and its not changed, then exit here
                -- this prevents multiple propogation from different children in one transaction
                if (to_jsonb(NEW) ? ''updated_date'') THEN
                    -- must be a seperate condition to prevent exception if column does not exist
                    IF (OLD.updated_date = NEW.updated_date) THEN
                        RETURN NULL;
                    END IF;
                END IF;

                -- UPDATE (where relationship is unchanged, or changed to another entity in which case a change is triggered on both the old and new relation)
                IF (OLD.' || idColumnName || ' IS NOT NULL AND NEW.' || idColumnName || ' IS NOT NULL) THEN
                    UPDATE ' || foreignSchemaName || '.' || foreignTableName || ' SET updated_date=now()
                    WHERE (' || foreignIdColumnName || ' = OLD.' || idColumnName || ') OR (' || foreignIdColumnName || ' = NEW.' || idColumnName || ');

                -- INSERT (or UPDATE which sets nullable relationship)
                ELSIF (NEW.' || idColumnName || ' IS NOT NULL) THEN
                    UPDATE ' || foreignSchemaName || '.' || foreignTableName || ' SET updated_date=now()
                    WHERE ' || foreignIdColumnName || ' = NEW.' || idColumnName || ';

                -- DELETE (or UPDATE which removes nullable relationship)
                ELSIF (OLD.' || idColumnName || ' IS NOT NULL) THEN
                    UPDATE ' || foreignSchemaName || '.' || foreignTableName || ' SET updated_date=now()
                    WHERE ' || foreignIdColumnName || ' = OLD.' || idColumnName || ';

                END IF;
                RETURN NULL;
            END $b$;
            REVOKE EXECUTE ON FUNCTION ' || schemaName || '.' || functionName || '() FROM public;
            ';

  -- Function runs *AFTER* INSERT, UPDATE, DELETE. Propogated queries can still raise an error and rollback the transaction
  EXECUTE  'DROP TRIGGER IF EXISTS _200_propogate_timestamps on ' || schemaName || '.' || tableName;
  EXECUTE  'CREATE trigger _200_propogate_timestamps
            AFTER INSERT OR UPDATE OR DELETE ON ' || schemaName || '.' || tableName || '
            FOR EACH ROW EXECUTE PROCEDURE ' || schemaName || '.' || functionName || '();';
END;
$_$;


--
-- Name: define_timestamps_trigger(text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_timestamps_trigger(tablename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM ax_define.drop_timestamps_trigger(tableName, schemaName);
  -- Full row comparison is not compatible with column type JSON. Expect error: "could not identify an equality operator for type json"
  EXECUTE 'CREATE trigger _100_timestamps BEFORE UPDATE ON ' || schemaName || '.' || tableName ||
          ' for each ROW when (old.* is distinct from new.*) EXECUTE PROCEDURE ax_utils.tg__timestamps();';
END;
$$;


--
-- Name: define_unique_constraint(text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_unique_constraint(fieldname text, tablename text, schemaname text, constraintname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  SELECT COALESCE(constraintName, tableName || '_' || fieldName || '_is_unique') INTO constraintName;
  PERFORM ax_utils.validate_identifier_length(constraintName, 'If the auto-generated name is too long then a "constraintName" argument must be provided.');
  PERFORM ax_define.drop_unique_constraint(fieldName, tableName, schemaName, constraintName);
  EXECUTE 'ALTER TABLE ' || schemaName || '.' || tableName || ' ADD CONSTRAINT ' ||constraintName || ' UNIQUE (' || fieldName || ');';
END;
$$;


--
-- Name: define_unique_index(text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_unique_index(fieldname text, tablename text, schemaname text, indexname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  SELECT COALESCE(indexName, 'idx_' || tableName || '_' || fieldName) INTO indexName;
  PERFORM ax_utils.validate_identifier_length(indexName, 'If the auto-generated name is too long then an "indexName" argument must be provided.');
  PERFORM ax_define.drop_index(fieldName, tableName, indexName);
  EXECUTE 'CREATE UNIQUE INDEX ' || indexName || ' ON ' || schemaName || '.' || tableName || ' (' || fieldName || ');';
END;
$$;


--
-- Name: define_user_id_on_table(text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_user_id_on_table(tablename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  EXECUTE '
    DO $do$ BEGIN
      BEGIN
          ALTER TABLE ' || schemaName || '.' || tableName || ' ADD COLUMN user_id UUID NOT NULL DEFAULT ''00000000-0000-0000-0000-000000000000'';
      EXCEPTION
          WHEN duplicate_column THEN RAISE NOTICE ''The column user_id already exists in the ' || schemaName || '.' || tableName || ' table.'';
      END;
    END $do$;

    ALTER TABLE ' || schemaName || '.' || tableName || ' DROP CONSTRAINT IF EXISTS user_id_not_default;
    ALTER TABLE ' || schemaName || '.' || tableName || ' ADD CONSTRAINT user_id_not_default CHECK (ax_utils.constraint_not_default_uuid(user_id, uuid_nil()));

    SELECT ax_define.define_user_id_trigger(''' || tableName || ''', ''' || schemaName || ''');
  ';
END;
$_$;


--
-- Name: define_user_id_trigger(text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_user_id_trigger(tablename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM ax_define.drop_user_id_trigger(tableName, schemaName);
  EXECUTE 'CREATE trigger _200_user_id BEFORE INSERT OR UPDATE ON ' || schemaName || '.' || tableName ||
          ' for each ROW EXECUTE PROCEDURE ax_utils.tg__user_id();';
END;
$$;


--
-- Name: define_users_trigger(text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.define_users_trigger(tablename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM ax_define.drop_users_trigger(tableName, schemaName);
  -- Full row comparison is not compatible with column type JSON. Expect error: "could not identify an equality operator for type json"
  EXECUTE 'CREATE trigger _200_username BEFORE UPDATE ON ' || schemaName || '.' || tableName ||
          ' for each ROW when (old.* is distinct from new.*) EXECUTE PROCEDURE ax_utils.tg__username();';
  -- INSERT trigger's WHEN condition cannot reference OLD values
  EXECUTE 'CREATE trigger _200_username_before_insert BEFORE INSERT ON ' || schemaName || '.' || tableName ||
          ' for each ROW EXECUTE PROCEDURE ax_utils.tg__username();';
END;
$$;


--
-- Name: drop_index(text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.drop_index(fieldname text, tablename text, indexname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  SELECT COALESCE(indexName, 'idx_' || tableName || '_' || fieldName) INTO indexName;
  PERFORM ax_utils.validate_identifier_length(indexName, 'If the auto-generated name is too long then an "indexName" argument must be provided.');
  EXECUTE 'DROP INDEX IF EXISTS ' || indexName || ' cascade;';
END;
$$;


--
-- Name: drop_indexes_with_id(text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.drop_indexes_with_id(fieldname text, tablename text, indexnameasc text DEFAULT NULL::text, indexnamedesc text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  SELECT COALESCE(indexNameAsc, 'idx_' || tableName || '_' || fieldName || '_asc_with_id') INTO indexNameAsc;
  SELECT COALESCE(indexNameDesc, 'idx_' || tableName || '_' || fieldName || '_desc_with_id') INTO indexNameDesc;
  PERFORM ax_utils.validate_identifier_length(indexNameAsc, 'If the auto-generated name is too long then an "indexNameAsc" argument must be provided.');
  PERFORM ax_utils.validate_identifier_length(indexNameDesc, 'If the auto-generated name is too long then an "indexNameDesc" argument must be provided.');
  EXECUTE 'DROP INDEX IF EXISTS ' || indexNameAsc || ' cascade;';
  EXECUTE 'DROP INDEX IF EXISTS ' || indexNameDesc || ' cascade;';
END;
$$;


--
-- Name: drop_like_index(text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.drop_like_index(fieldname text, tablename text, indexname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  SELECT COALESCE(indexName, 'idx_trgm_' || tableName || '_' || fieldName) INTO indexName;
  PERFORM ax_utils.validate_identifier_length(indexName, 'If the auto-generated name is too long then an "indexName" argument must be provided.');
  EXECUTE 'DROP INDEX IF EXISTS ' || indexName || ' cascade;';
END;
$$;


--
-- Name: drop_multiple_field_index(text[], text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.drop_multiple_field_index(fieldnames text[], tablename text, indexname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  fieldNamesConcat text = array_to_string(array_agg(fieldNames), '_');
BEGIN
  SELECT COALESCE(indexName, 'idx_' || tableName || '_' || fieldNamesConcat) INTO indexName;
  PERFORM ax_utils.validate_identifier_length(indexName, 'If the auto-generated name is too long then an "indexName" argument must be provided.');
  EXECUTE 'DROP INDEX IF EXISTS ' || indexName || ' cascade;';
END;
$$;


--
-- Name: drop_tenant_environment_trigger(text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.drop_tenant_environment_trigger(tablename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  EXECUTE 'DROP trigger IF EXISTS _200_tenant_environment on ' || schemaName || '.' || tableName || ';';
  EXECUTE 'DROP trigger IF EXISTS _200_tenant_environment_on_delete on ' || schemaName || '.' || tableName || ';';
END;
$$;


--
-- Name: drop_timestamp_propagation(text, text, text, text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.drop_timestamp_propagation(idcolumnname text, tablename text, schemaname text, foreignidcolumnname text, foreigntablename text, foreignschemaname text, functionname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  SELECT COALESCE(functionName, 'tg_' || tableName || '__' || foreignTableName || '_ts_propagation') INTO functionName;
  PERFORM ax_utils.validate_identifier_length(functionName, 'If the auto-generated name is too long then a "functionName" argument must be provided.');
  EXECUTE  'DROP TRIGGER IF EXISTS _200_propogate_timestamps on ' || schemaName || '.' || tableName;
  EXECUTE  'DROP FUNCTION IF EXISTS ' || schemaName || '.' || functionName || '()';
END;
$$;


--
-- Name: drop_timestamps_trigger(text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.drop_timestamps_trigger(tablename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  EXECUTE 'DROP trigger IF EXISTS _100_timestamps on ' || schemaName || '.' || tableName || ';';
END;
$$;


--
-- Name: drop_unique_constraint(text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.drop_unique_constraint(fieldname text, tablename text, schemaname text, constraintname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  SELECT COALESCE(constraintName, tableName || '_' || fieldName || '_is_unique') INTO constraintName;
  PERFORM ax_utils.validate_identifier_length(constraintName, 'If the auto-generated name is too long then a "constraintName" argument must be provided.');
  EXECUTE 'ALTER TABLE ' || schemaName || '.' || tableName || ' DROP CONSTRAINT IF EXISTS ' || constraintName || ';';
END;
$$;


--
-- Name: drop_user_id_trigger(text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.drop_user_id_trigger(tablename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  EXECUTE 'DROP trigger IF EXISTS _200_user_id on ' || schemaName || '.' || tableName || ';';
END;
$$;


--
-- Name: drop_users_trigger(text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.drop_users_trigger(tablename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  EXECUTE 'DROP trigger IF EXISTS _200_username on ' || schemaName || '.' || tableName || ';';
  EXECUTE 'DROP trigger IF EXISTS _200_username_before_insert on ' || schemaName || '.' || tableName || ';';
END;
$$;


--
-- Name: live_suggestions_endpoint(text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.live_suggestions_endpoint(propertyname text, typename text, schemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  EXECUTE 'CREATE OR REPLACE FUNCTION ' || schemaName || '.get_' || typeName || '_values() ' ||
    'RETURNS SETOF text AS $get$ ' ||
      'SELECT DISTINCT ' || propertyName || ' FROM '|| schemaName || '.' || typeName || ' ' ||
      'ORDER BY ' || propertyName || ' ASC' ||
    '$get$ LANGUAGE SQL STABLE;';
END;
$_$;


--
-- Name: pgmemento_create_table_audit(text, text, text, boolean, boolean, boolean); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.pgmemento_create_table_audit(table_name text, schema_name text DEFAULT 'app_public'::text, audit_id_column_name text DEFAULT 'pgmemento_audit_id'::text, log_old_data boolean DEFAULT true, log_new_data boolean DEFAULT false, log_state boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
    PERFORM pgmemento.create_table_audit($1, $2, $3, $4, $5, $6, TRUE);
EXCEPTION
    -- If this has been run before the table will already have the pgmemento_audit_id column and an error will be thrown.
    WHEN duplicate_column THEN
        RAISE INFO 'Column % already exists on %.%', $3, $2, $1 ;
END;
$_$;


--
-- Name: pgmemento_delete_old_logs(interval); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.pgmemento_delete_old_logs(age interval) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    counter INTEGER;
    transaction_id INTEGER;
    tablename TEXT;
    schemaname TEXT;
BEGIN
    counter := 0;
    FOR transaction_id, tablename, schemaname IN (
        -- 1. Get all transaction metadata and associated table event metadata older than specified age.
        SELECT DISTINCT
            tl.id, el.table_name, el.schema_name
        FROM
            pgmemento.transaction_log tl
            JOIN pgmemento.table_event_log el ON tl.id = el.transaction_id
        WHERE
            tl.txid_time  < NOW() - age)
    LOOP
        -- 2. Delete all table event metadata and row log entries associated with the transaction.
        PERFORM  pgmemento.delete_table_event_log(transaction_id, tablename, schemaname);
        -- 3. Delete the transaction metadata itself.
        PERFORM pgmemento.delete_txid_log(transaction_id);
        counter := counter + 1;
    END LOOP;

    RETURN counter;
END;
$$;


--
-- Name: set_enum_as_column_type(text, text, text, text, text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.set_enum_as_column_type(columnname text, tablename text, schemaname text, enumname text, enumschemaname text, defaultenumvalue text DEFAULT ''::text, notnulloptions text DEFAULT 'NOT NULL'::text, constraintname text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  default_setting TEXT = '';
BEGIN
  SELECT COALESCE(constraintName, tableName || '_' || columnName || '_fkey') INTO constraintName;
  PERFORM ax_utils.validate_identifier_length(constraintName, 'If the auto-generated name is too long then a "constraintName" argument must be provided.');
  IF NOT coalesce(defaultEnumValue, '') = '' THEN
    default_setting = 'DEFAULT ''' || defaultEnumValue || '''::text';
  END IF;
  IF NOT ax_define.column_exists(columnName, tableName, schemaName) THEN
    EXECUTE 'ALTER TABLE ' || schemaName || '.' || tableName || ' ADD COLUMN ' || columnName ||' text ' || default_setting || ' ' || notNullOptions || ';';
  END IF;

  -- Set the column that uses enum value as a foreign key
  EXECUTE 'ALTER TABLE ' || schemaName || '.' || tableName || ' ADD CONSTRAINT ' || constraintName || ' FOREIGN KEY ('|| columnName ||') REFERENCES ' || enumSchemaName || '.' || enumName || '(value);';
END;
$$;


--
-- Name: set_enum_domain(text, text, text, text, text); Type: FUNCTION; Schema: ax_define; Owner: -
--

CREATE FUNCTION ax_define.set_enum_domain(columnname text, tablename text, schemaname text, enumname text, enumschemaname text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
BEGIN
  EXECUTE '
    DO $do$ BEGIN
      BEGIN
        CREATE DOMAIN ' || enumSchemaName || '.' || enumName || ' AS text;
      EXCEPTION
        WHEN duplicate_object THEN RAISE NOTICE ''Domain already existed.'';
      END;
    END $do$;
    ALTER TABLE ' || schemaName || '.' || tableName || ' ALTER COLUMN ' || columnName || ' TYPE ' || enumSchemaName || '.' || enumName || ';
  ';
END;
$_$;


--
-- Name: constraint_has_allowed_value(text, text[], text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_has_allowed_value(input_value text, allowed_values text[], error_message text DEFAULT 'The value "%s" is not in the list of allowed values ("%s").'::text, error_code text DEFAULT 'ALWDV'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
begin
  if input_value = ANY(allowed_values) then
    return true;
  end if;
  perform ax_utils.raise_error(error_message, error_code, input_value, array_to_string(allowed_values, '", "'));
end;
$$;


--
-- Name: constraint_is_base64(text, text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_is_base64(input_value text, error_message text DEFAULT 'The property must be a Base64 encoded value.'::text, error_code text DEFAULT 'BAS64'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
begin
  if ax_utils.validation_is_base64(input_value) then
    return true;
  end if;
  perform ax_utils.raise_error(error_message, error_code);
end;
$$;


--
-- Name: constraint_is_identifier_key(text, text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_is_identifier_key(input_value text, error_message text DEFAULT 'The property must only contain letters, numbers, underscores, and dashes.'::text, error_code text DEFAULT 'IDKEY'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
begin
  if ax_utils.validation_is_identifier_key(input_value) then
    return true;
  end if;
  perform ax_utils.raise_error(error_message, error_code);
end;
$$;


--
-- Name: constraint_is_trimmed(text, text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_is_trimmed(input_value text, error_message text DEFAULT 'The property value must not start or end with whitespace characters.'::text, error_code text DEFAULT 'NTRIM'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
begin
  if ax_utils.validation_is_trimmed(input_value) then
    return true;
  end if;
  perform ax_utils.raise_error(error_message, error_code);
end;
$$;


--
-- Name: constraint_is_url(text, text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_is_url(input_value text, error_message text DEFAULT 'The property must be a valid URL.'::text, error_code text DEFAULT 'NVURL'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF ax_utils.validation_is_optional_url(input_value) THEN
    RETURN true;
  END IF;
  perform ax_utils.raise_error(error_message, error_code);
END;
$$;


--
-- Name: constraint_matches_pattern(text, text, text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_matches_pattern(input_value text, pattern text, error_message text DEFAULT 'The value "%s" does not match the pattern "%s".'::text, error_code text DEFAULT 'PATRN'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF input_value !~* pattern THEN
      perform ax_utils.raise_error(error_message, error_code, input_value, pattern);
  END IF;
  RETURN true;
END;
$$;


--
-- Name: constraint_max_length(text, integer, text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_max_length(input_value text, max_length integer, error_message text DEFAULT 'The value "%s" is too long. It must be a maximum of %s characters long.'::text, error_code text DEFAULT 'MXLEN'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF length(input_value) > max_length THEN
      perform ax_utils.raise_error(error_message, error_code, input_value, max_length::text);
  END IF;
  RETURN true;
END;
$$;


--
-- Name: constraint_max_value(numeric, numeric, text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_max_value(input_value numeric, max_value numeric, error_message text DEFAULT 'The value "%s" is too big. The maximum is %s.'::text, error_code text DEFAULT 'MXVAL'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF input_value > max_value THEN
      perform ax_utils.raise_error(error_message, error_code, input_value::text, max_value::text);
  END IF;
  RETURN true;
END;
$$;


--
-- Name: constraint_min_length(text, integer, text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_min_length(input_value text, min_length integer, error_message text DEFAULT 'The value "%s" is not long enough. It must be at least %s characters long.'::text, error_code text DEFAULT 'MNLEN'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF length(input_value) < min_length THEN
  	perform ax_utils.raise_error(error_message, error_code, input_value, min_length::text);
  END IF;
  RETURN true;
END;
$$;


--
-- Name: constraint_min_value(numeric, numeric, text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_min_value(input_value numeric, min_value numeric, error_message text DEFAULT 'The value "%s" is too small. The minimum is %s.'::text, error_code text DEFAULT 'MNVAL'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF input_value < min_value THEN
  	perform ax_utils.raise_error(error_message, error_code, input_value::text, min_value::text);
  END IF;
  RETURN true;
END;
$$;


--
-- Name: constraint_not_default_uuid(uuid, uuid, text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_not_default_uuid(input_value uuid, default_uuid uuid DEFAULT 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid, error_message text DEFAULT 'A valid UUID must be provided - the value "%s" is not valid.'::text, error_code text DEFAULT 'UUID0'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
begin
  if input_value IS NULL OR input_value = default_uuid then
    perform ax_utils.raise_error(error_message, error_code, input_value::text);
  end if;
  return true;
end;
$$;


--
-- Name: constraint_not_empty(text, text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_not_empty(input_value text, error_message text DEFAULT 'The property value must not be empty.'::text, error_code text DEFAULT 'EMPTY'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
begin
  if ax_utils.validation_not_empty(input_value) then
    return true;
  end if;
  perform ax_utils.raise_error(error_message, error_code);
end;
$$;


--
-- Name: constraint_not_empty_array(text[], text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_not_empty_array(input_value text[], error_message text DEFAULT 'The property must not be an empty array or contain empty/whitespace elements.'::text, error_code text DEFAULT 'EMPTY'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF ax_utils.validation_not_empty_array(input_value) THEN
    RETURN true;
  END IF;
  perform ax_utils.raise_error(error_message, error_code);
END;
$$;


--
-- Name: constraint_starts_with(text, text, text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.constraint_starts_with(input_value text, prefix_value text, error_message text DEFAULT 'The property must start with "%2$s".'::text, error_code text DEFAULT 'STRWT'::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
begin
  if ax_utils.validation_starts_with(input_value, prefix_value) then
    return true;
  end if;
  perform ax_utils.raise_error(error_message, error_code, input_value, prefix_value::text);
end;
$$;


--
-- Name: current_environment_id(); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.current_environment_id() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT coalesce(nullif(current_setting('mosaic.environment_id', TRUE), ''), 'ffffffff-ffff-ffff-ffff-ffffffffffff')::UUID;
$$;


--
-- Name: current_tenant_id(); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.current_tenant_id() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT coalesce(nullif(current_setting('mosaic.tenant_id', TRUE), ''), 'ffffffff-ffff-ffff-ffff-ffffffffffff')::UUID;
$$;


--
-- Name: current_user_id(); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.current_user_id() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT coalesce(nullif(current_setting('mosaic.auth.user_id', TRUE), ''), uuid_nil()::TEXT)::UUID;
$$;


--
-- Name: raise_error(text, text, text[]); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.raise_error(error_message text, error_code text, VARIADIC placeholder_values text[] DEFAULT '{}'::text[]) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION '%', format(error_message, VARIADIC placeholder_values) using errcode = error_code;
END;
$$;


--
-- Name: tg__graphql_subscription(); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.tg__graphql_subscription() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
DECLARE
  v_process_new bool = (TG_OP = 'INSERT' OR TG_OP = 'UPDATE');
  v_process_old bool = (TG_OP = 'UPDATE' OR TG_OP = 'DELETE');
  v_event text = TG_ARGV[0];
  v_topic_template text = TG_ARGV[1];
  v_attribute text = TG_ARGV[2];
  v_record record;
  v_sub text;
  v_topic text;
  v_i int = 0;
  v_last_topic text;
BEGIN
  FOR v_i IN 0..1 LOOP
    IF (v_i = 0) AND v_process_new IS TRUE THEN
      v_record = new;
    ELSIF (v_i = 1) AND v_process_old IS TRUE THEN
      v_record = old;
    ELSE
      CONTINUE;
    END IF;
    IF v_attribute IS NOT NULL THEN
      EXECUTE 'select $1.' || quote_ident(v_attribute)
        USING v_record
        INTO  v_sub;
    END IF;
    IF v_sub IS NOT NULL THEN
      v_topic = replace(v_topic_template, '$1', v_sub);
    ELSE
      v_topic = v_topic_template;
    END IF;
    IF v_topic IS DISTINCT FROM v_last_topic THEN
      -- This if statement prevents us from triggering the same notification twice
      v_last_topic = v_topic; 
      perform pg_notify(v_topic, json_build_object(
        'event', v_event,
        'subject', v_sub
      )::text);
    END IF;
  END LOOP;
  RETURN v_record;
END;
$_$;


--
-- Name: FUNCTION tg__graphql_subscription(); Type: COMMENT; Schema: ax_utils; Owner: -
--

COMMENT ON FUNCTION ax_utils.tg__graphql_subscription() IS 'This function enables the creation of simple focussed GraphQL subscriptions using database triggers. Read more here: https://www.graphile.org/postgraphile/subscriptions/#custom-subscriptions';


--
-- Name: tg__tenant_environment(); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.tg__tenant_environment() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
	tenant_id text = current_setting('mosaic.tenant_id', TRUE);
  environment_id text = current_setting('mosaic.environment_id', TRUE);
  is_superuser text = current_setting('is_superuser', TRUE);
  ignore_multitenancy text = current_setting('mosaic.ignore_multitenancy', TRUE);
BEGIN
  IF tenant_id <> '' THEN   -- Not null and not empty
    IF NEW.tenant_id::TEXT <> 'ffffffff-ffff-ffff-ffff-ffffffffffff' AND NEW.tenant_id::TEXT <> tenant_id THEN
      perform ax_utils.raise_error('The "mosaic.tenant_id" set via set_config must match the updated/inserted row.', 'TENAN');
    END IF;
    NEW.tenant_id = tenant_id;
  ELSIF is_superuser <> 'on' AND ignore_multitenancy <> 'on' THEN
    perform ax_utils.raise_error('The "mosaic.tenant_id" must be set via set_config value.', 'TENAN');
  END IF;
  IF environment_id <> '' THEN   -- Not null and not empty
    IF NEW.environment_id::TEXT <> 'ffffffff-ffff-ffff-ffff-ffffffffffff' AND NEW.environment_id::TEXT <> environment_id THEN
      perform ax_utils.raise_error('The "mosaic.environment_id" set via set_config must match the updated/inserted row.', 'ENVVV');
    END IF;
    NEW.environment_id = environment_id;
  ELSIF is_superuser <> 'on' AND ignore_multitenancy <> 'on' THEN
    perform ax_utils.raise_error('The "mosaic.environment_id" must be set via set_config value.', 'ENVVV');
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: FUNCTION tg__tenant_environment(); Type: COMMENT; Schema: ax_utils; Owner: -
--

COMMENT ON FUNCTION ax_utils.tg__tenant_environment() IS 'This trigger should be called on tables needing automatic tenant_id, environment_id - to support multi-tenancy';


--
-- Name: tg__tenant_environment_on_delete(); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.tg__tenant_environment_on_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
	tenant_id text = current_setting('mosaic.tenant_id', TRUE);
  environment_id text = current_setting('mosaic.environment_id', TRUE);
  is_superuser text = current_setting('is_superuser', TRUE);
  ignore_multitenancy text = current_setting('mosaic.ignore_multitenancy', TRUE);
BEGIN
  IF tenant_id <> '' THEN   -- Not null and not empty
    IF OLD.tenant_id::TEXT <> tenant_id THEN
      perform ax_utils.raise_error('The "mosaic.tenant_id" set via set_config must match the deleted row.', 'TENAN');
    END IF;
  ELSIF is_superuser <> 'on' AND ignore_multitenancy <> 'on' THEN
    perform ax_utils.raise_error('The "mosaic.tenant_id" must be set via set_config value.', 'TENAN');
  END IF;
  IF environment_id <> '' THEN   -- Not null and not empty
    IF OLD.environment_id::TEXT <> environment_id THEN
      perform ax_utils.raise_error('The "mosaic.environment_id" set via set_config must match the deleted row.', 'ENVVV');
    END IF;
  ELSIF is_superuser <> 'on' AND ignore_multitenancy <> 'on' THEN
    perform ax_utils.raise_error('The "mosaic.environment_id" must be set via set_config value.', 'ENVVV');
  END IF;
  RETURN OLD;
END;
$$;


--
-- Name: FUNCTION tg__tenant_environment_on_delete(); Type: COMMENT; Schema: ax_utils; Owner: -
--

COMMENT ON FUNCTION ax_utils.tg__tenant_environment_on_delete() IS 'This trigger should be called on tables needing automatic tenant_id, environment_id - to support multi-tenancy';


--
-- Name: tg__timestamps(); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.tg__timestamps() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
BEGIN
  NEW.created_date = (CASE WHEN TG_OP = 'INSERT' THEN (now() at time zone 'utc') ELSE OLD.created_date END);
  NEW.updated_date = (CASE WHEN TG_OP = 'UPDATE' AND OLD.updated_date  >= (now() at time zone 'utc') THEN OLD.updated_date  + interval '1 millisecond' ELSE (now() at time zone 'utc') END);
  RETURN NEW;
END;
$$;


--
-- Name: FUNCTION tg__timestamps(); Type: COMMENT; Schema: ax_utils; Owner: -
--

COMMENT ON FUNCTION ax_utils.tg__timestamps() IS 'This trigger should be called on all tables with created_date , updated_date  - it ensures that they cannot be manipulated and that updated_date  will always be larger than the previous updated_date .';


--
-- Name: tg__user_id(); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.tg__user_id() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  user_id_ text = current_setting('mosaic.auth.user_id', TRUE);
BEGIN
  IF user_id_ <> '' AND user_id_ <> uuid_nil()::TEXT THEN -- NOT NULL AND NOT DEFAULT
    NEW.user_id = user_id_;
  ELSEIF NEW.user_id IS NULL THEN
    perform ax_utils.raise_error('The "mosaic.auth.user_id" must be set via set_config value.', 'USRID');
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: FUNCTION tg__user_id(); Type: COMMENT; Schema: ax_utils; Owner: -
--

COMMENT ON FUNCTION ax_utils.tg__user_id() IS 'This trigger should be called on tables needing automatic user_id.';


--
-- Name: tg__username(); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.tg__username() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
	username text = pg_catalog.current_setting('mosaic.auth.subject_name', true);
BEGIN
  if username IS NULL OR username::char(5) = ''::char(5) then
  	RETURN NEW;
  end if;
  
  NEW.created_user = (CASE WHEN TG_OP = 'INSERT' THEN username ELSE OLD.created_user END);
  NEW.updated_user = (CASE WHEN TG_OP = 'UPDATE' OR TG_OP = 'INSERT' THEN username ELSE OLD.updated_user END);
  RETURN NEW;
END;
$$;


--
-- Name: user_has_permission(text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.user_has_permission(required_permissions text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
   if ax_utils.user_has_setting(required_permissions, 'mosaic.auth.permissions') = false then
    PERFORM ax_utils.raise_error('At least one of these permissions must be granted: %s', 'PERMI', required_permissions);
   end if;
   return true;
END;
$$;


--
-- Name: user_has_permission_and_tag(text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.user_has_permission_and_tag(required_permissions text, fieldvalue text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
	v_part text;
	v_user_permissions text = ',' || pg_catalog.current_setting('mosaic.auth.permissions', true) || ',';
	v_user_tags text = pg_catalog.current_setting('mosaic.auth.tags', true);
BEGIN
   -- check if the user has the needed permission - otherwise skip
   if ax_utils.user_has_setting(required_permissions, 'mosaic.auth.permissions') = false then
       RAISE EXCEPTION 'At least one of these permissions must be granted: (%)', required_permissions using errcode = 'PERMI'; 
   end if;   
   -- check if any tag matches the discrete column value
   foreach v_part in array string_to_array(v_user_tags, ',')
   loop
       if v_part = CAST (fieldValue AS TEXT) then
           return true;
       end if;
   end loop;
   return false;
END;
$$;


--
-- Name: user_has_setting(text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.user_has_setting(required_settings text, local_variable_field text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
	v_part text;
	v_user_settings text = ',' || pg_catalog.current_setting(local_variable_field, true) || ',';
BEGIN
   foreach v_part in array string_to_array(required_settings, ',')
   loop
       if v_user_settings like '%,' || v_part || ',%' then
           return true;
       end if;
   end loop;
   return false;
END;
$$;


--
-- Name: user_has_tag(text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.user_has_tag(required_permissions text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
   return ax_utils.user_has_setting(required_permissions, 'mosaic.auth.tags');
END;
$$;


--
-- Name: validate_identifier_length(text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.validate_identifier_length(identifier text, hint text DEFAULT ''::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  stack text; fcesig text; callinfo text;
BEGIN
  IF LENGTH(identifier) > 63 THEN
    -- get sig of calling function
    GET DIAGNOSTICS stack = PG_CONTEXT;
    fcesig := substring(substring(stack from 'function (.*)') from 'function (.*?) line');
    callinfo := CASE WHEN fcesig IS NULL THEN '' ELSE 'Long identifier in ' || fcesig::regprocedure::text || '. ' END;
    perform ax_utils.raise_error('%sIdentifier "%s" exceeds 63 bytes. %s', 'SETUP', callinfo, identifier, hint);
  END IF;
END;
$$;


--
-- Name: validation_is_base64(text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.validation_is_base64(input_value text) RETURNS boolean
    LANGUAGE plpgsql
    AS $_$
begin
  if input_value !~* '^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)?$' then
  	return false;
  end if;
  return true;
end;
$_$;


--
-- Name: validation_is_identifier_key(text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.validation_is_identifier_key(input_value text) RETURNS boolean
    LANGUAGE plpgsql
    AS $_$
begin
  if input_value !~* '^([A-Za-z0-9_\-])*$' then
  	return false;
  end if;
  return true;
end;
$_$;


--
-- Name: validation_is_optional_url(text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.validation_is_optional_url(input_value text) RETURNS boolean
    LANGUAGE plpgsql
    AS $_$
begin
  if not ax_utils.validation_not_empty(input_value) THEN
    return true;
  end if;

  if input_value !~* 'https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{2,255}(\.[a-z]{2,9})?\y([-a-zA-Z0-9@:%_\+.~#?&//=]*)$' then
  	return false;
  end if;
  return true;
end;
$_$;


--
-- Name: validation_is_trimmed(text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.validation_is_trimmed(input_value text) RETURNS boolean
    LANGUAGE plpgsql
    AS $_$
begin
  if input_value !~* '^(?!.*^[\s])(?!.*[\s]$).*$' then
  	return false;
  end if;
  return true;
end;
$_$;


--
-- Name: validation_is_url(text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.validation_is_url(input_value text) RETURNS boolean
    LANGUAGE plpgsql
    AS $_$
begin
  if input_value !~* 'https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{2,255}(\.[a-z]{2,9})?\y([-a-zA-Z0-9@:%_\+.~#?&//=]*)$' then
  	return false;
  end if;
  return true;
end;
$_$;


--
-- Name: validation_not_empty(text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.validation_not_empty(input_value text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
begin
  if input_value IS NULL OR input_value !~* '.*\S.*' then
  	return false;
  end if;
  return true;
end;
$$;


--
-- Name: validation_not_empty_array(text[]); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.validation_not_empty_array(input_value text[]) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
  val_ TEXT;
BEGIN
  IF array_length(input_value, 1) IS NULL THEN 
    RETURN FALSE;
  END IF;
 
 
  FOREACH val_ IN ARRAY input_value LOOP
 	  IF val_ IS NULL OR val_ !~* '.*\S.*' THEN
  	  	RETURN FALSE;
  	END IF;
  END LOOP;
  
  RETURN TRUE;
END;
$$;


--
-- Name: validation_starts_with(text, text); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.validation_starts_with(input_value text, prefix_value text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
begin
  if input_value like prefix_value || '%' then
  	return true;
  end if;
  return false;
end;
$$;


--
-- Name: validation_valid_url_array(text[]); Type: FUNCTION; Schema: ax_utils; Owner: -
--

CREATE FUNCTION ax_utils.validation_valid_url_array(input_value text[]) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
  val_ TEXT;
BEGIN
  IF array_length(input_value, 1) IS NOT NULL THEN 
    FOREACH val_ IN ARRAY input_value LOOP
      IF val_ IS NOT NULL THEN
        IF NOT ax_utils.validation_is_url(val_) THEN
          RETURN FALSE;
        END IF;
      ELSIF val_ IS NULL OR val_ !~* '.*\S.*' THEN
  	  	RETURN FALSE;
      END IF;
    END LOOP;
  END IF;
  RETURN TRUE;
END;
$$;


--
-- Name: notify_watchers_ddl(); Type: FUNCTION; Schema: postgraphile_watch; Owner: -
--

CREATE FUNCTION postgraphile_watch.notify_watchers_ddl() RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
begin
  perform pg_notify(
    'postgraphile_watch',
    json_build_object(
      'type',
      'ddl',
      'payload',
      (select json_agg(json_build_object('schema', schema_name, 'command', command_tag)) from pg_event_trigger_ddl_commands() as x)
    )::text
  );
end;
$$;


--
-- Name: notify_watchers_drop(); Type: FUNCTION; Schema: postgraphile_watch; Owner: -
--

CREATE FUNCTION postgraphile_watch.notify_watchers_drop() RETURNS event_trigger
    LANGUAGE plpgsql
    AS $$
begin
  perform pg_notify(
    'postgraphile_watch',
    json_build_object(
      'type',
      'drop',
      'payload',
      (select json_agg(distinct x.schema_name) from pg_event_trigger_dropped_objects() as x)
    )::text
  );
end;
$$;


--
-- Name: messaging_counter; Type: TABLE; Schema: app_private; Owner: -
--

CREATE TABLE app_private.messaging_counter (
    key text NOT NULL,
    counter integer DEFAULT 1,
    expiration_date timestamp with time zone DEFAULT ((now() + '1 day'::interval) AT TIME ZONE 'utc'::text) NOT NULL
);


--
-- Name: channel; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.channel (
    id text NOT NULL,
    dash_stream_url text,
    hls_stream_url text,
    key_id text
);


--
-- Name: TABLE channel; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.channel IS '@omit
@name channel_data';


--
-- Name: channel_images; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.channel_images (
    id integer NOT NULL,
    channel_id text,
    type text,
    path text,
    width integer,
    height integer
);


--
-- Name: channel_images_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.channel_images ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.channel_images_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: channel_localizations; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.channel_localizations (
    id integer NOT NULL,
    channel_id text,
    locale text NOT NULL,
    is_default_locale boolean NOT NULL,
    title text NOT NULL,
    description text
);


--
-- Name: TABLE channel_localizations; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.channel_localizations IS '@omit';


--
-- Name: channel_localizations_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.channel_localizations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.channel_localizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: channel_view; Type: VIEW; Schema: app_public; Owner: -
--

CREATE VIEW app_public.channel_view AS
 SELECT p.id,
    p.dash_stream_url,
    p.hls_stream_url,
    p.key_id,
    l.title,
    l.description
   FROM (app_public.channel_localizations l
     JOIN app_public.channel p ON ((l.channel_id = p.id)))
  WHERE (l.locale = ( SELECT current_setting('mosaic.locale'::text, true) AS current_setting));


--
-- Name: VIEW channel_view; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON VIEW app_public.channel_view IS '@name channel
@primaryKey id';


--
-- Name: collection; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.collection (
    id text NOT NULL,
    tags text[]
);


--
-- Name: TABLE collection; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.collection IS '@omit
@name collection_data';


--
-- Name: collection_images; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.collection_images (
    id integer NOT NULL,
    collection_id text,
    type text,
    path text,
    width integer,
    height integer
);


--
-- Name: collection_images_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.collection_images ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.collection_images_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: collection_items_relation; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.collection_items_relation (
    id integer NOT NULL,
    collection_id text,
    movie_id text,
    tvshow_id text,
    season_id text,
    episode_id text,
    order_no integer DEFAULT 0 NOT NULL,
    relation_type text
);


--
-- Name: collection_items_relation_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.collection_items_relation ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.collection_items_relation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: collection_localizations; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.collection_localizations (
    id integer NOT NULL,
    collection_id text,
    locale text NOT NULL,
    is_default_locale boolean NOT NULL,
    title text NOT NULL,
    description text,
    synopsis text
);


--
-- Name: TABLE collection_localizations; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.collection_localizations IS '@omit';


--
-- Name: collection_localizations_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.collection_localizations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.collection_localizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: collection_view; Type: VIEW; Schema: app_public; Owner: -
--

CREATE VIEW app_public.collection_view AS
 SELECT p.id,
    p.tags,
    l.title,
    l.description,
    l.synopsis
   FROM (app_public.collection_localizations l
     JOIN app_public.collection p ON ((l.collection_id = p.id)))
  WHERE (l.locale = ( SELECT current_setting('mosaic.locale'::text, true) AS current_setting));


--
-- Name: VIEW collection_view; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON VIEW app_public.collection_view IS '@name collection
@primaryKey id';


--
-- Name: episode; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.episode (
    id text NOT NULL,
    season_id text,
    index integer,
    original_title text,
    studio text,
    released timestamp with time zone,
    episode_cast text[],
    tags text[],
    production_countries text[]
);


--
-- Name: TABLE episode; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.episode IS '@omit
@name episode_data';


--
-- Name: episode_genres_relation; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.episode_genres_relation (
    id integer NOT NULL,
    episode_id text,
    tvshow_genre_id text,
    order_no integer DEFAULT 0 NOT NULL
);


--
-- Name: episode_genres_relation_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.episode_genres_relation ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.episode_genres_relation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: episode_images; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.episode_images (
    id integer NOT NULL,
    episode_id text,
    type text,
    path text,
    width integer,
    height integer
);


--
-- Name: episode_images_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.episode_images ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.episode_images_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: episode_licenses; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.episode_licenses (
    id integer NOT NULL,
    episode_id text,
    countries text[],
    start_time timestamp with time zone,
    end_time timestamp with time zone
);


--
-- Name: episode_licenses_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.episode_licenses ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.episode_licenses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: episode_localizations; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.episode_localizations (
    id integer NOT NULL,
    episode_id text,
    locale text NOT NULL,
    is_default_locale boolean NOT NULL,
    title text NOT NULL,
    description text,
    synopsis text
);


--
-- Name: TABLE episode_localizations; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.episode_localizations IS '@omit';


--
-- Name: episode_localizations_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.episode_localizations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.episode_localizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: episode_video_cue_points; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.episode_video_cue_points (
    id integer NOT NULL,
    episode_video_id integer,
    cue_point_type_key text NOT NULL,
    time_in_seconds numeric(13,5) NOT NULL,
    value text
);


--
-- Name: episode_video_cue_points_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.episode_video_cue_points ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.episode_video_cue_points_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: episode_video_streams; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.episode_video_streams (
    id integer NOT NULL,
    episode_video_id integer,
    label text,
    key_id text,
    format text,
    iv text,
    file text,
    language_code text,
    bitrate_in_kbps integer,
    type app_public.video_stream_type_enum,
    file_template text,
    codecs text,
    frame_rate numeric(8,5),
    height integer,
    width integer,
    display_aspect_ratio text,
    pixel_aspect_ratio text,
    sampling_rate integer,
    language_name text
);


--
-- Name: episode_video_streams_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.episode_video_streams ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.episode_video_streams_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: episode_videos; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.episode_videos (
    id integer NOT NULL,
    episode_id text,
    type text,
    title text,
    length_in_seconds numeric(13,5),
    audio_languages text[],
    subtitle_languages text[],
    caption_languages text[],
    dash_manifest text,
    hls_manifest text,
    is_protected boolean,
    output_format text
);


--
-- Name: episode_videos_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.episode_videos ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.episode_videos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: episode_view; Type: VIEW; Schema: app_public; Owner: -
--

CREATE VIEW app_public.episode_view AS
 SELECT p.id,
    p.season_id,
    p.index,
    p.original_title,
    p.studio,
    p.released,
    p.episode_cast,
    p.tags,
    p.production_countries,
    l.title,
    l.description,
    l.synopsis
   FROM (app_public.episode_localizations l
     JOIN app_public.episode p ON ((l.episode_id = p.id)))
  WHERE (l.locale = ( SELECT current_setting('mosaic.locale'::text, true) AS current_setting));


--
-- Name: VIEW episode_view; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON VIEW app_public.episode_view IS '@name episode
@primaryKey id';


--
-- Name: locales; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.locales (
    locale text NOT NULL,
    is_default boolean DEFAULT false NOT NULL
);


--
-- Name: movie; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.movie (
    id text NOT NULL,
    original_title text,
    studio text,
    released timestamp with time zone,
    movie_cast text[],
    production_countries text[],
    tags text[]
);


--
-- Name: TABLE movie; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.movie IS '@omit
@name movie_data';


--
-- Name: movie_genre; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.movie_genre (
    id text NOT NULL,
    order_no integer
);


--
-- Name: TABLE movie_genre; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.movie_genre IS '@omit
@name movie_genre_data';


--
-- Name: movie_genre_localizations; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.movie_genre_localizations (
    id integer NOT NULL,
    movie_genre_id text,
    locale text NOT NULL,
    is_default_locale boolean NOT NULL,
    title text NOT NULL
);


--
-- Name: TABLE movie_genre_localizations; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.movie_genre_localizations IS '@omit';


--
-- Name: movie_genre_localizations_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.movie_genre_localizations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.movie_genre_localizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: movie_genre_view; Type: VIEW; Schema: app_public; Owner: -
--

CREATE VIEW app_public.movie_genre_view AS
 SELECT p.id,
    p.order_no,
    l.title
   FROM (app_public.movie_genre_localizations l
     JOIN app_public.movie_genre p ON ((l.movie_genre_id = p.id)))
  WHERE (l.locale = ( SELECT current_setting('mosaic.locale'::text, true) AS current_setting));


--
-- Name: VIEW movie_genre_view; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON VIEW app_public.movie_genre_view IS '@name movie_genre
@primaryKey id';


--
-- Name: movie_genres_relation; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.movie_genres_relation (
    id integer NOT NULL,
    movie_id text,
    movie_genre_id text,
    order_no integer DEFAULT 0 NOT NULL
);


--
-- Name: movie_genres_relation_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.movie_genres_relation ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.movie_genres_relation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: movie_images; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.movie_images (
    id integer NOT NULL,
    movie_id text,
    type text,
    path text,
    width integer,
    height integer
);


--
-- Name: movie_images_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.movie_images ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.movie_images_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: movie_licenses; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.movie_licenses (
    id integer NOT NULL,
    movie_id text,
    countries text[],
    start_time timestamp with time zone,
    end_time timestamp with time zone
);


--
-- Name: movie_licenses_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.movie_licenses ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.movie_licenses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: movie_localizations; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.movie_localizations (
    id integer NOT NULL,
    movie_id text,
    locale text NOT NULL,
    is_default_locale boolean NOT NULL,
    title text NOT NULL,
    description text,
    synopsis text
);


--
-- Name: TABLE movie_localizations; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.movie_localizations IS '@omit';


--
-- Name: movie_localizations_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.movie_localizations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.movie_localizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: movie_video_cue_points; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.movie_video_cue_points (
    id integer NOT NULL,
    movie_video_id integer,
    cue_point_type_key text NOT NULL,
    time_in_seconds numeric(13,5) NOT NULL,
    value text
);


--
-- Name: movie_video_cue_points_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.movie_video_cue_points ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.movie_video_cue_points_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: movie_video_streams; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.movie_video_streams (
    id integer NOT NULL,
    movie_video_id integer,
    label text,
    key_id text,
    format text,
    iv text,
    file text,
    language_code text,
    bitrate_in_kbps integer,
    type app_public.video_stream_type_enum,
    file_template text,
    codecs text,
    frame_rate numeric(8,5),
    height integer,
    width integer,
    display_aspect_ratio text,
    pixel_aspect_ratio text,
    sampling_rate integer,
    language_name text
);


--
-- Name: movie_video_streams_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.movie_video_streams ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.movie_video_streams_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: movie_videos; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.movie_videos (
    id integer NOT NULL,
    movie_id text,
    type text,
    title text,
    length_in_seconds numeric(13,5),
    audio_languages text[],
    subtitle_languages text[],
    caption_languages text[],
    dash_manifest text,
    hls_manifest text,
    is_protected boolean,
    output_format text
);


--
-- Name: movie_videos_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.movie_videos ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.movie_videos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: movie_view; Type: VIEW; Schema: app_public; Owner: -
--

CREATE VIEW app_public.movie_view AS
 SELECT p.id,
    p.original_title,
    p.studio,
    p.released,
    p.movie_cast,
    p.production_countries,
    p.tags,
    l.title,
    l.description,
    l.synopsis
   FROM (app_public.movie_localizations l
     JOIN app_public.movie p ON ((l.movie_id = p.id)))
  WHERE (l.locale = ( SELECT current_setting('mosaic.locale'::text, true) AS current_setting));


--
-- Name: VIEW movie_view; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON VIEW app_public.movie_view IS '@name movie
@primaryKey id';


--
-- Name: playlist; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.playlist (
    id text NOT NULL,
    channel_id text,
    start_date_time timestamp with time zone NOT NULL,
    end_date_time timestamp with time zone NOT NULL
);


--
-- Name: program; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.program (
    id integer NOT NULL,
    playlist_id text,
    sort_index integer NOT NULL,
    movie_id text,
    episode_id text
);


--
-- Name: TABLE program; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.program IS '@omit
@name program_data';


--
-- Name: program_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.program ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.program_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: program_images; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.program_images (
    id integer NOT NULL,
    program_id integer,
    type text,
    path text,
    width integer,
    height integer
);


--
-- Name: program_images_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.program_images ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.program_images_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: program_localizations; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.program_localizations (
    id integer NOT NULL,
    program_id integer,
    locale text NOT NULL,
    is_default_locale boolean NOT NULL,
    title text NOT NULL
);


--
-- Name: TABLE program_localizations; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.program_localizations IS '@omit';


--
-- Name: program_localizations_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.program_localizations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.program_localizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: program_view; Type: VIEW; Schema: app_public; Owner: -
--

CREATE VIEW app_public.program_view AS
 SELECT p.id,
    p.playlist_id,
    p.sort_index,
    p.movie_id,
    p.episode_id,
    l.title
   FROM (app_public.program_localizations l
     JOIN app_public.program p ON ((l.program_id = p.id)))
  WHERE (l.locale = ( SELECT current_setting('mosaic.locale'::text, true) AS current_setting));


--
-- Name: VIEW program_view; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON VIEW app_public.program_view IS '@name program
@primaryKey id';


--
-- Name: season; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.season (
    id text NOT NULL,
    tvshow_id text,
    index integer,
    studio text,
    released timestamp with time zone,
    season_cast text[],
    production_countries text[],
    tags text[]
);


--
-- Name: TABLE season; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.season IS '@omit
@name season_data';


--
-- Name: season_genres_relation; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.season_genres_relation (
    id integer NOT NULL,
    season_id text,
    tvshow_genre_id text,
    order_no integer DEFAULT 0 NOT NULL
);


--
-- Name: season_genres_relation_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.season_genres_relation ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.season_genres_relation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: season_images; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.season_images (
    id integer NOT NULL,
    season_id text,
    type text,
    path text,
    width integer,
    height integer
);


--
-- Name: season_images_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.season_images ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.season_images_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: season_licenses; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.season_licenses (
    id integer NOT NULL,
    season_id text,
    countries text[],
    start_time timestamp with time zone,
    end_time timestamp with time zone
);


--
-- Name: season_licenses_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.season_licenses ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.season_licenses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: season_localizations; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.season_localizations (
    id integer NOT NULL,
    season_id text,
    locale text NOT NULL,
    is_default_locale boolean NOT NULL,
    description text,
    synopsis text
);


--
-- Name: TABLE season_localizations; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.season_localizations IS '@omit';


--
-- Name: season_localizations_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.season_localizations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.season_localizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: season_video_cue_points; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.season_video_cue_points (
    id integer NOT NULL,
    season_video_id integer,
    cue_point_type_key text NOT NULL,
    time_in_seconds numeric(13,5) NOT NULL,
    value text
);


--
-- Name: season_video_cue_points_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.season_video_cue_points ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.season_video_cue_points_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: season_video_streams; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.season_video_streams (
    id integer NOT NULL,
    season_video_id integer,
    label text,
    key_id text,
    format text,
    iv text,
    file text,
    language_code text,
    bitrate_in_kbps integer,
    type app_public.video_stream_type_enum,
    file_template text,
    codecs text,
    frame_rate numeric(8,5),
    height integer,
    width integer,
    display_aspect_ratio text,
    pixel_aspect_ratio text,
    sampling_rate integer,
    language_name text
);


--
-- Name: season_video_streams_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.season_video_streams ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.season_video_streams_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: season_videos; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.season_videos (
    id integer NOT NULL,
    season_id text,
    type text,
    title text,
    length_in_seconds numeric(13,5),
    audio_languages text[],
    subtitle_languages text[],
    caption_languages text[],
    dash_manifest text,
    hls_manifest text,
    is_protected boolean,
    output_format text
);


--
-- Name: season_videos_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.season_videos ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.season_videos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: season_view; Type: VIEW; Schema: app_public; Owner: -
--

CREATE VIEW app_public.season_view AS
 SELECT p.id,
    p.tvshow_id,
    p.index,
    p.studio,
    p.released,
    p.season_cast,
    p.production_countries,
    p.tags,
    l.description,
    l.synopsis
   FROM (app_public.season_localizations l
     JOIN app_public.season p ON ((l.season_id = p.id)))
  WHERE (l.locale = ( SELECT current_setting('mosaic.locale'::text, true) AS current_setting));


--
-- Name: VIEW season_view; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON VIEW app_public.season_view IS '@name season
@primaryKey id';


--
-- Name: tvshow; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.tvshow (
    id text NOT NULL,
    original_title text,
    studio text,
    released timestamp with time zone,
    tvshow_cast text[],
    production_countries text[],
    tags text[]
);


--
-- Name: TABLE tvshow; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.tvshow IS '@omit
@name tvshow_data';


--
-- Name: tvshow_genre; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.tvshow_genre (
    id text NOT NULL,
    order_no integer
);


--
-- Name: TABLE tvshow_genre; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.tvshow_genre IS '@omit
@name tvshow_genre_data';


--
-- Name: tvshow_genre_localizations; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.tvshow_genre_localizations (
    id integer NOT NULL,
    tvshow_genre_id text,
    locale text NOT NULL,
    is_default_locale boolean NOT NULL,
    title text NOT NULL
);


--
-- Name: TABLE tvshow_genre_localizations; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.tvshow_genre_localizations IS '@omit';


--
-- Name: tvshow_genre_localizations_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.tvshow_genre_localizations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.tvshow_genre_localizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tvshow_genre_view; Type: VIEW; Schema: app_public; Owner: -
--

CREATE VIEW app_public.tvshow_genre_view AS
 SELECT p.id,
    p.order_no,
    l.title
   FROM (app_public.tvshow_genre_localizations l
     JOIN app_public.tvshow_genre p ON ((l.tvshow_genre_id = p.id)))
  WHERE (l.locale = ( SELECT current_setting('mosaic.locale'::text, true) AS current_setting));


--
-- Name: VIEW tvshow_genre_view; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON VIEW app_public.tvshow_genre_view IS '@name tvshow_genre
@primaryKey id';


--
-- Name: tvshow_genres_relation; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.tvshow_genres_relation (
    id integer NOT NULL,
    tvshow_id text,
    tvshow_genre_id text,
    order_no integer DEFAULT 0 NOT NULL
);


--
-- Name: tvshow_genres_relation_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.tvshow_genres_relation ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.tvshow_genres_relation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tvshow_images; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.tvshow_images (
    id integer NOT NULL,
    tvshow_id text,
    type text,
    path text,
    width integer,
    height integer
);


--
-- Name: tvshow_images_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.tvshow_images ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.tvshow_images_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tvshow_licenses; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.tvshow_licenses (
    id integer NOT NULL,
    tvshow_id text,
    countries text[],
    start_time timestamp with time zone,
    end_time timestamp with time zone
);


--
-- Name: tvshow_licenses_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.tvshow_licenses ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.tvshow_licenses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tvshow_localizations; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.tvshow_localizations (
    id integer NOT NULL,
    tvshow_id text,
    locale text NOT NULL,
    is_default_locale boolean NOT NULL,
    title text NOT NULL,
    description text,
    synopsis text
);


--
-- Name: TABLE tvshow_localizations; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.tvshow_localizations IS '@omit';


--
-- Name: tvshow_localizations_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.tvshow_localizations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.tvshow_localizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tvshow_video_cue_points; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.tvshow_video_cue_points (
    id integer NOT NULL,
    tvshow_video_id integer,
    cue_point_type_key text NOT NULL,
    time_in_seconds numeric(13,5) NOT NULL,
    value text
);


--
-- Name: tvshow_video_cue_points_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.tvshow_video_cue_points ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.tvshow_video_cue_points_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tvshow_video_streams; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.tvshow_video_streams (
    id integer NOT NULL,
    tvshow_video_id integer,
    label text,
    key_id text,
    format text,
    iv text,
    file text,
    language_code text,
    bitrate_in_kbps integer,
    type app_public.video_stream_type_enum,
    file_template text,
    codecs text,
    frame_rate numeric(8,5),
    height integer,
    width integer,
    display_aspect_ratio text,
    pixel_aspect_ratio text,
    sampling_rate integer,
    language_name text
);


--
-- Name: tvshow_video_streams_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.tvshow_video_streams ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.tvshow_video_streams_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tvshow_videos; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.tvshow_videos (
    id integer NOT NULL,
    tvshow_id text,
    type text,
    title text,
    length_in_seconds numeric(13,5),
    audio_languages text[],
    subtitle_languages text[],
    caption_languages text[],
    dash_manifest text,
    hls_manifest text,
    is_protected boolean,
    output_format text
);


--
-- Name: tvshow_videos_id_seq; Type: SEQUENCE; Schema: app_public; Owner: -
--

ALTER TABLE app_public.tvshow_videos ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME app_public.tvshow_videos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tvshow_view; Type: VIEW; Schema: app_public; Owner: -
--

CREATE VIEW app_public.tvshow_view AS
 SELECT p.id,
    p.original_title,
    p.studio,
    p.released,
    p.tvshow_cast,
    p.production_countries,
    p.tags,
    l.title,
    l.description,
    l.synopsis
   FROM (app_public.tvshow_localizations l
     JOIN app_public.tvshow p ON ((l.tvshow_id = p.id)))
  WHERE (l.locale = ( SELECT current_setting('mosaic.locale'::text, true) AS current_setting));


--
-- Name: VIEW tvshow_view; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON VIEW app_public.tvshow_view IS '@name tvshow
@primaryKey id';


--
-- Name: video_stream_type; Type: TABLE; Schema: app_public; Owner: -
--

CREATE TABLE app_public.video_stream_type (
    value text NOT NULL,
    description text
);


--
-- Name: TABLE video_stream_type; Type: COMMENT; Schema: app_public; Owner: -
--

COMMENT ON TABLE app_public.video_stream_type IS '@enum';


--
-- Name: inbox inbox_pkey; Type: CONSTRAINT; Schema: app_hidden; Owner: -
--

ALTER TABLE ONLY app_hidden.inbox
    ADD CONSTRAINT inbox_pkey PRIMARY KEY (id);


--
-- Name: messaging_counter messaging_counter_pkey; Type: CONSTRAINT; Schema: app_private; Owner: -
--

ALTER TABLE ONLY app_private.messaging_counter
    ADD CONSTRAINT messaging_counter_pkey PRIMARY KEY (key);


--
-- Name: channel_images channel_images_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.channel_images
    ADD CONSTRAINT channel_images_pkey PRIMARY KEY (id);


--
-- Name: channel_localizations channel_localizations_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.channel_localizations
    ADD CONSTRAINT channel_localizations_pkey PRIMARY KEY (id);


--
-- Name: channel channel_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.channel
    ADD CONSTRAINT channel_pkey PRIMARY KEY (id);


--
-- Name: collection_images collection_images_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.collection_images
    ADD CONSTRAINT collection_images_pkey PRIMARY KEY (id);


--
-- Name: collection_items_relation collection_items_relation_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.collection_items_relation
    ADD CONSTRAINT collection_items_relation_pkey PRIMARY KEY (id);


--
-- Name: collection_localizations collection_localizations_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.collection_localizations
    ADD CONSTRAINT collection_localizations_pkey PRIMARY KEY (id);


--
-- Name: collection collection_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.collection
    ADD CONSTRAINT collection_pkey PRIMARY KEY (id);


--
-- Name: episode_genres_relation episode_genres_relation_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_genres_relation
    ADD CONSTRAINT episode_genres_relation_pkey PRIMARY KEY (id);


--
-- Name: episode_images episode_images_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_images
    ADD CONSTRAINT episode_images_pkey PRIMARY KEY (id);


--
-- Name: episode_licenses episode_licenses_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_licenses
    ADD CONSTRAINT episode_licenses_pkey PRIMARY KEY (id);


--
-- Name: episode_localizations episode_localizations_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_localizations
    ADD CONSTRAINT episode_localizations_pkey PRIMARY KEY (id);


--
-- Name: episode episode_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode
    ADD CONSTRAINT episode_pkey PRIMARY KEY (id);


--
-- Name: episode_video_cue_points episode_video_cue_points_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_video_cue_points
    ADD CONSTRAINT episode_video_cue_points_pkey PRIMARY KEY (id);


--
-- Name: episode_video_streams episode_video_streams_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_video_streams
    ADD CONSTRAINT episode_video_streams_pkey PRIMARY KEY (id);


--
-- Name: episode_videos episode_videos_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_videos
    ADD CONSTRAINT episode_videos_pkey PRIMARY KEY (id);


--
-- Name: locales locales_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.locales
    ADD CONSTRAINT locales_pkey PRIMARY KEY (locale);


--
-- Name: movie_genre_localizations movie_genre_localizations_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_genre_localizations
    ADD CONSTRAINT movie_genre_localizations_pkey PRIMARY KEY (id);


--
-- Name: movie_genre movie_genre_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_genre
    ADD CONSTRAINT movie_genre_pkey PRIMARY KEY (id);


--
-- Name: movie_genres_relation movie_genres_relation_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_genres_relation
    ADD CONSTRAINT movie_genres_relation_pkey PRIMARY KEY (id);


--
-- Name: movie_images movie_images_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_images
    ADD CONSTRAINT movie_images_pkey PRIMARY KEY (id);


--
-- Name: movie_licenses movie_licenses_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_licenses
    ADD CONSTRAINT movie_licenses_pkey PRIMARY KEY (id);


--
-- Name: movie_localizations movie_localizations_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_localizations
    ADD CONSTRAINT movie_localizations_pkey PRIMARY KEY (id);


--
-- Name: movie movie_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie
    ADD CONSTRAINT movie_pkey PRIMARY KEY (id);


--
-- Name: movie_video_cue_points movie_video_cue_points_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_video_cue_points
    ADD CONSTRAINT movie_video_cue_points_pkey PRIMARY KEY (id);


--
-- Name: movie_video_streams movie_video_streams_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_video_streams
    ADD CONSTRAINT movie_video_streams_pkey PRIMARY KEY (id);


--
-- Name: movie_videos movie_videos_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_videos
    ADD CONSTRAINT movie_videos_pkey PRIMARY KEY (id);


--
-- Name: playlist playlist_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.playlist
    ADD CONSTRAINT playlist_pkey PRIMARY KEY (id);


--
-- Name: program_images program_images_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.program_images
    ADD CONSTRAINT program_images_pkey PRIMARY KEY (id);


--
-- Name: program_localizations program_localizations_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.program_localizations
    ADD CONSTRAINT program_localizations_pkey PRIMARY KEY (id);


--
-- Name: program program_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.program
    ADD CONSTRAINT program_pkey PRIMARY KEY (id);


--
-- Name: season_genres_relation season_genres_relation_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_genres_relation
    ADD CONSTRAINT season_genres_relation_pkey PRIMARY KEY (id);


--
-- Name: season_images season_images_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_images
    ADD CONSTRAINT season_images_pkey PRIMARY KEY (id);


--
-- Name: season_licenses season_licenses_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_licenses
    ADD CONSTRAINT season_licenses_pkey PRIMARY KEY (id);


--
-- Name: season_localizations season_localizations_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_localizations
    ADD CONSTRAINT season_localizations_pkey PRIMARY KEY (id);


--
-- Name: season season_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season
    ADD CONSTRAINT season_pkey PRIMARY KEY (id);


--
-- Name: season_video_cue_points season_video_cue_points_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_video_cue_points
    ADD CONSTRAINT season_video_cue_points_pkey PRIMARY KEY (id);


--
-- Name: season_video_streams season_video_streams_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_video_streams
    ADD CONSTRAINT season_video_streams_pkey PRIMARY KEY (id);


--
-- Name: season_videos season_videos_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_videos
    ADD CONSTRAINT season_videos_pkey PRIMARY KEY (id);


--
-- Name: tvshow_genre_localizations tvshow_genre_localizations_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_genre_localizations
    ADD CONSTRAINT tvshow_genre_localizations_pkey PRIMARY KEY (id);


--
-- Name: tvshow_genre tvshow_genre_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_genre
    ADD CONSTRAINT tvshow_genre_pkey PRIMARY KEY (id);


--
-- Name: tvshow_genres_relation tvshow_genres_relation_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_genres_relation
    ADD CONSTRAINT tvshow_genres_relation_pkey PRIMARY KEY (id);


--
-- Name: tvshow_images tvshow_images_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_images
    ADD CONSTRAINT tvshow_images_pkey PRIMARY KEY (id);


--
-- Name: tvshow_licenses tvshow_licenses_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_licenses
    ADD CONSTRAINT tvshow_licenses_pkey PRIMARY KEY (id);


--
-- Name: tvshow_localizations tvshow_localizations_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_localizations
    ADD CONSTRAINT tvshow_localizations_pkey PRIMARY KEY (id);


--
-- Name: tvshow tvshow_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow
    ADD CONSTRAINT tvshow_pkey PRIMARY KEY (id);


--
-- Name: tvshow_video_cue_points tvshow_video_cue_points_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_video_cue_points
    ADD CONSTRAINT tvshow_video_cue_points_pkey PRIMARY KEY (id);


--
-- Name: tvshow_video_streams tvshow_video_streams_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_video_streams
    ADD CONSTRAINT tvshow_video_streams_pkey PRIMARY KEY (id);


--
-- Name: tvshow_videos tvshow_videos_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_videos
    ADD CONSTRAINT tvshow_videos_pkey PRIMARY KEY (id);


--
-- Name: channel_localizations unique_by_channel_id_and_locale; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.channel_localizations
    ADD CONSTRAINT unique_by_channel_id_and_locale UNIQUE (channel_id, locale);


--
-- Name: collection_localizations unique_by_collection_id_and_locale; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.collection_localizations
    ADD CONSTRAINT unique_by_collection_id_and_locale UNIQUE (collection_id, locale);


--
-- Name: episode_localizations unique_by_episode_id_and_locale; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_localizations
    ADD CONSTRAINT unique_by_episode_id_and_locale UNIQUE (episode_id, locale);


--
-- Name: movie_genre_localizations unique_by_movie_genre_id_and_locale; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_genre_localizations
    ADD CONSTRAINT unique_by_movie_genre_id_and_locale UNIQUE (movie_genre_id, locale);


--
-- Name: movie_localizations unique_by_movie_id_and_locale; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_localizations
    ADD CONSTRAINT unique_by_movie_id_and_locale UNIQUE (movie_id, locale);


--
-- Name: program_localizations unique_by_program_id_and_locale; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.program_localizations
    ADD CONSTRAINT unique_by_program_id_and_locale UNIQUE (program_id, locale);


--
-- Name: season_localizations unique_by_season_id_and_locale; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_localizations
    ADD CONSTRAINT unique_by_season_id_and_locale UNIQUE (season_id, locale);


--
-- Name: tvshow_genre_localizations unique_by_tvshow_genre_id_and_locale; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_genre_localizations
    ADD CONSTRAINT unique_by_tvshow_genre_id_and_locale UNIQUE (tvshow_genre_id, locale);


--
-- Name: tvshow_localizations unique_by_tvshow_id_and_locale; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_localizations
    ADD CONSTRAINT unique_by_tvshow_id_and_locale UNIQUE (tvshow_id, locale);


--
-- Name: video_stream_type video_stream_type_pkey; Type: CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.video_stream_type
    ADD CONSTRAINT video_stream_type_pkey PRIMARY KEY (value);


--
-- Name: idx_inbox_abandoned_at; Type: INDEX; Schema: app_hidden; Owner: -
--

CREATE INDEX idx_inbox_abandoned_at ON app_hidden.inbox USING btree (abandoned_at);


--
-- Name: idx_inbox_created_at; Type: INDEX; Schema: app_hidden; Owner: -
--

CREATE INDEX idx_inbox_created_at ON app_hidden.inbox USING btree (created_at);


--
-- Name: idx_inbox_locked_until; Type: INDEX; Schema: app_hidden; Owner: -
--

CREATE INDEX idx_inbox_locked_until ON app_hidden.inbox USING btree (locked_until);


--
-- Name: idx_inbox_processed_at; Type: INDEX; Schema: app_hidden; Owner: -
--

CREATE INDEX idx_inbox_processed_at ON app_hidden.inbox USING btree (processed_at);


--
-- Name: idx_inbox_segment; Type: INDEX; Schema: app_hidden; Owner: -
--

CREATE INDEX idx_inbox_segment ON app_hidden.inbox USING btree (segment);


--
-- Name: channel_images_channel_id_idx; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX channel_images_channel_id_idx ON app_public.channel_images USING btree (channel_id);


--
-- Name: idx_channel_localizations_channel_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_channel_localizations_channel_id ON app_public.channel_localizations USING btree (channel_id);


--
-- Name: idx_channel_localizations_locale; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_channel_localizations_locale ON app_public.channel_localizations USING btree (locale);


--
-- Name: idx_channel_localizations_title_asc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_channel_localizations_title_asc_with_id ON app_public.channel_localizations USING btree (title, channel_id);


--
-- Name: idx_channel_localizations_title_desc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_channel_localizations_title_desc_with_id ON app_public.channel_localizations USING btree (title DESC, channel_id);


--
-- Name: idx_collection_images_collection_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_collection_images_collection_id ON app_public.collection_images USING btree (collection_id);


--
-- Name: idx_collection_items_relation_collection_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_collection_items_relation_collection_id ON app_public.collection_items_relation USING btree (collection_id);


--
-- Name: idx_collection_items_relation_episode_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_collection_items_relation_episode_id ON app_public.collection_items_relation USING btree (episode_id);


--
-- Name: idx_collection_items_relation_movie_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_collection_items_relation_movie_id ON app_public.collection_items_relation USING btree (movie_id);


--
-- Name: idx_collection_items_relation_order_no; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_collection_items_relation_order_no ON app_public.collection_items_relation USING btree (order_no);


--
-- Name: idx_collection_items_relation_season_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_collection_items_relation_season_id ON app_public.collection_items_relation USING btree (season_id);


--
-- Name: idx_collection_items_relation_tvshow_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_collection_items_relation_tvshow_id ON app_public.collection_items_relation USING btree (tvshow_id);


--
-- Name: idx_collection_localizations_collection_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_collection_localizations_collection_id ON app_public.collection_localizations USING btree (collection_id);


--
-- Name: idx_collection_localizations_locale; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_collection_localizations_locale ON app_public.collection_localizations USING btree (locale);


--
-- Name: idx_collection_localizations_title_asc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_collection_localizations_title_asc_with_id ON app_public.collection_localizations USING btree (title, collection_id);


--
-- Name: idx_collection_localizations_title_desc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_collection_localizations_title_desc_with_id ON app_public.collection_localizations USING btree (title DESC, collection_id);


--
-- Name: idx_episode_genres_relation_episode_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_genres_relation_episode_id ON app_public.episode_genres_relation USING btree (episode_id);


--
-- Name: idx_episode_genres_relation_order_no; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_genres_relation_order_no ON app_public.episode_genres_relation USING btree (order_no);


--
-- Name: idx_episode_genres_relation_tvshow_genre_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_genres_relation_tvshow_genre_id ON app_public.episode_genres_relation USING btree (tvshow_genre_id);


--
-- Name: idx_episode_images_episode_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_images_episode_id ON app_public.episode_images USING btree (episode_id);


--
-- Name: idx_episode_licenses_episode_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_licenses_episode_id ON app_public.episode_licenses USING btree (episode_id);


--
-- Name: idx_episode_localizations_episode_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_localizations_episode_id ON app_public.episode_localizations USING btree (episode_id);


--
-- Name: idx_episode_localizations_locale; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_localizations_locale ON app_public.episode_localizations USING btree (locale);


--
-- Name: idx_episode_localizations_title_asc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_localizations_title_asc_with_id ON app_public.episode_localizations USING btree (title, episode_id);


--
-- Name: idx_episode_localizations_title_desc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_localizations_title_desc_with_id ON app_public.episode_localizations USING btree (title DESC, episode_id);


--
-- Name: idx_episode_season_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_season_id ON app_public.episode USING btree (season_id);


--
-- Name: idx_episode_video_cue_points_episode_video_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_video_cue_points_episode_video_id ON app_public.episode_video_cue_points USING btree (episode_video_id);


--
-- Name: idx_episode_video_streams_episode_video_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_video_streams_episode_video_id ON app_public.episode_video_streams USING btree (episode_video_id);


--
-- Name: idx_episode_video_streams_type; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_video_streams_type ON app_public.episode_video_streams USING btree (type);


--
-- Name: idx_episode_videos_episode_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_videos_episode_id ON app_public.episode_videos USING btree (episode_id);


--
-- Name: idx_episode_videos_type; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_episode_videos_type ON app_public.episode_videos USING btree (type);


--
-- Name: idx_movie_genre_localizations_locale; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_genre_localizations_locale ON app_public.movie_genre_localizations USING btree (locale);


--
-- Name: idx_movie_genre_localizations_movie_genre_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_genre_localizations_movie_genre_id ON app_public.movie_genre_localizations USING btree (movie_genre_id);


--
-- Name: idx_movie_genre_localizations_title_asc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_genre_localizations_title_asc_with_id ON app_public.movie_genre_localizations USING btree (title, movie_genre_id);


--
-- Name: idx_movie_genre_localizations_title_desc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_genre_localizations_title_desc_with_id ON app_public.movie_genre_localizations USING btree (title DESC, movie_genre_id);


--
-- Name: idx_movie_genre_order_no; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_genre_order_no ON app_public.movie_genre USING btree (order_no);


--
-- Name: idx_movie_genres_relation_movie_genre_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_genres_relation_movie_genre_id ON app_public.movie_genres_relation USING btree (movie_genre_id);


--
-- Name: idx_movie_genres_relation_movie_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_genres_relation_movie_id ON app_public.movie_genres_relation USING btree (movie_id);


--
-- Name: idx_movie_genres_relation_order_no; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_genres_relation_order_no ON app_public.movie_genres_relation USING btree (order_no);


--
-- Name: idx_movie_licenses_movie_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_licenses_movie_id ON app_public.movie_licenses USING btree (movie_id);


--
-- Name: idx_movie_localizations_locale; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_localizations_locale ON app_public.movie_localizations USING btree (locale);


--
-- Name: idx_movie_localizations_movie_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_localizations_movie_id ON app_public.movie_localizations USING btree (movie_id);


--
-- Name: idx_movie_localizations_title_asc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_localizations_title_asc_with_id ON app_public.movie_localizations USING btree (title, movie_id);


--
-- Name: idx_movie_localizations_title_desc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_localizations_title_desc_with_id ON app_public.movie_localizations USING btree (title DESC, movie_id);


--
-- Name: idx_movie_video_cue_points_movie_video_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_video_cue_points_movie_video_id ON app_public.movie_video_cue_points USING btree (movie_video_id);


--
-- Name: idx_movie_video_streams_movie_video_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_video_streams_movie_video_id ON app_public.movie_video_streams USING btree (movie_video_id);


--
-- Name: idx_movie_video_streams_type; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_video_streams_type ON app_public.movie_video_streams USING btree (type);


--
-- Name: idx_movie_videos_movie_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_videos_movie_id ON app_public.movie_videos USING btree (movie_id);


--
-- Name: idx_movie_videos_type; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_movie_videos_type ON app_public.movie_videos USING btree (type);


--
-- Name: idx_playlist_channel_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_playlist_channel_id ON app_public.playlist USING btree (channel_id);


--
-- Name: idx_playlist_end_date_time; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_playlist_end_date_time ON app_public.playlist USING btree (end_date_time);


--
-- Name: idx_playlist_start_date_time; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_playlist_start_date_time ON app_public.playlist USING btree (start_date_time);


--
-- Name: idx_program_localizations_locale; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_program_localizations_locale ON app_public.program_localizations USING btree (locale);


--
-- Name: idx_program_localizations_program_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_program_localizations_program_id ON app_public.program_localizations USING btree (program_id);


--
-- Name: idx_program_localizations_title_asc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_program_localizations_title_asc_with_id ON app_public.program_localizations USING btree (title, program_id);


--
-- Name: idx_program_localizations_title_desc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_program_localizations_title_desc_with_id ON app_public.program_localizations USING btree (title DESC, program_id);


--
-- Name: idx_program_playlist_id_sort_index; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_program_playlist_id_sort_index ON app_public.program USING btree (playlist_id, sort_index);


--
-- Name: idx_season_genres_relation_order_no; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_season_genres_relation_order_no ON app_public.season_genres_relation USING btree (order_no);


--
-- Name: idx_season_genres_relation_season_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_season_genres_relation_season_id ON app_public.season_genres_relation USING btree (season_id);


--
-- Name: idx_season_genres_relation_tvshow_genre_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_season_genres_relation_tvshow_genre_id ON app_public.season_genres_relation USING btree (tvshow_genre_id);


--
-- Name: idx_season_images_season_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_season_images_season_id ON app_public.season_images USING btree (season_id);


--
-- Name: idx_season_licenses_season_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_season_licenses_season_id ON app_public.season_licenses USING btree (season_id);


--
-- Name: idx_season_localizations_locale; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_season_localizations_locale ON app_public.season_localizations USING btree (locale);


--
-- Name: idx_season_localizations_season_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_season_localizations_season_id ON app_public.season_localizations USING btree (season_id);


--
-- Name: idx_season_tvshow_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_season_tvshow_id ON app_public.season USING btree (tvshow_id);


--
-- Name: idx_season_video_cue_points_season_video_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_season_video_cue_points_season_video_id ON app_public.season_video_cue_points USING btree (season_video_id);


--
-- Name: idx_season_video_streams_season_video_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_season_video_streams_season_video_id ON app_public.season_video_streams USING btree (season_video_id);


--
-- Name: idx_season_video_streams_type; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_season_video_streams_type ON app_public.season_video_streams USING btree (type);


--
-- Name: idx_season_videos_season_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_season_videos_season_id ON app_public.season_videos USING btree (season_id);


--
-- Name: idx_trgm_channel_localizations_title; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_trgm_channel_localizations_title ON app_public.channel_localizations USING gin (title public.gin_trgm_ops);


--
-- Name: idx_trgm_collection_localizations_title; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_trgm_collection_localizations_title ON app_public.collection_localizations USING gin (title public.gin_trgm_ops);


--
-- Name: idx_trgm_episode_localizations_title; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_trgm_episode_localizations_title ON app_public.episode_localizations USING gin (title public.gin_trgm_ops);


--
-- Name: idx_trgm_movie_genre_localizations_title; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_trgm_movie_genre_localizations_title ON app_public.movie_genre_localizations USING gin (title public.gin_trgm_ops);


--
-- Name: idx_trgm_movie_localizations_title; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_trgm_movie_localizations_title ON app_public.movie_localizations USING gin (title public.gin_trgm_ops);


--
-- Name: idx_trgm_program_localizations_title; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_trgm_program_localizations_title ON app_public.program_localizations USING gin (title public.gin_trgm_ops);


--
-- Name: idx_trgm_tvshow_genre_localizations_title; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_trgm_tvshow_genre_localizations_title ON app_public.tvshow_genre_localizations USING gin (title public.gin_trgm_ops);


--
-- Name: idx_trgm_tvshow_localizations_title; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_trgm_tvshow_localizations_title ON app_public.tvshow_localizations USING gin (title public.gin_trgm_ops);


--
-- Name: idx_tvshow_genre_localizations_locale; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_genre_localizations_locale ON app_public.tvshow_genre_localizations USING btree (locale);


--
-- Name: idx_tvshow_genre_localizations_title_asc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_genre_localizations_title_asc_with_id ON app_public.tvshow_genre_localizations USING btree (title, tvshow_genre_id);


--
-- Name: idx_tvshow_genre_localizations_title_desc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_genre_localizations_title_desc_with_id ON app_public.tvshow_genre_localizations USING btree (title DESC, tvshow_genre_id);


--
-- Name: idx_tvshow_genre_localizations_tvshow_genre_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_genre_localizations_tvshow_genre_id ON app_public.tvshow_genre_localizations USING btree (tvshow_genre_id);


--
-- Name: idx_tvshow_genre_order_no; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_genre_order_no ON app_public.tvshow_genre USING btree (order_no);


--
-- Name: idx_tvshow_genres_relation_order_no; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_genres_relation_order_no ON app_public.tvshow_genres_relation USING btree (order_no);


--
-- Name: idx_tvshow_genres_relation_tvshow_genre_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_genres_relation_tvshow_genre_id ON app_public.tvshow_genres_relation USING btree (tvshow_genre_id);


--
-- Name: idx_tvshow_genres_relation_tvshow_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_genres_relation_tvshow_id ON app_public.tvshow_genres_relation USING btree (tvshow_id);


--
-- Name: idx_tvshow_images_tvshow_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_images_tvshow_id ON app_public.tvshow_images USING btree (tvshow_id);


--
-- Name: idx_tvshow_licenses_tvshow_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_licenses_tvshow_id ON app_public.tvshow_licenses USING btree (tvshow_id);


--
-- Name: idx_tvshow_localizations_locale; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_localizations_locale ON app_public.tvshow_localizations USING btree (locale);


--
-- Name: idx_tvshow_localizations_title_asc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_localizations_title_asc_with_id ON app_public.tvshow_localizations USING btree (title, tvshow_id);


--
-- Name: idx_tvshow_localizations_title_desc_with_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_localizations_title_desc_with_id ON app_public.tvshow_localizations USING btree (title DESC, tvshow_id);


--
-- Name: idx_tvshow_localizations_tvshow_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_localizations_tvshow_id ON app_public.tvshow_localizations USING btree (tvshow_id);


--
-- Name: idx_tvshow_video_cue_points_tvshow_video_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_video_cue_points_tvshow_video_id ON app_public.tvshow_video_cue_points USING btree (tvshow_video_id);


--
-- Name: idx_tvshow_video_streams_tvshow_video_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_video_streams_tvshow_video_id ON app_public.tvshow_video_streams USING btree (tvshow_video_id);


--
-- Name: idx_tvshow_video_streams_type; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_video_streams_type ON app_public.tvshow_video_streams USING btree (type);


--
-- Name: idx_tvshow_videos_tvshow_id; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX idx_tvshow_videos_tvshow_id ON app_public.tvshow_videos USING btree (tvshow_id);


--
-- Name: movie_images_movie_id_idx; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX movie_images_movie_id_idx ON app_public.movie_images USING btree (movie_id);


--
-- Name: program_images_program_id_idx; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX program_images_program_id_idx ON app_public.program_images USING btree (program_id);


--
-- Name: tvshow_genre_order_no_idx; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX tvshow_genre_order_no_idx ON app_public.tvshow_genre USING btree (order_no);


--
-- Name: tvshow_genres_relation_order_no_idx; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX tvshow_genres_relation_order_no_idx ON app_public.tvshow_genres_relation USING btree (order_no);


--
-- Name: tvshow_genres_relation_tvshow_genre_id_idx; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX tvshow_genres_relation_tvshow_genre_id_idx ON app_public.tvshow_genres_relation USING btree (tvshow_genre_id);


--
-- Name: tvshow_genres_relation_tvshow_id_idx; Type: INDEX; Schema: app_public; Owner: -
--

CREATE INDEX tvshow_genres_relation_tvshow_id_idx ON app_public.tvshow_genres_relation USING btree (tvshow_id);


--
-- Name: locales _500_locales_inserted; Type: TRIGGER; Schema: app_public; Owner: -
--

CREATE TRIGGER _500_locales_inserted AFTER INSERT ON app_public.locales FOR EACH STATEMENT EXECUTE FUNCTION app_hidden.tg__locales_inserted();


--
-- Name: channel_images channel_images_channel_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.channel_images
    ADD CONSTRAINT channel_images_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES app_public.channel(id) ON DELETE CASCADE;


--
-- Name: channel_localizations channel_localizations_channel_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.channel_localizations
    ADD CONSTRAINT channel_localizations_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES app_public.channel(id) ON DELETE CASCADE;


--
-- Name: collection_images collection_images_collection_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.collection_images
    ADD CONSTRAINT collection_images_collection_id_fkey FOREIGN KEY (collection_id) REFERENCES app_public.collection(id) ON DELETE CASCADE;


--
-- Name: collection_items_relation collection_items_relation_collection_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.collection_items_relation
    ADD CONSTRAINT collection_items_relation_collection_id_fkey FOREIGN KEY (collection_id) REFERENCES app_public.collection(id) ON DELETE CASCADE;


--
-- Name: collection_localizations collection_localizations_collection_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.collection_localizations
    ADD CONSTRAINT collection_localizations_collection_id_fkey FOREIGN KEY (collection_id) REFERENCES app_public.collection(id) ON DELETE CASCADE;


--
-- Name: episode_genres_relation episode_genres_relation_episode_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_genres_relation
    ADD CONSTRAINT episode_genres_relation_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES app_public.episode(id) ON DELETE CASCADE;


--
-- Name: episode_images episode_images_episode_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_images
    ADD CONSTRAINT episode_images_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES app_public.episode(id) ON DELETE CASCADE;


--
-- Name: episode_licenses episode_licenses_episode_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_licenses
    ADD CONSTRAINT episode_licenses_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES app_public.episode(id) ON DELETE CASCADE;


--
-- Name: episode_localizations episode_localizations_episode_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_localizations
    ADD CONSTRAINT episode_localizations_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES app_public.episode(id) ON DELETE CASCADE;


--
-- Name: episode_video_cue_points episode_video_cue_points_episode_video_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_video_cue_points
    ADD CONSTRAINT episode_video_cue_points_episode_video_id_fkey FOREIGN KEY (episode_video_id) REFERENCES app_public.episode_videos(id) ON DELETE CASCADE;


--
-- Name: episode_video_streams episode_video_streams_episode_video_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_video_streams
    ADD CONSTRAINT episode_video_streams_episode_video_id_fkey FOREIGN KEY (episode_video_id) REFERENCES app_public.episode_videos(id) ON DELETE CASCADE;


--
-- Name: episode_video_streams episode_video_streams_type_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_video_streams
    ADD CONSTRAINT episode_video_streams_type_fkey FOREIGN KEY (type) REFERENCES app_public.video_stream_type(value);


--
-- Name: episode_videos episode_videos_episode_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.episode_videos
    ADD CONSTRAINT episode_videos_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES app_public.episode(id) ON DELETE CASCADE;


--
-- Name: movie_genre_localizations movie_genre_localizations_movie_genre_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_genre_localizations
    ADD CONSTRAINT movie_genre_localizations_movie_genre_id_fkey FOREIGN KEY (movie_genre_id) REFERENCES app_public.movie_genre(id) ON DELETE CASCADE;


--
-- Name: movie_genres_relation movie_genres_relation_movie_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_genres_relation
    ADD CONSTRAINT movie_genres_relation_movie_id_fkey FOREIGN KEY (movie_id) REFERENCES app_public.movie(id) ON DELETE CASCADE;


--
-- Name: movie_images movie_images_movie_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_images
    ADD CONSTRAINT movie_images_movie_id_fkey FOREIGN KEY (movie_id) REFERENCES app_public.movie(id) ON DELETE CASCADE;


--
-- Name: movie_licenses movie_licenses_movie_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_licenses
    ADD CONSTRAINT movie_licenses_movie_id_fkey FOREIGN KEY (movie_id) REFERENCES app_public.movie(id) ON DELETE CASCADE;


--
-- Name: movie_localizations movie_localizations_movie_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_localizations
    ADD CONSTRAINT movie_localizations_movie_id_fkey FOREIGN KEY (movie_id) REFERENCES app_public.movie(id) ON DELETE CASCADE;


--
-- Name: movie_video_cue_points movie_video_cue_points_movie_video_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_video_cue_points
    ADD CONSTRAINT movie_video_cue_points_movie_video_id_fkey FOREIGN KEY (movie_video_id) REFERENCES app_public.movie_videos(id) ON DELETE CASCADE;


--
-- Name: movie_video_streams movie_video_streams_movie_video_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_video_streams
    ADD CONSTRAINT movie_video_streams_movie_video_id_fkey FOREIGN KEY (movie_video_id) REFERENCES app_public.movie_videos(id) ON DELETE CASCADE;


--
-- Name: movie_video_streams movie_video_streams_type_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_video_streams
    ADD CONSTRAINT movie_video_streams_type_fkey FOREIGN KEY (type) REFERENCES app_public.video_stream_type(value);


--
-- Name: movie_videos movie_videos_movie_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.movie_videos
    ADD CONSTRAINT movie_videos_movie_id_fkey FOREIGN KEY (movie_id) REFERENCES app_public.movie(id) ON DELETE CASCADE;


--
-- Name: playlist playlist_channel_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.playlist
    ADD CONSTRAINT playlist_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES app_public.channel(id) ON DELETE CASCADE;


--
-- Name: program_images program_images_program_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.program_images
    ADD CONSTRAINT program_images_program_id_fkey FOREIGN KEY (program_id) REFERENCES app_public.program(id) ON DELETE CASCADE;


--
-- Name: program_localizations program_localizations_program_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.program_localizations
    ADD CONSTRAINT program_localizations_program_id_fkey FOREIGN KEY (program_id) REFERENCES app_public.program(id) ON DELETE CASCADE;


--
-- Name: program program_playlist_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.program
    ADD CONSTRAINT program_playlist_id_fkey FOREIGN KEY (playlist_id) REFERENCES app_public.playlist(id) ON DELETE CASCADE;


--
-- Name: season_genres_relation season_genres_relation_season_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_genres_relation
    ADD CONSTRAINT season_genres_relation_season_id_fkey FOREIGN KEY (season_id) REFERENCES app_public.season(id) ON DELETE CASCADE;


--
-- Name: season_images season_images_season_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_images
    ADD CONSTRAINT season_images_season_id_fkey FOREIGN KEY (season_id) REFERENCES app_public.season(id) ON DELETE CASCADE;


--
-- Name: season_licenses season_licenses_season_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_licenses
    ADD CONSTRAINT season_licenses_season_id_fkey FOREIGN KEY (season_id) REFERENCES app_public.season(id) ON DELETE CASCADE;


--
-- Name: season_localizations season_localizations_season_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_localizations
    ADD CONSTRAINT season_localizations_season_id_fkey FOREIGN KEY (season_id) REFERENCES app_public.season(id) ON DELETE CASCADE;


--
-- Name: season_video_cue_points season_video_cue_points_season_video_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_video_cue_points
    ADD CONSTRAINT season_video_cue_points_season_video_id_fkey FOREIGN KEY (season_video_id) REFERENCES app_public.season_videos(id) ON DELETE CASCADE;


--
-- Name: season_video_streams season_video_streams_season_video_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_video_streams
    ADD CONSTRAINT season_video_streams_season_video_id_fkey FOREIGN KEY (season_video_id) REFERENCES app_public.season_videos(id) ON DELETE CASCADE;


--
-- Name: season_video_streams season_video_streams_type_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_video_streams
    ADD CONSTRAINT season_video_streams_type_fkey FOREIGN KEY (type) REFERENCES app_public.video_stream_type(value);


--
-- Name: season_videos season_videos_season_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.season_videos
    ADD CONSTRAINT season_videos_season_id_fkey FOREIGN KEY (season_id) REFERENCES app_public.season(id) ON DELETE CASCADE;


--
-- Name: tvshow_genre_localizations tvshow_genre_localizations_tvshow_genre_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_genre_localizations
    ADD CONSTRAINT tvshow_genre_localizations_tvshow_genre_id_fkey FOREIGN KEY (tvshow_genre_id) REFERENCES app_public.tvshow_genre(id) ON DELETE CASCADE;


--
-- Name: tvshow_genres_relation tvshow_genres_relation_tvshow_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_genres_relation
    ADD CONSTRAINT tvshow_genres_relation_tvshow_id_fkey FOREIGN KEY (tvshow_id) REFERENCES app_public.tvshow(id) ON DELETE CASCADE;


--
-- Name: tvshow_images tvshow_images_tvshow_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_images
    ADD CONSTRAINT tvshow_images_tvshow_id_fkey FOREIGN KEY (tvshow_id) REFERENCES app_public.tvshow(id) ON DELETE CASCADE;


--
-- Name: tvshow_licenses tvshow_licenses_tvshow_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_licenses
    ADD CONSTRAINT tvshow_licenses_tvshow_id_fkey FOREIGN KEY (tvshow_id) REFERENCES app_public.tvshow(id) ON DELETE CASCADE;


--
-- Name: tvshow_localizations tvshow_localizations_tvshow_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_localizations
    ADD CONSTRAINT tvshow_localizations_tvshow_id_fkey FOREIGN KEY (tvshow_id) REFERENCES app_public.tvshow(id) ON DELETE CASCADE;


--
-- Name: tvshow_video_cue_points tvshow_video_cue_points_tvshow_video_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_video_cue_points
    ADD CONSTRAINT tvshow_video_cue_points_tvshow_video_id_fkey FOREIGN KEY (tvshow_video_id) REFERENCES app_public.tvshow_videos(id) ON DELETE CASCADE;


--
-- Name: tvshow_video_streams tvshow_video_streams_tvshow_video_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_video_streams
    ADD CONSTRAINT tvshow_video_streams_tvshow_video_id_fkey FOREIGN KEY (tvshow_video_id) REFERENCES app_public.tvshow_videos(id) ON DELETE CASCADE;


--
-- Name: tvshow_video_streams tvshow_video_streams_type_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_video_streams
    ADD CONSTRAINT tvshow_video_streams_type_fkey FOREIGN KEY (type) REFERENCES app_public.video_stream_type(value);


--
-- Name: tvshow_videos tvshow_videos_tvshow_id_fkey; Type: FK CONSTRAINT; Schema: app_public; Owner: -
--

ALTER TABLE ONLY app_public.tvshow_videos
    ADD CONSTRAINT tvshow_videos_tvshow_id_fkey FOREIGN KEY (tvshow_id) REFERENCES app_public.tvshow(id) ON DELETE CASCADE;


--
-- Name: SCHEMA app_hidden; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA app_hidden TO catalog_service_gql_role;


--
-- Name: SCHEMA app_public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA app_public TO catalog_service_gql_role;
GRANT USAGE ON SCHEMA app_public TO catalog_service_login;


--
-- Name: SCHEMA ax_define; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA ax_define TO catalog_service_gql_role;


--
-- Name: SCHEMA ax_utils; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA ax_utils TO catalog_service_gql_role;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO catalog_service_owner;
GRANT USAGE ON SCHEMA public TO catalog_service_gql_role;


--
-- Name: TABLE inbox; Type: ACL; Schema: app_hidden; Owner: -
--

GRANT SELECT,INSERT,DELETE ON TABLE app_hidden.inbox TO catalog_service_gql_role;


--
-- Name: COLUMN inbox.locked_until; Type: ACL; Schema: app_hidden; Owner: -
--

GRANT UPDATE(locked_until) ON TABLE app_hidden.inbox TO catalog_service_gql_role;


--
-- Name: COLUMN inbox.processed_at; Type: ACL; Schema: app_hidden; Owner: -
--

GRANT UPDATE(processed_at) ON TABLE app_hidden.inbox TO catalog_service_gql_role;


--
-- Name: COLUMN inbox.abandoned_at; Type: ACL; Schema: app_hidden; Owner: -
--

GRANT UPDATE(abandoned_at) ON TABLE app_hidden.inbox TO catalog_service_gql_role;


--
-- Name: COLUMN inbox.started_attempts; Type: ACL; Schema: app_hidden; Owner: -
--

GRANT UPDATE(started_attempts) ON TABLE app_hidden.inbox TO catalog_service_gql_role;


--
-- Name: COLUMN inbox.finished_attempts; Type: ACL; Schema: app_hidden; Owner: -
--

GRANT UPDATE(finished_attempts) ON TABLE app_hidden.inbox TO catalog_service_gql_role;


--
-- Name: FUNCTION next_inbox_messages(max_size integer, lock_ms integer); Type: ACL; Schema: app_hidden; Owner: -
--

REVOKE ALL ON FUNCTION app_hidden.next_inbox_messages(max_size integer, lock_ms integer) FROM PUBLIC;
GRANT ALL ON FUNCTION app_hidden.next_inbox_messages(max_size integer, lock_ms integer) TO catalog_service_gql_role;


--
-- Name: FUNCTION tg__locales_inserted(); Type: ACL; Schema: app_hidden; Owner: -
--

REVOKE ALL ON FUNCTION app_hidden.tg__locales_inserted() FROM PUBLIC;
GRANT ALL ON FUNCTION app_hidden.tg__locales_inserted() TO catalog_service_gql_role;


--
-- Name: FUNCTION add_default_placeholder_localizations(newlocale text); Type: ACL; Schema: app_private; Owner: -
--

REVOKE ALL ON FUNCTION app_private.add_default_placeholder_localizations(newlocale text) FROM PUBLIC;


--
-- Name: FUNCTION define_localization_view(tablename text, localizationstablename text, fkcolumn text); Type: ACL; Schema: app_private; Owner: -
--

REVOKE ALL ON FUNCTION app_private.define_localization_view(tablename text, localizationstablename text, fkcolumn text) FROM PUBLIC;


--
-- Name: FUNCTION set_initial_locales(); Type: ACL; Schema: app_private; Owner: -
--

REVOKE ALL ON FUNCTION app_private.set_initial_locales() FROM PUBLIC;


--
-- Name: FUNCTION column_exists(columnname text, tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.column_exists(columnname text, tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.column_exists(columnname text, tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION create_enum_table(enumname text, schemaname text, loginroleplaceholder text, enumvalues text, enumdesriptions text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.create_enum_table(enumname text, schemaname text, loginroleplaceholder text, enumvalues text, enumdesriptions text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.create_enum_table(enumname text, schemaname text, loginroleplaceholder text, enumvalues text, enumdesriptions text) TO catalog_service_gql_role;


--
-- Name: FUNCTION create_messaging_counter_table(); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.create_messaging_counter_table() FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.create_messaging_counter_table() TO catalog_service_gql_role;


--
-- Name: FUNCTION create_messaging_health_monitoring(); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.create_messaging_health_monitoring() FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.create_messaging_health_monitoring() TO catalog_service_gql_role;


--
-- Name: FUNCTION create_trx_next_messages_function(trx_next_message_function_schema text, trx_table_schema text, trx_table_name text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.create_trx_next_messages_function(trx_next_message_function_schema text, trx_table_schema text, trx_table_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.create_trx_next_messages_function(trx_next_message_function_schema text, trx_table_schema text, trx_table_name text) TO catalog_service_gql_role;


--
-- Name: FUNCTION create_trx_table(trx_schema text, trx_table_name text, additional_roles_to_grant text[], concurrency text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.create_trx_table(trx_schema text, trx_table_name text, additional_roles_to_grant text[], concurrency text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.create_trx_table(trx_schema text, trx_table_name text, additional_roles_to_grant text[], concurrency text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_audit_date_fields_on_table(tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_audit_date_fields_on_table(tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_audit_date_fields_on_table(tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_audit_user_fields_on_table(tablename text, schemaname text, defaultusername text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_audit_user_fields_on_table(tablename text, schemaname text, defaultusername text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_audit_user_fields_on_table(tablename text, schemaname text, defaultusername text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_authentication(readpermissions text, modifypermissions text, tablename text, schemaname text, additionalrls text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_authentication(readpermissions text, modifypermissions text, tablename text, schemaname text, additionalrls text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_authentication(readpermissions text, modifypermissions text, tablename text, schemaname text, additionalrls text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_deferred_unique_constraint(fieldname text, tablename text, schemaname text, constraintname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_deferred_unique_constraint(fieldname text, tablename text, schemaname text, constraintname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_deferred_unique_constraint(fieldname text, tablename text, schemaname text, constraintname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_end_user_authentication(tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_end_user_authentication(tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_end_user_authentication(tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_index(fieldname text, tablename text, schemaname text, indexname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_index(fieldname text, tablename text, schemaname text, indexname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_index(fieldname text, tablename text, schemaname text, indexname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_indexes_with_id(fieldname text, tablename text, schemaname text, indexnameasc text, indexnamedesc text, idfieldname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_indexes_with_id(fieldname text, tablename text, schemaname text, indexnameasc text, indexnamedesc text, idfieldname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_indexes_with_id(fieldname text, tablename text, schemaname text, indexnameasc text, indexnamedesc text, idfieldname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_like_index(fieldname text, tablename text, schemaname text, indexname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_like_index(fieldname text, tablename text, schemaname text, indexname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_like_index(fieldname text, tablename text, schemaname text, indexname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_multiple_field_index(fieldnames text[], tablename text, schemaname text, indexname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_multiple_field_index(fieldnames text[], tablename text, schemaname text, indexname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_multiple_field_index(fieldnames text[], tablename text, schemaname text, indexname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_readonly_authentication(readpermissions text, tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_readonly_authentication(readpermissions text, tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_readonly_authentication(readpermissions text, tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_subscription_triggers(idcolumn text, tablename text, schemaname text, maintablename text, eventtype text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_subscription_triggers(idcolumn text, tablename text, schemaname text, maintablename text, eventtype text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_subscription_triggers(idcolumn text, tablename text, schemaname text, maintablename text, eventtype text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_tenant_environment_trigger(tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_tenant_environment_trigger(tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_tenant_environment_trigger(tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_timestamp_propagation(idcolumnname text, tablename text, schemaname text, foreignidcolumnname text, foreigntablename text, foreignschemaname text, functionname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_timestamp_propagation(idcolumnname text, tablename text, schemaname text, foreignidcolumnname text, foreigntablename text, foreignschemaname text, functionname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_timestamp_propagation(idcolumnname text, tablename text, schemaname text, foreignidcolumnname text, foreigntablename text, foreignschemaname text, functionname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_timestamps_trigger(tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_timestamps_trigger(tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_timestamps_trigger(tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_unique_constraint(fieldname text, tablename text, schemaname text, constraintname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_unique_constraint(fieldname text, tablename text, schemaname text, constraintname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_unique_constraint(fieldname text, tablename text, schemaname text, constraintname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_unique_index(fieldname text, tablename text, schemaname text, indexname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_unique_index(fieldname text, tablename text, schemaname text, indexname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_unique_index(fieldname text, tablename text, schemaname text, indexname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_user_id_on_table(tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_user_id_on_table(tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_user_id_on_table(tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_user_id_trigger(tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_user_id_trigger(tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_user_id_trigger(tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION define_users_trigger(tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.define_users_trigger(tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.define_users_trigger(tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION drop_index(fieldname text, tablename text, indexname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.drop_index(fieldname text, tablename text, indexname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.drop_index(fieldname text, tablename text, indexname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION drop_indexes_with_id(fieldname text, tablename text, indexnameasc text, indexnamedesc text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.drop_indexes_with_id(fieldname text, tablename text, indexnameasc text, indexnamedesc text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.drop_indexes_with_id(fieldname text, tablename text, indexnameasc text, indexnamedesc text) TO catalog_service_gql_role;


--
-- Name: FUNCTION drop_like_index(fieldname text, tablename text, indexname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.drop_like_index(fieldname text, tablename text, indexname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.drop_like_index(fieldname text, tablename text, indexname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION drop_multiple_field_index(fieldnames text[], tablename text, indexname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.drop_multiple_field_index(fieldnames text[], tablename text, indexname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.drop_multiple_field_index(fieldnames text[], tablename text, indexname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION drop_tenant_environment_trigger(tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.drop_tenant_environment_trigger(tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.drop_tenant_environment_trigger(tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION drop_timestamp_propagation(idcolumnname text, tablename text, schemaname text, foreignidcolumnname text, foreigntablename text, foreignschemaname text, functionname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.drop_timestamp_propagation(idcolumnname text, tablename text, schemaname text, foreignidcolumnname text, foreigntablename text, foreignschemaname text, functionname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.drop_timestamp_propagation(idcolumnname text, tablename text, schemaname text, foreignidcolumnname text, foreigntablename text, foreignschemaname text, functionname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION drop_timestamps_trigger(tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.drop_timestamps_trigger(tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.drop_timestamps_trigger(tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION drop_unique_constraint(fieldname text, tablename text, schemaname text, constraintname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.drop_unique_constraint(fieldname text, tablename text, schemaname text, constraintname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.drop_unique_constraint(fieldname text, tablename text, schemaname text, constraintname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION drop_user_id_trigger(tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.drop_user_id_trigger(tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.drop_user_id_trigger(tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION drop_users_trigger(tablename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.drop_users_trigger(tablename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.drop_users_trigger(tablename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION live_suggestions_endpoint(propertyname text, typename text, schemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.live_suggestions_endpoint(propertyname text, typename text, schemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.live_suggestions_endpoint(propertyname text, typename text, schemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION pgmemento_create_table_audit(table_name text, schema_name text, audit_id_column_name text, log_old_data boolean, log_new_data boolean, log_state boolean); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.pgmemento_create_table_audit(table_name text, schema_name text, audit_id_column_name text, log_old_data boolean, log_new_data boolean, log_state boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.pgmemento_create_table_audit(table_name text, schema_name text, audit_id_column_name text, log_old_data boolean, log_new_data boolean, log_state boolean) TO catalog_service_gql_role;


--
-- Name: FUNCTION pgmemento_delete_old_logs(age interval); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.pgmemento_delete_old_logs(age interval) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.pgmemento_delete_old_logs(age interval) TO catalog_service_gql_role;


--
-- Name: FUNCTION set_enum_as_column_type(columnname text, tablename text, schemaname text, enumname text, enumschemaname text, defaultenumvalue text, notnulloptions text, constraintname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.set_enum_as_column_type(columnname text, tablename text, schemaname text, enumname text, enumschemaname text, defaultenumvalue text, notnulloptions text, constraintname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.set_enum_as_column_type(columnname text, tablename text, schemaname text, enumname text, enumschemaname text, defaultenumvalue text, notnulloptions text, constraintname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION set_enum_domain(columnname text, tablename text, schemaname text, enumname text, enumschemaname text); Type: ACL; Schema: ax_define; Owner: -
--

REVOKE ALL ON FUNCTION ax_define.set_enum_domain(columnname text, tablename text, schemaname text, enumname text, enumschemaname text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_define.set_enum_domain(columnname text, tablename text, schemaname text, enumname text, enumschemaname text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_has_allowed_value(input_value text, allowed_values text[], error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_has_allowed_value(input_value text, allowed_values text[], error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_has_allowed_value(input_value text, allowed_values text[], error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_is_base64(input_value text, error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_is_base64(input_value text, error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_is_base64(input_value text, error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_is_identifier_key(input_value text, error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_is_identifier_key(input_value text, error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_is_identifier_key(input_value text, error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_is_trimmed(input_value text, error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_is_trimmed(input_value text, error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_is_trimmed(input_value text, error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_is_url(input_value text, error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_is_url(input_value text, error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_is_url(input_value text, error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_matches_pattern(input_value text, pattern text, error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_matches_pattern(input_value text, pattern text, error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_matches_pattern(input_value text, pattern text, error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_max_length(input_value text, max_length integer, error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_max_length(input_value text, max_length integer, error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_max_length(input_value text, max_length integer, error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_max_value(input_value numeric, max_value numeric, error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_max_value(input_value numeric, max_value numeric, error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_max_value(input_value numeric, max_value numeric, error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_min_length(input_value text, min_length integer, error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_min_length(input_value text, min_length integer, error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_min_length(input_value text, min_length integer, error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_min_value(input_value numeric, min_value numeric, error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_min_value(input_value numeric, min_value numeric, error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_min_value(input_value numeric, min_value numeric, error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_not_default_uuid(input_value uuid, default_uuid uuid, error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_not_default_uuid(input_value uuid, default_uuid uuid, error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_not_default_uuid(input_value uuid, default_uuid uuid, error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_not_empty(input_value text, error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_not_empty(input_value text, error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_not_empty(input_value text, error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_not_empty_array(input_value text[], error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_not_empty_array(input_value text[], error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_not_empty_array(input_value text[], error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION constraint_starts_with(input_value text, prefix_value text, error_message text, error_code text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.constraint_starts_with(input_value text, prefix_value text, error_message text, error_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.constraint_starts_with(input_value text, prefix_value text, error_message text, error_code text) TO catalog_service_gql_role;


--
-- Name: FUNCTION current_environment_id(); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.current_environment_id() FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.current_environment_id() TO catalog_service_gql_role;


--
-- Name: FUNCTION current_tenant_id(); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.current_tenant_id() FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.current_tenant_id() TO catalog_service_gql_role;


--
-- Name: FUNCTION current_user_id(); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.current_user_id() FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.current_user_id() TO catalog_service_gql_role;


--
-- Name: FUNCTION raise_error(error_message text, error_code text, VARIADIC placeholder_values text[]); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.raise_error(error_message text, error_code text, VARIADIC placeholder_values text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.raise_error(error_message text, error_code text, VARIADIC placeholder_values text[]) TO catalog_service_gql_role;


--
-- Name: FUNCTION tg__graphql_subscription(); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.tg__graphql_subscription() FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.tg__graphql_subscription() TO catalog_service_gql_role;


--
-- Name: FUNCTION tg__tenant_environment(); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.tg__tenant_environment() FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.tg__tenant_environment() TO catalog_service_gql_role;


--
-- Name: FUNCTION tg__tenant_environment_on_delete(); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.tg__tenant_environment_on_delete() FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.tg__tenant_environment_on_delete() TO catalog_service_gql_role;


--
-- Name: FUNCTION tg__timestamps(); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.tg__timestamps() FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.tg__timestamps() TO catalog_service_gql_role;


--
-- Name: FUNCTION tg__user_id(); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.tg__user_id() FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.tg__user_id() TO catalog_service_gql_role;


--
-- Name: FUNCTION tg__username(); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.tg__username() FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.tg__username() TO catalog_service_gql_role;


--
-- Name: FUNCTION user_has_permission(required_permissions text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.user_has_permission(required_permissions text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.user_has_permission(required_permissions text) TO catalog_service_gql_role;


--
-- Name: FUNCTION user_has_permission_and_tag(required_permissions text, fieldvalue text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.user_has_permission_and_tag(required_permissions text, fieldvalue text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.user_has_permission_and_tag(required_permissions text, fieldvalue text) TO catalog_service_gql_role;


--
-- Name: FUNCTION user_has_setting(required_settings text, local_variable_field text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.user_has_setting(required_settings text, local_variable_field text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.user_has_setting(required_settings text, local_variable_field text) TO catalog_service_gql_role;


--
-- Name: FUNCTION user_has_tag(required_permissions text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.user_has_tag(required_permissions text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.user_has_tag(required_permissions text) TO catalog_service_gql_role;


--
-- Name: FUNCTION validate_identifier_length(identifier text, hint text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.validate_identifier_length(identifier text, hint text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.validate_identifier_length(identifier text, hint text) TO catalog_service_gql_role;


--
-- Name: FUNCTION validation_is_base64(input_value text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.validation_is_base64(input_value text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.validation_is_base64(input_value text) TO catalog_service_gql_role;


--
-- Name: FUNCTION validation_is_identifier_key(input_value text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.validation_is_identifier_key(input_value text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.validation_is_identifier_key(input_value text) TO catalog_service_gql_role;


--
-- Name: FUNCTION validation_is_optional_url(input_value text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.validation_is_optional_url(input_value text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.validation_is_optional_url(input_value text) TO catalog_service_gql_role;


--
-- Name: FUNCTION validation_is_trimmed(input_value text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.validation_is_trimmed(input_value text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.validation_is_trimmed(input_value text) TO catalog_service_gql_role;


--
-- Name: FUNCTION validation_is_url(input_value text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.validation_is_url(input_value text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.validation_is_url(input_value text) TO catalog_service_gql_role;


--
-- Name: FUNCTION validation_not_empty(input_value text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.validation_not_empty(input_value text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.validation_not_empty(input_value text) TO catalog_service_gql_role;


--
-- Name: FUNCTION validation_not_empty_array(input_value text[]); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.validation_not_empty_array(input_value text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.validation_not_empty_array(input_value text[]) TO catalog_service_gql_role;


--
-- Name: FUNCTION validation_starts_with(input_value text, prefix_value text); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.validation_starts_with(input_value text, prefix_value text) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.validation_starts_with(input_value text, prefix_value text) TO catalog_service_gql_role;


--
-- Name: FUNCTION validation_valid_url_array(input_value text[]); Type: ACL; Schema: ax_utils; Owner: -
--

REVOKE ALL ON FUNCTION ax_utils.validation_valid_url_array(input_value text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION ax_utils.validation_valid_url_array(input_value text[]) TO catalog_service_gql_role;


--
-- Name: TABLE channel; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.channel TO catalog_service_gql_role;


--
-- Name: TABLE channel_images; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.channel_images TO catalog_service_gql_role;


--
-- Name: SEQUENCE channel_images_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.channel_images_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE channel_localizations; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.channel_localizations TO catalog_service_gql_role;


--
-- Name: SEQUENCE channel_localizations_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.channel_localizations_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE channel_view; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.channel_view TO catalog_service_gql_role;


--
-- Name: TABLE collection; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.collection TO catalog_service_gql_role;


--
-- Name: TABLE collection_images; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.collection_images TO catalog_service_gql_role;


--
-- Name: SEQUENCE collection_images_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.collection_images_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE collection_items_relation; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.collection_items_relation TO catalog_service_gql_role;


--
-- Name: SEQUENCE collection_items_relation_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.collection_items_relation_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE collection_localizations; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.collection_localizations TO catalog_service_gql_role;


--
-- Name: SEQUENCE collection_localizations_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.collection_localizations_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE collection_view; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.collection_view TO catalog_service_gql_role;


--
-- Name: TABLE episode; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.episode TO catalog_service_gql_role;


--
-- Name: TABLE episode_genres_relation; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.episode_genres_relation TO catalog_service_gql_role;


--
-- Name: SEQUENCE episode_genres_relation_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.episode_genres_relation_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE episode_images; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.episode_images TO catalog_service_gql_role;


--
-- Name: SEQUENCE episode_images_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.episode_images_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE episode_licenses; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.episode_licenses TO catalog_service_gql_role;


--
-- Name: SEQUENCE episode_licenses_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.episode_licenses_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE episode_localizations; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.episode_localizations TO catalog_service_gql_role;


--
-- Name: SEQUENCE episode_localizations_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.episode_localizations_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE episode_video_cue_points; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.episode_video_cue_points TO catalog_service_gql_role;


--
-- Name: SEQUENCE episode_video_cue_points_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.episode_video_cue_points_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE episode_video_streams; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.episode_video_streams TO catalog_service_gql_role;


--
-- Name: SEQUENCE episode_video_streams_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.episode_video_streams_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE episode_videos; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.episode_videos TO catalog_service_gql_role;


--
-- Name: SEQUENCE episode_videos_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.episode_videos_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE episode_view; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.episode_view TO catalog_service_gql_role;


--
-- Name: TABLE locales; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.locales TO catalog_service_gql_role;


--
-- Name: TABLE movie; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.movie TO catalog_service_gql_role;


--
-- Name: TABLE movie_genre; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.movie_genre TO catalog_service_gql_role;


--
-- Name: TABLE movie_genre_localizations; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.movie_genre_localizations TO catalog_service_gql_role;


--
-- Name: SEQUENCE movie_genre_localizations_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.movie_genre_localizations_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE movie_genre_view; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.movie_genre_view TO catalog_service_gql_role;


--
-- Name: TABLE movie_genres_relation; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.movie_genres_relation TO catalog_service_gql_role;


--
-- Name: SEQUENCE movie_genres_relation_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.movie_genres_relation_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE movie_images; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.movie_images TO catalog_service_gql_role;


--
-- Name: SEQUENCE movie_images_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.movie_images_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE movie_licenses; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.movie_licenses TO catalog_service_gql_role;


--
-- Name: SEQUENCE movie_licenses_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.movie_licenses_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE movie_localizations; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.movie_localizations TO catalog_service_gql_role;


--
-- Name: SEQUENCE movie_localizations_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.movie_localizations_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE movie_video_cue_points; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.movie_video_cue_points TO catalog_service_gql_role;


--
-- Name: SEQUENCE movie_video_cue_points_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.movie_video_cue_points_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE movie_video_streams; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.movie_video_streams TO catalog_service_gql_role;


--
-- Name: SEQUENCE movie_video_streams_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.movie_video_streams_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE movie_videos; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.movie_videos TO catalog_service_gql_role;


--
-- Name: SEQUENCE movie_videos_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.movie_videos_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE movie_view; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.movie_view TO catalog_service_gql_role;


--
-- Name: TABLE playlist; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.playlist TO catalog_service_gql_role;


--
-- Name: TABLE program; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.program TO catalog_service_gql_role;


--
-- Name: SEQUENCE program_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.program_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE program_images; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.program_images TO catalog_service_gql_role;


--
-- Name: SEQUENCE program_images_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.program_images_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE program_localizations; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.program_localizations TO catalog_service_gql_role;


--
-- Name: SEQUENCE program_localizations_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.program_localizations_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE program_view; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.program_view TO catalog_service_gql_role;


--
-- Name: TABLE season; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.season TO catalog_service_gql_role;


--
-- Name: TABLE season_genres_relation; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.season_genres_relation TO catalog_service_gql_role;


--
-- Name: SEQUENCE season_genres_relation_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.season_genres_relation_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE season_images; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.season_images TO catalog_service_gql_role;


--
-- Name: SEQUENCE season_images_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.season_images_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE season_licenses; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.season_licenses TO catalog_service_gql_role;


--
-- Name: SEQUENCE season_licenses_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.season_licenses_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE season_localizations; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.season_localizations TO catalog_service_gql_role;


--
-- Name: SEQUENCE season_localizations_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.season_localizations_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE season_video_cue_points; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.season_video_cue_points TO catalog_service_gql_role;


--
-- Name: SEQUENCE season_video_cue_points_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.season_video_cue_points_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE season_video_streams; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.season_video_streams TO catalog_service_gql_role;


--
-- Name: SEQUENCE season_video_streams_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.season_video_streams_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE season_videos; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.season_videos TO catalog_service_gql_role;


--
-- Name: SEQUENCE season_videos_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.season_videos_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE season_view; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.season_view TO catalog_service_gql_role;


--
-- Name: TABLE tvshow; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.tvshow TO catalog_service_gql_role;


--
-- Name: TABLE tvshow_genre; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.tvshow_genre TO catalog_service_gql_role;


--
-- Name: TABLE tvshow_genre_localizations; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.tvshow_genre_localizations TO catalog_service_gql_role;


--
-- Name: SEQUENCE tvshow_genre_localizations_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.tvshow_genre_localizations_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE tvshow_genre_view; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.tvshow_genre_view TO catalog_service_gql_role;


--
-- Name: TABLE tvshow_genres_relation; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.tvshow_genres_relation TO catalog_service_gql_role;


--
-- Name: SEQUENCE tvshow_genres_relation_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.tvshow_genres_relation_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE tvshow_images; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.tvshow_images TO catalog_service_gql_role;


--
-- Name: SEQUENCE tvshow_images_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.tvshow_images_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE tvshow_licenses; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.tvshow_licenses TO catalog_service_gql_role;


--
-- Name: SEQUENCE tvshow_licenses_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.tvshow_licenses_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE tvshow_localizations; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.tvshow_localizations TO catalog_service_gql_role;


--
-- Name: SEQUENCE tvshow_localizations_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.tvshow_localizations_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE tvshow_video_cue_points; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.tvshow_video_cue_points TO catalog_service_gql_role;


--
-- Name: SEQUENCE tvshow_video_cue_points_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.tvshow_video_cue_points_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE tvshow_video_streams; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.tvshow_video_streams TO catalog_service_gql_role;


--
-- Name: SEQUENCE tvshow_video_streams_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.tvshow_video_streams_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE tvshow_videos; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.tvshow_videos TO catalog_service_gql_role;


--
-- Name: SEQUENCE tvshow_videos_id_seq; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE app_public.tvshow_videos_id_seq TO catalog_service_gql_role;


--
-- Name: TABLE tvshow_view; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.tvshow_view TO catalog_service_gql_role;


--
-- Name: TABLE video_stream_type; Type: ACL; Schema: app_public; Owner: -
--

GRANT SELECT ON TABLE app_public.video_stream_type TO catalog_service_login;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: app_hidden; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE catalog_service_owner IN SCHEMA app_hidden GRANT SELECT,USAGE ON SEQUENCES TO catalog_service_gql_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: app_hidden; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE catalog_service_owner IN SCHEMA app_hidden GRANT ALL ON FUNCTIONS TO catalog_service_gql_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: app_public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE catalog_service_owner IN SCHEMA app_public GRANT SELECT,USAGE ON SEQUENCES TO catalog_service_gql_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: app_public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE catalog_service_owner IN SCHEMA app_public GRANT ALL ON FUNCTIONS TO catalog_service_gql_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: ax_define; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE catalog_service_owner IN SCHEMA ax_define GRANT SELECT,USAGE ON SEQUENCES TO catalog_service_gql_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: ax_define; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE catalog_service_owner IN SCHEMA ax_define GRANT ALL ON FUNCTIONS TO catalog_service_gql_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: ax_utils; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE catalog_service_owner IN SCHEMA ax_utils GRANT SELECT,USAGE ON SEQUENCES TO catalog_service_gql_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: ax_utils; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE catalog_service_owner IN SCHEMA ax_utils GRANT ALL ON FUNCTIONS TO catalog_service_gql_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE catalog_service_owner IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES TO catalog_service_gql_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE catalog_service_owner IN SCHEMA public GRANT ALL ON FUNCTIONS TO catalog_service_gql_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: -; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE catalog_service_owner REVOKE ALL ON FUNCTIONS FROM PUBLIC;


--
-- Name: postgraphile_watch_ddl; Type: EVENT TRIGGER; Schema: -; Owner: -
--

CREATE EVENT TRIGGER postgraphile_watch_ddl ON ddl_command_end
         WHEN TAG IN ('ALTER AGGREGATE', 'ALTER DOMAIN', 'ALTER EXTENSION', 'ALTER FOREIGN TABLE', 'ALTER FUNCTION', 'ALTER POLICY', 'ALTER SCHEMA', 'ALTER TABLE', 'ALTER TYPE', 'ALTER VIEW', 'COMMENT', 'CREATE AGGREGATE', 'CREATE DOMAIN', 'CREATE EXTENSION', 'CREATE FOREIGN TABLE', 'CREATE FUNCTION', 'CREATE INDEX', 'CREATE POLICY', 'CREATE RULE', 'CREATE SCHEMA', 'CREATE TABLE', 'CREATE TABLE AS', 'CREATE VIEW', 'DROP AGGREGATE', 'DROP DOMAIN', 'DROP EXTENSION', 'DROP FOREIGN TABLE', 'DROP FUNCTION', 'DROP INDEX', 'DROP OWNED', 'DROP POLICY', 'DROP RULE', 'DROP SCHEMA', 'DROP TABLE', 'DROP TYPE', 'DROP VIEW', 'GRANT', 'REVOKE', 'SELECT INTO')
   EXECUTE FUNCTION postgraphile_watch.notify_watchers_ddl();


--
-- Name: postgraphile_watch_drop; Type: EVENT TRIGGER; Schema: -; Owner: -
--

CREATE EVENT TRIGGER postgraphile_watch_drop ON sql_drop
   EXECUTE FUNCTION postgraphile_watch.notify_watchers_drop();


--
-- PostgreSQL database dump complete
--

