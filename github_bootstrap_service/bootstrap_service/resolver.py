from __future__ import annotations

import json
import re
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


@dataclass(frozen=True)
class PaperModeSpec:
    id: str
    label: str
    description: str
    forbidden_primary_family_ids: list[str]


@dataclass(frozen=True)
class SourceFamilySpec:
    id: str
    label: str
    family_type: str
    supported_paper_modes: list[str]
    unit_of_analysis: str
    modalities: list[str]
    trusted_domains: list[str]
    allow_in_automatic_mode: bool
    search_keywords: list[str]
    minimum_case_count: int | None = None
    minimum_asset_count: int | None = None
    minimum_result_count: int | None = None


@dataclass(frozen=True)
class DatasetCandidate:
    family_id: str
    family_label: str
    dataset_id: str
    title: str
    summary: str
    access_url: str
    primary_domain: str
    trusted_domains: list[str]
    unit_of_analysis: str
    modalities: list[str]
    score: float
    evidence_count: int | None
    qualifies_as_primary_data: bool
    provenance_note: str
    api_url: str | None = None
    download_urls: list[str] | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "family_id": self.family_id,
            "family_label": self.family_label,
            "dataset_id": self.dataset_id,
            "title": self.title,
            "summary": self.summary,
            "access_url": self.access_url,
            "primary_domain": self.primary_domain,
            "trusted_domains": self.trusted_domains,
            "unit_of_analysis": self.unit_of_analysis,
            "modalities": self.modalities,
            "score": round(self.score, 3),
            "evidence_count": self.evidence_count,
            "qualifies_as_primary_data": self.qualifies_as_primary_data,
            "provenance_note": self.provenance_note,
            "api_url": self.api_url,
            "download_urls": self.download_urls or [],
        }


@dataclass(frozen=True)
class ResolutionBundle:
    paper_mode: str
    inferred_modalities: list[str]
    acceptable_units: list[str]
    incompatible_primary_family_ids: list[str]
    status: str
    summary: str
    blocking_reason: str | None
    selected_candidate: DatasetCandidate | None
    candidates: list[DatasetCandidate]

    def as_dict(self) -> dict[str, Any]:
        return {
            "paper_mode": self.paper_mode,
            "inferred_modalities": self.inferred_modalities,
            "acceptable_units": self.acceptable_units,
            "incompatible_primary_family_ids": self.incompatible_primary_family_ids,
            "status": self.status,
            "summary": self.summary,
            "blocking_reason": self.blocking_reason,
            "selected_candidate": self.selected_candidate.as_dict() if self.selected_candidate else None,
            "candidates": [candidate.as_dict() for candidate in self.candidates],
        }


class SourceFamilyRegistry:
    def __init__(self) -> None:
        resources_root = Path(__file__).resolve().parent / "resources"
        self._paper_modes = {
            payload["id"]: PaperModeSpec(**payload)
            for payload in json.loads((resources_root / "paper_modes.json").read_text(encoding="utf-8"))
        }
        self._source_families = {
            payload["id"]: SourceFamilySpec(**payload)
            for payload in json.loads((resources_root / "source_families.json").read_text(encoding="utf-8"))
        }

    def paper_mode(self, paper_mode_id: str) -> PaperModeSpec:
        return self._paper_modes[paper_mode_id]

    def source_families(self) -> list[SourceFamilySpec]:
        return list(self._source_families.values())


class SourceFamilyResolver:
    def __init__(self, registry: SourceFamilyRegistry | None = None) -> None:
        self._registry = registry or SourceFamilyRegistry()

    def resolve(
        self,
        *,
        title: str,
        theme: str,
        notes: list[dict[str, Any]],
        dataset_hints: list[str],
        dataset_ids: list[str] | None = None,
    ) -> ResolutionBundle:
        text = " ".join(
            [title, theme] + [str(note.get("title") or "") + " " + str(note.get("content") or "") for note in notes]
        ).lower()
        paper_mode = self._classify_paper_mode(text)
        inferred_modalities, acceptable_units = self._infer_modalities_and_units(text, paper_mode)
        mode_spec = self._registry.paper_mode(paper_mode)
        normalized_dataset_ids = self._normalize_dataset_ids(dataset_ids)

        families = [
            family for family in self._registry.source_families()
            if paper_mode in family.supported_paper_modes
            and family.allow_in_automatic_mode
            and self._family_is_compatible(family, inferred_modalities, paper_mode)
        ]
        ranked_families = sorted(
            families,
            key=lambda family: self._family_priority_score(family, inferred_modalities, text),
            reverse=True,
        )

        candidates = self._lookup_explicit_candidates(
            ranked_families=ranked_families,
            dataset_ids=normalized_dataset_ids,
            text=text,
            dataset_hints=dataset_hints,
        )
        if candidates:
            return self._resolution_from_candidates(
                paper_mode=paper_mode,
                inferred_modalities=inferred_modalities,
                acceptable_units=acceptable_units,
                forbidden_primary_family_ids=mode_spec.forbidden_primary_family_ids,
                candidates=candidates,
                skip_family_bias=True,
            )
        seen_candidates = {(candidate.family_id, candidate.dataset_id) for candidate in candidates}
        for family in ranked_families[:10]:
            for candidate in self._search_family(family, text, dataset_hints):
                key = (candidate.family_id, candidate.dataset_id)
                if key in seen_candidates:
                    continue
                candidates.append(candidate)
                seen_candidates.add(key)

        candidates = [
            replace(
                candidate,
                score=candidate.score + self._candidate_family_bias(candidate.family_id, text),
            )
            for candidate in candidates
        ]
        return self._resolution_from_candidates(
            paper_mode=paper_mode,
            inferred_modalities=inferred_modalities,
            acceptable_units=acceptable_units,
            forbidden_primary_family_ids=mode_spec.forbidden_primary_family_ids,
            candidates=candidates,
        )

    def _resolution_from_candidates(
        self,
        *,
        paper_mode: str,
        inferred_modalities: list[str],
        acceptable_units: list[str],
        forbidden_primary_family_ids: list[str],
        candidates: list[DatasetCandidate],
        skip_family_bias: bool = False,
    ) -> ResolutionBundle:
        ranked_candidates = candidates if skip_family_bias else list(candidates)
        ranked_candidates.sort(key=lambda candidate: candidate.score, reverse=True)

        if paper_mode == "empirical_dataset":
            ranked_candidates = [
                candidate for candidate in ranked_candidates
                if candidate.family_id not in forbidden_primary_family_ids
            ]
            qualifying = [candidate for candidate in ranked_candidates if candidate.qualifies_as_primary_data]
            if not qualifying:
                return ResolutionBundle(
                    paper_mode=paper_mode,
                    inferred_modalities=inferred_modalities,
                    acceptable_units=acceptable_units,
                    incompatible_primary_family_ids=forbidden_primary_family_ids,
                    status="blocked",
                    summary="No qualifying open empirical dataset was resolved from the trusted source families.",
                    blocking_reason=(
                        "No qualifying open dataset found for this empirical question across the trusted source families. "
                        "The run should block before manuscript writing rather than invent synthetic evidence."
                    ),
                    selected_candidate=None,
                    candidates=ranked_candidates[:8],
                )
            selected = qualifying[0]
            return ResolutionBundle(
                paper_mode=paper_mode,
                inferred_modalities=inferred_modalities,
                acceptable_units=acceptable_units,
                incompatible_primary_family_ids=forbidden_primary_family_ids,
                status="resolved",
                summary=f"Selected {selected.title} from {selected.family_label} as the primary empirical source.",
                blocking_reason=None,
                selected_candidate=selected,
                candidates=ranked_candidates[:8],
            )

        selected = ranked_candidates[0] if ranked_candidates else None
        if selected is None:
            return ResolutionBundle(
                paper_mode=paper_mode,
                inferred_modalities=inferred_modalities,
                acceptable_units=acceptable_units,
                incompatible_primary_family_ids=forbidden_primary_family_ids,
                status="blocked",
                summary="No compatible source family could be resolved for this note.",
                blocking_reason="No compatible source family could be resolved for this note.",
                selected_candidate=None,
                candidates=[],
            )

        return ResolutionBundle(
            paper_mode=paper_mode,
            inferred_modalities=inferred_modalities,
            acceptable_units=acceptable_units,
            incompatible_primary_family_ids=forbidden_primary_family_ids,
            status="resolved",
            summary=f"Selected {selected.title} from {selected.family_label}.",
            blocking_reason=None,
            selected_candidate=selected,
            candidates=ranked_candidates[:8],
        )

    def _classify_paper_mode(self, text: str) -> str:
        if any(phrase in text for phrase in ["literature review", "systematic review", "narrative review", "meta-analysis"]):
            return "literature_review"
        if any(phrase in text for phrase in ["bibliometric", "citation network", "publication trend", "scholarly output"]):
            return "bibliometric"
        if any(
            phrase in text for phrase in [
                "kitaev chain",
                "bdg formalism",
                "bogoliubov-de gennes",
                "braiding operators",
                "clifford gates",
                "heavy math paper",
                "fault-tolerant quantum",
                "surface code threshold",
                "majorana zero modes",
            ]
        ):
            return "theoretical_commentary"
        if any(phrase in text for phrase in ["simulation study", "benchmark", "methods paper", "synthetic benchmark"]):
            return "methods_simulation"
        if any(phrase in text for phrase in ["commentary", "perspective", "opinion", "theoretical"]):
            return "theoretical_commentary"
        return "empirical_dataset"

    def _infer_modalities_and_units(self, text: str, paper_mode: str) -> tuple[list[str], list[str]]:
        modalities: list[str] = []
        acceptable_units: list[str] = []
        prevalence_terms = ["prevalence", "incidence", "epidemiology", "cohort", "registry", "survey"]

        if self._contains_any_phrase(text, ["glioblastoma", "gbm", "tumor", "cancer", "mutation", "survival"]):
            modalities.append("cancer_genomics")
            acceptable_units.extend(["patient", "tumor_sample"])

        if self._contains_any_phrase(text, prevalence_terms):
            modalities.append("clinical_cohort")
            acceptable_units.extend(["patient", "subject", "row"])

        epilepsy_tokens = ["epilepsy", "seizure", "seizures", "epileptic"]
        specific_neurophysiology_tokens = ["ecog", "ieeg", "lfp", "spike", "rns", "responsive neurostimulation", "eeg"]
        generic_neurophysiology_tokens = ["signal", "signals", "recording", "recordings"]
        mentions_specific_neurophysiology = self._contains_any_phrase(text, specific_neurophysiology_tokens)
        mentions_generic_neurophysiology = self._contains_any_phrase(text, generic_neurophysiology_tokens)
        negates_neurophysiology = self._negates_any_phrase(
            text,
            specific_neurophysiology_tokens + ["recording", "recordings", "signal", "signals"],
        )
        prevalence_or_cohort_focus = self._contains_any_phrase(text, prevalence_terms)
        if self._contains_any_phrase(text, epilepsy_tokens) and (
            (mentions_specific_neurophysiology and not negates_neurophysiology)
            or (mentions_generic_neurophysiology and not negates_neurophysiology and not prevalence_or_cohort_focus)
            or (mentions_generic_neurophysiology and not negates_neurophysiology and self._contains_any_phrase(text, ["recording", "recordings"]))
        ):
            modalities.append("neurophysiology")
            acceptable_units.extend(["recording_session", "subject"])
        elif self._contains_any_phrase(text, epilepsy_tokens):
            modalities.append("clinical_cohort")
            acceptable_units.extend(["patient", "subject"])

        gene_expression_terms = ["gene expression", "transcript", "transcripts", "rna-seq", "rnaseq", "single-cell", "single cell", "microarray"]
        if self._contains_any_phrase(text, gene_expression_terms) and not self._negates_any_phrase(text, gene_expression_terms):
            modalities.append("gene_expression")
            acceptable_units.extend(["sample", "cell"])

        if paper_mode in {"bibliometric", "literature_review"} and any(
            token in text for token in ["citation", "literature", "publication", "paper", "author", "journal", "review"]
        ):
            modalities.append("bibliographic")
            acceptable_units.append("article")

        if not modalities:
            modalities.append("general_empirical")
            acceptable_units.append("row")

        return sorted(set(modalities)), sorted(set(acceptable_units))

    def _family_is_compatible(
        self,
        family: SourceFamilySpec,
        inferred_modalities: list[str],
        paper_mode: str,
    ) -> bool:
        if paper_mode in {"bibliometric", "literature_review"}:
            return bool(set(family.modalities).intersection({"bibliographic", "literature"}))

        specific_modalities = [
            modality for modality in inferred_modalities
            if modality not in {"bibliographic", "literature", "general_empirical"}
        ]
        if not specific_modalities:
            return True
        family_modalities = set(family.modalities)
        compatibility_expansions = {
            "clinical_cohort": {"clinical_cohort", "general_empirical", "tabular"},
        }
        for modality in specific_modalities:
            acceptable_family_modalities = compatibility_expansions.get(modality, {modality})
            if family_modalities.intersection(acceptable_family_modalities):
                return True
        return False

    def _family_priority_score(self, family: SourceFamilySpec, inferred_modalities: list[str], text: str) -> float:
        score = 0.0
        family_type_boost = {
            "direct_runtime_source": 12,
            "domain_repository": 8,
            "general_repository": 5,
            "discovery_catalog": 1,
        }
        score += family_type_boost.get(family.family_type, 0)
        score += sum(8 for modality in inferred_modalities if modality in family.modalities)
        score += sum(3 for keyword in family.search_keywords if keyword in text)
        if any(token in text for token in ["prevalence", "incidence", "epidemiology", "cohort", "registry", "survey"]):
            if "clinical_cohort" in family.modalities:
                score += 12
            if any(phrase in text for phrase in ["not recordings", "not recording", "not eeg", "not ieeg", "not ecog"]) and "neurophysiology" in family.modalities and "clinical_cohort" not in family.modalities:
                score -= 10
        expression_focus = self._contains_any_phrase(
            text,
            ["gene expression", "transcript", "transcripts", "rna-seq", "rnaseq", "microarray", "single-cell", "single cell", "deg", "degs"],
        )
        cohort_or_genomics_focus = self._contains_any_phrase(
            text,
            [
                "survival", "overall survival", "progression-free survival", "prognosis", "stage at diagnosis",
                "mutation", "mutational", "copy number", "copy-number", "fusion", "fusions",
                "tumor mutational burden", "tmb", "co-occur", "cooccur", "somatic", "carrier", "carriers",
            ],
        )
        if family.id in {"gdc_cancer_genomics", "cbioportal_cancer_studies"}:
            if cohort_or_genomics_focus:
                score += 18
            if expression_focus and not cohort_or_genomics_focus:
                score -= 8
        if family.id == "geo_functional_genomics":
            if expression_focus:
                score += 18
            if cohort_or_genomics_focus and not expression_focus:
                score -= 18
        return score

    def _candidate_family_bias(self, family_id: str, text: str) -> float:
        expression_focus = self._contains_any_phrase(
            text,
            ["gene expression", "transcript", "transcripts", "rna-seq", "rnaseq", "microarray", "single-cell", "single cell", "deg", "degs"],
        )
        cohort_or_genomics_focus = self._contains_any_phrase(
            text,
            [
                "survival", "overall survival", "progression-free survival", "prognosis", "stage at diagnosis",
                "mutation", "mutational", "copy number", "copy-number", "fusion", "fusions",
                "tumor mutational burden", "tmb", "co-occur", "cooccur", "somatic", "carrier", "carriers",
            ],
        )
        if family_id in {"gdc_cancer_genomics", "cbioportal_cancer_studies"}:
            if cohort_or_genomics_focus:
                return 10.0
            if expression_focus and not cohort_or_genomics_focus:
                return -6.0
        if family_id == "geo_functional_genomics":
            if expression_focus:
                return 10.0
            if cohort_or_genomics_focus and not expression_focus:
                return -10.0
        return 0.0

    def _search_family(
        self,
        family: SourceFamilySpec,
        text: str,
        dataset_hints: list[str],
    ) -> list[DatasetCandidate]:
        if family.id == "gdc_cancer_genomics":
            return self._search_gdc_projects(family, text, dataset_hints)
        if family.id == "cbioportal_cancer_studies":
            return self._search_cbioportal_studies(family, text, dataset_hints)
        if family.id == "geo_functional_genomics":
            return self._search_geo(family, text, dataset_hints)
        if family.id == "dandi_neurophysiology":
            return self._search_dandi(family, text, dataset_hints)
        if family.id == "openneuro_neurophysiology":
            return self._search_openneuro(family, text, dataset_hints)
        if family.id == "harvard_dataverse_open_data":
            return self._search_harvard_dataverse(family, text, dataset_hints)
        if family.id == "zenodo_open_research":
            return self._search_zenodo(family, text, dataset_hints)
        if family.id == "figshare_open_data":
            return self._search_figshare(family, text, dataset_hints)
        if family.id == "openalex_literature":
            return self._search_openalex(family, text, dataset_hints)
        return []

    def _search_gdc_projects(
        self,
        family: SourceFamilySpec,
        text: str,
        dataset_hints: list[str],
    ) -> list[DatasetCandidate]:
        payload = self._request_json(
            "https://api.gdc.cancer.gov/projects?size=200&fields=project_id,name,primary_site,disease_type,summary.case_count,summary.file_count"
        )
        results: list[DatasetCandidate] = []
        for project in ((payload or {}).get("data") or {}).get("hits") or []:
            project_id = str(project.get("project_id") or project.get("id") or "").strip()
            name = str(project.get("name") or project_id).strip()
            disease = " ".join(project.get("disease_type") or [])
            primary_site = " ".join(project.get("primary_site") or [])
            haystack = " ".join([project_id, name, disease, primary_site]).lower()
            match_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
            case_count = int((((project.get("summary") or {}).get("case_count")) or 0))
            if match_score <= 0:
                continue
            qualifies = case_count >= (family.minimum_case_count or 1)
            results.append(
                DatasetCandidate(
                    family_id=family.id,
                    family_label=family.label,
                    dataset_id=project_id,
                    title=name,
                    summary=f"{disease} | primary site: {primary_site or 'unknown'} | cases: {case_count}",
                    access_url=f"https://portal.gdc.cancer.gov/projects/{project_id}",
                    primary_domain=family.trusted_domains[0],
                    trusted_domains=family.trusted_domains,
                    unit_of_analysis=family.unit_of_analysis,
                    modalities=family.modalities,
                    score=match_score + min(case_count, 500) / 50,
                    evidence_count=case_count,
                    qualifies_as_primary_data=qualifies,
                    provenance_note="Resolved deterministically from the GDC projects endpoint.",
                    api_url=f"https://api.gdc.cancer.gov/projects/{project_id}",
                )
            )
        return results

    def _search_cbioportal_studies(
        self,
        family: SourceFamilySpec,
        text: str,
        dataset_hints: list[str],
    ) -> list[DatasetCandidate]:
        payload = self._request_json(
            "https://www.cbioportal.org/api/studies?projection=SUMMARY&pageSize=1000&pageNumber=0"
        )
        results: list[DatasetCandidate] = []
        for study in payload or []:
            study_id = str(study.get("studyId") or "").strip()
            title = str(study.get("name") or study_id).strip()
            description = str(study.get("description") or "").strip()
            cancer_type = str(study.get("cancerTypeId") or "").strip()
            haystack = " ".join([study_id, title, description, cancer_type]).lower()
            match_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
            sample_count = int(study.get("allSampleCount") or 0)
            if match_score <= 0:
                continue
            qualifies = bool(study.get("publicStudy", True) and study.get("readPermission", True))
            results.append(
                DatasetCandidate(
                    family_id=family.id,
                    family_label=family.label,
                    dataset_id=study_id,
                    title=title,
                    summary=f"{description[:240]} | samples: {sample_count}",
                    access_url=f"https://www.cbioportal.org/study/summary?id={study_id}",
                    primary_domain=family.trusted_domains[0],
                    trusted_domains=family.trusted_domains,
                    unit_of_analysis=family.unit_of_analysis,
                    modalities=family.modalities,
                    score=match_score + min(sample_count, 500) / 50,
                    evidence_count=sample_count,
                    qualifies_as_primary_data=qualifies,
                    provenance_note="Resolved deterministically from the cBioPortal studies endpoint.",
                    api_url=f"https://www.cbioportal.org/api/studies/{study_id}",
                )
            )
        return results

    def _search_geo(
        self,
        family: SourceFamilySpec,
        text: str,
        dataset_hints: list[str],
    ) -> list[DatasetCandidate]:
        results: list[DatasetCandidate] = []
        seen_ids: set[str] = set()
        for query in self._query_variants(text, family.search_keywords, dataset_hints):
            search_payload = self._request_json(
                "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
                f"?db=gds&retmode=json&retmax=5&term={self._url_encode(query)}"
            )
            id_list = ((search_payload or {}).get("esearchresult") or {}).get("idlist") or []
            if not id_list:
                continue
            summary_payload = self._request_json(
                "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi"
                f"?db=gds&retmode=json&id={','.join(id_list)}"
            )
            summary_result = (summary_payload or {}).get("result") or {}
            for uid in summary_result.get("uids") or []:
                summary = summary_result.get(str(uid)) or {}
                accession = str(summary.get("accession") or summary.get("gse") or uid).strip()
                if not accession or accession in seen_ids:
                    continue
                seen_ids.add(accession)
                title = str(summary.get("title") or accession).strip()
                description = str(summary.get("summary") or "").strip()
                sample_count = len(summary.get("samples") or [])
                haystack = " ".join([accession, title, description, str(summary.get("gdstype") or "")]).lower()
                match_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
                if match_score <= 0:
                    continue
                qualifies = sample_count >= (family.minimum_asset_count or 1)
                results.append(
                    DatasetCandidate(
                        family_id=family.id,
                        family_label=family.label,
                        dataset_id=accession,
                        title=title,
                        summary=f"{str(summary.get('gdstype') or 'GEO series')} | samples: {sample_count}",
                        access_url=f"https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc={accession}",
                        primary_domain=family.trusted_domains[0],
                        trusted_domains=family.trusted_domains,
                        unit_of_analysis=family.unit_of_analysis,
                        modalities=family.modalities,
                        score=match_score + min(sample_count, 100) / 20,
                        evidence_count=sample_count,
                        qualifies_as_primary_data=qualifies,
                        provenance_note="Resolved deterministically from NCBI GEO E-utilities.",
                        api_url=(
                            "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi"
                            f"?db=gds&retmode=json&id={uid}"
                        ),
                    )
                )
        return results

    def _search_dandi(self, family: SourceFamilySpec, text: str, dataset_hints: list[str]) -> list[DatasetCandidate]:
        results: list[DatasetCandidate] = []
        seen_ids: set[str] = set()
        for query in self._query_variants(text, family.search_keywords, dataset_hints):
            payload = self._request_json(
                f"https://api.dandiarchive.org/api/dandisets/?page_size=25&search={self._url_encode(query)}"
            )
            for dandiset in (payload or {}).get("results") or []:
                identifier = str(dandiset.get("identifier") or "").strip()
                if not identifier or identifier in seen_ids:
                    continue
                seen_ids.add(identifier)
                version = (dandiset.get("most_recent_published_version") or {}) if isinstance(dandiset.get("most_recent_published_version"), dict) else {}
                title = str(version.get("name") or dandiset.get("name") or identifier).strip()
                description = str(version.get("description") or dandiset.get("description") or "").strip()
                asset_count = int(version.get("asset_count") or 0)
                haystack = " ".join([identifier, title, description]).lower()
                match_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
                if match_score <= 0:
                    continue
                qualifies = asset_count >= (family.minimum_asset_count or 1)
                results.append(
                    DatasetCandidate(
                        family_id=family.id,
                        family_label=family.label,
                        dataset_id=identifier,
                        title=title,
                        summary=f"DANDI dandiset {identifier} | assets: {asset_count}",
                        access_url=f"https://dandiarchive.org/dandiset/{identifier}",
                        primary_domain=family.trusted_domains[0],
                        trusted_domains=family.trusted_domains,
                        unit_of_analysis=family.unit_of_analysis,
                        modalities=family.modalities,
                        score=match_score + min(asset_count, 200) / 25,
                        evidence_count=asset_count,
                        qualifies_as_primary_data=qualifies,
                        provenance_note="Resolved deterministically from the DANDI API.",
                        api_url=f"https://api.dandiarchive.org/api/dandisets/{identifier}/",
                    )
                )
        return results

    def _search_openneuro(self, family: SourceFamilySpec, text: str, dataset_hints: list[str]) -> list[DatasetCandidate]:
        query = {
            "query": "query { datasets(first: 200) { edges { node { id name } } } }"
        }
        payload = self._request_json("https://openneuro.org/crn/graphql", method="POST", body=query)
        results: list[DatasetCandidate] = []
        for edge in (((payload or {}).get("data") or {}).get("datasets") or {}).get("edges") or []:
            node = edge.get("node") or {}
            dataset_id = str(node.get("id") or "").strip()
            title = str(node.get("name") or dataset_id).strip()
            haystack = " ".join([dataset_id, title]).lower()
            match_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
            if match_score <= 0:
                continue
            results.append(
                DatasetCandidate(
                    family_id=family.id,
                    family_label=family.label,
                    dataset_id=dataset_id,
                    title=title,
                    summary=f"OpenNeuro dataset {dataset_id}",
                    access_url=f"https://openneuro.org/datasets/{dataset_id}",
                    primary_domain=family.trusted_domains[0],
                    trusted_domains=family.trusted_domains,
                    unit_of_analysis=family.unit_of_analysis,
                    modalities=family.modalities,
                    score=match_score,
                    evidence_count=1,
                    qualifies_as_primary_data=True,
                    provenance_note="Resolved deterministically from the OpenNeuro GraphQL dataset index.",
                    api_url="https://openneuro.org/crn/graphql",
                )
            )
        return results

    def _search_harvard_dataverse(
        self,
        family: SourceFamilySpec,
        text: str,
        dataset_hints: list[str],
    ) -> list[DatasetCandidate]:
        results: list[DatasetCandidate] = []
        seen_ids: set[str] = set()
        for query in self._query_variants(text, family.search_keywords, dataset_hints):
            payload = self._request_json(
                "https://dataverse.harvard.edu/api/search"
                f"?q={self._url_encode(query)}&type=dataset&per_page=5"
            )
            for item in ((payload or {}).get("data") or {}).get("items") or []:
                global_id = str(item.get("global_id") or "").strip()
                if not global_id or global_id in seen_ids:
                    continue
                seen_ids.add(global_id)
                detail_payload = self._request_json(
                    "https://dataverse.harvard.edu/api/datasets/:persistentId/"
                    f"?persistentId={self._url_encode(global_id)}"
                )
                latest_version = ((detail_payload or {}).get("data") or {}).get("latestVersion") or {}
                files = latest_version.get("files") or []
                data_files = [
                    entry for entry in files
                    if not bool(entry.get("restricted"))
                    and self._is_likely_data_file(
                        str(((entry.get("dataFile") or {}).get("filename")) or entry.get("label") or ""),
                        str(((entry.get("dataFile") or {}).get("contentType")) or ""),
                    )
                ]
                haystack = " ".join(
                    [
                        str(item.get("name") or ""),
                        str(item.get("description") or ""),
                        str(item.get("citation") or ""),
                        " ".join(item.get("subjects") or []),
                    ]
                ).lower()
                match_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
                if match_score <= 0:
                    continue
                download_urls = [
                    f"https://dataverse.harvard.edu/api/access/datafile/{(entry.get('dataFile') or {}).get('id')}"
                    for entry in data_files
                    if (entry.get("dataFile") or {}).get("id")
                ][:5]
                results.append(
                    DatasetCandidate(
                        family_id=family.id,
                        family_label=family.label,
                        dataset_id=global_id,
                        title=str(item.get("name") or global_id).strip(),
                        summary=f"{str(item.get('description') or '')[:220]} | data files: {len(data_files)}",
                        access_url=str(item.get("url") or f"https://dataverse.harvard.edu/dataset.xhtml?persistentId={global_id}"),
                        primary_domain=family.trusted_domains[0],
                        trusted_domains=family.trusted_domains,
                        unit_of_analysis=family.unit_of_analysis,
                        modalities=family.modalities,
                        score=match_score + min(len(data_files), 50) / 5,
                        evidence_count=len(data_files),
                        qualifies_as_primary_data=len(data_files) >= (family.minimum_asset_count or 1),
                        provenance_note="Resolved deterministically from the Harvard Dataverse search and dataset APIs.",
                        api_url=(
                            "https://dataverse.harvard.edu/api/datasets/:persistentId/"
                            f"?persistentId={self._url_encode(global_id)}"
                        ),
                        download_urls=download_urls,
                    )
                )
        return results

    def _search_zenodo(
        self,
        family: SourceFamilySpec,
        text: str,
        dataset_hints: list[str],
    ) -> list[DatasetCandidate]:
        results: list[DatasetCandidate] = []
        seen_ids: set[str] = set()
        for query in self._query_variants(text, family.search_keywords, dataset_hints):
            payload = self._request_json(f"https://zenodo.org/api/records?q={self._url_encode(query)}")
            for record in ((payload or {}).get("hits") or {}).get("hits") or []:
                record_id = str(record.get("id") or "").strip()
                if not record_id or record_id in seen_ids:
                    continue
                seen_ids.add(record_id)
                metadata = record.get("metadata") if isinstance(record.get("metadata"), dict) else {}
                title = str(metadata.get("title") or record_id).strip()
                description = str(metadata.get("description") or "").strip()
                access_right = str(metadata.get("access_right") or "").strip().lower()
                data_files = [
                    str(((entry.get("links") or {}).get("self")) or "").strip()
                    for entry in (record.get("files") or [])
                    if self._is_likely_data_file(str(entry.get("key") or ""), "")
                ]
                haystack = " ".join([title, description]).lower()
                match_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
                if match_score <= 0:
                    continue
                results.append(
                    DatasetCandidate(
                        family_id=family.id,
                        family_label=family.label,
                        dataset_id=f"zenodo:{record_id}",
                        title=title,
                        summary=f"Zenodo record {record_id} | data files: {len(data_files)}",
                        access_url=str(record.get("doi_url") or f"https://zenodo.org/records/{record_id}"),
                        primary_domain=family.trusted_domains[0],
                        trusted_domains=family.trusted_domains,
                        unit_of_analysis=family.unit_of_analysis,
                        modalities=family.modalities,
                        score=match_score + min(len(data_files), 20),
                        evidence_count=len(data_files),
                        qualifies_as_primary_data=(
                            access_right == "open" and len(data_files) >= (family.minimum_asset_count or 1)
                        ),
                        provenance_note="Resolved deterministically from the Zenodo records API.",
                        api_url=f"https://zenodo.org/api/records/{record_id}",
                        download_urls=data_files[:5],
                    )
                )
        return results

    def _search_figshare(
        self,
        family: SourceFamilySpec,
        text: str,
        dataset_hints: list[str],
    ) -> list[DatasetCandidate]:
        results: list[DatasetCandidate] = []
        seen_ids: set[str] = set()
        for query in self._query_variants(text, family.search_keywords, dataset_hints):
            payload = self._request_json(
                "https://api.figshare.com/v2/articles"
                f"?search_for={self._url_encode(query)}&page_size=10"
            )
            for item in payload or []:
                article_id = str(item.get("id") or "").strip()
                if not article_id or article_id in seen_ids:
                    continue
                seen_ids.add(article_id)
                detail_payload = self._request_json(f"https://api.figshare.com/v2/articles/{article_id}")
                data_files = [
                    str(entry.get("download_url") or "").strip()
                    for entry in ((detail_payload or {}).get("files") or [])
                    if self._is_likely_data_file(str(entry.get("name") or ""), str(entry.get("mimetype") or ""))
                ]
                haystack = " ".join(
                    [str(item.get("title") or ""), str((detail_payload or {}).get("description") or "")]
                ).lower()
                match_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
                if match_score <= 0:
                    continue
                results.append(
                    DatasetCandidate(
                        family_id=family.id,
                        family_label=family.label,
                        dataset_id=f"figshare:{article_id}",
                        title=str(item.get("title") or article_id).strip(),
                        summary=f"Figshare article {article_id} | data files: {len(data_files)}",
                        access_url=str((detail_payload or {}).get("figshare_url") or item.get("url_public_html") or ""),
                        primary_domain=family.trusted_domains[0],
                        trusted_domains=family.trusted_domains,
                        unit_of_analysis=family.unit_of_analysis,
                        modalities=family.modalities,
                        score=match_score + min(len(data_files), 20),
                        evidence_count=len(data_files),
                        qualifies_as_primary_data=(
                            bool((detail_payload or {}).get("is_public"))
                            and len(data_files) >= (family.minimum_asset_count or 1)
                        ),
                        provenance_note="Resolved deterministically from the Figshare public articles API.",
                        api_url=f"https://api.figshare.com/v2/articles/{article_id}",
                        download_urls=data_files[:5],
                    )
                )
        return results

    def _search_openalex(self, family: SourceFamilySpec, text: str, dataset_hints: list[str]) -> list[DatasetCandidate]:
        results: list[DatasetCandidate] = []
        seen_ids: set[str] = set()
        for query in self._query_variants(text, family.search_keywords, dataset_hints):
            payload = self._request_json(
                f"https://api.openalex.org/works?search={self._url_encode(query)}&per-page=10"
            )
            for work in (payload or {}).get("results") or []:
                work_id = str(work.get("id") or "").strip()
                if not work_id or work_id in seen_ids:
                    continue
                seen_ids.add(work_id)
                title = str(work.get("display_name") or work.get("title") or work_id).strip()
                year = work.get("publication_year")
                abstract = ""
                abstract_inverted_index = work.get("abstract_inverted_index")
                if isinstance(abstract_inverted_index, dict):
                    abstract_tokens = sorted(
                        (
                            (position, token)
                            for token, positions in abstract_inverted_index.items()
                            if isinstance(positions, list)
                            for position in positions
                            if isinstance(position, int)
                        ),
                        key=lambda item: item[0],
                    )
                    abstract = " ".join(token for _, token in abstract_tokens)
                haystack = " ".join([title, abstract, str(year or "")]).lower()
                match_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
                if match_score <= 0:
                    continue
                results.append(
                    DatasetCandidate(
                        family_id=family.id,
                        family_label=family.label,
                        dataset_id=work_id,
                        title=title,
                        summary=f"OpenAlex work metadata | year: {year or 'unknown'}",
                        access_url=work_id,
                        primary_domain=family.trusted_domains[0],
                        trusted_domains=family.trusted_domains,
                        unit_of_analysis=family.unit_of_analysis,
                        modalities=family.modalities,
                        score=match_score,
                        evidence_count=1,
                        qualifies_as_primary_data=False,
                        provenance_note="Resolved deterministically from the OpenAlex works API. Valid for reviews/bibliometrics only.",
                        api_url=work_id,
                    )
                )
        return results

    def _best_query(self, text: str, keywords: list[str]) -> str:
        title_tokens = [token for token in re.findall(r"[a-z0-9]{3,}", text.lower()) if token not in {"the", "and", "for", "with"}]
        prioritized = [keyword for keyword in keywords if keyword in text]
        return " ".join((prioritized + title_tokens)[:6]) or "public dataset"

    def _query_variants(self, text: str, keywords: list[str], dataset_hints: list[str]) -> list[str]:
        queries: list[str] = []
        seen: set[str] = set()
        seed_queries = dataset_hints + [self._best_query(text, keywords)]
        matched_keywords = [keyword for keyword in keywords if keyword in text][:3]
        if matched_keywords:
            seed_queries.append(" ".join(matched_keywords))
        major_terms = re.findall(r"[a-z0-9]{4,}", text.lower())
        if major_terms:
            seed_queries.append(" ".join(major_terms[:4]))
        if "epilepsy" in text and any(token in text for token in ["pediatric", "child", "children", "adolescent"]):
            seed_queries.append("children epilepsy")
            seed_queries.append("pediatric epilepsy")
        if "epilepsy" in text and any(token in text for token in ["prevalence", "incidence", "epidemiology", "cohort"]):
            seed_queries.append("epilepsy prevalence")
            seed_queries.append("epilepsy epidemiology dataset")
            if any(token in text for token in ["pediatric", "child", "children", "adolescent"]):
                seed_queries.append("pediatric epilepsy prevalence")
                seed_queries.append("pediatric epilepsy cohort")
                seed_queries.append("children with epilepsy dataset")
                seed_queries.append("pediatric epilepsy registry")
            if "refractory" in text:
                seed_queries.append("refractory epilepsy children dataset")
        if any(token in text for token in ["rns", "responsive neurostimulation"]):
            seed_queries.append("epilepsy neurostimulation")
        if "autism" in text and any(token in text for token in ["prevalence", "incidence"]):
            seed_queries.append("autism prevalence")
            if any(token in text for token in ["professional", "workplace", "employment", "occupational"]):
                seed_queries.append("autism employment prevalence")
        if any(token in text for token in ["sex differences", "gender"]):
            seed_queries.append("sex gender")

        for query in seed_queries:
            normalized = re.sub(r"\s+", " ", str(query).strip().lower())
            if not normalized or normalized in seen:
                continue
            seen.add(normalized)
            queries.append(normalized)
            if len(queries) >= 8:
                break
        return queries or ["public dataset"]

    def _text_match_score(
        self,
        query_text: str,
        candidate_text: str,
        family_keywords: list[str],
        dataset_hints: list[str],
    ) -> float:
        score = 0.0
        stopwords = {
            "about", "across", "after", "among", "analysis", "analyze", "and", "compare", "data", "dataset",
            "differences", "for", "from", "into", "metadata", "need", "not", "notes", "open", "paper", "public",
            "real", "study", "subject", "than", "that", "the", "their", "this", "using", "with",
        }
        query_terms = {
            token for token in re.findall(r"[a-z0-9]{3,}", query_text.lower())
            if token not in stopwords
        }
        candidate_terms = {
            token for token in re.findall(r"[a-z0-9]{3,}", candidate_text.lower())
            if token not in stopwords
        }
        family_keyword_terms = {
            token
            for keyword in family_keywords
            for token in re.findall(r"[a-z0-9]{3,}", keyword.lower())
            if token not in stopwords
        }
        salient_terms = query_terms - family_keyword_terms
        high_signal_stopwords = stopwords.union(
            {
                "prevalence", "incidence", "epidemiology", "cohort", "registry", "survey",
                "children", "child", "pediatric", "adolescent", "adolescents", "young", "adult", "adults",
                "community", "professional", "settings", "employment", "workplace", "occupational",
                "recording", "recordings", "signal", "signals",
                "responsive", "neurostimulation", "neurophysiology", "survival", "difference", "differences", "sex", "gender",
            }
        )
        high_signal_terms = {token for token in salient_terms if token not in high_signal_stopwords}
        matched_terms = query_terms.intersection(candidate_terms)
        matched_salient_terms = salient_terms.intersection(candidate_terms)
        matched_high_signal_terms = high_signal_terms.intersection(candidate_terms)
        synonym_groups = [
            {"prevalence", "incidence", "epidemiology", "cohort", "registry", "survey"},
            {"recording", "recordings", "eeg", "ieeg", "ecog", "lfp", "signal"},
        ]
        cohort_terms = {"prevalence", "incidence", "epidemiology", "cohort", "registry", "survey", "population", "patients", "children"}
        recording_terms = {"recording", "recordings", "eeg", "ieeg", "ecog", "lfp", "signal", "signals"}
        gene_terms = {"gene", "genes", "genomic", "genomics", "expression", "transcript", "transcripts", "rna", "rnaseq", "microarray"}
        condition_groups = [
            {"epilepsy", "epileptic", "seizure", "seizures"},
            {"autism", "asd"},
            {"glioblastoma", "gbm"},
            {"kidney", "renal"},
            {"alzheimer", "alzheimers"},
            {"parkinson", "parkinsons"},
            {"diabetes", "diabetic"},
        ]

        score += len(matched_terms)
        score += len(matched_salient_terms) * 1.75
        score += len(matched_high_signal_terms) * 3.0
        for group in synonym_groups:
            if query_terms.intersection(group) and candidate_terms.intersection(group):
                score += 2.5
        if salient_terms and not matched_salient_terms:
            score -= 2.5
        elif salient_terms:
            score -= max(0.0, (len(salient_terms) - len(matched_salient_terms)) * 0.15)
        if high_signal_terms and not matched_high_signal_terms:
            score -= 2.0
        elif high_signal_terms:
            score -= max(0.0, (len(high_signal_terms) - len(matched_high_signal_terms)) * 0.25)
        score += sum(2 for keyword in family_keywords if keyword in query_text and keyword in candidate_text)
        score += sum(1.5 for hint in dataset_hints if hint.lower() in candidate_text)
        prevalence_focus = bool(query_terms.intersection({"prevalence", "incidence", "epidemiology", "cohort", "registry", "survey"}))
        negates_recordings = self._negates_any_phrase(query_text, list(recording_terms))
        negates_gene_terms = self._negates_any_phrase(
            query_text,
            ["gene expression", "transcript", "transcripts", "rna-seq", "rnaseq", "microarray", "gene", "genes"],
        )
        recording_focus = bool(query_terms.intersection(recording_terms)) and not negates_recordings
        gene_focus = bool(query_terms.intersection(gene_terms)) and not negates_gene_terms
        if prevalence_focus and candidate_terms.intersection(cohort_terms):
            score += 4.0
        if prevalence_focus and not recording_focus and candidate_terms.intersection(recording_terms):
            score -= 8.0
        if prevalence_focus and not gene_focus and candidate_terms.intersection(gene_terms):
            score -= 7.0
        if negates_recordings and candidate_terms.intersection(recording_terms):
            score -= 12.0
        if negates_gene_terms and candidate_terms.intersection(gene_terms):
            score -= 12.0
        for index, group in enumerate(condition_groups):
            if not query_terms.intersection(group):
                continue
            if candidate_terms.intersection(group):
                score += 6.0
            elif any(candidate_terms.intersection(other_group) for group_index, other_group in enumerate(condition_groups) if group_index != index):
                score -= 6.0
        return score

    def _normalize_dataset_ids(self, dataset_ids: list[str] | None) -> list[str]:
        if not dataset_ids:
            return []
        normalized: list[str] = []
        seen: set[str] = set()
        for dataset_id in dataset_ids:
            value = str(dataset_id or "").strip()
            if not value:
                continue
            lowered = value.lower()
            if lowered in seen:
                continue
            seen.add(lowered)
            normalized.append(value)
        return normalized

    def _lookup_explicit_candidates(
        self,
        *,
        ranked_families: list[SourceFamilySpec],
        dataset_ids: list[str],
        text: str,
        dataset_hints: list[str],
    ) -> list[DatasetCandidate]:
        if not dataset_ids:
            return []

        family_by_id = {family.id: family for family in self._registry.source_families()}
        candidates: list[DatasetCandidate] = []
        for dataset_id in dataset_ids:
            candidate = None
            lowered = dataset_id.lower()
            if lowered.startswith("zenodo:"):
                family = family_by_id.get("zenodo_open_research")
                if family is not None:
                    candidate = self._lookup_zenodo_candidate(
                        family,
                        record_id=dataset_id.split(":", 1)[1],
                        text=text,
                        dataset_hints=dataset_hints,
                    )
            elif lowered.startswith("figshare:"):
                family = family_by_id.get("figshare_open_data")
                if family is not None:
                    candidate = self._lookup_figshare_candidate(
                        family,
                        article_id=dataset_id.split(":", 1)[1],
                        text=text,
                        dataset_hints=dataset_hints,
                    )
            elif lowered.startswith("https://openalex.org/") or re.fullmatch(r"w\d+", lowered):
                family = family_by_id.get("openalex_literature")
                if family is not None:
                    candidate = self._lookup_openalex_candidate(
                        family,
                        work_id=dataset_id,
                        text=text,
                        dataset_hints=dataset_hints,
                    )
            elif re.fullmatch(r"gse\d+", lowered):
                family = family_by_id.get("geo_functional_genomics")
                if family is not None:
                    candidate = self._lookup_geo_candidate(
                        family,
                        accession=dataset_id.upper(),
                        text=text,
                        dataset_hints=dataset_hints,
                    )
            elif re.fullmatch(r"\d{6}", dataset_id):
                family = family_by_id.get("dandi_neurophysiology")
                if family is not None:
                    candidate = self._lookup_dandi_candidate(
                        family,
                        identifier=dataset_id,
                        text=text,
                        dataset_hints=dataset_hints,
                    )
            elif lowered.startswith("doi:"):
                family = family_by_id.get("harvard_dataverse_open_data")
                if family is not None:
                    candidate = self._lookup_dataverse_candidate(
                        family,
                        persistent_id=dataset_id,
                        text=text,
                        dataset_hints=dataset_hints,
                    )
            if candidate is not None:
                candidates.append(candidate)
        return candidates

    def _lookup_zenodo_candidate(
        self,
        family: SourceFamilySpec,
        *,
        record_id: str,
        text: str,
        dataset_hints: list[str],
    ) -> DatasetCandidate | None:
        payload = self._request_json(f"https://zenodo.org/api/records/{self._url_encode(record_id)}")
        if not isinstance(payload, dict):
            return None
        metadata = payload.get("metadata") if isinstance(payload.get("metadata"), dict) else {}
        title = str(metadata.get("title") or record_id).strip()
        description = str(metadata.get("description") or "").strip()
        access_right = str(metadata.get("access_right") or "").strip().lower()
        data_files = [
            str(((entry.get("links") or {}).get("self")) or "").strip()
            for entry in (payload.get("files") or [])
            if self._is_likely_data_file(str(entry.get("key") or ""), "")
        ]
        haystack = " ".join([record_id, title, description]).lower()
        base_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
        return DatasetCandidate(
            family_id=family.id,
            family_label=family.label,
            dataset_id=f"zenodo:{record_id}",
            title=title,
            summary=f"Zenodo record {record_id} | data files: {len(data_files)}",
            access_url=str(payload.get("doi_url") or f"https://zenodo.org/records/{record_id}"),
            primary_domain=family.trusted_domains[0],
            trusted_domains=family.trusted_domains,
            unit_of_analysis=family.unit_of_analysis,
            modalities=family.modalities,
            score=max(base_score, 0) + 100 + min(len(data_files), 20),
            evidence_count=len(data_files),
            qualifies_as_primary_data=access_right == "open" and len(data_files) >= (family.minimum_asset_count or 1),
            provenance_note="Resolved directly from an explicit Zenodo dataset id.",
            api_url=f"https://zenodo.org/api/records/{record_id}",
            download_urls=data_files[:5],
        )

    def _lookup_figshare_candidate(
        self,
        family: SourceFamilySpec,
        *,
        article_id: str,
        text: str,
        dataset_hints: list[str],
    ) -> DatasetCandidate | None:
        payload = self._request_json(f"https://api.figshare.com/v2/articles/{self._url_encode(article_id)}")
        if not isinstance(payload, dict):
            return None
        title = str(payload.get("title") or article_id).strip()
        description = str(payload.get("description") or "").strip()
        data_files = [
            str(entry.get("download_url") or "").strip()
            for entry in (payload.get("files") or [])
            if self._is_likely_data_file(str(entry.get("name") or ""), str(entry.get("mimetype") or ""))
        ]
        haystack = " ".join([article_id, title, description]).lower()
        base_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
        return DatasetCandidate(
            family_id=family.id,
            family_label=family.label,
            dataset_id=f"figshare:{article_id}",
            title=title,
            summary=f"Figshare article {article_id} | data files: {len(data_files)}",
            access_url=str(payload.get("figshare_url") or payload.get("url_public_html") or ""),
            primary_domain=family.trusted_domains[0],
            trusted_domains=family.trusted_domains,
            unit_of_analysis=family.unit_of_analysis,
            modalities=family.modalities,
            score=max(base_score, 0) + 100 + min(len(data_files), 20),
            evidence_count=len(data_files),
            qualifies_as_primary_data=bool(payload.get("is_public")) and len(data_files) >= (family.minimum_asset_count or 1),
            provenance_note="Resolved directly from an explicit Figshare dataset id.",
            api_url=f"https://api.figshare.com/v2/articles/{article_id}",
            download_urls=data_files[:5],
        )

    def _lookup_openalex_candidate(
        self,
        family: SourceFamilySpec,
        *,
        work_id: str,
        text: str,
        dataset_hints: list[str],
    ) -> DatasetCandidate | None:
        normalized_work_id = work_id if work_id.lower().startswith("https://openalex.org/") else f"https://openalex.org/{work_id.upper()}"
        payload = self._request_json(normalized_work_id.replace("https://openalex.org/", "https://api.openalex.org/works/"))
        if not isinstance(payload, dict):
            return None
        title = str(payload.get("display_name") or payload.get("title") or normalized_work_id).strip()
        year = payload.get("publication_year")
        haystack = " ".join([normalized_work_id, title, str(year or "")]).lower()
        base_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
        return DatasetCandidate(
            family_id=family.id,
            family_label=family.label,
            dataset_id=normalized_work_id,
            title=title,
            summary=f"OpenAlex work metadata | year: {year or 'unknown'}",
            access_url=normalized_work_id,
            primary_domain=family.trusted_domains[0],
            trusted_domains=family.trusted_domains,
            unit_of_analysis=family.unit_of_analysis,
            modalities=family.modalities,
            score=max(base_score, 0) + 100,
            evidence_count=1,
            qualifies_as_primary_data=False,
            provenance_note="Resolved directly from an explicit OpenAlex work id.",
            api_url=normalized_work_id.replace("https://openalex.org/", "https://api.openalex.org/works/"),
        )

    def _lookup_geo_candidate(
        self,
        family: SourceFamilySpec,
        *,
        accession: str,
        text: str,
        dataset_hints: list[str],
    ) -> DatasetCandidate | None:
        search_payload = self._request_json(
            "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
            f"?db=gds&retmode=json&retmax=1&term={self._url_encode(accession)}"
        )
        id_list = ((search_payload or {}).get("esearchresult") or {}).get("idlist") or []
        if not id_list:
            return None
        summary_payload = self._request_json(
            "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi"
            f"?db=gds&retmode=json&id={','.join(id_list[:1])}"
        )
        summary_result = (summary_payload or {}).get("result") or {}
        summary = summary_result.get(str(id_list[0])) or {}
        title = str(summary.get("title") or accession).strip()
        description = str(summary.get("summary") or "").strip()
        sample_count = len(summary.get("samples") or [])
        haystack = " ".join([accession, title, description, str(summary.get("gdstype") or "")]).lower()
        base_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
        return DatasetCandidate(
            family_id=family.id,
            family_label=family.label,
            dataset_id=accession,
            title=title,
            summary=f"{str(summary.get('gdstype') or 'GEO series')} | samples: {sample_count}",
            access_url=f"https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc={accession}",
            primary_domain=family.trusted_domains[0],
            trusted_domains=family.trusted_domains,
            unit_of_analysis=family.unit_of_analysis,
            modalities=family.modalities,
            score=max(base_score, 0) + 100 + min(sample_count, 100) / 20,
            evidence_count=sample_count,
            qualifies_as_primary_data=sample_count >= (family.minimum_asset_count or 1),
            provenance_note="Resolved directly from an explicit GEO accession.",
            api_url=(
                "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi"
                f"?db=gds&retmode=json&id={id_list[0]}"
            ),
        )

    def _lookup_dandi_candidate(
        self,
        family: SourceFamilySpec,
        *,
        identifier: str,
        text: str,
        dataset_hints: list[str],
    ) -> DatasetCandidate | None:
        payload = self._request_json(f"https://api.dandiarchive.org/api/dandisets/{self._url_encode(identifier)}/")
        if not isinstance(payload, dict):
            return None
        version = payload.get("most_recent_published_version") if isinstance(payload.get("most_recent_published_version"), dict) else {}
        title = str(version.get("name") or payload.get("name") or identifier).strip()
        description = str(version.get("description") or payload.get("description") or "").strip()
        asset_count = int(version.get("asset_count") or 0)
        haystack = " ".join([identifier, title, description]).lower()
        base_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
        return DatasetCandidate(
            family_id=family.id,
            family_label=family.label,
            dataset_id=identifier,
            title=title,
            summary=f"DANDI dandiset {identifier} | assets: {asset_count}",
            access_url=f"https://dandiarchive.org/dandiset/{identifier}",
            primary_domain=family.trusted_domains[0],
            trusted_domains=family.trusted_domains,
            unit_of_analysis=family.unit_of_analysis,
            modalities=family.modalities,
            score=max(base_score, 0) + 100 + min(asset_count, 200) / 25,
            evidence_count=asset_count,
            qualifies_as_primary_data=asset_count >= (family.minimum_asset_count or 1),
            provenance_note="Resolved directly from an explicit DANDI dataset id.",
            api_url=f"https://api.dandiarchive.org/api/dandisets/{identifier}/",
        )

    def _lookup_dataverse_candidate(
        self,
        family: SourceFamilySpec,
        *,
        persistent_id: str,
        text: str,
        dataset_hints: list[str],
    ) -> DatasetCandidate | None:
        payload = self._request_json(
            "https://dataverse.harvard.edu/api/datasets/:persistentId/"
            f"?persistentId={self._url_encode(persistent_id)}"
        )
        latest_version = ((payload or {}).get("data") or {}).get("latestVersion") or {}
        metadata_blocks = latest_version.get("metadataBlocks") or {}
        citation_fields = ((metadata_blocks.get("citation") or {}).get("fields") or []) if isinstance(metadata_blocks, dict) else []
        title = persistent_id
        description = ""
        for field in citation_fields:
            field_name = str(field.get("typeName") or "").strip()
            if field_name == "title":
                title = str(field.get("value") or title).strip()
            elif field_name == "dsDescription":
                values = field.get("value") or []
                if values:
                    nested_fields = (values[0] or {}).get("dsDescriptionValue") if isinstance(values[0], dict) else None
                    if isinstance(nested_fields, dict):
                        description = str(nested_fields.get("value") or "").strip()
        files = latest_version.get("files") or []
        data_files = [
            entry for entry in files
            if not bool(entry.get("restricted"))
            and self._is_likely_data_file(
                str(((entry.get("dataFile") or {}).get("filename")) or entry.get("label") or ""),
                str(((entry.get("dataFile") or {}).get("contentType")) or ""),
            )
        ]
        haystack = " ".join([persistent_id, title, description]).lower()
        base_score = self._text_match_score(text, haystack, family.search_keywords, dataset_hints)
        download_urls = [
            f"https://dataverse.harvard.edu/api/access/datafile/{(entry.get('dataFile') or {}).get('id')}"
            for entry in data_files
            if (entry.get("dataFile") or {}).get("id")
        ][:5]
        return DatasetCandidate(
            family_id=family.id,
            family_label=family.label,
            dataset_id=persistent_id,
            title=title,
            summary=f"{description[:220]} | data files: {len(data_files)}",
            access_url=f"https://dataverse.harvard.edu/dataset.xhtml?persistentId={persistent_id}",
            primary_domain=family.trusted_domains[0],
            trusted_domains=family.trusted_domains,
            unit_of_analysis=family.unit_of_analysis,
            modalities=family.modalities,
            score=max(base_score, 0) + 100 + min(len(data_files), 50) / 5,
            evidence_count=len(data_files),
            qualifies_as_primary_data=len(data_files) >= (family.minimum_asset_count or 1),
            provenance_note="Resolved directly from an explicit Harvard Dataverse dataset id.",
            api_url=(
                "https://dataverse.harvard.edu/api/datasets/:persistentId/"
                f"?persistentId={self._url_encode(persistent_id)}"
            ),
            download_urls=download_urls,
        )

    def _contains_any_phrase(self, text: str, phrases: list[str]) -> bool:
        lowered = text.lower()
        return any(self._contains_phrase(lowered, phrase) for phrase in phrases)

    def _contains_phrase(self, text: str, phrase: str) -> bool:
        pattern = r"\b" + re.escape(phrase.lower()).replace(r"\ ", r"[-\s]+") + r"\b"
        return re.search(pattern, text) is not None

    def _negates_any_phrase(self, text: str, phrases: list[str]) -> bool:
        lowered = text.lower()
        for phrase in phrases:
            phrase_pattern = re.escape(phrase.lower()).replace(r"\ ", r"[-\s]+")
            pattern = rf"\b(?:not|without|rather than|instead of|exclude|excluding|avoid)\b[^.:\n]{{0,100}}\b{phrase_pattern}\b"
            if re.search(pattern, lowered):
                return True
        return False

    def _request_json(
        self,
        url: str,
        *,
        method: str = "GET",
        body: dict[str, Any] | None = None,
    ) -> Any:
        data = json.dumps(body).encode("utf-8") if body is not None else None
        request = Request(
            url,
            data=data,
            method=method,
            headers={
                "User-Agent": "Sidekick/1.0",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
        try:
            with urlopen(request, timeout=20) as response:
                raw = response.read()
        except (HTTPError, URLError):
            return None

        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return None

    def _url_encode(self, text: str) -> str:
        return re.sub(r"\s+", "%20", text.strip())

    def _is_likely_data_file(self, filename: str, content_type: str) -> bool:
        lowered_name = filename.lower().strip()
        lowered_type = content_type.lower().strip()
        data_extensions = (
            ".csv", ".tsv", ".tab", ".xlsx", ".xls", ".json", ".jsonl", ".xml", ".zip", ".gz", ".tgz", ".tar",
            ".parquet", ".feather", ".npy", ".npz", ".mat", ".h5", ".hdf5", ".nwb", ".edf", ".bdf", ".set", ".fif",
            ".nii", ".nii.gz", ".txt", ".rds", ".pkl", ".pickle", ".sqlite", ".db", ".loom", ".fastq", ".fq",
            ".fasta", ".fa", ".bam", ".sam", ".vcf", ".bed", ".bw", ".bigwig", ".gct",
        )
        data_mime_hints = (
            "application/json", "application/zip", "application/gzip", "application/x-hdf", "application/x-hdf5",
            "text/csv", "text/tab-separated-values", "application/vnd.ms-excel",
        )
        return lowered_name.endswith(data_extensions) or lowered_type.startswith(data_mime_hints)
