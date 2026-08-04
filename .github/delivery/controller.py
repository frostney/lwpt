#!/usr/bin/env python3
"""Trusted GitHub adapter for LWPT's managed-delivery state machine."""

from __future__ import annotations

import argparse
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
MANAGED_RUN_RE = re.compile(r"^delivery-pr/(\d+)/([0-9a-f]{40})/([0-9a-f]{64})/(\d+)$")
FULL_CI_RUN_RE = re.compile(r"^full-ci/(\d+)/([0-9a-f]{40})/([0-9a-f]{64})/(\d+)$")


class GitHub:
    def __init__(self) -> None:
        self.repository = os.environ["GITHUB_REPOSITORY"]
        self.owner, self.name = self.repository.split("/", 1)
        self.token = os.environ["GITHUB_TOKEN"]
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
                nodes { author { login } state commit { oid } submittedAt }
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
        snapshot, digest = self.snapshot(number)
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

    def full_ci(self, number: int, expected_head: str) -> None:
        pull = self.current_pull(number, expected_head)
        self.require_same_repository(pull)
        snapshot, digest = self.snapshot(number)
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
            f"Candidate topology: `{digest}`\n\n```json\n{summary}\n```",
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

    def validate_reviews(self, number: int, head: str) -> None:
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
            if permission in {"admin", "maintain", "write"}:
                maintainers.add(login)
        errors = review_evidence_errors(
            head, self.automations, checks, reviews, threads, maintainers
        )
        if errors:
            raise DeliveryError("review evidence is not terminal: " + "; ".join(errors))

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

    def observe(self, event_path: str | None) -> None:
        numbers: set[int] = set()
        if event_path:
            event = json.loads(Path(event_path).read_text(encoding="utf-8"))
            pull = event.get("pull_request")
            if pull:
                number = pull["number"]
                head = pull["head"]["sha"]
                if pull.get("state") == "open":
                    numbers.add(number)
                else:
                    self.fail_pending_head(
                        number,
                        head,
                        "Pull request closed",
                        f"Pull request #{number} closed before the proof completed.",
                    )
                before = event.get("before")
                if before and before != head:
                    self.fail_superseded_head(number, before)
        for pull in self.github.open_pulls():
            if MANAGED_LABEL in label_names(pull):
                numbers.add(pull["number"])
        for number in sorted(numbers):
            self.observe_one(number)

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
        check = self.require_owned_check(
            check_id,
            FULL_CI_CHECK,
            self.full_ci_external_id(number, head, requested_digest),
        )
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
        if conclusion != "success":
            for entry in snapshot.get("entries", []) if "snapshot" in locals() else []:
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "operation",
        choices=["enrol", "ci", "review", "full-ci", "merge", "reset", "observe", "finalize", "watchdog"],
    )
    parser.add_argument("--pr-number", type=int)
    parser.add_argument("--expected-head")
    parser.add_argument("--candidate-pr-number", type=int)
    parser.add_argument("--event-path")
    parser.add_argument("--maximum-age-minutes", type=int, default=120)
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
