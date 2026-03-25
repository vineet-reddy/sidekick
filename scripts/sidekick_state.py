#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sqlite3
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any


DEFAULT_BUNDLE_ID = "com.vineet.Sidekick"


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    store_path = resolve_store_path(
        bundle_id=args.bundle_id,
        device=args.device,
        explicit_path=args.store_path,
    )
    payload = inspect_store(store_path)

    if args.section == "summary":
        payload = payload["summary"]
    elif args.section in {"notes", "papers", "runs"}:
        payload = payload[args.section]

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        render(payload=payload, section=args.section, store_path=store_path)

    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Inspect the Sidekick simulator SwiftData store without opening Xcode or the Simulator UI."
    )
    parser.add_argument(
        "section",
        nargs="?",
        default="summary",
        choices=["summary", "notes", "papers", "runs", "all"],
        help="Which section to print.",
    )
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID, help="App bundle ID. Defaults to Sidekick.")
    parser.add_argument("--device", default="booted", help="Simulator device selector for simctl. Defaults to `booted`.")
    parser.add_argument("--store-path", help="Use an explicit SwiftData store path instead of resolving via simctl.")
    parser.add_argument("--json", action="store_true", help="Print JSON instead of the human-readable summary.")
    return parser


def resolve_store_path(*, bundle_id: str, device: str, explicit_path: str | None) -> Path:
    if explicit_path:
        path = Path(explicit_path).expanduser().resolve()
        if not path.exists():
            raise FileNotFoundError(f"Store path does not exist: {path}")
        return path

    result = subprocess.run(
        ["xcrun", "simctl", "get_app_container", device, bundle_id, "data"],
        capture_output=True,
        text=True,
        check=True,
    )
    container_path = Path(result.stdout.strip()).expanduser().resolve()
    candidates = [
        container_path / "Library" / "Application Support" / "default.store",
        container_path / "default.store",
        container_path / "Documents" / "default.store",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError(f"Could not find a Sidekick SwiftData store under {container_path}")


def inspect_store(store_path: Path) -> dict[str, Any]:
    with sqlite3.connect(f"file:{store_path}?mode=ro", uri=True) as connection:
        connection.row_factory = sqlite3.Row
        table_columns = {
            "ZNOTE": columns_for_table(connection, "ZNOTE"),
            "ZPAPER": columns_for_table(connection, "ZPAPER"),
            "ZRESEARCHRUN": columns_for_table(connection, "ZRESEARCHRUN"),
        }

        notes = fetch_notes(connection, table_columns["ZNOTE"])
        papers = fetch_papers(connection)
        runs = fetch_runs(connection)

    return {
        "summary": {
            "store_path": str(store_path),
            "note_count": len(notes),
            "paper_count": len(papers),
            "run_count": len(runs),
            "queued_run_count": len([run for run in runs if run["status"] == "queued"]),
            "running_run_count": len([run for run in runs if run["status"] == "running"]),
            "failed_run_count": len([run for run in runs if run["status"] == "failed"]),
            "ready_paper_count": len([paper for paper in papers if paper["status"] == "ready"]),
        },
        "notes": notes,
        "papers": papers,
        "runs": runs,
    }


def columns_for_table(connection: sqlite3.Connection, table_name: str) -> set[str]:
    rows = connection.execute(f"PRAGMA table_info({table_name})").fetchall()
    return {str(row["name"]) for row in rows}


def fetch_notes(connection: sqlite3.Connection, columns: set[str]) -> list[dict[str, Any]]:
    select_columns = [
        "Z_PK",
        "ZCREATEDAT",
        "ZUPDATEDAT",
        "ZCONTENT",
        "ZID",
    ]
    if "ZPRIORITYREQUESTEDAT" in columns:
        select_columns.append("ZPRIORITYREQUESTEDAT")

    query = f"SELECT {', '.join(select_columns)} FROM ZNOTE ORDER BY ZUPDATEDAT DESC"
    rows = connection.execute(query).fetchall()
    notes: list[dict[str, Any]] = []
    for row in rows:
        content = str(row["ZCONTENT"] or "")
        notes.append(
            {
                "pk": row["Z_PK"],
                "id": decode_uuid(row["ZID"]),
                "created_at": row["ZCREATEDAT"],
                "updated_at": row["ZUPDATEDAT"],
                "priority_requested_at": row["ZPRIORITYREQUESTEDAT"] if "ZPRIORITYREQUESTEDAT" in row.keys() else None,
                "title": first_line(content) or "Untitled note",
                "content_preview": preview(content),
            }
        )
    return notes


def fetch_papers(connection: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = connection.execute(
        """
        SELECT
            Z_PK,
            ZCREATEDAT,
            ZUPDATEDAT,
            ZTITLE,
            ZSTATUSRAW,
            ZCODEXTASKID,
            ZSOURCENOTEIDSSTORAGE,
            ZID
        FROM ZPAPER
        ORDER BY ZUPDATEDAT DESC
        """
    ).fetchall()
    papers: list[dict[str, Any]] = []
    for row in rows:
        papers.append(
            {
                "pk": row["Z_PK"],
                "id": decode_uuid(row["ZID"]),
                "created_at": row["ZCREATEDAT"],
                "updated_at": row["ZUPDATEDAT"],
                "status": str(row["ZSTATUSRAW"] or ""),
                "title": str(row["ZTITLE"] or "").strip() or "Untitled paper",
                "task_id": str(row["ZCODEXTASKID"] or "").strip(),
                "source_note_ids": decode_json_text(row["ZSOURCENOTEIDSSTORAGE"]),
            }
        )
    return papers


def fetch_runs(connection: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = connection.execute(
        """
        SELECT
            Z_PK,
            ZCREATEDAT,
            ZUPDATEDAT,
            ZRUNID,
            ZTITLE,
            ZTHEME,
            ZSTAGERAW,
            ZSTATUSRAW,
            ZQUEUESTATERAW,
            ZLATESTPROGRESSMESSAGE,
            ZLASTERROR,
            ZACTIVETASKID,
            ZSOURCENOTEIDSSTORAGE,
            ZDATASETIDSSTORAGE,
            ZALLOWEDDOMAINSSTORAGE,
            ZPAPERID,
            ZID
        FROM ZRESEARCHRUN
        ORDER BY ZUPDATEDAT DESC
        """
    ).fetchall()
    runs: list[dict[str, Any]] = []
    for row in rows:
        runs.append(
            {
                "pk": row["Z_PK"],
                "id": decode_uuid(row["ZID"]),
                "paper_id": decode_uuid(row["ZPAPERID"]),
                "created_at": row["ZCREATEDAT"],
                "updated_at": row["ZUPDATEDAT"],
                "run_id": str(row["ZRUNID"] or "").strip(),
                "active_task_id": str(row["ZACTIVETASKID"] or "").strip(),
                "title": str(row["ZTITLE"] or "").strip() or "Untitled run",
                "theme": str(row["ZTHEME"] or "").strip(),
                "stage": str(row["ZSTAGERAW"] or "").strip(),
                "status": str(row["ZSTATUSRAW"] or "").strip(),
                "queue_state": str(row["ZQUEUESTATERAW"] or "").strip(),
                "latest_progress": str(row["ZLATESTPROGRESSMESSAGE"] or "").strip(),
                "last_error": str(row["ZLASTERROR"] or "").strip(),
                "source_note_ids": decode_json_text(row["ZSOURCENOTEIDSSTORAGE"]),
                "dataset_ids": decode_json_text(row["ZDATASETIDSSTORAGE"]),
                "allowed_domains": decode_json_text(row["ZALLOWEDDOMAINSSTORAGE"]),
            }
        )
    return runs


def decode_json_text(value: Any) -> Any:
    raw = str(value or "").strip()
    if not raw:
        return []
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


def decode_uuid(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        try:
            return str(uuid.UUID(bytes=value))
        except ValueError:
            return value.hex()
    return str(value)


def first_line(content: str) -> str:
    for line in content.splitlines():
        stripped = line.strip()
        if stripped:
            return stripped
    return ""


def preview(content: str, limit: int = 120) -> str:
    normalized = " ".join(part for part in content.split())
    if len(normalized) <= limit:
        return normalized
    return normalized[: limit - 1] + "…"


def render(*, payload: Any, section: str, store_path: Path) -> None:
    if section == "summary":
        print(f"store: {store_path}")
        for key, value in payload.items():
            if key == "store_path":
                continue
            print(f"{key}: {value}")
        return

    if section == "notes":
        for note in payload:
            print(f"{note['updated_at']}  {note['id']}  {note['title']}")
            print(f"  priority_requested_at: {note['priority_requested_at']}")
            print(f"  preview: {note['content_preview']}")
        return

    if section == "papers":
        for paper in payload:
            print(f"{paper['status']:<10} {paper['updated_at']}  {paper['title']}")
            print(f"  id: {paper['id']}")
            print(f"  task_id: {paper['task_id']}")
            print(f"  source_note_ids: {paper['source_note_ids']}")
        return

    if section == "runs":
        for run in payload:
            print(f"{run['status']:<10} {run['stage']:<10} {run['queue_state']:<24} {run['updated_at']}  {run['title']}")
            print(f"  run_id: {run['run_id']}")
            print(f"  active_task_id: {run['active_task_id']}")
            print(f"  paper_id: {run['paper_id']}")
            print(f"  source_note_ids: {run['source_note_ids']}")
            print(f"  dataset_ids: {run['dataset_ids']}")
            print(f"  allowed_domains: {run['allowed_domains']}")
            if run["latest_progress"]:
                print(f"  latest_progress: {run['latest_progress']}")
            if run["last_error"]:
                print(f"  last_error: {run['last_error']}")
        return

    print(json.dumps(payload, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        stderr = error.stderr.strip() if isinstance(error.stderr, str) else ""
        message = stderr or str(error)
        print(message, file=sys.stderr)
        raise SystemExit(error.returncode)
    except FileNotFoundError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
