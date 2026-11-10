#!/usr/bin/env python3
"""Generate a reproducible, entirely synthetic Somali mobile-money dataset.

Python 3.9+; standard library only. No network access or external accounts.
Run: python generate_data.py --out data --payments 100000 --customers 5000
Read README.md before interpreting the generated data. This is a learning
simulation of one provider, not a description of any real provider's systems.
"""

import argparse
import csv
import hashlib
import heapq
import json
import math
import random
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

VERSION = "1.0.0"
UTC = timezone.utc
LOCAL = timezone(timedelta(hours=3))
FIRST_NAMES = [
    "Ayaan", "Fadumo", "Sahra", "Hodan", "Ifrah", "Nimco", "Hibo", "Deeqa",
    "Ubah", "Nasteexo", "Maryan", "Khadra", "Shukri", "Ruqiya", "Hani", "Sagal",
    "Cabdiraxmaan", "Maxamed", "Axmed", "Cabdullaahi", "Cali", "Xasan", "Xuseen",
    "Yuusuf", "Ibraahim", "Cabdi", "Saciid", "Bashiir", "Khaalid", "Cumar",
]
FAMILY_NAMES = ["Maxamed", "Axmed", "Cali", "Xasan", "Cabdullaahi", "Nuur",
                "Warsame", "Faarax", "Cumar", "Yuusuf", "Ibraahim", "Jaamac"]
CITIES = ["Muqdisho", "Baydhabo", "Kismaayo", "Boosaaso", "Garoowe", "Beledweyne"]
# Illustrative population weights, not measured Somali market shares.
CITY_WEIGHTS = [40, 15, 15, 12, 10, 8]
HOUR_WEIGHTS = [1, 1, 1, 1, 1, 2, 4, 7, 9, 10, 10, 9,
                8, 8, 8, 9, 10, 12, 14, 15, 13, 10, 6, 3]
FAILURE_CODES = [
    ("INSUFFICIENT_FUNDS", "FAILURE", "BALANCE_ENGINE", "Available balance is below the requested amount", "NO"),
    ("RECIPIENT_INACTIVE", "FAILURE", "ACCOUNT_VALIDATOR", "Recipient wallet is inactive", "NO"),
    ("TRANSFER_LIMIT_EXCEEDED", "FAILURE", "LIMIT_ENGINE", "Amount exceeds the simulated per-transfer limit", "NO"),
    ("SERVICE_UNAVAILABLE", "FAILURE", "PAYMENT_SWITCH", "System definitively rejected the attempt before posting", "YES"),
    ("PROCESSING_ERROR", "FAILURE", "PAYMENT_ENGINE", "System confirmed a processing failure without posting", "YES"),
    ("PROCESSING_EXPIRED", "FAILURE", "PAYMENT_ENGINE", "System confirmed cancellation and released the hold", "YES"),
    ("RESPONSE_TIMEOUT", "UNCERTAINTY", "PAYMENT_GATEWAY", "No final response yet; payment outcome is not a confirmed failure", "NO"),
]
CODE_SOURCE = {row[0]: row[2] for row in FAILURE_CODES}
RETRYABLE = {row[0] for row in FAILURE_CODES if row[4] == "YES"}


@dataclass
class Config:
    seed: int = 42
    start_date: str = "2026-07-01"
    days: int = 90
    customers: int = 5000
    payments: int = 100000
    transfer_limit_cents: int = 50000
    max_attempts: int = 3
    duplicate_rate: float = 0.01
    late_rate: float = 0.02
    drop_rate: float = 0.002
    retry_probability: float = 0.65
    timeout_probability: float = 0.025
    unresolved_given_timeout: float = 0.04
    failure_given_resolved_timeout: float = 0.20

    def validate(self):
        if not 2 <= self.customers <= 100000:
            raise ValueError("customers must be between 2 and 100000")
        if not 1 <= self.payments <= 1000000:
            raise ValueError("payments must be between 1 and 1000000")
        if not 1 <= self.days <= 366:
            raise ValueError("days must be between 1 and 366")
        if self.transfer_limit_cents <= 0 or self.max_attempts < 1:
            raise ValueError("transfer_limit_cents and max_attempts must be positive")
        for key in ("duplicate_rate", "late_rate", "drop_rate", "retry_probability",
                    "timeout_probability", "unresolved_given_timeout", "failure_given_resolved_timeout"):
            if not 0 <= getattr(self, key) <= 1:
                raise ValueError(key + " must be between 0 and 1")
        datetime.strptime(self.start_date, "%Y-%m-%d")


def iso(ms):
    return datetime.fromtimestamp(ms / 1000, UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


class Simulator:
    def __init__(self, config):
        config.validate()
        self.config = config
        self.rng = random.Random(config.seed)
        # Transport randomness is independent of business-state randomness.
        self.transport_rng = random.Random(config.seed + 1000003)
        local_start = datetime.strptime(config.start_date, "%Y-%m-%d").replace(tzinfo=LOCAL)
        self.start = int(local_start.timestamp() * 1000)
        self.end = self.start + config.days * 86400000  # exclusive observation cutoff
        self.customers = []
        self.wallets = []
        self.wallet_by_id = {}
        self.balance = {}
        self.held = defaultdict(int)
        self.requests = []
        self.attempts = []
        self.outcomes = {}
        self.events = []
        self.entries = []
        self.incidents = []
        self.queue = []
        self.sequence = 0

    def schedule(self, at, action, payload):
        self.sequence += 1
        heapq.heappush(self.queue, (at, self.sequence, action, payload))

    def create_customers(self):
        for index in range(1, self.config.customers + 1):
            cid, wid = "CUS_%06d" % index, "WAL_%06d" % index
            city = self.rng.choices(CITIES, CITY_WEIGHTS)[0]
            name = " ".join([self.rng.choice(FIRST_NAMES), self.rng.choice(FAMILY_NAMES), self.rng.choice(FAMILY_NAMES)])
            self.customers.append({"customer_id": cid, "full_name": name, "home_city": city,
                                   "registered_at": iso(self.start - self.rng.randint(30, 730) * 86400000)})
            # Guarantee two active wallets, even for small test runs.
            status = "ACTIVE" if index <= 2 or self.rng.random() >= 0.02 else "INACTIVE"
            opening = max(0, min(500000, int(self.rng.lognormvariate(math.log(15000), 0.9))))
            row = {"wallet_id": wid, "customer_id": cid, "currency": "USD", "status": status,
                   "opening_balance_cents": opening, "snapshot_at": iso(self.start)}
            self.wallets.append(row)
            self.wallet_by_id[wid] = row
            self.balance[wid] = opening

    def create_incidents(self):
        for index in range(max(1, self.config.days // 6)):
            day = min(self.config.days - 1, index * 6 + 2)
            at = self.start + day * 86400000 + self.rng.randint(9, 20) * 3600000
            finish = min(self.end, at + self.rng.randint(60, 180) * 60000)
            self.incidents.append({
                "incident_id": "INC_%04d" % (index + 1), "started_at": iso(at), "ended_at": iso(finish),
                "affected_city": "ALL" if index % 3 == 0 else CITIES[index % len(CITIES)],
                "affected_channel": "ALL" if index % 4 == 0 else "USSD",
                "incident_type": "SIMULATED_SWITCH_DEGRADATION", "recorded_by": "SYSTEM_MONITOR",
                "_start": at, "_end": finish,
            })

    def create_requests(self):
        active = [w["wallet_id"] for w in self.wallets if w["status"] == "ACTIVE"]
        all_wallets = list(self.wallet_by_id)
        customer_city = {row["customer_id"]: row["home_city"] for row in self.customers}
        weights = [0.94 if (self.start + d * 86400000) // 86400000 % 7 == 1 else 1.0
                   for d in range(self.config.days)]
        # No claim is made about actual weekday usage: explicit synthetic variation.
        for index in range(1, self.config.payments + 1):
            day = self.rng.choices(range(self.config.days), weights)[0]
            hour = self.rng.choices(range(24), HOUR_WEIGHTS)[0]
            at = self.start + day * 86400000 + hour * 3600000 + self.rng.randrange(3600000)
            sender = self.rng.choice(active)
            recipient = self.rng.choice(all_wallets)
            while recipient == sender:
                recipient = self.rng.choice(all_wallets)
            amount = max(10, min(150000, int(self.rng.lognormvariate(math.log(1800), 1.25))))
            # Deliberately include a small tail over the configured limit.
            if self.rng.random() < 0.012:
                amount = self.config.transfer_limit_cents + self.rng.randint(1, 50000)
            request = {
                "payment_id": "PAY_%07d" % index, "requested_at": iso(at),
                "sender_wallet_id": sender, "recipient_wallet_id": recipient,
                "amount_cents": amount, "currency": "USD", "payment_type": "P2P",
                "channel": self.rng.choices(["USSD", "APP"], [85, 15])[0],
                "origin_city": customer_city[self.wallet_by_id[sender]["customer_id"]],
            }
            self.requests.append(request)
            self.schedule(at, "attempt", (request, 1))
        self.requests.sort(key=lambda r: (r["requested_at"], r["payment_id"]))

    def event(self, attempt, at, status, reason="", incident_id=""):
        source = CODE_SOURCE.get(reason, "PAYMENT_ENGINE")
        self.events.append({
            "event_id": "EVT_%09d" % (len(self.events) + 1),
            "payment_id": attempt["payment_id"], "attempt_id": attempt["attempt_id"],
            "event_at": iso(at), "status": status, "reason_code": reason,
            "reason_source": "SYSTEM" if reason else "", "system_component": source,
            "incident_id": incident_id,
        })
        self.outcomes[attempt["attempt_id"]] = {
            "attempt_id": attempt["attempt_id"], "payment_id": attempt["payment_id"],
            "attempt_number": attempt["attempt_number"], "final_status_as_of_cutoff": status,
            "reason_code_as_of_cutoff": reason, "state_event_at": iso(at),
        }

    def start_attempt(self, request, number, at):
        sender, receiver, amount = request["sender_wallet_id"], request["recipient_wallet_id"], request["amount_cents"]
        available = self.balance[sender] - self.held[sender]
        attempt = {
            "attempt_id": "%s_A%d" % (request["payment_id"], number),
            "payment_id": request["payment_id"], "attempt_number": number,
            "started_at": iso(at), "available_balance_cents_at_start": available,
        }
        self.attempts.append(attempt)
        self.event(attempt, at, "REQUESTED")
        incident = next((row for row in self.incidents if row["_start"] <= at < row["_end"]
                         and row["affected_city"] in ("ALL", request["origin_city"])
                         and row["affected_channel"] in ("ALL", request["channel"])), None)
        iid = incident["incident_id"] if incident else ""
        reason = ""
        if self.wallet_by_id[receiver]["status"] != "ACTIVE":
            reason = "RECIPIENT_INACTIVE"
        elif amount > self.config.transfer_limit_cents:
            reason = "TRANSFER_LIMIT_EXCEEDED"
        elif available < amount:
            reason = "INSUFFICIENT_FUNDS"
        elif self.rng.random() < (0.18 if incident else 0.003):
            reason = "SERVICE_UNAVAILABLE"
        elif self.rng.random() < 0.004:
            reason = "PROCESSING_ERROR"
        if reason:
            self.schedule(at + self.rng.randint(200, 2000), "finish",
                          (request, attempt, "FAILED", reason, False, iid))
            return
        # Reserve funds before final processing; concurrent attempts cannot overspend.
        self.held[sender] += amount
        timeout_rate = max(0.25, self.config.timeout_probability) if incident else self.config.timeout_probability
        if self.rng.random() < timeout_rate:
            pending_at = at + 10000
            self.schedule(pending_at, "pending", (attempt, iid))
            if self.rng.random() < self.config.unresolved_given_timeout:
                return  # intentionally still reserved/unresolved at observation cutoff
            final_at = pending_at + self.rng.randint(30000, 1200000)
            failed = self.rng.random() < self.config.failure_given_resolved_timeout
            status, reason = ("FAILED", "PROCESSING_EXPIRED") if failed else ("SUCCEEDED", "")
        else:
            final_at = at + self.rng.randint(300, 6000)
            status, reason = "SUCCEEDED", ""
        self.schedule(final_at, "finish", (request, attempt, status, reason, True, iid))

    def finish(self, request, attempt, status, reason, reserved, iid, at):
        sender, receiver, amount = request["sender_wallet_id"], request["recipient_wallet_id"], request["amount_cents"]
        if reserved:
            self.held[sender] -= amount
        if status == "SUCCEEDED":
            self.balance[sender] -= amount
            self.balance[receiver] += amount
            for wid, sign in ((sender, -1), (receiver, 1)):
                self.entries.append({
                    "entry_id": "LED_%09d" % (len(self.entries) + 1),
                    "payment_id": request["payment_id"], "attempt_id": attempt["attempt_id"],
                    "wallet_id": wid, "posted_at": iso(at), "signed_amount_cents": sign * amount,
                    "currency": "USD", "entry_type": "TRANSFER_OUT" if sign < 0 else "TRANSFER_IN",
                })
        self.event(attempt, at, status, reason, iid)
        number = attempt["attempt_number"]
        if status == "FAILED" and reason in RETRYABLE and number < self.config.max_attempts:
            if self.rng.random() < self.config.retry_probability:
                # Same logical payment; a new attempt only after a confirmed failure.
                self.schedule(at + self.rng.randint(60000, 300000), "attempt", (request, number + 1))

    def run(self):
        self.create_customers()
        self.create_incidents()
        self.create_requests()
        while self.queue:
            at, _, action, payload = heapq.heappop(self.queue)
            if at >= self.end:
                break
            if action == "attempt":
                self.start_attempt(*payload, at)
            elif action == "pending":
                attempt, iid = payload
                self.event(attempt, at, "PENDING", "RESPONSE_TIMEOUT", iid)
            elif action == "finish":
                self.finish(*payload, at)
        self.wallet_closing = [{
            "wallet_id": row["wallet_id"], "currency": "USD", "snapshot_at": iso(self.end),
            "ledger_balance_cents": self.balance[row["wallet_id"]],
            "held_balance_cents": self.held[row["wallet_id"]],
            "available_balance_cents": self.balance[row["wallet_id"]] - self.held[row["wallet_id"]],
        } for row in self.wallets]
        return self

    def validate(self):
        """Business invariants; raise rather than writing an inconsistent dataset."""
        def check(condition, description):
            if not condition:
                raise ValueError("Validation failed: " + description)
        check(len(self.requests) == self.config.payments, "payment count")
        requests = {r["payment_id"]: r for r in self.requests}
        attempts = {r["attempt_id"]: r for r in self.attempts}
        check(len(attempts) == len(self.attempts), "unique attempt IDs")
        check(len({r["event_id"] for r in self.events}) == len(self.events), "unique canonical event IDs")
        check(len({r["customer_id"] for r in self.customers}) == len(self.customers), "unique customers")
        check(len(requests) == len(self.requests), "unique payment IDs")
        check(len(self.outcomes) == len(attempts), "outcome coverage")
        for r in self.requests:
            check(r["sender_wallet_id"] in self.balance and r["recipient_wallet_id"] in self.balance, "wallet references")
            check(r["sender_wallet_id"] != r["recipient_wallet_id"] and r["amount_cents"] > 0, "transfer validity")
        groups = defaultdict(list)
        for event in self.events:
            check(event["attempt_id"] in attempts, "event attempt reference")
            check(event["payment_id"] == attempts[event["attempt_id"]]["payment_id"], "event payment reference")
            check(not event["reason_code"] or event["reason_source"] == "SYSTEM", "system-only reasons")
            check(event["event_at"] < iso(self.end), "event before cutoff")
            groups[event["attempt_id"]].append(event)
        permitted = {"REQUESTED": {"PENDING", "SUCCEEDED", "FAILED"}, "PENDING": {"SUCCEEDED", "FAILED"},
                     "SUCCEEDED": set(), "FAILED": set()}
        for aid, events in groups.items():
            check(events[0]["status"] == "REQUESTED", "initial requested state")
            for previous, current in zip(events, events[1:]):
                check(current["status"] in permitted[previous["status"]], "valid lifecycle transition")
                check(current["event_at"] >= previous["event_at"], "event chronology")
            check(events[-1]["status"] == self.outcomes[aid]["final_status_as_of_cutoff"], "final event agrees with outcome")
        entry_groups = defaultdict(list)
        deltas = Counter()
        success_payments = Counter()
        for row in self.entries:
            entry_groups[row["attempt_id"]].append(row)
            deltas[row["wallet_id"]] += row["signed_amount_cents"]
        for aid, outcome in self.outcomes.items():
            request = requests[outcome["payment_id"]]
            entries = entry_groups.get(aid, [])
            status, code = outcome["final_status_as_of_cutoff"], outcome["reason_code_as_of_cutoff"]
            if status == "SUCCEEDED":
                check(len(entries) == 2, "two ledger entries for success")
                check(sum(r["signed_amount_cents"] for r in entries) == 0, "balanced transfer")
                check({(r["wallet_id"], r["signed_amount_cents"]) for r in entries} == {
                    (request["sender_wallet_id"], -request["amount_cents"]),
                    (request["recipient_wallet_id"], request["amount_cents"])}, "correct ledger parties and amount")
                check(code == "", "no failure code on success")
                success_payments[request["payment_id"]] += 1
            else:
                check(not entries, "no posting for failed or unresolved attempt")
            if status == "FAILED":
                check(code in CODE_SOURCE and code != "RESPONSE_TIMEOUT", "definitive failure code")
            if code == "INSUFFICIENT_FUNDS":
                check(attempts[aid]["available_balance_cents_at_start"] < request["amount_cents"], "insufficient funds is genuine")
            if code == "TRANSFER_LIMIT_EXCEEDED":
                check(request["amount_cents"] > self.config.transfer_limit_cents, "limit failure is genuine")
            if code == "RECIPIENT_INACTIVE":
                check(self.wallet_by_id[request["recipient_wallet_id"]]["status"] == "INACTIVE", "inactive recipient is genuine")
        check(all(n == 1 for n in success_payments.values()), "at most one posting per logical payment")
        for attempt in self.attempts:
            check(attempt["payment_id"] in requests, "attempt payment reference")
            number = attempt["attempt_number"]
            if number > 1:
                previous = self.outcomes["%s_A%d" % (attempt["payment_id"], number - 1)]
                check(previous["final_status_as_of_cutoff"] == "FAILED", "retry only after failure")
                check(previous["state_event_at"] < attempt["started_at"], "retry after previous result")
        for wallet in self.wallets:
            wid = wallet["wallet_id"]
            check(wallet["opening_balance_cents"] + deltas[wid] == self.balance[wid], "wallet reconciles to ledger")
            check(0 <= self.held[wid] <= self.balance[wid], "nonnegative available and held balances")
        check(sum(self.balance.values()) == sum(w["opening_balance_cents"] for w in self.wallets), "total money conserved")
        return {"business_invariants": "PASS", "logical_payments": len(self.requests),
                "attempts": len(self.attempts), "canonical_events": len(self.events), "ledger_entries": len(self.entries)}

    def transport(self):
        """Deliver events with duplicates, lateness, and missing analytics records.

        This models log-delivery defects, not additional payment-system failures.
        Physical duplicate deliveries keep the same event_id and new delivery_id.
        """
        delivered, audit = [], []
        seq = 0
        rng = self.transport_rng
        for event in self.events:
            flags = []
            event_ms = int(datetime.fromisoformat(event["event_at"].replace("Z", "+00:00")).timestamp() * 1000)
            copies, after_cutoff = 0, 0
            if rng.random() < self.config.drop_rate:
                flags.append("DROPPED_FROM_ANALYTICS_FEED")
            else:
                delay = rng.randint(0, 10000)
                if rng.random() < self.config.late_rate:
                    delay += rng.randint(3600000, 129600000)
                    flags.append("LATE_DELIVERY")
                arrival = event_ms + delay
                arrivals = [arrival]
                if rng.random() < self.config.duplicate_rate:
                    arrivals.append(arrival + rng.randint(1000, 7200000))
                    flags.append("DUPLICATE_DELIVERY")
                for when in arrivals:
                    if when >= self.end:
                        after_cutoff += 1
                        continue
                    seq += 1
                    delivered.append(dict(event, delivery_id="DEL_%09d" % seq, ingested_at=iso(when)))
                    copies += 1
            if after_cutoff:
                flags.append("NOT_YET_ARRIVED_AT_CUTOFF")
            audit.append({"event_id": event["event_id"], "event_at": event["event_at"],
                          "injected_conditions": "|".join(flags), "copies_received_by_cutoff": copies,
                          "copies_after_cutoff": after_cutoff})
        delivered.sort(key=lambda r: (r["ingested_at"], r["delivery_id"]))
        return delivered, audit

    def export(self, output):
        result = self.validate()
        output = Path(output)
        if output.exists() and any(output.iterdir()):
            raise ValueError("Output directory is not empty. Choose a new --out folder; existing data will not be overwritten.")
        output.mkdir(parents=True, exist_ok=True)
        schema = {}

        def save(relative, rows, fields):
            write_csv(output / relative, rows, fields)
            schema[relative] = {"row_count": len(rows), "columns": fields}

        save("source/customers.csv", self.customers, ["customer_id", "full_name", "home_city", "registered_at"])
        save("source/wallets_opening.csv", self.wallets, ["wallet_id", "customer_id", "currency", "status", "opening_balance_cents", "snapshot_at"])
        save("source/wallets_closing.csv", self.wallet_closing, ["wallet_id", "currency", "snapshot_at", "ledger_balance_cents", "held_balance_cents", "available_balance_cents"])
        save("source/payment_requests.csv", self.requests, ["payment_id", "requested_at", "sender_wallet_id", "recipient_wallet_id", "amount_cents", "currency", "payment_type", "channel", "origin_city"])
        save("source/payment_attempts.csv", self.attempts, ["attempt_id", "payment_id", "attempt_number", "started_at", "available_balance_cents_at_start"])
        event_fields = ["event_id", "payment_id", "attempt_id", "event_at", "status", "reason_code", "reason_source", "system_component", "incident_id"]
        delivery_fields = event_fields + ["delivery_id", "ingested_at"]
        delivered, audit = self.transport()
        for day, rows in group_days(delivered).items():
            save("source/event_deliveries/" + day + ".csv", rows, delivery_fields)
        save("source/ledger_entries.csv", self.entries, ["entry_id", "payment_id", "attempt_id", "wallet_id", "posted_at", "signed_amount_cents", "currency", "entry_type"])
        incident_fields = ["incident_id", "started_at", "ended_at", "affected_city", "affected_channel", "incident_type", "recorded_by"]
        incident_rows = [{k: r[k] for k in incident_fields} for r in self.incidents]
        save("source/system_incidents.csv", incident_rows, incident_fields)
        code_fields = ["reason_code", "reason_class", "system_component", "description", "retry_after_confirmed_failure"]
        code_rows = [dict(zip(code_fields, row)) for row in FAILURE_CODES]
        save("source/reason_codes.csv", code_rows, code_fields)
        outcome_fields = ["attempt_id", "payment_id", "attempt_number", "final_status_as_of_cutoff", "reason_code_as_of_cutoff", "state_event_at"]
        outcomes = sorted(self.outcomes.values(), key=lambda r: r["attempt_id"])
        save("evaluation/expected_attempt_outcomes.csv", outcomes, outcome_fields)
        save("evaluation/canonical_events.csv", self.events, event_fields)
        save("evaluation/event_delivery_audit.csv", audit, ["event_id", "event_at", "injected_conditions", "copies_received_by_cutoff", "copies_after_cutoff"])
        latest = {}
        for row in outcomes:
            if row["attempt_number"] > latest.get(row["payment_id"], {}).get("attempt_number", 0):
                latest[row["payment_id"]] = row
        payment_outcomes = sorted(latest.values(), key=lambda r: r["payment_id"])
        save("evaluation/expected_payment_outcomes.csv", payment_outcomes, outcome_fields)
        status_counts = dict(sorted(Counter(r["final_status_as_of_cutoff"] for r in outcomes).items()))
        payment_counts = dict(sorted(Counter(r["final_status_as_of_cutoff"] for r in payment_outcomes).items()))
        reason_counts = dict(sorted(Counter(r["reason_code_as_of_cutoff"] for r in outcomes if r["final_status_as_of_cutoff"] == "FAILED").items()))
        flags = Counter(flag for row in audit for flag in row["injected_conditions"].split("|") if flag)
        summary = dict(result, attempt_status_counts=status_counts, payment_status_counts=payment_counts,
                       failed_attempts_by_reason=reason_counts, received_event_rows=len(delivered),
                       distinct_received_events=len({r["event_id"] for r in delivered}),
                       delivery_conditions=dict(sorted(flags.items())),
                       initial_money_cents=sum(r["opening_balance_cents"] for r in self.wallets),
                       closing_money_cents=sum(self.balance.values()), held_money_cents=sum(self.held.values()))
        write_json(output / "evaluation/validation_summary.json", summary)
        write_json(output / "schema.json", schema)
        write_json(output / "generation_config.json", dict(asdict(self.config), generator_version=VERSION,
                   observation_start_utc=iso(self.start), observation_cutoff_exclusive_utc=iso(self.end),
                   business_timezone="Africa/Mogadishu (UTC+03:00)", currency="USD", fees_cents=0,
                   provider_id="SIM_WALLET", synthetic=True, reason_source_policy="SYSTEM_ONLY"))
        checksums = {}
        for path in sorted(output.rglob("*")):
            if path.is_file():
                checksums[path.relative_to(output).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
        write_json(output / "checksums.json", checksums)
        return summary


def group_days(rows):
    days = defaultdict(list)
    for row in rows:
        days[row["ingested_at"][:10]].append(row)
    return dict(sorted(days.items()))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=Path("data"))
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--start-date", default="2026-07-01", help="First local business date, YYYY-MM-DD")
    parser.add_argument("--days", type=int, default=90)
    parser.add_argument("--customers", type=int, default=5000)
    parser.add_argument("--payments", type=int, default=100000, help="Logical transfers; retries create additional attempts")
    args = parser.parse_args()
    try:
        config = Config(seed=args.seed, start_date=args.start_date, days=args.days,
                        customers=args.customers, payments=args.payments)
        config.validate()
        if args.out.exists() and any(args.out.iterdir()):
            raise ValueError("Output directory is not empty; choose another --out folder.")
        simulator = Simulator(config).run()
        summary = simulator.export(args.out)
    except (ValueError, OSError) as error:
        parser.exit(2, "Error: %s\n" % error)
    print(json.dumps(summary, indent=2))
    print("\nSynthetic dataset saved to: " + str(args.out.resolve()))
    print("Use source/ for your pipeline; keep evaluation/ separate for validation.")


if __name__ == "__main__":
    main()
