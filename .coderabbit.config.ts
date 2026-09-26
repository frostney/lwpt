// CodeRabbit configuration for lwpt, in two parts merged with mergeConfig:
//
// 1. Review scope: the Agent Skills installed by the skills CLI and listed in
//    skills-lock.json are not reviewed; skills the lock does not list are
//    project-authored and stay reviewed. The function is shared from
//    frostney/coderabbit (lib/skills.ts); it needs this repository's lock,
//    which only a file here can read — through skills-lock.yaml, a symlink to
//    skills-lock.json (see that repository's README, "Shared functions").
// 2. lwpt's own review policy on top of the central frostney/coderabbit
//    configuration.
import { defineConfig, includeRemote, mergeConfig } from "@coderabbitai/config"
import lock from "./skills-lock.yaml"

// includeRemote passes the shared module's exports through at runtime. The
// lock is read through the skills-lock.yaml symlink because CodeRabbit's
// config sandbox cannot import .json, and JSON is valid YAML.
const { excludeVendoredSkills } = includeRemote({
  path: "lib/skills.ts",
}) as unknown as {
  excludeVendoredSkills(lock: unknown): ReturnType<typeof includeRemote>
}

export default defineConfig(
  mergeConfig(excludeVendoredSkills(lock), {
    // Fall through to the central configuration (and then the CodeRabbit
    // web-UI settings) for every value not set here. It shares
    // `reviews.auto_review.base_branches: [".*"]`, which keeps native
    // upper-stack PRs that target the codex/ branch immediately below them
    // eligible.
    inheritance: true,
    reviews: {
      auto_review: {
        // Managed PRs opt into the scarce review pass only after their
        // current head has passed exact-head admission. Ordinary PRs retain
        // the manual label trigger.
        enabled: false,
        // A label is still required, so allowing drafts lets CI-clean
        // ordinary PRs request review without a ready transition that would
        // duplicate their CI.
        drafts: true,
        labels: ["review:ready"],
        // Do not spend a review on every push. After the first label-gated
        // pass, later CI-clean heads request one incremental pass with the
        // review command.
        auto_incremental_review: false,
      },
    },
  }),
)
