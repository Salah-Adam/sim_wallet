#!/usr/bin/env python3
"""Load generated source data into an empty MySQL exercise database.

Dry run (no server/dependency needed): python load_mysql.py --data data --dry-run
Load: python load_mysql.py --data data --user YOUR_MYSQL_USER
Install driver first: python -m pip install mysql-connector-python
No evaluation/ answer files are loaded. Never drops or truncates existing data.
"""

import argparse
import csv
import getpass
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

TABLES = [
    ("reason_codes", "reason_codes.csv"),
    ("customers", "customers.csv"),
    ("wallets_opening", "wallets_opening.csv"),
    ("wallets_closing", "wallets_closing.csv"),
    ("payment_requests", "payment_requests.csv"),
    ("payment_attempts", "payment_attempts.csv"),
    ("system_incidents", "system_incidents.csv"),
    ("event_deliveries", "event_deliveries/*.csv"),
    ("ledger_entries", "ledger_entries.csv"),
]


def identifier(value):
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}", value):
        raise ValueError("SQL identifiers must start with a letter and contain only letters, digits, underscores (max 64).")
    return "`" + value + "`"


def convert(column, value):
    if value == "":
        return None
    if column.endswith("_at"):
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("Timestamp must include timezone: " + column)
        return parsed.astimezone(timezone.utc).replace(tzinfo=None)
    if column.endswith("_cents") or column == "available_balance_cents_at_start" or column == "attempt_number":
        return int(value)
    return value


def csv_batches(path, expected_columns, batch_size):
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != expected_columns:
            raise ValueError("Unexpected CSV columns: " + str(path))
        batch = []
        for row in reader:
            if None in row or any(value is None for value in row.values()):
                raise ValueError("Malformed CSV row in " + str(path))
            batch.append(tuple(convert(column, row[column]) for column in expected_columns))
            if len(batch) == batch_size:
                yield batch
                batch = []
        if batch:
            yield batch


def load_plan(data, batch_size):
    schema = json.loads((data / "schema.json").read_text(encoding="utf-8"))
    plan, counts = [], {}
    for table, pattern in TABLES:
        paths = sorted((data / "source").glob(pattern))
        if not paths and table != "event_deliveries":
            raise ValueError("Missing source file: " + pattern)
        counts[table] = 0
        for path in paths:
            relative = path.relative_to(data).as_posix()
            columns = schema[relative]["columns"]
            for column in columns:
                identifier(column)
            count = sum(len(batch) for batch in csv_batches(path, columns, batch_size))
            if count != schema[relative]["row_count"]:
                raise ValueError("Row count differs from schema.json: " + relative)
            counts[table] += count
            plan.append((table, path, columns))
    return plan, counts


def schema_statements(path):
    # The supplied schema contains only simple CREATE statements and line comments.
    sql = "\n".join(line for line in path.read_text(encoding="utf-8").splitlines()
                    if not line.lstrip().startswith("--"))
    return [part.strip() for part in sql.split(";") if part.strip()]


def populate(connection, data, plan, counts, batch_size):
    cursor = connection.cursor()
    try:
        # DDL auto-commits in MySQL. The row load below is one separate transaction.
        for statement in schema_statements(Path(__file__).with_name("schema_mysql.sql")):
            cursor.execute(statement)
        for table in [name for name, _ in TABLES] + ["dataset_metadata"]:
            cursor.execute("SELECT 1 FROM " + identifier(table) + " LIMIT 1")
            if cursor.fetchone() is not None:
                raise ValueError("Table " + table + " is not empty. Choose a new --database; existing rows are untouched.")
        connection.commit()
        connection.start_transaction()
        for table, path, columns in plan:
            statement = "INSERT INTO %s (%s) VALUES (%s)" % (
                identifier(table), ", ".join(identifier(column) for column in columns),
                ", ".join(["%s"] * len(columns)))
            for batch in csv_batches(path, columns, batch_size):
                cursor.executemany(statement, batch)
        config = json.loads((data / "generation_config.json").read_text(encoding="utf-8"))
        cursor.execute("INSERT INTO dataset_metadata (metadata_key, metadata_json) VALUES (%s, %s)",
                       ("generation_config", json.dumps(config)))
        for table, expected in counts.items():
            cursor.execute("SELECT COUNT(*) FROM " + identifier(table))
            actual = cursor.fetchone()[0]
            if actual != expected:
                raise ValueError("Loaded row-count mismatch for " + table)
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        cursor.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", type=Path, default=Path("data"))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3306)
    parser.add_argument("--user")
    parser.add_argument("--database", default="somali_wallet_source")
    parser.add_argument("--batch-size", type=int, default=1000)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    connection = None
    try:
        identifier(args.database)
        if args.batch_size < 1:
            raise ValueError("batch-size must be positive")
        plan, counts = load_plan(args.data, args.batch_size)
        if args.dry_run:
            print(json.dumps({"offline_csv_validation": "PASS", "table_row_counts": counts}, indent=2))
            print("No connection made. SQL execution still requires validation on a MySQL server.")
            return
        if not args.user:
            raise ValueError("Provide --user with your MySQL username.")
        try:
            import mysql.connector
        except ImportError as error:
            raise ValueError("Install the driver: python -m pip install mysql-connector-python") from error
        password = os.environ.get("MM_MYSQL_PASSWORD")
        if password is None:
            password = getpass.getpass("MySQL password (not saved): ")
        connection = mysql.connector.connect(host=args.host, port=args.port, user=args.user,
                                             password=password, charset="utf8mb4", autocommit=False,
                                             connection_timeout=15)
        cursor = connection.cursor()
        try:
            cursor.execute("SET SESSION time_zone = '+00:00'")
            cursor.execute("CREATE DATABASE IF NOT EXISTS " + identifier(args.database) + " CHARACTER SET utf8mb4")
            cursor.execute("USE " + identifier(args.database))
        finally:
            cursor.close()
        populate(connection, args.data, plan, counts, args.batch_size)
        print(json.dumps({"loaded_database": args.database, "verified_table_row_counts": counts}, indent=2))
        print("Only source data was loaded. evaluation/ remains separate.")
    except Exception as error:
        parser.exit(2, "Load failed: %s\n" % error)
    finally:
        if connection is not None:
            connection.close()


if __name__ == "__main__":
    main()
