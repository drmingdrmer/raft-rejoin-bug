# Raft Replication Session Isolation Bug - Document Index

## 🎯 Quick Start

**New to this research?** Start here:
1. Clone the repositories: `./clone-repos.sh` (optional, for source code access)
2. Read [README.md](README.md) for an overview
3. Check the [SURVEY-REPORT.md](SURVEY-REPORT.md) for comprehensive findings
4. Read the technical article: [English](raft-rs-replication-bug.md) | [中文](raft-rs-replication-bug-zh.md)

### Clone Repositories

```bash
# Clone all 16 Raft implementations (~500MB)
./clone-repos.sh
```

## 📚 Documents by Purpose

### For Understanding the Bug

**Best starting point**: [raft-rs-replication-bug.md](raft-rs-replication-bug.md)
- Clear explanation of the bug mechanism
- Step-by-step reproduction scenario
- Impact analysis and solutions
- Available in: [English](raft-rs-replication-bug.md) | [中文](raft-rs-replication-bug-zh.md)

**Original research**: [raft-rs-replication-session-issue.md](raft-rs-replication-session-issue.md)
- Chinese document comparing OpenRaft and raft-rs approaches
- Historical context and discovery process

### For Implementation Analysis

**Comprehensive survey**: [SURVEY-REPORT.md](SURVEY-REPORT.md)
- Analysis of 16 Raft implementations
- 10 vulnerable, 5 protected, 1 N/A
- Detailed code references and protection mechanisms
- Language/ecosystem vulnerability analysis

**Individual analyses**:
- [hashicorp-raft-analysis.md](hashicorp-raft-analysis.md) - Most popular Go implementation (VULNERABLE)
- [sofa-jraft-analysis.md](sofa-jraft-analysis.md) - Java implementation with version counter (PROTECTED)

### For Operators and Developers

**README**: [README.md](README.md)
- Quick reference table of all implementations
- Protection mechanism examples
- Recommendations for operators

**Implementation list**: [repo-list.md](repo-list.md)
- Complete list of Raft implementations surveyed
- Star counts and language information

## 🔍 Quick Reference

### Vulnerability Status

| Category | Count | Percentage |
|----------|-------|------------|
| VULNERABLE | 10/15 | 67% |
| PROTECTED | 5/15 | 33% |
| N/A (no membership changes) | 1/16 | - |

### Most Popular Implementations

| Implementation | Stars | Status | Document |
|----------------|-------|--------|----------|
| hashicorp/raft | 8,826 | ✗ VULNERABLE | [Analysis](hashicorp-raft-analysis.md) |
| dragonboat | 5,262 | ✗ VULNERABLE | [Survey](SURVEY-REPORT.md#dragonboat-5262-stars---vulnerable) |
| braft | 4,174 | ✓ PROTECTED | [Survey](SURVEY-REPORT.md#braft-4174-stars---protected-) |
| sofa-jraft | 3,762 | ✓ PROTECTED | [Analysis](sofa-jraft-analysis.md) |
| raft-rs (TiKV) | 3,224 | ✗ VULNERABLE | [Article](raft-rs-replication-bug.md) |

### Protection Mechanisms

| Mechanism | Implementations | Complexity | Protocol Changes |
|-----------|----------------|------------|------------------|
| CallId matching | braft, Apache Ratis | Medium | No |
| Version counter | sofa-jraft | Low | No |
| RPC client ID | NuRaft | Low | No |
| Membership check | canonical-raft, Ra | Medium | No |

## 📖 Reading Paths

### Path 1: Quick Overview (15 minutes)
1. [README.md](README.md) - Overview and results table
2. [raft-rs-replication-bug.md](raft-rs-replication-bug.md) - Bug explanation
3. [SURVEY-REPORT.md](SURVEY-REPORT.md) - Executive summary section

### Path 2: Deep Technical (1-2 hours)
1. [raft-rs-replication-bug.md](raft-rs-replication-bug.md) - Understand the bug
2. [SURVEY-REPORT.md](SURVEY-REPORT.md) - All implementation analyses
3. [hashicorp-raft-analysis.md](hashicorp-raft-analysis.md) - Example vulnerable impl
4. [sofa-jraft-analysis.md](sofa-jraft-analysis.md) - Example protected impl

### Path 3: Implementation Review (30 minutes)
1. [SURVEY-REPORT.md](SURVEY-REPORT.md) - Protection mechanisms section
2. Find your implementation in the survey
3. Check the code references for your language

### Path 4: Research Context (Chinese readers)
1. [raft-rs-replication-session-issue.md](raft-rs-replication-session-issue.md) - Original research
2. [raft-rs-replication-bug-zh.md](raft-rs-replication-bug-zh.md) - Technical article
3. [SURVEY-REPORT.md](SURVEY-REPORT.md) - Survey results

## 🔗 External Resources

### Source Code Repositories
All implementations are cloned in subdirectories:
- `hashicorp-raft/`, `dragonboat/`, `raft-rs/`, `sofa-jraft/`
- `braft/`, `apache-ratis/`, `nuraft/`, `raft-java/`
- `logcabin/`, `canonical-raft/`, `etcd-raft/`, `redisraft/`
- `eliben-raft/`, `rabbitmq-ra/`, `pysyncobj/`, `willemt-raft/`

### Related OpenRaft Documentation
- OpenRaft's replication session ID design (external)
- Membership change protocol (external)

## 📝 Document Metadata

| Document | Language | Length | Last Updated | Purpose |
|----------|----------|--------|--------------|---------|
| README.md | EN | ~150 lines | 2025-11-12 | Overview |
| SURVEY-REPORT.md | EN | ~537 lines | 2025-11-12 | Comprehensive survey |
| raft-rs-replication-bug.md | EN | ~250 lines | 2025-11-12 | Technical article |
| raft-rs-replication-bug-zh.md | ZH | ~250 lines | 2025-11-12 | Technical article (Chinese) |
| hashicorp-raft-analysis.md | EN | ~250 lines | 2025-11-12 | Individual analysis |
| sofa-jraft-analysis.md | EN | ~150 lines | 2025-11-12 | Individual analysis |
| raft-rs-replication-session-issue.md | ZH | ~360 lines | 2025-11-07 | Original research |

## 🎓 Key Takeaways

1. **67% of implementations are vulnerable** - This is a widespread issue
2. **Term-only validation is insufficient** - Need explicit session tracking
3. **Multiple solutions exist** - No protocol changes required
4. **Data safety preserved** - Bug causes operational issues, not data loss
5. **Popular implementations affected** - Including hashicorp/raft, etcd-io/raft, raft-rs

## 💡 For Maintainers

If you maintain a Raft implementation:
1. Check if you're in the [survey](SURVEY-REPORT.md)
2. Review the [protection mechanisms](SURVEY-REPORT.md#protection-mechanisms-found)
3. Consider implementing a [version counter](SURVEY-REPORT.md#solution-1-version-counter-recommended-for-existing-implementations)

## 🤝 Contributing

To add analysis of additional implementations:
1. Clone the repository
2. Follow the [methodology](SURVEY-REPORT.md#survey-methodology)
3. Add findings to SURVEY-REPORT.md
4. Update this index

---

**Survey Date**: November 2025
**Implementations Analyzed**: 16
**Total Stars**: 60,000+
**Finding**: 67% vulnerable to replication session isolation bug
