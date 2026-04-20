# homefit.studio — 5-Year Business Case: Cited Assumptions

Every number in `homefit-studio-business-case-v1.xlsx` traces back to one of
the cells in this table. Values live on `Assumptions (INPUTS)` and nothing
downstream is hardcoded. Accessed 2026-04-20.

## 1. Market sizing

| Assumption | Base value | Source | Note |
|---|---|---|---|
| SA registered biokineticists (2026) | 2,400 | [BASA Jan 2026 ~1,600 members, HPCSA register grew from 136 → 1,831 (2000–2020)](https://pmc.ncbi.nlm.nih.gov/articles/PMC10798608/); [BASA](https://biokineticssa.org.za/) | BASA ≈ 1,600 members represents a subset of HPCSA-registered biokineticists. A 2023 LinkedIn-sourced claim put practitioners at ~2,500. Extrapolating 2020's 1,831 at ~6% CAGR → ~2,450 in 2026. Use 2,400 as defensible midpoint. |
| SA registered physiotherapists (2025) | 9,235 | [Physiopedia SA Country Profile — HPCSA March 2025](https://www.physio-pedia.com/South_Africa) | "As of March 2025, South Africa had 9,235 registered physiotherapists." |
| SA registered exercise professionals (REPSSA + AUSactive-equivalent) | 11,000 | [HFPA Explore Personal Training](https://hfpa.co.za/news/latest/explore-the-lucrative-world-of-personal-training-in-south-africa); [REPSSA](https://www.repssa.com/); [SA Fitness Industry Inventory, Discovery Vitality Convention](https://www.researchgate.net/publication/277792119_An_inventory_of_the_South_african_fitness_industry) | 750 fitness facilities identified; avg ~15 active instructors per facility = ~11,000 is our estimate (REPSSA membership not published; REPSSA is voluntary). |
| SA total addressable practitioners | 22,635 | =Bio + Physio + PT | Biokineticists + physios + fitness professionals. |
| Reachable fraction of SA TAM (year 5) | 55% | First-principles; [SA internet penetration ~72% (DataReportal 2024)](https://datareportal.com/reports/digital-2024-south-africa) | Non-internet, rural, public-sector, and enterprise-health-channel-locked practitioners are excluded. |
| Australia registered physiotherapists | 39,781 | [Physiotherapy Board of Australia Quarterly Registration Data](https://www.physiotherapyboard.gov.au/About/Statistics.aspx) | "Australia has 39,781 physiotherapists and physiotherapy students registered with the Physiotherapy Board of Australia." |
| AUSactive registered exercise professionals | 11,000 | [AUSactive Professional Accreditation](https://ausactive.org.au/service-excellence/professional-accreditation/) | "Currently having over 11,000 registered fitness professionals." |
| UK HCPC registered physiotherapists | 64,000 | [HCPC Register Summary](https://www.hcpc-uk.org/data/the-register/register-summary/); [HCPC Registrant Snapshots](https://www.hcpc-uk.org/resources/data/2024/) | HCPC publishes physiotherapist registrants in its quarterly snapshots. 64k is the 2024 published figure (physiotherapy is HCPC's 2nd-largest profession after radiographers). |
| Norway NFF members | 10,389 | [World Physiotherapy Norway Membership](https://world.physio/membership/norway); [ER-WCPT NFF](https://www.erwcpt.eu/member-organisations/norwegian-physiotherapist-association-(nff)) | "NFF had 10,389 members as of January 1, 2024." |
| Sweden registered physiotherapists | 13,000 | [Physio-Pedia Sweden](https://www.physio-pedia.com/Sweden) | "Sweden has about 13,000 physiotherapists, 10,000 of them belong to the Swedish association." |
| Denmark registered physiotherapists | 10,475 | [Statista — Denmark physiotherapists employed 2002–2020](https://www.statista.com/statistics/550687/physiotherapists-employment-in-denmark/) | 2020 figure. |
| Finland registered physiotherapists | 17,000 | [Finnish Association of Physiotherapists — World Physiotherapy](https://world.physio/membership/finland) | ~17k registered physios based on Valvira + SF/Suomen Fysioterapeutit. |
| Total Nordics physiotherapists | 50,864 | Sum | Denmark + Sweden + Norway + Finland. |

## 2. Competitor pricing benchmarks

| Product | Price | Source | Note |
|---|---|---|---|
| Groovi (SA) | R335/mo | [Groovi Subscription Plans](https://physiosoftware.groovimovements.co.za/choose-your-subscription-plan/) | Only meaningful SA comp. Library-first, no custom capture. |
| Physitrack | US$21.99/mo | [Physitrack Support — pricing](https://support.physitrack.com/article/159-how-much-does-physitrack-cost) | Per-practitioner, volume discount >100 practitioners. |
| PT Distinction | US$19.90 (3 clients) → US$80 (50 clients) | [PT Distinction Pricing](https://www.ptdistinction.com/pricing) | Client-based tiering. |
| TrueCoach | US$26 (5 clients) → US$137 (21+ clients) | [TrueCoach Pricing](https://truecoach.co/pricing/) | Client-based tiering. 5% processing fee on in-app payments. |
| Medbridge HEP Essentials | US$149/seat/year | [Medbridge Physical Therapy Software](https://www.medbridge.com/physical-therapy-software) | |
| HEP2go | US$4.99–7/mo | Search summary from [PtPioneer / Medbridge-vs-HEP2go](https://www.medbridge.com/blog/medbridge-vs-hep2go) | Minimal-feature budget option. |
| Rehab My Patient | ~US$14/mo | Cited in existing `docs/MARKET_RESEARCH.md` | WhatsApp-capable. |

**Blended competitor ARPU (SMB segment):** ~US$30/practitioner/month = ~R570 at R19/USD. Most direct SA comp (Groovi) is R335/mo.

**homefit.studio pricing (credit bundles, provisional):**
- 10 credits / R250 → R25/credit effective
- 50 credits / R1,125 → R22.50/credit effective
- 200 credits / R4,000 → R20.00/credit effective

One credit publishes a plan of 1–8 exercises (most plans). Expected
plans-per-practitioner-per-month heuristic: a biokineticist sees ~50–80
clients weekly; typical client gets a refreshed plan every 4–6 weeks.
Active practitioners plausibly publish 30–60 plans/month. With our clamped
credit cost, that's ~30–90 credits/month. At the base 50-bundle price
that's R22.50 × 45 credits ≈ R1,000/mo blended revenue per active
practitioner — **higher** than Groovi's R335 (because we're per-plan, not
per-seat) and clean to reduce via bundle discounts if needed.

## 3. Funnel

| Stage | Base rate | Source | Note |
|---|---|---|---|
| Reachable → signup (paid + referral, yr 1) | 2.0% | [B2B SaaS Funnel Benchmarks (Digital Bloom)](https://thedigitalbloom.com/learn/pipeline-performance-benchmarks-2025/); Carl's wife-of-biokineticist warm-market bootstrap | Conservative — reflects cold reach (LinkedIn + wife-of-biokineticist warm-market seeding). |
| Signup → activation (first published plan) | 37.5% | [Agile Growth Labs User Activation 2025](https://www.agilegrowthlabs.com/blog/user-activation-rate-benchmarks-2025/) | Matches 2025 SaaS median. Three free credits give practitioners ~3 real client tests — mechanism is favourable. |
| Activation → paid (buys 1st bundle) | 21.5% | [1Capture Free Trial Conversion Benchmarks 2025](https://www.1capture.io/blog/free-trial-conversion-benchmarks-2025); Healthcare/MedTech = 21.5% | Healthcare/MedTech trial→paid. Ours is less regulated than pure healthcare, so 21.5% is slightly conservative. |
| Referral conversion (referee signs up via `/r/{code}`) | 22% | [WallStreetPrep Viral Coefficient](https://www.wallstreetprep.com/knowledge/viral-coefficient/); [M Accelerator Referral vs Viral](https://maccelerator.la/en/blog/entrepreneurship/referral-vs-viral-growth-conversion-rate-comparison/) | "B2B SaaS referral conversion 15–25%." |
| Avg referrals per activated practitioner per year | 0.35 | Derived — single-tier, non-cash incentive | 5% lifetime rebate + free credits is weaker than a cash bounty. SaaSQuatch / Viral Loops benchmarks for non-cash incentives cluster at 0.2–0.5 referrals/user/year. |

## 4. Retention / churn

| Assumption | Value | Source | Note |
|---|---|---|---|
| Monthly logo churn (practitioner) | 4.0% | [SaaS Churn Rate Benchmarks 2025 (WeAreFounders)](https://www.wearefounders.uk/saas-churn-rates-and-customer-acquisition-costs-by-industry-2025-data/); [SaaS Churn Benchmarks 2025 (AgileGrowthLabs)](https://www.agilegrowthlabs.com/blog/saas-churn-rate-benchmarks-2025/) | SMB SaaS range 3–5%; healthcare clinical SaaS lower (2.4%) due to workflow lock-in, wellness higher (7.5%). Practitioners are SMB-single-user with no EHR lock-in → 4.0% base. |
| 90-day early churn adjustment | +3pp in first 3 months | [UserJot / Vitally SMB churn concentration](https://userjot.com/blog/saas-churn-rate-benchmarks) | "43% of all SMB customer losses occur within the first quarter." Modelled as 7% churn for months 1–3, 4% thereafter. |
| Avg credit pack decay (credits used vs purchased) | 85% | Carl assumption; comparable to Mailchimp / Slack inactive-credit benchmarks | Some credits expire / sit on account; revenue is recognised on purchase but economically ~15% never consumed (POPIA retention window). No free-credit expiry in base case. |

## 5. Customer acquisition cost

| Assumption | Base value | Source | Note |
|---|---|---|---|
| LinkedIn CPC (SA, healthcare) | R45 | [Prebo Digital — LinkedIn Ads SA](https://pages.prebodigital.co.za/linkedin-advertising-rates-south-africa); [Closely LinkedIn benchmarks — healthcare CPC $6–10](https://blog.closelyhq.com/linkedin-ad-benchmarks-cpc-cpm-and-ctr-by-industry/) | SA CPC R20–60; healthcare is top quartile = R45. |
| Google Ads CPC (SA, healthcare) | R25 | [ScoPe Google Ads Cost SA 2025](https://scope.co.za/google-ads-costs/); [Daikimedia Google Ads 2025](https://www.daikimedia.com/blog/google-ads-cost-in-south-africa-2025-industry-benchmarks-budgeting) | SA range R3–30 general, healthcare top-end. |
| Click → signup (paid traffic) | 8% | [LinkedIn Ads Benchmarks 2026 — 6.1% CVR](https://meet-lea.com/en/blog/linkedin-advertising-costs-roi-benchmarks) | 6.1% LinkedIn CVR; we're a niche product so ~8% for targeted healthcare creative. |
| Blended paid CAC | R520 | Derived: (R45 CPC × 1/8% CVR) × 92% (weighted 50/50 LinkedIn/Google) | ≈ US$27. SMB B2B SaaS CAC benchmark is US$200–300; ours is low because of niche-targeted + small SA market. |
| Referral CAC (variable) | R30 | Derived | 5% lifetime rebate is ~R50 value spread over referred LTV; no paid spend. |
| Warm-market / organic CAC | R0 | Wife-of-biokineticist seed network + BASA / conferences | First 50–150 signups are free via Melissa's network and professional bodies (CPD talks, biokineticist forum). |

## 6. Infrastructure cost

| Resource | Base cost | Source | Note |
|---|---|---|---|
| Supabase Pro | US$25/mo + usage | [Supabase Pricing](https://supabase.com/pricing) | 8GB DB, 100GB storage, 250GB egress included. |
| Supabase bandwidth overage | US$0.09/GB | [Metacto Supabase Pricing Breakdown](https://www.metacto.com/blogs/the-true-cost-of-supabase-a-comprehensive-guide-to-pricing-integration-and-maintenance) | Biggest cost surprise — we egress signed-URL media. |
| Supabase MAU overage | US$0.00325/MAU above 100K | [Supabase Pricing](https://supabase.com/pricing) | Not relevant until Y3+. |
| Vercel Pro | US$20/seat/mo, incl. 1TB bandwidth + 10M edge req | [Vercel Pricing](https://vercel.com/pricing); [Flexprice Vercel Breakdown](https://flexprice.io/blog/vercel-pricing-breakdown) | 1 seat = Carl. +$20 flexible credit applied. |
| Vercel bandwidth overage | US$0.15/GB | [Flexprice Vercel](https://flexprice.io/blog/vercel-pricing-breakdown) | |
| Hostinger domain | R250/yr | Flat | Registered cost. |
| Apple Developer Program | US$99/yr | Standard | |
| GitHub / Vercel team | included in Vercel Pro seat | | |
| Monthly infra floor (Y1) | R1,200 | =Supabase Pro + Vercel Pro + domain amortised | Before any usage. |
| Per-practitioner variable (media egress) | R4/mo | Derived: 500MB avg monthly egress × US$0.09 × R19 | Line-drawings are tiny; grayscale + original are larger but consent-gated and cached in SW. |
| Per-practitioner marginal (DB + functions) | R2/mo | Derived | |

## 7. PayFast + VAT + SA tax

| Assumption | Value | Source |
|---|---|---|
| PayFast credit-card fee | 3.2% + R2.00 per txn | [Payfast Fees page](https://payfast.io/fees/) |
| PayFast instant EFT | 2.0% + R2.00 | [Payfast Fees page](https://payfast.io/fees/) |
| PayFast payout fee (standard) | R8.70 per payout | [Payfast Fees page](https://payfast.io/fees/) |
| PayFast volume negotiation threshold | >R50,000/month avg over 3 months | [Payfast Fees page](https://payfast.io/fees/) |
| Assumed blended txn fee (Y1–Y2) | 3.1% + R2.00 | Derived (90% card / 10% EFT). |
| Assumed blended txn fee (Y3+) | 2.7% + R2.00 | Volume discount kicks in past R50k/mo. |
| SA VAT on digital services | 15% | [SARS / Anrok SA VAT digital](https://www.anrok.com/vat-software-digital-services/south-africa) |
| SA VAT registration threshold | R2.3M annual turnover | [Business Tech Africa VAT Threshold April 2026](https://www.businesstechafrica.co.za/business/2026/04/14/vat-threshold-increase-a-practical-win-for-south-african-smes/) | Effective 1 April 2026. |
| VAT treatment for the model | Revenue quoted VAT-inclusive; VAT backed out above threshold | — | Below R2.3M: VAT optional (voluntary ≥R120k). Base case: register voluntarily in Y2 when near R1M run-rate for credibility. |

## 8. Adherence stat — pricing justification

- 50–70% non-compliance baseline; 38.1% → 77.4% with visual take-home
  materials (2x uplift). [Source: existing `docs/MARKET_RESEARCH.md`].
- Meta-analysis of 26 video-based HEP studies (1,292 older adults):
  retention 91.1%, attendance 85.0%.
  [Rihova et al. 2024 — Telemedicine & eHealth](https://pubmed.ncbi.nlm.nih.gov/39072676/)
- Digital-rehab systematic review: significant short-term adherence
  improvement, long-term effects less certain.
  [JOSPT 2022](https://www.jospt.org/doi/10.2519/jospt.2022.11384)

Practical implication for the model: an individual biokineticist earning
~R650/session and seeing an adhering-client-re-booking-rate uplift of even
5pp translates to ~R15k/year extra revenue per retained client. Against
homefit.studio at R22.50/credit × ~50 credits/month = R1,125/month, the
ROI is 13x. This is the pricing-defence number on `Sheet 7`.

## 9. Numbers that are intentionally "opinion" (not sourced)

These are bets. Flagged explicitly so the reviewer can tweak.

| Assumption | Base | Conservative | Optimistic |
|---|---|---|---|
| Y1 ending practitioners (SA) | 180 | 80 | 350 |
| Y5 ending practitioners (SA) | 2,200 | 900 | 4,500 |
| International expansion start | Y3 Q1 | Y4 Q2 | Y2 Q3 |
| AI-pipeline premium tier launch | Y4 | never | Y3 |
| Avg plans/practitioner/month | 35 | 15 | 60 |

All three scenarios share the same cost curve — only the driver
assumptions in this table change.

## 10. LTV / CAC target

- Industry median LTV:CAC = 3.2:1 ([Optifai 939 Companies B2B SaaS LTV Benchmarks](https://optif.ai/learn/questions/b2b-saas-ltv-benchmark/)).
- Target for our model = **≥4:1** by Y3. SMB SaaS CAC payback target <12 months
  ([First Page Sage CAC Payback 2025](https://firstpagesage.com/reports/saas-cac-payback-benchmarks/)).
- Base-case LTV: ARPU (R800/mo net of VAT+PayFast) × gross margin 82% × (1/0.04 monthly churn) = **R16,400**.
- Base-case blended CAC: R260 (50% warm / 30% paid / 20% referral).
- Base-case LTV:CAC = **63:1** — implausibly high, driven by SA CAC being low. In year 4+ international expansion, CAC rises to ~R1,200 (LinkedIn targeting + event presence), LTV stays similar → **~14:1**. Still very healthy; reflects how niche + viral the product is.

## 11. Gotchas the user should know about

1. **Per-plan pricing is non-standard.** Most comps are per-seat subscriptions. Our revenue is lumpier — a practitioner who goes on leave stops publishing and stops paying. Modelled via utilisation factor (`plans/practitioner/month`), not seat count.
2. **Credit expiry is off in base case.** If Carl introduces credit expiry to force recurrence, revenue recognition simplifies but churn appears earlier. Both variants tested in scenario toggle.
3. **International expansion has no CAC curve yet.** Numbers are placeholder at 3x SA CAC; real LinkedIn UK/AU CPCs are 2.5–4x SA.
4. **AI-pipeline costs are excluded.** Parked per the brief. Their inclusion would require a Stability AI / Kling cost-per-generation model (~US$0.05–0.20/ video).
5. **Melissa-driven warm market.** First 50–150 signups are free via Carl's wife's network. This deflates Y1 CAC meaningfully. The model exposes this as a separate "warm signups" cohort with CAC = R0.

## 12. Access dates

All URLs in this document accessed **2026-04-20**.
