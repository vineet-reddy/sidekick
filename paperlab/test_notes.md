# Sidekick Test Notes — Niche Scientist Inputs

> **Purpose:** Every note below simulates a real scientist typing into Sidekick.
> Notes are messy on purpose: misspellings, jargon, no dataset specified,
> shorthand, vague phrasing. The app must resolve datasets, run analysis,
> and produce a Paper (not a Memo) for each one — or have an extremely
> good reason documented in `memo_reasons` if it can't.
>
> **How to use this file as a verification gate:**
>
> ```
> for note in notes:
>     result = paperlab run --notes "$note"
>     assert result.route == "paper" or memo_reasons are justified
>     assert result.validation.paper_checks all pass (for papers)
>     assert result.artifacts are non-empty
>     assert result.sources have reproducible receipts
> ```
>
> An overnight agent should treat any unexpected Memo routing or resolution
> block as a bug to investigate, not a note to skip.

---

## Category 1: Cancer Genomics (GDC / cBioPortal targets)

### Note 1 — GBM sex differences
```
are there sex-based differnces in survival outcomes for glioblastoma multiforme patients?
specifically interested in IDH mutant vs wildtype stratified by gender
```

### Note 2 — BRCA somatic landscape
```
somatic mutation landscape in BRCA1/BRCA2 carriers with triple-negative breast cancer
vs non-carriers. want to know which genes are differentially mutated
```

### Note 3 — Pediatric sarcoma copy number
```
copy number alterations in pediatric ewing sarcoma, especially STAG2 deletions
and their correlaiton with patient age at diagnosis
```

### Note 4 — Pancreatic cancer driver co-occurrence
```
co-occurance of KRAS G12D and TP53 mutations in pancreatic ductal adenocarcinoma
and whether SMAD4 loss modifies prognosis
```

### Note 5 — Melanoma immunotherapy TMB
```
tumor mutational burden as a predictor of immunotherpy response in cutaneous melanoma,
compare high vs low TMB groups on progression-free survival
```

### Note 6 — Lung adenocarcinoma fusions
```
prevalence of ALK and ROS1 gene fusions in lung adenocarcinoma among never-smokers,
any age or ethnic disparities?
```

---

## Category 2: Gene Expression / Functional Genomics (GEO targets)

### Note 7 — IBD intestinal transcriptomics
```
differentially expressed genes in ileal biopsies from crohn's disease vs ulcerative
colitus patients, especially interested in autophagy pathways like ATG16L1 and NOD2
```

### Note 8 — Preeclampsia placental RNA
```
transcriptomic changes in placental tissue from preeclamptic pregnancys compared to
normotensive controls, are angiogenic factors like VEGF and sFlt-1 dysregulated at
the mRNA level?
```

### Note 9 — ALS motor neuron expression
```
gene expression profiling of motor neurons from ALS patients vs healthy controls,
particularly TDP-43 and FUS pathways. interested in spinal cord tissue not blood
```

### Note 10 — Psoriasis skin lesions
```
rnaseq of lesional vs non-lesional skin in psoriasis patients, what are the top
upregulated IL-17 pathway genes and is there a th17 signiture?
```

### Note 11 — Single-cell kidney fibrosis
```
single cell rnaseq of kidney biopsy from patients with diabetic nephropathy,
which cell types show the strongest fibrotic gene signatrue (COL1A1, ACTA2, etc)
```

---

## Category 3: Neurophysiology (DANDI / OpenNeuro targets)

### Note 12 — Hippocampal sharp-wave ripples
```
sharp wave ripple events in hippocampal CA1 recordings, does ripple frequency
correlate with memory consolidaton performance? need electrophysiology data
from rodent models
```

### Note 13 — Resting-state fMRI in ADHD
```
resting state fMRI connectivity in children with ADHD vs typically developing controls,
specifically default mode network and fronto-parietal network coupling differences
```

### Note 14 — EEG epilepsy seizure onset
```
intracranial eeg recordings from epilepsy patients, can we identify pre-seizure
spectral changes in the gamma band 30-100 hz in the seizure onset zone?
```

### Note 15 — Neuropixels visual cortex
```
neuropixels recordings from mouse visual cortex during oriented grating stimuli,
what is the distribution of orientation selectivity across cortical layers?
```

---

## Category 4: Epidemiology / Public Health (Dataverse / Zenodo / Figshare targets)

### Note 16 — Arsenic groundwater Bangladesh
```
arsenic contamination in groundwater wells in bangladesh, is there a spatial
correlation between well depth and arsenic concentration above WHO guidlines
(10 ug/L)? any publicly available well survey data
```

### Note 17 — COVID vaccine hesitancy rural US
```
vaccine hesitency survey data from rural US populations during covid-19,
what demographic factors (age, education, political affiliation) best predict
refusal? need actual survey microdata not aggregated stats
```

### Note 18 — Malaria drug resistance markers
```
prevalence of pfkelch13 mutations associated with artemisinin resistance in
plasmodium falciparum isolates from southeast asia, has the C580Y allele
frequency changed between 2015-2023?
```

### Note 19 — Maternal mortality sub-Saharan Africa
```
maternal mortality ratios across sub-saharan african countries, is there a
relationship between skilled birth attendence rates and MMR after controlling
for GDP per capita?
```

---

## Category 5: Bibliometric / Literature (OpenAlex targets)

### Note 20 — CRISPR publication trends
```
publication trends for CRISPR-Cas9 research from 2012-2024, which institutions
have the highest output and how has the field shifted from basic science to
clinical applications?
```

### Note 21 — Retraction rates by field
```
retraction rates across biomedical subfields (oncology, cardiology, psychiatry, etc),
are certain journals or countries disproportionately represented in retractions?
need citation-level data not just counts
```

### Note 22 — AI in radiology literature
```
systematic mapping of artificial intellegence applications in diagnostic radiology,
what proportion of published studies have external validation cohorts and how has
this changed since 2018?
```

---

## Category 6: Cross-domain / Ambiguous / Edge Cases

### Note 23 — Microbiome + metabolomics (no obvious single family)
```
gut microbiome composition (16S or shotgun metagenomic) in patients with
major depressive disorder, any correlation with tryptophan metabolites or
short-chain fatty acid levels?
```

### Note 24 — Climate + ecology (not a standard biomedical domain)
```
coral reef bleaching events in the great barrier reef from satellite-derived
sea surface temp data, is bleaching severity correlated with el nino
intensity index?
```

### Note 25 — Agricultural genomics (niche, not standard medical)
```
genome wide association study for drought tolerence in rice (oryza sativa),
which loci on chromosomes 1 and 9 are significantly associated with root
depth under water-deficit conditions?
```

### Note 26 — Extremely terse note
```
p53 mutations colorectal cancer survival
```

### Note 27 — Run-on stream of consciousness
```
so i was reading about how statins might have anti-cancer properties beyond
their lipid lowering effects and im wondering if theres any large cohort data
showing whether patients on long term statin therapy have different cancer
incidence rates especially for colorectal and breast cancer adjusting for
age bmi smoking etc
```

### Note 28 — Non-English scientific terms mixed in
```
differential expression of Hox genes in drosophila melanogaster embryogenesis,
specifically the bithorax complex (BX-C), comparing wildtype to Ubx null mutants.
are there publicly available microarray or rnaseq datasets from embryonic stages?
```

### Note 29 — Methods-heavy request (simulation-adjacent)
```
benchmarking dimensionality reduction methods (PCA, t-SNE, UMAP) on high-dimensional
single cell rna-seq data, which method best preserves global structure as measured
by trustworthyness and continuity metrics? use a real dataset not simulated
```

### Note 30 — Theoretical but with empirical angle
```
testing the neutral theory of molecular evolution using synonymous substitution
rates (dN/dS) across mammalian orthologs, do housekeeping genes show stronger
purifying selection than tissue-specific genes?
```

---

## Category 7: Intentionally Tricky / Adversarial

### Note 31 — Mentions a fake database
```
i need data from the Global Neurofibromatosis Registry (GNFR) on tumor burden
in NF1 patients stratified by age of onset, compare pediatric vs adult presentation
```

### Note 32 — Asks for proprietary/paywalled data indirectly
```
patient-level data from the Framingham Heart Study on left ventricular mass index
trajectories over 20 years, stratified by hypertension status
```

### Note 33 — Extremely niche rare disease
```
whole exome sequencing of patients with Wolfram syndrome (DIDMOAD), looking for
WFS1 and CISD2 variant spectrum and genotype-phenotype correlaitons for diabetes
insipidus severity
```

### Note 34 — Multiple typos and abbreviations
```
DEGs in NSCLC pts w/ EGFR exon 19 del vs L858R comparing tx-naive vs post-TKI
resistence, any publically avail RNAseq?
```

### Note 35 — Ambiguous between review and empirical
```
what do we know about the role of ferroptosis in hepatocellular carcinoma and
can we find any expression data showing GPX4 or SLC7A11 levels in HCC vs
normal liver?
```

---

## Category 8: Real-world Messy Scientist Notes

### Note 36 — PI forwarding a grant aim
```
Aim 2: Characterize the spatial transcriptomic landscape of the tumor
microenvironment in high-grade serous ovarian cancer, with emphasis on
T-cell exclusion zones and CAF subtypes. Use publicly available data.
```

### Note 37 — Grad student's half-formed idea
```
something about circadian rhythm genes and depression? like CLOCK and BMAL1
expression in post-mortem brain tissue from MDD patients. is there data for this
```

### Note 38 — Wet-lab scientist wanting computational validation
```
we found METTL3 is upregulated in our AML cell lines by western blot. can you
check if m6A writers (METTL3, METTL14, WTAP) are also upregulated in AML
patient samples vs normal bone marrow at the transcriptomic level?
```

### Note 39 — Clinical researcher's natural language
```
looking at whether there are racial disparites in stage at diagnosis for
prostate cancer in the US, specifically comparing black and white men under 55.
need real registry data not published summary tables
```

### Note 40 — Postdoc's quick Slack-style message
```
hey can you check if there's a correlation between tumor purity estimates and
overall survival in TCGA low grade glioma (LGG)? someone mentioned this at
journal club
```

---

# Verification Protocol for Overnight Agents

When using this file as a gate, the agent should:

1. **Run each note** through `paperlab run --notes "<note text>"` (or equivalent pipeline call)
2. **For each run, check:**
   - Did resolution succeed? If blocked, is the block justified or a bug?
   - Did the workspace produce a non-empty ledger with real artifacts?
   - Did validation approve at least one result with reproducible source receipts?
   - Did paper_checks all pass? If not, which failed and why?
   - Was the final route `paper` or `memo`? If memo, are the `memo_reasons` genuine
     limitations of the note, or failures of the pipeline?
3. **Classification of failures:**
   - **Pipeline bug:** The note is reasonable and an open dataset exists, but the
     pipeline failed to find it, use it, or validate the work. *Fix the pipeline.*
   - **Note limitation:** The note genuinely asks for something that can't be done
     with open data (e.g., proprietary Framingham data). *Document and skip.*
   - **Resolver gap:** A real open dataset exists but isn't in any source family.
     *Add the source family or widen discovery.*
4. **Success criteria for calling the job done:**
   - Notes 1–15, 20–22, 26–30, 34–40 should all produce Papers (not Memos)
   - Notes 16–19 should produce Papers if suitable open data is found, Memos if not
     (but the resolver should at least *try* Zenodo/Dataverse/Figshare)
   - Notes 23–25 are stretch goals — Papers if the resolver can find data outside
     standard biomedical families
   - Notes 31–32 are expected to gracefully degrade (Memo with clear explanation),
     not crash or hallucinate a fake dataset
   - Note 33 may Memo due to rare disease data scarcity — acceptable if documented
   - Note 35 should resolve the ambiguity and attempt empirical analysis
5. **No note should cause:**
   - An unhandled exception or crash
   - A Paper routed from synthetic/simulated data
   - A source with no reproducible receipt passing validation
   - Banned language in the final manuscript
