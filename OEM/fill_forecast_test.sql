SET SERVEROUTPUT ON;
SET DEFINE OFF;

ALTER SESSION SET CONTAINER = DEV;

DECLARE
    v_ts_name   VARCHAR2(30) := 'TBS_FORECAST_TEST';
    v_user_name VARCHAR2(30) := 'FORECAST_USER';
    v_sql       VARCHAR2(1000);
    v_exists    NUMBER;
BEGIN
    -- Create the tablespace + user only on the very first run — safe to
    -- re-run this whole script every "day" without recreating anything.
    SELECT COUNT(*) INTO v_exists FROM dba_tablespaces WHERE tablespace_name = v_ts_name;
    IF v_exists = 0 THEN
        EXECUTE IMMEDIATE 'CREATE TABLESPACE ' || v_ts_name ||
                           ' DATAFILE ''' || v_ts_name || '.dbf'' SIZE 50M ' ||
                           ' AUTOEXTEND OFF EXTENT MANAGEMENT LOCAL UNIFORM SIZE 64K';
        DBMS_OUTPUT.PUT_LINE('Created tablespace ' || v_ts_name || ' (50MB, AUTOEXTEND OFF)');
    END IF;

    SELECT COUNT(*) INTO v_exists FROM dba_users WHERE username = v_user_name;
    IF v_exists = 0 THEN
        EXECUTE IMMEDIATE 'CREATE USER ' || v_user_name || ' IDENTIFIED BY "TestPassword123#" ' ||
                           ' DEFAULT TABLESPACE ' || v_ts_name || ' TEMPORARY TABLESPACE temp';
        EXECUTE IMMEDIATE 'GRANT CONNECT, RESOURCE TO ' || v_user_name;
        EXECUTE IMMEDIATE 'ALTER USER ' || v_user_name || ' QUOTA UNLIMITED ON ' || v_ts_name;
        DBMS_OUTPUT.PUT_LINE('Created user ' || v_user_name);
    END IF;

    BEGIN
        EXECUTE IMMEDIATE 'CREATE TABLE ' || v_user_name || '.fill_table (id NUMBER, filler_data VARCHAR2(4000))';
    EXCEPTION WHEN OTHERS THEN NULL; -- already exists after the first run
    END;

    -- Add a MODEST, fixed increment each time this runs — small enough
    -- that several runs are needed to approach the breach threshold,
    -- unlike the original 5alerts.sql which deliberately overshoots
    -- instantly. Roughly ~10-15% of capacity per run at these settings
    -- (an estimate, not verified against a real instance — check actual
    -- usage after each run with the query below and adjust the loop
    -- count if it's climbing too fast or slow).
    BEGIN
        FOR j IN 1..3 LOOP
            v_sql := 'INSERT /*+ APPEND */ INTO ' || v_user_name || '.fill_table ' ||
                     'SELECT LEVEL, RPAD(''X'', 4000, ''X'') FROM DUAL CONNECT BY LEVEL <= 500';
            EXECUTE IMMEDIATE v_sql;
            COMMIT;
        END LOOP;
        DBMS_OUTPUT.PUT_LINE('Added this run''s increment to ' || v_ts_name);
    EXCEPTION
        WHEN OTHERS THEN
            COMMIT;
            DBMS_OUTPUT.PUT_LINE(v_ts_name || ' is now completely full — increment only partially applied.');
    END;
END;
/

-- Check current usage so you can decide whether to run again
COLUMN pct_used FORMAT 990.0
SELECT ROUND((1 - NVL(fs.bytes,0)/df.bytes) * 100, 1) AS pct_used
FROM dba_data_files df
LEFT JOIN (SELECT file_id, SUM(bytes) bytes FROM dba_free_space GROUP BY file_id) fs
  ON fs.file_id = df.file_id
WHERE df.tablespace_name = 'TBS_FORECAST_TEST';
