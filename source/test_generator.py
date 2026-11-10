"""Meaningful simulator checks. Run: python -m unittest -v test_generator.py"""
import csv
import json
import tempfile
import unittest
from collections import Counter, defaultdict
from pathlib import Path

from sim_wallet.source.generate_data import Config, Simulator


class GeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sim = Simulator(Config(seed=42, days=15, customers=150, payments=6000)).run()

    def test_business_invariants(self):
        self.assertEqual(self.sim.validate()["business_invariants"], "PASS")

    def test_ledger_replays_without_negative_balances(self):
        balances = {r["wallet_id"]: r["opening_balance_cents"] for r in self.sim.wallets}
        postings = defaultdict(list)
        for row in self.sim.entries:
            postings[row["attempt_id"]].append(row)
        for rows in sorted(postings.values(), key=lambda rows: (rows[0]["posted_at"], rows[0]["entry_id"])):
            self.assertEqual(len(rows), 2)
            self.assertEqual(sum(r["signed_amount_cents"] for r in rows), 0)
            for row in rows:
                balances[row["wallet_id"]] += row["signed_amount_cents"]
                self.assertGreaterEqual(balances[row["wallet_id"]], 0)
        self.assertEqual(balances, self.sim.balance)

    def test_insufficient_funds_limit_and_inactive_codes_follow_rules(self):
        requests = {r["payment_id"]: r for r in self.sim.requests}
        attempts = {r["attempt_id"]: r for r in self.sim.attempts}
        seen = set()
        for row in self.sim.outcomes.values():
            request = requests[row["payment_id"]]
            code = row["reason_code_as_of_cutoff"]
            if code == "INSUFFICIENT_FUNDS":
                self.assertLess(attempts[row["attempt_id"]]["available_balance_cents_at_start"], request["amount_cents"])
                seen.add(code)
            elif code == "TRANSFER_LIMIT_EXCEEDED":
                self.assertGreater(request["amount_cents"], self.sim.config.transfer_limit_cents)
                seen.add(code)
            elif code == "RECIPIENT_INACTIVE":
                self.assertEqual(self.sim.wallet_by_id[request["recipient_wallet_id"]]["status"], "INACTIVE")
                seen.add(code)
        self.assertEqual(seen, {"INSUFFICIENT_FUNDS", "TRANSFER_LIMIT_EXCEEDED", "RECIPIENT_INACTIVE"})

    def test_retries_never_follow_success_or_pending(self):
        for attempt in self.sim.attempts:
            if attempt["attempt_number"] > 1:
                prior_id = "%s_A%d" % (attempt["payment_id"], attempt["attempt_number"] - 1)
                prior = self.sim.outcomes[prior_id]
                self.assertEqual(prior["final_status_as_of_cutoff"], "FAILED")
                self.assertLess(prior["state_event_at"], attempt["started_at"])
        success_by_payment = Counter(r["payment_id"] for r in self.sim.outcomes.values()
                                     if r["final_status_as_of_cutoff"] == "SUCCEEDED")
        self.assertTrue(all(v == 1 for v in success_by_payment.values()))

    def test_timeout_is_uncertainty_and_can_resolve_both_ways(self):
        timeouts = {e["attempt_id"] for e in self.sim.events if e["reason_code"] == "RESPONSE_TIMEOUT"}
        self.assertTrue(timeouts)
        statuses = {self.sim.outcomes[aid]["final_status_as_of_cutoff"] for aid in timeouts}
        self.assertTrue({"SUCCEEDED", "FAILED", "PENDING"}.issubset(statuses))
        for event in self.sim.events:
            if event["reason_code"] == "RESPONSE_TIMEOUT":
                self.assertEqual(event["status"], "PENDING")

    def test_all_uncertain_timeouts_keep_reserves(self):
        sim = Simulator(Config(seed=9, days=2, customers=20, payments=100,
                               timeout_probability=1.0, unresolved_given_timeout=1.0)).run()
        sim.validate()
        self.assertTrue(any(r["final_status_as_of_cutoff"] == "PENDING" for r in sim.outcomes.values()))
        self.assertTrue(all(r["final_status_as_of_cutoff"] != "SUCCEEDED" for r in sim.outcomes.values()))
        self.assertGreater(sum(sim.held.values()), 0)

    def test_reproducible_export_and_transport_conditions(self):
        config = Config(seed=88, days=4, customers=60, payments=1000,
                        duplicate_rate=0.20, late_rate=0.25, drop_rate=0.10)
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / "one", Path(directory) / "two"]
            for path in paths:
                Simulator(config).run().export(path)
            self.assertEqual((paths[0] / "checksums.json").read_bytes(), (paths[1] / "checksums.json").read_bytes())
            summary = json.loads((paths[0] / "evaluation/validation_summary.json").read_text())
            for condition in ["DUPLICATE_DELIVERY", "LATE_DELIVERY", "DROPPED_FROM_ANALYTICS_FEED"]:
                self.assertGreater(summary["delivery_conditions"][condition], 0)
            self.assertGreater(summary["received_event_rows"], summary["distinct_received_events"])
            deliveries = []
            for file in sorted((paths[0] / "source/event_deliveries").glob("*.csv")):
                with file.open(newline="", encoding="utf-8") as handle:
                    deliveries.extend(csv.DictReader(handle))
            canonical = {}
            for row in deliveries:
                contents = {k: v for k, v in row.items() if k not in ("delivery_id", "ingested_at")}
                if row["event_id"] in canonical:
                    self.assertEqual(contents, canonical[row["event_id"]])
                canonical[row["event_id"]] = contents
                self.assertGreaterEqual(row["ingested_at"], row["event_at"])
            self.assertEqual(len({r["delivery_id"] for r in deliveries}), len(deliveries))

    def test_output_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            sentinel = path / "my_work.txt"
            sentinel.write_text("keep me")
            with self.assertRaises(ValueError):
                self.sim.export(path)
            self.assertEqual(sentinel.read_text(), "keep me")

    def test_minimum_dataset_and_invalid_config(self):
        Simulator(Config(days=1, customers=2, payments=1)).run().validate()
        for config in [Config(customers=1), Config(days=0), Config(payments=0), Config(drop_rate=2.0)]:
            with self.assertRaises(ValueError):
                Simulator(config)


if __name__ == "__main__":
    unittest.main()
