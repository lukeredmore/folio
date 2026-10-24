# Code Organization, Anti-Slop & Testing Rules

1. **File Size Limits (Rust & Swift)**:
   - Keep all Rust files (`core/**/*.rs`, `zed/**/*.rs`) and Swift files (`Sources/**/*.swift`, `Tests/**/*.swift`) under **250 lines** (hard ceiling: **350 lines**).
   - If a file exceeds 300 lines, split it into focused submodules or domain-specific Swift extension/test files before adding new code.
2. **Dedicated Test Files & `tst/` Directories Only**:
   - **Never** write `#[cfg(test)]` or `#[test]` inside Rust `src/`. All Rust tests must reside in `<crate>/tst/*.rs`.
   - **Never** reintroduce a monolithic `Tests/FolioTests/FolioTests.swift` file. Keep Swift tests split into focused domain-specific `*Tests.swift` files under `Tests/FolioTests/`.
3. **Shared Behavior-Asserting Specs**:
   - Editor behaviors (active-line syntax reveal vs. inactive-line folding, newline list continuation, inline delimiter toggling, heading level toggling, paragraph reflow, and math layout) must be defined in `tst/specs/*.json` and asserted across both Rust (`folio_engine` + `folio_zed_extension`) and Swift (`FolioTests`).
4. **Verification Gate**:
   - Always run `./scripts/audit_slop.sh` before finishing any Rust or Swift task.
