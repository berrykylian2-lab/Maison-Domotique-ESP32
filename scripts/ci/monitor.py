import argparse
import concurrent.futures
import datetime
import json
import os
import re
import sys
import time

from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError


WINGET = (
    "https://api.github.com/repos/"
    "microsoft/winget-pkgs/contents/manifests/"
)

SOURCES = {
    "Blender": WINGET + "b/BlenderFoundation/Blender",
    "Git": WINGET + "g/Git/Git",
    "UV": WINGET + "a/astral-sh/uv",
    "NodeJS": WINGET + "o/OpenJS/NodeJS/LTS",
    "Codex": "https://registry.npmjs.org/@openai%2Fcodex/latest",
    "MCP": "https://pypi.org/pypi/mcp-for-blender/json",
}


def utc_now():
    return datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat()


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    temporary = path.with_suffix(path.suffix + ".tmp")

    temporary.write_text(
        json.dumps(data, indent=2, sort_keys=True),
        encoding="utf-8",
    )

    temporary.replace(path)


def stable_version(value):
    return (
        isinstance(value, str)
        and re.fullmatch(r"\d+(?:\.\d+)+", value)
        is not None
    )


def version_key(value):
    return tuple(int(part) for part in value.split("."))


def extract_version(name, data):
    if name == "Codex":
        versions = [data["version"]]

    elif name == "MCP":
        versions = [
            version
            for version, files in data["releases"].items()
            if any(not item.get("yanked", False) for item in files)
        ]

    else:
        versions = [
            item["name"]
            for item in data
            if item.get("type") == "dir"
        ]

    stable = [
        version
        for version in versions
        if stable_version(version)
    ]

    if not stable:
        raise ValueError("No stable version found")

    return max(stable, key=version_key)


def request_json(url, timeout):
    request = Request(
        url,
        headers={
            "User-Agent": "Maison-Domotique-CI/1.0",
            "Accept": "application/json",
        },
    )

    token = os.environ.get("GH_TOKEN")

    if url.startswith(WINGET) and token:
        request.add_unredirected_header(
            "Authorization",
            f"Bearer {token}",
        )

    with urlopen(request, timeout=timeout) as response:
        payload = response.read(8 * 1024 * 1024 + 1)

        if len(payload) > 8 * 1024 * 1024:
            raise ValueError("Response too large")

        return json.loads(payload)


def check_source(name, url, attempts, timeout):
    started = time.monotonic()
    errors = []

    for attempt in range(1, attempts + 1):
        retry = False

        try:
            data = request_json(url, timeout)
            version = extract_version(name, data)

            return {
                "component": name,
                "status": "RECOVERED" if errors else "SUCCESS",
                "version": version,
                "attempts": attempt,
                "durationSeconds": round(
                    time.monotonic() - started, 3
                ),
                "previousErrors": errors,
                "source": url,
            }

        except HTTPError as error:
            errors.append(f"HTTP {error.code}")
            retry = (
                error.code in (408, 429)
                or 500 <= error.code < 600
            )

        except (URLError, TimeoutError, OSError) as error:
            errors.append(type(error).__name__)
            retry = True

        except Exception as error:
            errors.append(type(error).__name__)

        if not retry or attempt == attempts:
            break

        time.sleep(min(2 ** (attempt - 1), 4))

    return {
        "component": name,
        "status": "ERROR",
        "attempts": attempt,
        "durationSeconds": round(
            time.monotonic() - started, 3
        ),
        "errors": errors,
        "source": url,
    }


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--mode",
        choices=["health", "versions"],
        required=True,
    )

    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=10)
    parser.add_argument("--output", required=True)
    parser.add_argument("--report", required=True)

    args = parser.parse_args()

    if not 1 <= args.attempts <= 3:
        parser.error("Attempts must be between 1 and 3")

    if not 1 <= args.timeout <= 30:
        parser.error("Timeout must be between 1 and 30")

    started = time.monotonic()

    with concurrent.futures.ThreadPoolExecutor(
        max_workers=len(SOURCES)
    ) as executor:

        futures = [
            executor.submit(
                check_source,
                name,
                url,
                args.attempts,
                args.timeout,
            )
            for name, url in SOURCES.items()
        ]

        results = [future.result() for future in futures]

    failures = [
        result
        for result in results
        if result["status"] == "ERROR"
    ]

    recovered = [
        result
        for result in results
        if result["status"] == "RECOVERED"
    ]

    report = {
        "timestampUtc": utc_now(),
        "mode": args.mode,
        "status": (
            "ERROR" if failures
            else "RECOVERED" if recovered
            else "SUCCESS"
        ),
        "durationSeconds": round(
            time.monotonic() - started, 3
        ),
        "totalComponents": len(SOURCES),
        "failedComponents": len(failures),
        "recoveredComponents": len(recovered),
        "results": results,
    }

    write_json(args.report, report)

    for result in results:
        print(
            f"[{result['status']}] "
            f"{result['component']} "
            f"{result.get('version', '')} "
            f"- {result['durationSeconds']}s"
        )

    if failures:
        return 1

    if args.mode == "versions":
        snapshot = {
            result["component"]: result["version"]
            for result in results
        }

        write_json(args.output, snapshot)

    return 0


if __name__ == "__main__":
    sys.exit(main())
