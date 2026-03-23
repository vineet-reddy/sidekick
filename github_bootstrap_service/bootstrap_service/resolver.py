from __future__ import annotations

import json
import re
from dataclasses import dataclass
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
    ) -> ResolutionBundle:
        text = " ".join(
            [title, theme] + [str(note.get("title") or "") + " " + str(note.get("content") or "") for note in notes]
        ).lower()
        paper_mode = self._classify_paper_mode(text)
        inferred_modalities, acceptable_units = self._infer_modalities_and_units(text, paper_mode)
        mode_spec = self._registry.paper_mode(paper_mode)

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

        candidates: list[DatasetCandidate] = []
        for family in ranked_families[:8]:
            candidates.extend(self._search_family(family, text, dataset_hints))

        candidates.sort(key=lambda candidate: candidate.score, reverse=True)

        if paper_mode == "empirical_dataset":
            candidates = [
                candidate for candidate in candidates
                if candidate.family_id not in mode_spec.forbidden_primary_family_ids
            ]
            qualifying = [candidate for candidate in candidates if candidate.qualifies_as_primary_data]
            if not qualifying:
                return ResolutionBundle(
                    paper_mode=paper_mode,
                    inferred_modalities=inferred_modalities,
                    acceptable_units=acceptable_units,
                    incompatible_primary_family_ids=mode_spec.forbidden_primary_family_ids,
                    status="blocked",
                    summary="No qualifying open empirical dataset was resolved from the trusted source families.",
                    blocking_reason=(
                        "No qualifying open dataset found for this empirical question across the trusted source families. "
                        "The run should block before manuscript writing rather than invent synthetic evidence."
                    ),
                    selected_candidate=None,
                    candidates=candidates[:8],
                )
            selected = qualifying[0]
            return ResolutionBundle(
                paper_mode=paper_mode,
                inferred_modalities=inferred_modalities,
                acceptable_units=acceptable_units,
                incompatible_primary_family_ids=mode_spec.forbidden_primary_family_ids,
                status="resolved",
                summary=f"Selected {selected.title} from {selected.family_label} as the primary empirical source.",
                blocking_reason=None,
                selected_candidate=selected,
                candidates=candidates[:8],
            )

        selected = candidates[0] if candidates else None
        if selected is None:
            return ResolutionBundle(
                paper_mode=paper_mode,
                inferred_modalities=inferred_modalities,
                acceptable_units=acceptable_units,
                incompatible_primary_family_ids=mode_spec.forbidden_primary_family_ids,
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
            incompatible_primary_family_ids=mode_spec.forbidden_primary_family_ids,
            status="resolved",
            summary=f"Selected {selected.title} from {selected.family_label}.",
            blocking_reason=None,
            selected_candidate=selected,
            candidates=candidates[:8],
        )

    def _classify_paper_mode(self, text: str) -> str:
        if any(phrase in text for phrase in ["literature review", "systematic review", "narrative review", "meta-analysis"]):
            return "literature_review"
        if any(phrase in text for phrase in ["bibliometric", "citation network", "publication trend", "scholarly output"]):
            return "bibliometric"
        if any(phrase in text for phrase in ["simulation study", "benchmark", "methods paper", "synthetic benchmark"]):
            return "methods_simulation"
        if any(phrase in text for phrase in ["commentary", "perspective", "opinion", "theoretical"]):
            return "theoretical_commentary"
        return "empirical_dataset"

    def _infer_modalities_and_units(self, text: str, paper_mode: str) -> tuple[list[str], list[str]]:
        modalities: list[str] = []
        acceptable_units: list[str] = []

        if any(token in text for token in ["glioblastoma", "gbm", "tumor", "cancer", "mutation", "survival"]):
            modalities.append("cancer_genomics")
            acceptable_units.extend(["patient", "tumor_sample"])

        if any(token in text for token in ["epilepsy", "seizure", "ecog", "ieeg", "lfp", "spike", "rns", "responsive neurostimulation"]):
            modalities.append("neurophysiology")
            acceptable_units.extend(["recording_session", "subject"])

        if any(token in text for token in ["expression", "transcript", "rna-seq", "rnaseq", "single-cell", "microarray", "gene"]):
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
        return bool(set(family.modalities).intersection(specific_modalities))

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
        return score

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
            qualifies = sample_count >= (family.minimum_case_count or 1)
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
                asset_count = int(version.get("asset_count") or 0)
                haystack = " ".join([identifier, title, query]).lower()
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
                haystack = " ".join([title, str(year or ""), query]).lower()
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
        if "glioblastoma" in text or "gbm" in text:
            seed_queries.append("glioblastoma gene expression")
        if any(token in text for token in ["rns", "responsive neurostimulation"]):
            seed_queries.append("epilepsy neurostimulation")
        if any(token in text for token in ["sex differences", "gender"]):
            seed_queries.append("sex gender")

        for query in seed_queries:
            normalized = re.sub(r"\s+", " ", str(query).strip().lower())
            if not normalized or normalized in seen:
                continue
            seen.add(normalized)
            queries.append(normalized)
            if len(queries) >= 6:
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
        score += len(query_terms.intersection(candidate_terms))
        score += sum(2 for keyword in family_keywords if keyword in query_text and keyword in candidate_text)
        score += sum(1.5 for hint in dataset_hints if hint.lower() in candidate_text)
        return score

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
