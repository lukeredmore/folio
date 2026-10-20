# Code Organization, Anti-Slop & Testing Rules

1. **File Size Limits**:
   - Keep all Rust source files (`core/**/src/**/*.rs`, `zed/**/src/**/*.rs`) under **250 lines** (hard ceiling: **350 lines**).
   - If a file exceeds 300 lines, split it into focused submodules before adding new code.
2. **Dedicated `tst/` Directories Only**:
   - **Never** write `#[cfg(test)]` or `#[test]` inside `src/`.
   - All Rust tests must reside in `<crate>/tst/*.rs` and shared cross-platform behavior fixtures in `tst/specs/*.json`.
3. **Shared Behavior-Asserting Specs**:
   - Editor behaviors (active-line syntax reveal vs. inactive-line folding, newline list continuation, inline delimiter toggling, heading level toggling, paragraph reflow, and math layout) must be defined in `tst/specs/*.json` and asserted across both Rust (`folio_engine` + `folio_zed_mod`) and Swift (`FolioTests`).
4. **Verification Gate**:
   - Always run `./scripts/audit_slop.sh` before finishing any Rust task.
