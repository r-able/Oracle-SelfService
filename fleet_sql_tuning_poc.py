#!/usr/bin/env python3
"""
Fleet SQL Tuning POC — scans multiple PDBs under a single CDB, identifies the
top SQL statements by CPU and by elapsed time over the last N hours (from
AWR), runs the SQL Tuning Advisor against each, and reports findings.

ANALYSIS ONLY. This script never applies a SQL Profile, creates an index, or
modifies PROD in any way — it creates a Tuning Advisor task, reads its
report, and drops the task again.
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone

import oracledb


TOP_SQL_QUERY = """
SELECT sql_id, metric_value FROM (
    SELECT s.sql_id,
           SUM(s.{metric_col}) AS metric_value
    FROM dba_hist_sqlstat s
    JOIN dba_hist_snapshot sn
        ON s.snap_id = sn.snap_id
       AND s.dbid = sn.dbid
       AND s.instance_number = sn.instance_number
    WHERE s.con_id = SYS_CONTEXT('USERENV', 'CON_ID')
      AND sn.begin_interval_time >= SYSTIMESTAMP - INTERVAL '{hours}' HOUR
    GROUP BY s.sql_id
)
ORDER BY metric_value DESC
FETCH FIRST {top_n} ROWS ONLY
"""

BENEFIT_RE = re.compile(r"(\d+(?:\.\d+)?)\s*%\s*benefit", re.IGNORECASE)
RECOMMENDATION_TYPE_RE = re.compile(
    r"(SQL Profile|Index|Statistics|Restructure SQL)", re.IGNORECASE
)


def connect(host, port, service, user, password):
    dsn = f"{host}:{port}/{service}"
    return oracledb.connect(user=user, password=password, dsn=dsn)


def get_top_sql(cursor, metric_col, hours, top_n):
    q = TOP_SQL_QUERY.format(metric_col=metric_col, hours=hours, top_n=top_n)
    cursor.execute(q)
    return [row[0] for row in cursor.fetchall()]


def run_tuning_advisor(cursor, connection, sql_id):
    task_name = f"POC_TUNE_{sql_id}_{int(datetime.now().timestamp())}"
    try:
        cursor.execute(
            """
            DECLARE
                v_task_name VARCHAR2(100);
            BEGIN
                v_task_name := DBMS_SQLTUNE.CREATE_TUNING_TASK(
                    sql_id      => :sql_id,
                    scope       => DBMS_SQLTUNE.SCOPE_COMPREHENSIVE,
                    time_limit  => 60,
                    task_name   => :task_name
                );
                DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name => :task_name);
            END;
            """,
            sql_id=sql_id,
            task_name=task_name,
        )
        connection.commit()

        report_var = cursor.var(oracledb.DB_TYPE_CLOB)
        cursor.execute(
            """
            BEGIN
                :report := DBMS_SQLTUNE.REPORT_TUNING_TASK(
                    task_name => :task_name,
                    type      => 'TEXT',
                    level     => 'TYPICAL',
                    section   => 'ALL'
                );
            END;
            """,
            report=report_var,
            task_name=task_name,
        )
        report_text = report_var.getvalue().read()

        has_recommendation = (
            "no recommendations" not in report_text.lower()
            and "findings" in report_text.lower()
        )
        benefit_match = BENEFIT_RE.search(report_text)
        type_match = RECOMMENDATION_TYPE_RE.search(report_text)

        return {
            "sql_id": sql_id,
            "task_name": task_name,
            "has_recommendation": has_recommendation,
            "recommendation_type": type_match.group(1) if type_match else None,
            "benefit_pct": float(benefit_match.group(1)) if benefit_match else None,
            "report_excerpt": report_text[:2000],
        }
    finally:
        try:
            cursor.execute(
                "BEGIN DBMS_SQLTUNE.DROP_TUNING_TASK(:t); END;", t=task_name
            )
            connection.commit()
        except oracledb.DatabaseError:
            pass


def scan_pdb(connection, pdb, hours, top_n):
    cursor = connection.cursor()
    cursor.execute(f"ALTER SESSION SET CONTAINER = {pdb}")

    cpu_ids = get_top_sql(cursor, "cpu_time_delta", hours, top_n)
    elapsed_ids = get_top_sql(cursor, "elapsed_time_delta", hours, top_n)

    ranked = {}
    for sid in cpu_ids:
        ranked.setdefault(sid, set()).add("CPU")
    for sid in elapsed_ids:
        ranked.setdefault(sid, set()).add("ELAPSED")

    results = []
    for sql_id, reasons in ranked.items():
        rec = run_tuning_advisor(cursor, connection, sql_id)
        if rec:
            rec["ranked_by"] = sorted(reasons)
            results.append(rec)

    cursor.close()
    return results


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=1521)
    p.add_argument("--service", required=True)
    p.add_argument("--pdbs", required=True, help="Comma-separated PDB list")
    p.add_argument("--hours", type=int, default=24)
    p.add_argument("--top-n", type=int, default=5)
    p.add_argument("--output", required=True)
    args = p.parse_args()

    user = os.environ.get("ORACLE_POC_USER")
    password = os.environ.get("ORACLE_POC_PASSWORD")
    if not user or not password:
        sys.exit("ORACLE_POC_USER / ORACLE_POC_PASSWORD must be set in the environment")

    pdb_list = [x.strip() for x in args.pdbs.split(",") if x.strip()]

    fleet_results = {
        "scan_started": datetime.now(timezone.utc).isoformat(),
        "cdb_service": args.service,
        "hours_window": args.hours,
        "top_n": args.top_n,
        "pdbs": {},
    }

    connection = connect(args.host, args.port, args.service, user, password)
    print(f"Connected to {args.host}:{args.port}/{args.service}")

    for pdb in pdb_list:
        print(f"Scanning PDB {pdb} ...")
        pdb_results = scan_pdb(connection, pdb, args.hours, args.top_n)
        found = sum(1 for r in pdb_results if r["has_recommendation"])
        print(
            f"  -> {len(pdb_results)} SQL statements analyzed, "
            f"{found} with a tuning recommendation"
        )
        fleet_results["pdbs"][pdb] = pdb_results

    connection.close()
    fleet_results["scan_completed"] = datetime.now(timezone.utc).isoformat()

    with open(args.output, "w") as f:
        json.dump(fleet_results, f, indent=2)

    total_analyzed = sum(len(v) for v in fleet_results["pdbs"].values())
    total_found = sum(
        1 for v in fleet_results["pdbs"].values() for r in v if r["has_recommendation"]
    )
    print(
        f"\nDone. {len(pdb_list)} PDBs scanned, {total_analyzed} unique SQL "
        f"statements analyzed, {total_found} tuning opportunities found."
    )
    print(f"Results written to {args.output}")


if __name__ == "__main__":
    main()
