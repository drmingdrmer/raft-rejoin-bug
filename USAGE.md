# How to Use This Survey

## For First-Time Users

### 1. Clone the Repositories (Optional)

If you want to examine the source code:

```bash
./clone-repos.sh
```

This downloads all 16 Raft implementations (~500MB, shallow clone). Already-cloned repos are skipped.

### 2. Start Reading

Choose your reading path:

**Quick Overview (15 min)**:
```bash
cat README.md
cat raft-rs-replication-bug.md  # or raft-rs-replication-bug-zh.md for Chinese
```

**Comprehensive Analysis (1-2 hours)**:
```bash
cat SURVEY-REPORT.md
```

**Navigate All Documents**:
```bash
cat INDEX.md
```

## For Researchers

### Verify the Analysis

1. Clone a specific implementation:
   ```bash
   cd hashicorp-raft  # or any other implementation
   ```

2. Follow the file paths in the analysis:
   ```bash
   # From hashicorp-raft-analysis.md
   cat raft.go | sed -n '582,593p'  # View specific lines
   ```

3. Search for specific code patterns:
   ```bash
   grep -r "maybe_update" raft-rs/src/
   ```

### Add New Implementations

1. Clone the new implementation
2. Follow the methodology in SURVEY-REPORT.md (Section: Survey Methodology)
3. Add your findings to SURVEY-REPORT.md
4. Update the summary statistics
5. Update clone-repos.sh if needed

## For Implementation Maintainers

### Check If Your Implementation Is Vulnerable

1. Find your implementation in SURVEY-REPORT.md
2. Look for the status: ✗ VULNERABLE or ✓ PROTECTED
3. Review the code references provided

### If Vulnerable, How to Fix

See the "Solutions and Recommendations" section in SURVEY-REPORT.md:

**Quick Fix (Recommended)**: Add a version counter
```rust
// Example in Rust
struct Replicator {
    version: u64,
    // ... other fields
}

impl Replicator {
    fn reset(&mut self) {
        self.version += 1;
        // ... reset logic
    }
}
```

**Alternative Solutions**:
- CallId correlation (like braft, Apache Ratis)
- RPC client ID validation (like NuRaft)
- Membership checking (like canonical-raft, RabbitMQ Ra)

## For Operators

### Understanding the Risk

1. Read "Impact Assessment" in SURVEY-REPORT.md
2. Check if you're using a vulnerable implementation
3. Review "Trigger Conditions" to understand when the bug occurs

### Mitigation

- **Data safety**: The bug does NOT cause data loss
- **Operational impact**: Can cause infinite retry loops and resource exhaustion
- **Workaround**: Restart affected nodes if you encounter the issue
- **Prevention**: Use learner → voter promotions instead of remove → re-add

## File Structure

```
rejoin-bug-survey/
├── clone-repos.sh           # Script to clone all repos
├── .gitignore               # Excludes cloned repos from git
├── README.md                # Quick overview
├── INDEX.md                 # Document navigation
├── SURVEY-REPORT.md         # Comprehensive analysis
├── USAGE.md                 # This file
├── raft-rs-replication-bug.md           # Blog article (EN)
├── raft-rs-replication-bug-zh.md        # Blog article (ZH)
├── raft-rs-replication-session-issue.md # Original research
├── hashicorp-raft-analysis.md           # Individual analysis
├── sofa-jraft-analysis.md               # Individual analysis
└── [16 implementation directories]      # Cloned source code
```

## Common Tasks

### Find All Vulnerable Implementations
```bash
grep "VULNERABLE" SURVEY-REPORT.md | grep "stars"
```

### Check a Specific Language
```bash
grep "| Go |" SURVEY-REPORT.md
```

### See Protection Mechanisms
```bash
sed -n '/## Protection Mechanisms Found/,/## Vulnerable Implementations/p' SURVEY-REPORT.md
```

### Count Lines of Analysis
```bash
wc -l *.md
```

## Getting Help

- Read the "Survey Methodology" section for analysis approach
- Check INDEX.md for document navigation
- Review the "Key Findings" section for main takeaways

## Contributing

To contribute additional analysis:

1. Follow the existing format in SURVEY-REPORT.md
2. Include file paths and line numbers
3. Provide code snippets showing the vulnerability or protection
4. Update summary statistics
5. Add to the comparison tables

## License

This survey is provided for educational and research purposes. Each Raft implementation has its own license (see individual repositories).
