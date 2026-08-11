#!/usr/bin/env python3
"""Trusted GitHub adapter for LWPT's managed-delivery state machine."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from model import (
    CI_READY_LABEL,
    DeliveryError,
    FULL_CI_REQUIRED_LABEL,
    MANAGED_LABEL,
    MERGE_READY_LABEL,
    READINESS_LABELS,
    REVIEW_READY_LABEL,
    derive_candidate_snapshot,
    label_names,
    require_expected_head,
    review_evidence_errors,
    snapshot_contains,
    snapshot_digest,
    snapshot_requires_full_ci,
    watchdog_expired,
    workflow_conclusion,
)


DELIVERY_CHECK = "delivery-admission"
FULL_CI_CHECK = "full-ci"
OWNED_APP = "github-actions"
DIAGNOSTIC_TARGETS = {"x86_64-win64", "i386-win32"}
DIAGNOSTIC_SELECTORS = {"default", "e2e", "tls"}
MANAGED_RUN_RE = re.compile(r"^delivery-pr/(\d+)/([0-9a-f]{40})/([0-9a-f]{64})/(\d+)$")
FULL_CI_RUN_RE = re.compile(r"^full-ci/(\d+)/([0-9a-f]{40})/([0-9a-f]{64})/(\d+)$")
DIAGNOSTIC_RUN_RE = re.compile(
    r"^diagnostic/(\d+)/([0-9a-f]{40})/(x86_64-win64|i386-win32)/(default|e2e|tls)$"
)


class GitHub:
    def __init__(self) -> None:
        self.repository = os.environ["GITHUB_REPOSITORY"]
        self.owner, self.name = self.repository.split("/", 1)
        self.token = os.environ["GH_TOKEN"]
        self.api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com")
        self.graphql_url = os.environ.get("GITHUB_GRAPHQL_URL", "https://api.github.com/graphql")

    def request(self, method: str, path: str, payload: Any | None = None) -> Any:
        url = path if path.startswith("https://") else f"{self.api_url}{path}"
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(url, data=body, method=method)
        request.add_header("Accept", "application/vnd.github+json")
        request.add_header("Authorization", f"Bearer {self.token}")
        request.add_header("X-GitHub-Api-Version", "2022-11-28")
        if body is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise DeliveryError(f"GitHub API {method} {path} failed ({error.code}): {detail}") from error
        except (urllib.error.URLError, TimeoutError) as error:
            raise DeliveryError(f"GitHub API {method} {path} failed: {error}") from error

    def graphql(self, query: str, variables: dict[str, Any]) -> dict[str, Any]:
        url = self.graphql_url
        body = json.dumps({"query": query, "variables": variables}).encode("utf-8")
        request = urllib.request.Request(url, data=body, method="POST")
        request.add_header("Accept", "application/vnd.github+json")
        request.add_header("Authorization", f"Bearer {self.token}")
        request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise DeliveryError(f"GitHub GraphQL request failed ({error.code}): {detail}") from error
        except (urllib.error.URLError, TimeoutError) as error:
            raise DeliveryError(f"GitHub GraphQL request failed: {error}") from error
        if result.get("errors"):
            raise DeliveryError(f"GitHub GraphQL request failed: {result['errors']}")
        return result["data"]

    def pull(self, number: int) -> dict[str, Any]:
        return self.request("GET", f"/repos/{self.repository}/pulls/{number}")

    def open_pulls(self) -> list[dict[str, Any]]:
        return self.request("GET", f"/repos/{self.repository}/pulls?state=open&per_page=100")

    def topology(self, number: int) -> dict[str, Any]:
        query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              id number state isDraft headRefOid baseRefOid baseRefName
              headRepository { nameWithOwner }
              labels(first: 100) { nodes { name } }
              stackEntry { position }
              stack {
                id number baseRefName
                entries(first: 100) {
                  nodes {
                    position
                    pullRequest {
                      number state headRefOid baseRefOid baseRefName
                      headRepository { nameWithOwner }
                      labels(first: 100) { nodes { name } }
                    }
                  }
                  pageInfo { hasNextPage }
                }
              }
            }
          }
        }
        """
        data = self.graphql(query, {"owner": self.owner, "name": self.name, "number": number})
        pull = data["repository"]["pullRequest"]
        if not pull:
            raise DeliveryError(f"pull request #{number} does not exist")
        if pull.get("stack") and pull["stack"]["entries"]["pageInfo"]["hasNextPage"]:
            raise DeliveryError("native stack exceeds the supported 100-entry fail-closed bound")
        return pull

    def check_runs(self, head: str) -> list[dict[str, Any]]:
        result = self.request(
            "GET", f"/repos/{self.repository}/commits/{head}/check-runs?per_page=100"
        )
        if result["total_count"] > len(result["check_runs"]):
            raise DeliveryError("check-run evidence exceeds the supported 100-item fail-closed bound")
        return result["check_runs"]

    def check_run(self, check_id: int) -> dict[str, Any]:
        return self.request("GET", f"/repos/{self.repository}/check-runs/{check_id}")

    def create_check(
        self, name: str, head: str, external_id: str, title: str, summary: str
    ) -> dict[str, Any]:
        return self.request(
            "POST",
            f"/repos/{self.repository}/check-runs",
            {
                "name": name,
                "head_sha": head,
                "status": "in_progress",
                "external_id": external_id,
                "output": {"title": title, "summary": summary},
            },
        )

    def update_check(
        self,
        check_id: int,
        *,
        title: str,
        summary: str,
        conclusion: str | None = None,
        details_url: str | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {"output": {"title": title, "summary": summary}}
        if conclusion:
            payload.update({"status": "completed", "conclusion": conclusion})
        else:
            payload["status"] = "in_progress"
        if details_url:
            payload["details_url"] = details_url
        return self.request(
            "PATCH", f"/repos/{self.repository}/check-runs/{check_id}", payload
        )

    def add_labels(self, number: int, labels: list[str]) -> None:
        self.request(
            "POST", f"/repos/{self.repository}/issues/{number}/labels", {"labels": labels}
        )

    def remove_label(self, number: int, label: str) -> None:
        encoded = urllib.parse.quote(label, safe="")
        try:
            self.request("DELETE", f"/repos/{self.repository}/issues/{number}/labels/{encoded}")
        except DeliveryError as error:
            if "(404)" not in str(error):
                raise

    def dispatch(self, workflow: str, inputs: dict[str, str]) -> None:
        repository = self.request("GET", f"/repos/{self.repository}")
        self.request(
            "POST",
            f"/repos/{self.repository}/actions/workflows/{workflow}/dispatches",
            {"ref": repository["default_branch"], "inputs": inputs},
        )

    def workflow_runs(self, workflow: str) -> list[dict[str, Any]]:
        runs: list[dict[str, Any]] = []
        for status in ("queued", "in_progress"):
            result = self.request(
                "GET",
                f"/repos/{self.repository}/actions/workflows/{workflow}/runs"
                f"?event=workflow_dispatch&status={status}&per_page=100",
            )
            if result["total_count"] > len(result["workflow_runs"]):
                raise DeliveryError(
                    "active workflow-run evidence exceeds the supported 100-item fail-closed bound"
                )
            runs.extend(result["workflow_runs"])
        return runs

    def cancel_run(self, run_id: int) -> None:
        try:
            self.request("POST", f"/repos/{self.repository}/actions/runs/{run_id}/cancel")
        except DeliveryError as error:
            if "(404)" not in str(error) and "(409)" not in str(error):
                raise

    def collaborator_permission(self, login: str) -> str:
        encoded = urllib.parse.quote(login, safe="")
        result = self.request(
            "GET", f"/repos/{self.repository}/collaborators/{encoded}/permission"
        )
        return result["permission"]

    def mark_ready(self, node_id: str) -> None:
        mutation = """
        mutation($id: ID!) {
          markPullRequestReadyForReview(input: {pullRequestId: $id}) {
            pullRequest { id isDraft }
          }
        }
        """
        self.graphql(mutation, {"id": node_id})

    def review_evidence(self, number: int) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviews(first: 100) {
                nodes { author { login } state commit { oid } body submittedAt }
                pageInfo { hasNextPage }
              }
              reviewThreads(first: 100) {
                nodes {
                  isResolved
                  comments(first: 100) {
                    nodes { author { login } authorAssociation body createdAt }
                    pageInfo { hasNextPage }
                  }
                }
                pageInfo { hasNextPage }
              }
            }
          }
        }
        """
        data = self.graphql(query, {"owner": self.owner, "name": self.name, "number": number})
        pull = data["repository"]["pullRequest"]
        reviews = pull["reviews"]
        threads = pull["reviewThreads"]
        if reviews["pageInfo"]["hasNextPage"] or threads["pageInfo"]["hasNextPage"]:
            raise DeliveryError("review evidence exceeds the supported 100-item fail-closed bound")
        normalized_threads = []
        for thread in threads["nodes"]:
            if thread["comments"]["pageInfo"]["hasNextPage"]:
                raise DeliveryError("a review thread exceeds the supported 100-comment fail-closed bound")
            normalized_threads.append(
                {"isResolved": thread["isResolved"], "comments": thread["comments"]["nodes"]}
            )
        return reviews["nodes"], normalized_threads


class Controller:
    def __init__(self, github: GitHub) -> None:
        self.github = github
        config_path = Path(__file__).with_name("review-automations.json")
        self.automations = json.loads(config_path.read_text(encoding="utf-8"))["automations"]

    @staticmethod
    def delivery_external_id(number: int, head: str, digest: str) -> str:
        return f"delivery:v1:{number}:{head}:{digest}"

    @staticmethod
    def full_ci_external_id(number: int, head: str, digest: str) -> str:
        return f"full-ci:v1:{number}:{head}:{digest}"

    @staticmethod
    def owned(check: dict[str, Any], name: str) -> bool:
        return check.get("name") == name and check.get("app", {}).get("slug") == OWNED_APP

    def matching_check(self, head: str, name: str, external_id: str) -> dict[str, Any] | None:
        matches = [
            check
            for check in self.github.check_runs(head)
            if self.owned(check, name) and check.get("external_id") == external_id
        ]
        return sorted(matches, key=lambda item: item["id"])[-1] if matches else None

    def latest_owned_check(self, head: str, name: str) -> dict[str, Any] | None:
        matches = [check for check in self.github.check_runs(head) if self.owned(check, name)]
        return sorted(matches, key=lambda item: item["id"])[-1] if matches else None

    def require_owned_check(
        self, check_id: int, name: str, expected_external_id: str
    ) -> dict[str, Any]:
        check = self.github.check_run(check_id)
        if not self.owned(check, name) or check.get("external_id") != expected_external_id:
            raise DeliveryError(
                f"check #{check_id} is not the expected app-owned {name} proof"
            )
        return check

    def dispatch_with_terminal_failure(
        self,
        workflow: str,
        inputs: dict[str, str],
        check: dict[str, Any],
        failure_title: str,
    ) -> None:
        try:
            self.github.dispatch(workflow, inputs)
        except DeliveryError as error:
            self.github.update_check(
                check["id"],
                title=failure_title,
                summary=str(error),
                conclusion="failure",
            )
            raise

    def current_pull(self, number: int, expected_head: str | None = None) -> dict[str, Any]:
        pull = self.github.pull(number)
        if pull["state"] != "open":
            raise DeliveryError(f"pull request #{number} is not open")
        if expected_head is not None:
            require_expected_head(pull, expected_head)
        return pull

    def snapshot(self, number: int) -> tuple[dict[str, Any], str]:
        snapshot = derive_candidate_snapshot(self.github.topology(number))
        return snapshot, snapshot_digest(snapshot)

    def require_same_repository(self, pull: dict[str, Any]) -> None:
        if pull["head"]["repo"]["full_name"] != self.github.repository:
            raise DeliveryError("managed delivery refuses fork heads; use the ordinary PR route")

    def clear_readiness(self, number: int, labels: tuple[str, ...] = READINESS_LABELS) -> None:
        for label in labels:
            self.github.remove_label(number, label)

    def ensure_delivery_check(
        self, number: int, head: str, snapshot: dict[str, Any], digest: str, retry: bool = False
    ) -> dict[str, Any]:
        external_id = self.delivery_external_id(number, head, digest)
        check = self.matching_check(head, DELIVERY_CHECK, external_id)
        if check and (check["status"] != "completed" or check.get("conclusion") == "success"):
            return check
        if check and not retry:
            return check
        summary = json.dumps(snapshot, sort_keys=True, separators=(",", ":"))
        return self.github.create_check(
            DELIVERY_CHECK,
            head,
            external_id,
            "Waiting for managed-delivery CI",
            f"Exact topology: `{digest}`\n\n```json\n{summary}\n```",
        )

    def enrol(self, number: int, expected_head: str) -> None:
        pull = self.current_pull(number, expected_head)
        self.require_same_repository(pull)
        snapshot, digest = self.snapshot(number)
        self.ensure_delivery_check(number, expected_head, snapshot, digest, retry=True)
        self.clear_readiness(number)
        self.github.add_labels(number, [MANAGED_LABEL])

    def ci(self, number: int, expected_head: str) -> None:
        pull = self.current_pull(number, expected_head)
        self.require_same_repository(pull)
        if MANAGED_LABEL not in label_names(pull):
            raise DeliveryError(f"pull request #{number} is not {MANAGED_LABEL}")
        snapshot, digest = self.snapshot(number)
        check = self.ensure_delivery_check(number, expected_head, snapshot, digest, retry=True)
        if check.get("conclusion") == "success":
            self.github.add_labels(number, [CI_READY_LABEL])
            return
        if check.get("output", {}).get("title") == "Managed PR CI running":
            return
        self.clear_readiness(number, (REVIEW_READY_LABEL, MERGE_READY_LABEL))
        self.github.add_labels(number, [CI_READY_LABEL])
        self.github.update_check(
            check["id"],
            title="Managed PR CI running",
            summary=f"Read-only exact-head matrix dispatched for `{expected_head}` and topology `{digest}`.",
        )
        try:
            self.dispatch_with_terminal_failure(
                "delivery-pr.yml",
                {
                    "pr_number": str(number),
                    "expected_head": expected_head,
                    "topology_digest": digest,
                    "check_id": str(check["id"]),
                },
                check,
                "Managed PR CI dispatch failed",
            )
        except DeliveryError:
            self.clear_readiness(number)
            raise

    def require_delivery_success(self, number: int, expected_head: str) -> dict[str, Any]:
        _, digest = self.snapshot(number)
        check = self.matching_check(
            expected_head,
            DELIVERY_CHECK,
            self.delivery_external_id(number, expected_head, digest),
        )
        if not check or check.get("conclusion") != "success":
            raise DeliveryError(
                f"#{number} lacks successful exact-head {DELIVERY_CHECK} evidence for topology {digest}"
            )
        return check

    def review(self, number: int, expected_head: str) -> None:
        pull = self.current_pull(number, expected_head)
        self.require_same_repository(pull)
        if MANAGED_LABEL not in label_names(pull):
            raise DeliveryError(f"pull request #{number} is not {MANAGED_LABEL}")
        self.require_delivery_success(number, expected_head)
        self.clear_readiness(number, (MERGE_READY_LABEL,))
        self.github.add_labels(number, [CI_READY_LABEL, REVIEW_READY_LABEL])

    def diagnostic(
        self, number: int, expected_head: str, target: str, selector: str
    ) -> None:
        pull = self.current_pull(number, expected_head)
        self.require_same_repository(pull)
        if target not in DIAGNOSTIC_TARGETS:
            raise DeliveryError(f"unsupported diagnostic target: {target}")
        if selector not in DIAGNOSTIC_SELECTORS:
            raise DeliveryError(f"unsupported diagnostic selector: {selector}")
        self.github.dispatch(
            "ci.yml",
            {
                "mode": "diagnostic",
                "candidate_pr_number": str(number),
                "expected_head": expected_head,
                "diagnostic_target": target,
                "diagnostic_selector": selector,
            },
        )

    def full_ci(self, number: int, expected_head: str) -> None:
        self.current_pull(number, expected_head)
        snapshot, digest = self.snapshot(number)
        if not snapshot_requires_full_ci(snapshot):
            raise DeliveryError(
                f"candidate #{number} is not marked {FULL_CI_REQUIRED_LABEL}"
            )
        review_fingerprints: dict[str, str] = {}
        for entry in snapshot["entries"]:
            member = self.current_pull(entry["number"], entry["head"])
            self.require_same_repository(member)
            if member.get("mergeable") is False or member.get("mergeable_state") in {
                "behind",
                "dirty",
                "unknown",
            }:
                raise DeliveryError(
                    f"pull request #{entry['number']} is not integrated with its current base"
                )
            if (member.get("base") or {}).get("sha") not in {None, entry["base"]}:
                raise DeliveryError(
                    f"pull request #{entry['number']} base changed during promotion"
                )
            self.require_delivery_success(entry["number"], entry["head"])
            review_fingerprints[str(entry["number"])] = self.validate_reviews(
                entry["number"], entry["head"]
            )
        external_id = self.full_ci_external_id(number, expected_head, digest)
        check = self.matching_check(expected_head, FULL_CI_CHECK, external_id)
        if check and check.get("conclusion") == "success":
            return
        if check and check["status"] != "completed":
            return
        summary = json.dumps(snapshot, sort_keys=True, separators=(",", ":"))
        check = self.github.create_check(
            FULL_CI_CHECK,
            expected_head,
            external_id,
            "Full CI running",
            f"Candidate topology: `{digest}`\n\n```json\n{summary}\n```\n\n"
            + "```review-evidence\n"
            + json.dumps(review_fingerprints, sort_keys=True, separators=(",", ":"))
            + "\n```",
        )
        self.dispatch_with_terminal_failure(
            "ci.yml",
            {
                "mode": "full-ci",
                "candidate_pr_number": str(number),
                "expected_head": expected_head,
                "topology_digest": digest,
                "check_id": str(check["id"]),
            },
            check,
            "Full CI dispatch failed",
        )

    def require_full_ci(self, candidate: int, snapshot: dict[str, Any], digest: str) -> None:
        if not snapshot_requires_full_ci(snapshot):
            return
        head = snapshot["entries"][-1]["head"]
        check = self.matching_check(
            head, FULL_CI_CHECK, self.full_ci_external_id(candidate, head, digest)
        )
        if not check or check.get("conclusion") != "success":
            raise DeliveryError(
                f"candidate #{candidate} requires successful exact-topology {FULL_CI_CHECK} evidence"
            )

    @staticmethod
    def review_fingerprint(
        checks: list[dict[str, Any]],
        reviews: list[dict[str, Any]],
        threads: list[dict[str, Any]],
        automations: list[dict[str, Any]],
    ) -> str:
        def configured_check(check: dict[str, Any]) -> bool:
            for automation in automations:
                contexts = set(automation.get("check_contexts", []))
                if automation.get("check_context"):
                    contexts.add(automation["check_context"])
                apps = set(automation.get("check_app_slugs", []))
                if check.get("name") in contexts and (
                    not apps or (check.get("app") or {}).get("slug") in apps
                ):
                    return True
            return False

        evidence = {
            "checks": sorted(
                [
                    {
                        "id": check.get("id"),
                        "name": check.get("name"),
                        "app": (check.get("app") or {}).get("slug"),
                        "status": check.get("status"),
                        "conclusion": check.get("conclusion"),
                        "completed_at": check.get("completed_at"),
                    }
                    for check in checks
                    if configured_check(check)
                ],
                key=lambda item: (item["name"] or "", item["id"] or 0),
            ),
            "reviews": reviews,
            "threads": threads,
        }
        encoded = json.dumps(
            evidence, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    def current_review_fingerprint(self, number: int, head: str) -> str:
        checks = self.github.check_runs(head)
        reviews, threads = self.github.review_evidence(number)
        return self.review_fingerprint(checks, reviews, threads, self.automations)

    def validate_reviews(self, number: int, head: str) -> str:
        checks = self.github.check_runs(head)
        reviews, threads = self.github.review_evidence(number)
        reply_logins = {
            comment.get("author", {}).get("login")
            for thread in threads
            for comment in thread["comments"]
            if comment.get("author")
        }
        maintainers: set[str] = set()
        for login in sorted(login for login in reply_logins if login):
            try:
                permission = self.github.collaborator_permission(login)
            except DeliveryError:
                continue
            if permission in {"admin", "maintain"}:
                maintainers.add(login)
        errors = review_evidence_errors(
            head, self.automations, checks, reviews, threads, maintainers
        )
        if errors:
            raise DeliveryError("review evidence is not terminal: " + "; ".join(errors))
        return self.review_fingerprint(checks, reviews, threads, self.automations)

    def merge(self, number: int, expected_head: str, candidate: int) -> None:
        pull = self.current_pull(number, expected_head)
        self.require_same_repository(pull)
        if MANAGED_LABEL not in label_names(pull):
            raise DeliveryError(f"pull request #{number} is not {MANAGED_LABEL}")
        self.require_delivery_success(number, expected_head)
        if REVIEW_READY_LABEL not in label_names(pull):
            raise DeliveryError(f"pull request #{number} has not opened the review phase")
        self.validate_reviews(number, expected_head)
        candidate_pull = self.current_pull(candidate)
        self.require_same_repository(candidate_pull)
        candidate_snapshot, digest = self.snapshot(candidate)
        if not snapshot_contains(candidate_snapshot, number):
            raise DeliveryError(f"#{number} is not in candidate #{candidate}'s native prefix")
        self.require_full_ci(candidate, candidate_snapshot, digest)
        self.github.add_labels(
            number, [CI_READY_LABEL, REVIEW_READY_LABEL, MERGE_READY_LABEL]
        )
        topology = self.github.topology(number)
        if topology["isDraft"]:
            self.github.mark_ready(topology["id"])

    def reset(self, number: int, expected_head: str) -> None:
        pull = self.current_pull(number, expected_head)
        self.clear_readiness(number)
        if MANAGED_LABEL in label_names(pull):
            snapshot, digest = self.snapshot(number)
            check = self.latest_owned_check(expected_head, DELIVERY_CHECK)
            if check and check["status"] != "completed":
                self.github.update_check(
                    check["id"],
                    title="Managed delivery reset",
                    summary="The coordinator explicitly returned this head to waiting state.",
                    conclusion="failure",
                )
            self.ensure_delivery_check(number, expected_head, snapshot, digest, retry=True)

    def observe_one(self, number: int) -> None:
        pull = self.current_pull(number)
        head = pull["head"]["sha"]
        labels = label_names(pull)
        snapshot, digest = self.snapshot(number)
        external_id = self.delivery_external_id(number, head, digest)
        current = self.matching_check(head, DELIVERY_CHECK, external_id)
        latest = self.latest_owned_check(head, DELIVERY_CHECK)

        if latest and latest.get("external_id") != external_id and latest["status"] != "completed":
            self.github.update_check(
                latest["id"],
                title="Delivery topology changed",
                summary=f"Current exact topology is `{digest}`; the prior proof is stale.",
                conclusion="failure",
            )
            current = None
        if current is None:
            if MANAGED_LABEL in labels:
                self.clear_readiness(number)
            current = self.ensure_delivery_check(number, head, snapshot, digest, retry=True)

        if MANAGED_LABEL in labels:
            if pull["head"]["repo"]["full_name"] != self.github.repository:
                self.clear_readiness(number)
                if current["status"] != "completed":
                    self.github.update_check(
                        current["id"],
                        title="Managed fork refused",
                        summary="The privileged controller never dispatches or executes fork code.",
                        conclusion="failure",
                    )
                return
            if current.get("conclusion") not in {None, "success"}:
                self.clear_readiness(number)
            if REVIEW_READY_LABEL in labels and current.get("conclusion") != "success":
                self.clear_readiness(number, (REVIEW_READY_LABEL, MERGE_READY_LABEL))
            if pull.get("draft"):
                self.clear_readiness(number, (MERGE_READY_LABEL,))
        # Ordinary PR labels retain their existing human/provider semantics;
        # only the aggregate admission check is controller-owned for them.

    def fail_pending_head(self, number: int, head: str, title: str, summary: str) -> None:
        prefixes = (
            f"delivery:v1:{number}:{head}:",
            f"full-ci:v1:{number}:{head}:",
        )
        for check in self.github.check_runs(head):
            if check["status"] == "completed" or not any(
                check.get("external_id", "").startswith(prefix) for prefix in prefixes
            ):
                continue
            if not (
                self.owned(check, DELIVERY_CHECK) or self.owned(check, FULL_CI_CHECK)
            ):
                continue
            self.github.update_check(
                check["id"],
                title=title,
                summary=summary,
                conclusion="failure",
            )

    def fail_superseded_head(self, number: int, head: str) -> None:
        self.fail_pending_head(
            number,
            head,
            "Proof head superseded",
            f"Pull request #{number} no longer has head `{head}`.",
        )

    def cancel_superseded_ci_runs(
        self,
        number: int,
        current_head: str,
        current_digest: str,
        review_changed: bool = False,
        closed: bool = False,
    ) -> None:
        for run in self.github.workflow_runs("ci.yml"):
            if run.get("status") not in {"queued", "in_progress"}:
                continue
            title = run.get("display_title", "")
            full_ci = FULL_CI_RUN_RE.match(title)
            diagnostic = DIAGNOSTIC_RUN_RE.match(title)
            should_cancel = False
            if full_ci:
                if int(full_ci.group(1)) == number and (
                    closed
                    or review_changed
                    or full_ci.group(2) != current_head
                    or full_ci.group(3) != current_digest
                ):
                    should_cancel = True
                elif int(full_ci.group(1)) == number:
                    should_cancel = False
                else:
                    check = self.github.check_run(int(full_ci.group(4)))
                    summary = (check.get("output") or {}).get("summary") or ""
                    marker = "```json\n"
                    start = summary.find(marker)
                    end = summary.find("\n```", start + len(marker))
                    snapshot = None
                    if start >= 0 and end > start:
                        try:
                            snapshot = json.loads(summary[start + len(marker):end])
                        except json.JSONDecodeError:
                            snapshot = None
                    if snapshot is not None and snapshot_digest(snapshot) == full_ci.group(3):
                        member = next(
                            (entry for entry in snapshot.get("entries", [])
                             if entry.get("number") == number),
                            None,
                        )
                        if member is not None:
                            should_cancel = (
                                closed
                                or review_changed
                                or member.get("head") != current_head
                            )
            elif diagnostic and int(diagnostic.group(1)) == number:
                should_cancel = closed or diagnostic.group(2) != current_head
            if should_cancel:
                self.github.cancel_run(run["id"])

    def is_review_check(self, check: dict[str, Any]) -> bool:
        name = check.get("name")
        app = (check.get("app") or {}).get("slug")
        for automation in self.automations:
            contexts = set(automation.get("check_contexts", []))
            if automation.get("check_context"):
                contexts.add(automation["check_context"])
            apps = set(automation.get("check_app_slugs", []))
            if name in contexts and (not apps or app in apps):
                return True
        return False

    def invalidate_active_full_ci_for_member(
        self,
        number: int,
        title: str,
        summary: str,
        force: bool = False,
    ) -> None:
        for run in self.github.workflow_runs("ci.yml"):
            match = FULL_CI_RUN_RE.match(run.get("display_title", ""))
            if not match:
                continue
            check = self.github.check_run(int(match.group(4)))
            output = (check.get("output") or {}).get("summary") or ""
            marker = "```json\n"
            start = output.find(marker)
            end = output.find("\n```", start + len(marker))
            if start < 0 or end <= start:
                continue
            try:
                snapshot = json.loads(output[start + len(marker):end])
            except json.JSONDecodeError:
                continue
            if snapshot_digest(snapshot) != match.group(3) or not snapshot_contains(
                snapshot, number
            ):
                continue
            review_marker = "```review-evidence\n"
            review_start = output.find(review_marker)
            review_end = output.find("\n```", review_start + len(review_marker))
            stored_fingerprints: dict[str, str] = {}
            if review_start >= 0 and review_end > review_start:
                try:
                    stored_fingerprints = json.loads(
                        output[review_start + len(review_marker):review_end]
                    )
                except json.JSONDecodeError:
                    stored_fingerprints = {}
            member = next(
                entry for entry in snapshot["entries"] if entry["number"] == number
            )
            if not force:
                try:
                    current_fingerprint = self.current_review_fingerprint(
                        number, member["head"]
                    )
                except DeliveryError:
                    current_fingerprint = ""
                if stored_fingerprints.get(str(number)) == current_fingerprint:
                    continue
            self.github.cancel_run(run["id"])
            if check.get("status") != "completed" and self.owned(
                check, FULL_CI_CHECK
            ):
                self.github.update_check(
                    check["id"],
                    title=title,
                    summary=(
                        summary
                        + "\n\n```json\n"
                        + json.dumps(snapshot, sort_keys=True, separators=(",", ":"))
                        + "\n```\n\n```review-evidence\n"
                        + json.dumps(
                            stored_fingerprints,
                            sort_keys=True,
                            separators=(",", ":"),
                        )
                        + "\n```"
                    ),
                    conclusion="failure",
                )

    def observe(self, event_path: str | None) -> None:
        numbers: set[int] = set()
        review_changed_numbers: set[int] = set()
        force_review_change: set[int] = set()
        if event_path:
            event = json.loads(Path(event_path).read_text(encoding="utf-8"))
            check_run = event.get("check_run")
            if check_run and self.is_review_check(check_run):
                for reference in check_run.get("pull_requests", []):
                    review_changed_numbers.add(reference["number"])
                    if event.get("action") in {"rerequested", "requested_action"}:
                        force_review_change.add(reference["number"])
                    numbers.add(reference["number"])
            pull = event.get("pull_request")
            if pull:
                number = pull["number"]
                head = pull["head"]["sha"]
                if "review" in event or "comment" in event:
                    review_changed_numbers.add(number)
                    if event.get("action") in {"edited", "dismissed", "deleted"}:
                        force_review_change.add(number)
                if pull.get("state") == "open":
                    numbers.add(number)
                else:
                    self.fail_pending_head(
                        number,
                        head,
                        "Pull request closed",
                        f"Pull request #{number} closed before the proof completed.",
                    )
                    self.cancel_superseded_ci_runs(
                        number, head, "", closed=True
                    )
                    self.invalidate_active_full_ci_for_member(
                        number,
                        "Prefix member closed",
                        f"Pull request #{number} closed before the proof completed.",
                        force=True,
                    )
                before = event.get("before")
                if before and before != head:
                    self.fail_superseded_head(number, before)
                    try:
                        _, digest = self.snapshot(number)
                        self.cancel_superseded_ci_runs(number, head, digest)
                    except DeliveryError:
                        pass
        for pull in self.github.open_pulls():
            if MANAGED_LABEL in label_names(pull):
                numbers.add(pull["number"])
        for number in sorted(numbers):
            self.observe_one(number)
            pull = self.current_pull(number)
            _, digest = self.snapshot(number)
            if number in review_changed_numbers:
                self.invalidate_active_full_ci_for_member(
                    number,
                    "Review evidence changed",
                    f"Review activity changed on prefix member #{number} after full-CI promotion started.",
                    force=number in force_review_change,
                )
            self.cancel_superseded_ci_runs(
                number,
                pull["head"]["sha"],
                digest,
            )

    def fail_pending_full_ci_review_change(self, number: int, head: str) -> None:
        prefix = f"full-ci:v1:{number}:{head}:"
        for check in self.github.check_runs(head):
            if (
                check["status"] != "completed"
                and self.owned(check, FULL_CI_CHECK)
                and check.get("external_id", "").startswith(prefix)
            ):
                self.github.update_check(
                    check["id"],
                    title="Review evidence changed",
                    summary="Review activity changed after full-CI promotion started.",
                    conclusion="failure",
                )

    def finalize_managed(self, run: dict[str, Any], match: re.Match[str]) -> None:
        number = int(match.group(1))
        head, requested_digest, check_id = match.group(2), match.group(3), int(match.group(4))
        check = self.require_owned_check(
            check_id,
            DELIVERY_CHECK,
            self.delivery_external_id(number, head, requested_digest),
        )
        conclusion, title = workflow_conclusion(run.get("conclusion"))
        summary = f"Workflow run {run['id']} concluded `{run.get('conclusion')}`."
        try:
            pull = self.current_pull(number, head)
            if MANAGED_LABEL not in label_names(pull):
                raise DeliveryError("managed-delivery label was removed during the matrix")
            snapshot, digest = self.snapshot(number)
            if digest != requested_digest:
                raise DeliveryError(
                    f"topology changed from {requested_digest} to {digest} during PR CI"
                )
            summary = (
                f"Workflow run {run['id']} concluded `{run.get('conclusion')}` for topology "
                f"`{digest}`.\n\n```json\n"
                f"{json.dumps(snapshot, sort_keys=True, separators=(',', ':'))}\n```"
            )
        except DeliveryError as error:
            conclusion, title = "failure", "Managed PR CI evidence became stale"
            summary = f"Workflow run {run['id']}: {error}"
        self.github.update_check(
            check_id,
            title=title,
            summary=summary,
            conclusion=conclusion,
            details_url=run["html_url"],
        )
        if conclusion != "success":
            self.clear_readiness(number)

    def finalize_full_ci(self, run: dict[str, Any], match: re.Match[str]) -> None:
        number = int(match.group(1))
        head, requested_digest, check_id = match.group(2), match.group(3), int(match.group(4))
        snapshot: dict[str, Any] | None = None
        check = self.require_owned_check(
            check_id,
            FULL_CI_CHECK,
            self.full_ci_external_id(number, head, requested_digest),
        )
        if check.get("status") == "completed":
            return
        conclusion, title = workflow_conclusion(run.get("conclusion"))
        summary = f"Workflow run {run['id']} concluded `{run.get('conclusion')}`."
        try:
            self.current_pull(number, head)
            snapshot, digest = self.snapshot(number)
            if digest != requested_digest:
                raise DeliveryError(
                    f"topology changed from {requested_digest} to {digest} during full CI"
                )
            summary = (
                f"Workflow run {run['id']} concluded `{run.get('conclusion')}` for candidate "
                f"#{number}, head `{head}`, and topology `{digest}`.\n\n```json\n"
                f"{json.dumps(snapshot, sort_keys=True, separators=(',', ':'))}\n```"
            )
        except DeliveryError as error:
            conclusion, title = "failure", "Full-CI evidence became stale"
            summary = f"Workflow run {run['id']}: {error}"
        self.github.update_check(
            check_id,
            title=title,
            summary=summary,
            conclusion=conclusion,
            details_url=run["html_url"],
        )
        if conclusion != "success" and snapshot is not None:
            for entry in snapshot.get("entries", []):
                self.github.remove_label(entry["number"], MERGE_READY_LABEL)

    def finalize_ordinary(self, run: dict[str, Any]) -> None:
        conclusion, title = workflow_conclusion(run.get("conclusion"))
        references = run.get("pull_requests", [])
        if not references:
            references = [
                {"number": pull["number"]}
                for pull in self.github.open_pulls()
                if pull["head"]["sha"] == run["head_sha"]
            ]
        for reference in references:
            number = reference["number"]
            try:
                pull = self.current_pull(number, run["head_sha"])
            except DeliveryError:
                continue
            if MANAGED_LABEL in label_names(pull):
                continue
            snapshot, digest = self.snapshot(number)
            check = self.ensure_delivery_check(
                number, run["head_sha"], snapshot, digest, retry=True
            )
            self.github.update_check(
                check["id"],
                title=title,
                summary=(
                    f"Ordinary PR workflow run {run['id']} concluded "
                    f"`{run.get('conclusion')}` for topology `{digest}`."
                ),
                conclusion=conclusion,
                details_url=run["html_url"],
            )

    def finalize(self, event_path: str) -> None:
        event = json.loads(Path(event_path).read_text(encoding="utf-8"))
        run = event["workflow_run"]
        managed = MANAGED_RUN_RE.match(run.get("display_title", ""))
        full_ci = FULL_CI_RUN_RE.match(run.get("display_title", ""))
        if managed:
            self.finalize_managed(run, managed)
        elif full_ci:
            self.finalize_full_ci(run, full_ci)
        elif run.get("name") == "PR":
            self.finalize_ordinary(run)

    def watchdog(self, maximum_age_minutes: int) -> None:
        now = datetime.now(timezone.utc)
        for pull in self.github.open_pulls():
            head = pull["head"]["sha"]
            for check in self.github.check_runs(head):
                if not (
                    self.owned(check, DELIVERY_CHECK) or self.owned(check, FULL_CI_CHECK)
                ):
                    continue
                if check["status"] == "completed":
                    continue
                if watchdog_expired(check["started_at"], maximum_age_minutes, now):
                    self.github.update_check(
                        check["id"],
                        title="Delivery proof timed out",
                        summary=(
                            f"No terminal workflow result arrived within {maximum_age_minutes} minutes."
                        ),
                        conclusion="failure",
                    )
                    if check["name"] == DELIVERY_CHECK:
                        self.clear_readiness(pull["number"])
                    else:
                        try:
                            snapshot, _ = self.snapshot(pull["number"])
                        except DeliveryError:
                            continue
                        for entry in snapshot["entries"]:
                            self.github.remove_label(entry["number"], MERGE_READY_LABEL)


def positive_integer(value: str) -> int:
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "operation",
        choices=["enrol", "ci", "review", "diagnostic", "full-ci", "merge", "reset", "observe", "finalize", "watchdog"],
    )
    parser.add_argument("--pr-number", type=int)
    parser.add_argument("--expected-head")
    parser.add_argument("--candidate-pr-number", type=int)
    parser.add_argument("--diagnostic-target")
    parser.add_argument("--diagnostic-selector")
    parser.add_argument("--event-path")
    parser.add_argument("--maximum-age-minutes", type=positive_integer, default=120)
    return parser.parse_args()


def require(value: Any, name: str) -> Any:
    if value in {None, ""}:
        raise DeliveryError(f"{name} is required")
    return value


def main() -> int:
    args = parse_args()
    controller = Controller(GitHub())
    try:
        if args.operation == "enrol":
            controller.enrol(require(args.pr_number, "pr-number"), require(args.expected_head, "expected-head"))
        elif args.operation == "ci":
            controller.ci(require(args.pr_number, "pr-number"), require(args.expected_head, "expected-head"))
        elif args.operation == "review":
            controller.review(require(args.pr_number, "pr-number"), require(args.expected_head, "expected-head"))
        elif args.operation == "diagnostic":
            controller.diagnostic(
                require(args.pr_number, "pr-number"),
                require(args.expected_head, "expected-head"),
                require(args.diagnostic_target, "diagnostic-target"),
                require(args.diagnostic_selector, "diagnostic-selector"),
            )
        elif args.operation == "full-ci":
            controller.full_ci(require(args.pr_number, "pr-number"), require(args.expected_head, "expected-head"))
        elif args.operation == "merge":
            controller.merge(
                require(args.pr_number, "pr-number"),
                require(args.expected_head, "expected-head"),
                require(args.candidate_pr_number, "candidate-pr-number"),
            )
        elif args.operation == "reset":
            controller.reset(require(args.pr_number, "pr-number"), require(args.expected_head, "expected-head"))
        elif args.operation == "observe":
            controller.observe(args.event_path)
        elif args.operation == "finalize":
            controller.finalize(require(args.event_path, "event-path"))
        elif args.operation == "watchdog":
            controller.watchdog(args.maximum_age_minutes)
    except DeliveryError as error:
        print(f"::error::{error}", file=sys.stderr)
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as output:
                output.write(f"## Delivery transition rejected\n\n{error}\n")
        return 1
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write(f"## Delivery transition accepted\n\n`{args.operation}` completed.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
