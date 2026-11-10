"""Offline loader checks. These do not claim MySQL server integration testing."""
import csv
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

from sim_wallet.source.load_mysql import TABLES, convert, csv_batches, identifier, populate, schema_statements


class CursorStub:
    def __init__(self, occupied=False):
        self.occupied = occupied
        self.executed = []
        self.closed = False

    def execute(self, statement, params=None):
        self.executed.append((statement, params))

    def fetchone(self):
        return (1,) if self.occupied else None

    def executemany(self, statement, values):
        raise RuntimeError("simulated connection failure while inserting")

    def close(self):
        self.closed = True


class ConnectionStub:
    def __init__(self, occupied=False):
        self.cur = CursorStub(occupied)
        self.commits = 0
        self.rollbacks = 0
        self.started = 0

    def cursor(self):
        return self.cur

    def commit(self):
        self.commits += 1

    def rollback(self):
        self.rollbacks += 1

    def start_transaction(self):
        self.started += 1


class LoaderTests(unittest.TestCase):
    def test_timezone_conversion_preserves_instant_and_milliseconds(self):
        self.assertEqual(convert("event_at", "2026-07-01T03:12:34.567+03:00"), datetime(2026, 7, 1, 0, 12, 34, 567000))
        self.assertEqual(convert("event_at", "2026-07-01T00:12:34.567Z"), datetime(2026, 7, 1, 0, 12, 34, 567000))
        with self.assertRaises(ValueError):
            convert("event_at", "2026-07-01T00:12:34")

    def test_money_nulls_and_identifier_safety(self):
        self.assertEqual(convert("signed_amount_cents", "-2500"), -2500)
        self.assertEqual(convert("available_balance_cents_at_start", "123"), 123)
        self.assertIsNone(convert("reason_code", ""))
        with self.assertRaises(ValueError):
            convert("amount_cents", "25.25")
        for value in ["a; DROP DATABASE b", "name`bad", "", "x" * 65]:
            with self.assertRaises(ValueError):
                identifier(value)

    def test_malformed_csv_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            path.write_text("amount_cents,event_at\n100\n")
            with self.assertRaises(ValueError):
                list(csv_batches(path, ["amount_cents", "event_at"], 1000))

    def test_refuses_nonempty_table_before_data_insert(self):
        connection = ConnectionStub(occupied=True)
        with self.assertRaises(ValueError):
            populate(connection, Path("unused"), [], {}, 100)
        self.assertEqual(connection.started, 0)
        self.assertEqual(connection.commits, 0)
        self.assertEqual(connection.rollbacks, 1)
        self.assertTrue(connection.cur.closed)

    def test_insert_failure_rolls_back_data_transaction(self):
        connection = ConnectionStub()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "customers.csv"
            with path.open("w", newline="") as handle:
                writer = csv.writer(handle)
                writer.writerow(["customer_id"])
                writer.writerow(["CUS_000001"])
            with self.assertRaises(RuntimeError):
                populate(connection, Path(directory), [("customers", path, ["customer_id"])], {"customers": 1}, 100)
        self.assertEqual(connection.started, 1)
        self.assertEqual(connection.commits, 1)  # preflight only, before the failed data transaction
        self.assertEqual(connection.rollbacks, 1)
        self.assertTrue(connection.cur.closed)

    def test_schema_has_expected_tables_and_no_destructive_statements(self):
        statements = schema_statements(Path(__file__).with_name("schema_mysql.sql"))
        tables = {statement.split("(", 1)[0].split()[-1] for statement in statements}
        self.assertEqual(tables, {table for table, _ in TABLES} | {"dataset_metadata"})
        self.assertTrue(all(statement.startswith("CREATE TABLE IF NOT EXISTS") for statement in statements))


if __name__ == "__main__":
    unittest.main()
