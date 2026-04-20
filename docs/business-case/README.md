# homefit.studio — 5-Year Business Case

A working, editable financial model for homefit.studio's first five years.
Built 2026-04-20 for Carl. Focus is unit economics + path-to-profitability
(not valuation).

## Files

| File | Purpose |
|---|---|
| `homefit-studio-business-case-v1.xlsx` | The model. 9 sheets, formulas all the way through. |
| `assumptions-cited.md` | Every driver, its source (URL + access date), and the reasoning. |
| `README.md` | This file. |

## How to use it

1. Open `homefit-studio-business-case-v1.xlsx` in Excel or Google Sheets (Numbers works but chart rendering is patchy).
2. Go to `Assumptions`.
3. Cell `C6` is the scenario selector: **1 = Conservative, 2 = Base, 3 = Optimistic**. Change this one cell and every sheet recalculates.
4. All pale-coral cells are editable. Grey cells are formulas — don't overwrite them.
5. Every assumption has three columns (Conservative / Base / Optimistic). The "Active" column (G) uses `CHOOSE()` against the scenario selector.

**Golden rule**: if you need to change a number, find the assumption on
`Assumptions` and tweak it there. Nothing is hardcoded downstream.

## Sheet map

| Sheet | Contains |
|---|---|
| `README` | Pointer + currency note. |
| `Assumptions` | 50+ drivers grouped by theme. This is the only sheet you edit. |
| `Growth` | Practitioner funnel — monthly for Year 1, quarterly for Years 2–5. 28 period columns. |
| `Revenue` | Credit economics: active-paying × plans × credits × price → gross / VAT / net / USD-equivalent. |
| `Costs` | Infra (Supabase, Vercel, domain, Apple Developer) + OpEx (marketing, legal, salaries). |
| `P&L` | Annual rollup: gross revenue → gross profit → EBITDA → cumulative EBITDA. |
| `CashFlow` | Period cash view. Starts at R0 (no external funding modelled). |
| `Scenarios` | Unit economics: ARPU, LTV, CAC, payback. Y5 snapshot for the active scenario. |
| `Sensitivity` | Tornado-style scaffold — flex one driver at a time and re-read Y5 EBITDA. |

## Reading conventions

- **Currency**: ZAR primary. USD lines labelled `(info)` and use the FX rate on `Assumptions` (default R19/USD).
- **Time**: Y1 is the 12 months starting 2026-05-01 (MVP ship target). Y2–Y5 are quarterly rollups to keep the horizon scannable.
- **VAT**: Revenue is quoted VAT-inclusive. SA VAT registration is toggled by `vat_yr` (base: Year 2, when revenue crosses ~R1M run-rate). Before registration, no VAT is backed out and none is remitted to SARS.
- **PayFast fees**: Modelled as a blended percentage (90% card / 10% EFT) + R2.00 per transaction. Two rate bands — `pf_pct_early` for Y1–Y2, `pf_pct_late` for Y3+ (volume discount past R50k/mo).
- **Payment timing**: Simplified — PayFast payout is 3–5 business days. Treated as same-period for cash flow (not material at this scale).

## Scenario philosophy

Three scenarios, driven by toggling a single selector cell. They are NOT
independent models — every scenario uses the same cost curve, the same VAT
treatment, the same PayFast fees. Only the **driver assumptions** differ.

### Conservative

- Y5 SA practitioners target: **900 paying** (~4% of SA TAM).
- Reachable fraction: 35% (strip public-sector + enterprise-locked).
- Signup rate: 1.0% of reachable per year.
- Monthly churn: 6.0%.
- Plans per practitioner per month: 15.
- Revenue per credit: R20.
- International expansion: Y4 only.
- Paid CAC: R800 (LinkedIn gets expensive at scale).
- Founder on zero salary (bootstrap posture).

### Base

- Y5 SA practitioners target: **2,200 paying** (~10% of SA TAM).
- Reachable fraction: 55%.
- Signup rate: 2.0% of reachable per year.
- Monthly churn: 4.0% (SMB SaaS benchmark).
- Plans per practitioner per month: 35.
- Revenue per credit: R22.50 (mid-bundle pricing).
- International expansion: Y3 start.
- Paid CAC: R520 (blended LinkedIn+Google; SA cheaper than UK/AU).
- Founder salary from Y1: R25k/mo.
- 1 hire from Y3 (CS — R35k), 1 engineer from Y4 (R65k).

### Optimistic

- Y5 SA practitioners target: **4,500 paying** (~20% of SA TAM).
- Reachable fraction: 70%.
- Signup rate: 3.5%/yr + strong referral loop.
- Monthly churn: 2.5% (better than SMB median, matching healthcare lock-in).
- Plans per practitioner per month: 60.
- Revenue per credit: R25.
- International expansion: Y2 start.
- Paid CAC: R300 (better creative + word-of-mouth dominance).
- Hire 1 from Y2, Hire 2 from Y3 (faster team ramp).

## What the model currently produces (Base case, built 2026-04-20)

Back-of-envelope simulation (same formulas as the xlsx):

| Metric | Y1 | Y2 | Y3 | Y4 | Y5 |
|---|---|---|---|---|---|
| Paying practitioners (end-of-year) | ~23 | ~50 | ~67 | ~76 | ~81 |
| Annualised gross (Base) | R190k | R728k | R966k | R1.10M | R1.18M |

Optimistic scenario simulation:

| Metric | Y1 | Y2 | Y3 | Y4 | Y5 |
|---|---|---|---|---|---|
| Paying practitioners (end-of-year) | ~110 | ~490 | ~770 | ~960 | ~1,100 |
| Annualised gross (Optimistic) | ~R3M | ~R15M | ~R23M | ~R29M | ~R33M |

Conservative scenario simulation:

| Metric | Y1 | Y2 | Y3 | Y4 | Y5 |
|---|---|---|---|---|---|
| Paying practitioners (end-of-year) | ~8 | ~15 | ~20 | ~23 | ~25 |
| Annualised gross (Conservative) | R40k | R140k | R190k | R215k | R230k |

**Y5 EBITDA ranges (rough, from the xlsx):**

- Conservative: strongly negative — sub-scale; founder salary + marketing > revenue.
- Base: **~break-even to modestly positive**. ~R100k–400k/year. Validates bootstrapped-solo-founder thesis.
- Optimistic: **~R10–14M EBITDA**. ~35–45% margin. Fundable / sellable scale.

## Key insights from building the model

1. **The activation → paid funnel is the single biggest lever**. 0.375 × 0.215 = 8% of signups become paying on the base case. Conservative drops to 3%; optimistic reaches 15%. A 2x improvement here outweighs any pricing tweak.
2. **Plans-per-practitioner-per-month matters more than price per credit**. Groovi charges R335/mo flat; we charge per plan. A practitioner publishing 35 plans × 1.3 credits × R22.50 ≈ R1,025/mo blended. If they only publish 10 plans, revenue is R293/mo — below Groovi. The model is most sensitive to this number.
3. **CAC in SA is extremely cheap**. R520 paid CAC + R0 warm + R50 referral blends to R260. International CAC is 3x. The Y5 picture is shaped almost entirely by *when international expansion kicks in*.
4. **Churn dominates lifetime value**. Base case LTV ≈ R16k (churn 4%/mo = 25-month lifetime). Optimistic LTV ≈ R29k (churn 2.5% = 40-month lifetime). The 2.5x ARPU gap between scenarios is less significant than the 2x lifetime gap.
5. **SA VAT timing is a genuine consideration**. Voluntary registration in Y2 gives us input-VAT reclaim on Supabase/Vercel (paid ex-VAT to US vendors, so there's no reclaim there — infra is a pure cost). Base case registers in Y2 anyway for professional optics.

## Known limitations

- **No AI-pipeline premium tier.** Parked per the brief. Would require a Stability AI / Kling cost-per-generation assumption.
- **No international CAC curve.** Modelled as 3x SA flat; real ramp would need country-by-country cost tables.
- **No FX hedging.** Infra costs are USD; we assume a fixed rate (R19/USD base). Real-world FX volatility could move Y1 costs by ±15%.
- **No funding round.** Cash flow starts at R0. If Carl raises, opening cash and burn change but EBITDA stays the same.
- **No employee equity.** Salaries are cash only.
- **PayFast production fees**. Currently sandbox. Production merchant account may negotiate lower rates (already modelled in `pf_pct_late`).
- **Sensitivity sheet is manual.** To run a proper tornado, you toggle one input at a time and snapshot Y5 EBITDA into the grid.

## Source list (summary — see `assumptions-cited.md` for the full table)

- [HPCSA](https://www.hpcsa.co.za/) — physiotherapist + biokineticist registers (SA).
- [BASA](https://biokineticssa.org.za/) — Biokinetics Association SA membership.
- [Physiotherapy Board of Australia](https://www.physiotherapyboard.gov.au/About/Statistics.aspx) — AU registers.
- [HCPC](https://www.hcpc-uk.org/data/the-register/register-summary/) — UK registrant data.
- [World Physiotherapy](https://world.physio/) — Nordic member numbers.
- [AUSactive](https://ausactive.org.au/service-excellence/professional-accreditation/) — AU exercise professionals.
- [Groovi](https://physiosoftware.groovimovements.co.za/choose-your-subscription-plan/) — SA competitor pricing.
- [PT Distinction](https://www.ptdistinction.com/pricing), [TrueCoach](https://truecoach.co/pricing/), [Physitrack](https://support.physitrack.com/article/159-how-much-does-physitrack-cost), [Medbridge](https://www.medbridge.com/physical-therapy-software) — international comps.
- [Agile Growth Labs 2025 Activation Benchmarks](https://www.agilegrowthlabs.com/blog/user-activation-rate-benchmarks-2025/)
- [1Capture 2025 Free Trial Conversion Benchmarks](https://www.1capture.io/blog/free-trial-conversion-benchmarks-2025)
- [WeAreFounders SaaS Churn 2025](https://www.wearefounders.uk/saas-churn-rates-and-customer-acquisition-costs-by-industry-2025-data/)
- [Payfast fees](https://payfast.io/fees/)
- [Supabase pricing](https://supabase.com/pricing)
- [Vercel pricing](https://vercel.com/pricing)
- [SARS/Anrok SA VAT digital services](https://www.anrok.com/vat-software-digital-services/south-africa)
- [Rihova et al. 2024 — HEP video adherence meta-analysis](https://pubmed.ncbi.nlm.nih.gov/39072676/)

All URLs accessed **2026-04-20**.

## Revising the model

If Carl's assumptions shift (e.g. Melissa's network converts better than
expected, or international CAC turns out higher), the workflow is:

1. Update the relevant input cell in `Assumptions` (pale coral).
2. Let Excel recalculate.
3. Snapshot `Scenarios!C16:C20` (the Y5 block).
4. Update `assumptions-cited.md` with the new value + note why.
5. Bump the filename to `v2.xlsx`.

Don't edit formulas to force a result — edit the assumption.

## Commit

Branch: `docs/business-case-v1`
PR target: `main`
