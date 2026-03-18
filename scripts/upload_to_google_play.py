from __future__ import annotations

import argparse
import json
from pathlib import Path

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload


ANDROID_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Upload an Android App Bundle to a Google Play track."
    )
    parser.add_argument("--service-account-json", required=True)
    parser.add_argument("--package-name", required=True)
    parser.add_argument("--aab-path", required=True)
    parser.add_argument("--track", default="internal")
    parser.add_argument("--release-status", default="completed")
    parser.add_argument("--release-name", required=True)
    parser.add_argument("--release-notes", default="")
    parser.add_argument("--release-notes-file", default="")
    parser.add_argument("--release-notes-language", default="en-GB")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    service_account_path = Path(args.service_account_json)
    aab_path = Path(args.aab_path)

    if not service_account_path.exists():
        raise SystemExit(f"Service account file not found: {service_account_path}")
    if not aab_path.exists():
        raise SystemExit(f"App bundle not found: {aab_path}")

    release_notes = args.release_notes
    if args.release_notes_file:
        release_notes = Path(args.release_notes_file).read_text(encoding="utf-8")

    # Windows-downloaded JSON keys can include a UTF-8 BOM, so parse the file
    # ourselves with utf-8-sig before building the Google credentials.
    service_account_info = json.loads(
        service_account_path.read_text(encoding="utf-8-sig")
    )
    credentials = service_account.Credentials.from_service_account_info(
        service_account_info,
        scopes=[ANDROID_PUBLISHER_SCOPE],
    )

    service = build(
        "androidpublisher",
        "v3",
        credentials=credentials,
        cache_discovery=False,
    )

    edit = service.edits().insert(packageName=args.package_name, body={}).execute()
    edit_id = edit["id"]
    print(f"Created edit: {edit_id}")

    bundle = service.edits().bundles().upload(
        packageName=args.package_name,
        editId=edit_id,
        media_body=MediaFileUpload(str(aab_path), mimetype="application/octet-stream"),
    ).execute()
    version_code = str(bundle["versionCode"])
    print(f"Uploaded bundle with versionCode: {version_code}")

    releases = [
        {
            "name": args.release_name,
            "versionCodes": [version_code],
            "status": args.release_status,
        }
    ]

    if release_notes.strip():
        releases[0]["releaseNotes"] = [
            {
                "language": args.release_notes_language,
                "text": release_notes.strip(),
            }
        ]

    track_response = service.edits().tracks().update(
        packageName=args.package_name,
        editId=edit_id,
        track=args.track,
        body={"releases": releases},
    ).execute()
    print(json.dumps(track_response, indent=2))

    commit_response = service.edits().commit(
        packageName=args.package_name,
        editId=edit_id,
    ).execute()
    print(json.dumps(commit_response, indent=2))


if __name__ == "__main__":
    main()
