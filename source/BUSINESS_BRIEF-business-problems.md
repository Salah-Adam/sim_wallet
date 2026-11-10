# Business brief: Which transfer problems should we investigate first?

**Company:** SIM_WALLET, a fictional Somali mobile-money provider  
**Project sponsor:** Head of Payment Operations (a fictional stakeholder role)  
**Other stakeholders:** Payment Engineering and Wallet Reconciliation  
**Your role:** Data engineer and operations analyst  
**Assignment:** Build reliable payment reporting and recommend three investigation priorities

## 1. The manager's request

> Our customers use USSD and the app to send USD to other customers within our service. We have payment records, system events, incident records, and wallet ledger entries. We need a reliable way to turn those records into operational decisions.
>
> Tell me how many payments completed, which confirmed failures deserve attention, and which transfers still need investigation. Show whether retries recovered payments and where service incidents coincided with worse outcomes.
>
> At the end, recommend the three issues we should investigate first. For each, show the evidence, the customers and payments involved, the team that should investigate, and how we would measure improvement.

This is a fictional assignment. It does not assert that failures are increasing, customers are leaving, or money has been lost. Those claims have not been established. All failure reasons must come from the simulated payment system; there are no customer complaints or support-ticket records.

## 2. Business problem A: We do not yet have a reliable picture of unsuccessful payments

**Q1. Of the payments requested during the observation period, how many were successful, confirmed failed, or unresolved at the cutoff?**

**Q2. Which confirmed system failure reasons affect the most distinct senders and payments, and which represent technical problems versus valid transaction rejections?**

- Rank reasons by failed attempts, distinct payments with those failures, and distinct affected senders.
- Show requested amounts with a clear grain: an attempt-based sum can repeat the same payment. Distinct-payment counts across reasons can also overlap.
- Separate technical failures such as SERVICE_UNAVAILABLE from valid rejections such as INSUFFICIENT_FUNDS. Keep RESPONSE_TIMEOUT outside confirmed-failure totals.
- Show how many affected payments ultimately succeeded, so a temporary interruption is distinguishable from an unsuccessful final outcome.


## 3. Business problem B: We do not know where service investigation will be most useful

**Q3. Which city/channel groups have the greatest combination of failure rate, affected-customer count, and payment volume?**

**Q4. During each recorded incident, did relevant technical failures or unresolved outcomes increase compared with comparable non-incident periods?**


## 4. Business problem C: We do not know how much retries help customers complete payments

**Q5. How many payments whose first attempt failed later succeeded, and what share of first-failed payments does that represent?**

## 5. Business problem D: Operations needs an actionable list of unresolved transfers

**Q6. Which attempts still lack a definitive supported outcome, and which should operations investigate first?**

- Produce an investigation queue with payment_id, attempt_id, sender customer ID, amount, latest observed status, last system reason, attempt start, age at cutoff, ledger evidence, and the next evidence check.
- Cross-check the ledger before treating a missing success event as an unresolved payment. No ledger posting alone does not prove failure.
- Rank the queue using clearly stated criteria, such as age, requested amount, and evidence gaps. If you introduce age bands, label them proposed triage bands rather than an existing service-level agreement.

## 6. Business problem E: Management needs confidence in the report before using it

**Q9. Do reported successful transfers agree with the wallet ledger, and do wallet balances reconcile?**

- Check that each successful transfer has the expected balanced debit and credit postings.
- Reconcile opening balance plus signed ledger movements to closing ledger balance.
- Reconcile closing ledger balance to held balance plus available balance.
- Show discrepancies explicitly rather than forcing totals to agree. Sum one side of the ledger for successful transfer volume.

## 7. Final management decision: Our three investigation priorities

Deliver a ranked list with these columns:

| Priority | Evidence-backed problem | Affected senders and payments | Requested amount or held balance, clearly labelled | Recommended investigation | Proposed owner | Follow-up measure |
|---|---|---|---|---|---|---|
| 1–3 | Complete after analysis | Distinct counts with the cohort stated | Do not label as losses | A concrete next check | Operations, Engineering, or Reconciliation | A metric with a baseline and denominator |


## 8. Deliverables and completion criteria

1. **Reliable analytical tables:** reproducible extraction, deduplication, state reconstruction, reconciliation, and explicit exceptions.
2. **A compact dashboard:** one page for outcomes, failure reasons, incidents, and recovery; a second page for unresolved cases and data reliability. Keep the existing three-hour dashboard limit.
3. **An investigation table:** the unresolved-attempt queue, with supporting evidence and suggested next checks.
4. **A one-page management memo:** the three priorities, rationale, proposed owners, follow-up measures, and limitations.