// CodeRabbit configuration for lwpt: lwpt's own review policy on top of
// the central frostney/coderabbit configuration.
import { defineConfig } from "@coderabbitai/config"

export default defineConfig({
  // Fall through to the central configuration (and then the CodeRabbit
  // web-UI settings) for every value not set here. It shares
  // `reviews.auto_review.base_branches: [".*"]`, which keeps native
  // upper-stack PRs that target the branch immediately below them eligible.
  inheritance: true,
  reviews: {
    auto_review: {
      // Review every non-draft PR automatically as an advisory reviewer
      // (ADR-0046); the required review evidence is the independent review in
      // ORCHESTRATION.md. Set explicitly so a web-UI default cannot silently
      // turn automatic review off, and no label gates the first pass.
      enabled: true,
      drafts: false,
      // Do not spend a review on every push. After the first automatic pass,
      // a later head is reviewed only on request (`@coderabbitai review`).
      auto_incremental_review: false,
    },
  },
})
