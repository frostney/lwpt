// CodeRabbit configuration for lwpt: the shared frostney base
// (frostney/coderabbit/base.ts) plus lwpt's own review policy.
import { defineConfig, includeRemote, mergeConfig } from "@coderabbitai/config"

export default defineConfig(
  mergeConfig(
    // Shared: reviews.auto_review.base_branches [".*"], so pull requests
    // based on any branch are eligible — including native upper-stack PRs
    // that target the codex/ branch immediately below them, which the
    // previous `codex/.*` entry covered.
    includeRemote({ path: "base.ts" }),
    {
      reviews: {
        auto_review: {
          // Managed PRs opt into the scarce review pass only after their
          // current head has passed exact-head admission. Ordinary PRs
          // retain the manual label trigger.
          enabled: false,
          // A label is still required, so allowing drafts lets CI-clean
          // ordinary PRs request review without a ready transition that
          // would duplicate their CI.
          drafts: true,
          labels: ["review:ready"],
          // Do not spend a review on every push. After the first
          // label-gated pass, later CI-clean heads request one incremental
          // pass with the review command.
          auto_incremental_review: false,
        },
      },
    },
  ),
)
