# Raft Replication Session Isolation Bug - Document Index

## 🎯 Quick Start

1. Read [README.md](README.md) for an overview
2. Read the technical article: [English](raft-rs-replication-bug.md) | [中文](raft-rs-replication-bug-zh.md)
3. Check [SURVEY-REPORT.md](SURVEY-REPORT.md) for comprehensive findings
4. Clone source code: `./clone-repos.sh` (optional)

## 📚 Main Documents

- [README.md](README.md) - Overview and results summary
- [SURVEY-REPORT.md](SURVEY-REPORT.md) - Comprehensive analysis of 16 implementations
- [raft-rs-replication-bug.md](raft-rs-replication-bug.md) - Technical article (English)
- [raft-rs-replication-bug-zh.md](raft-rs-replication-bug-zh.md) - Technical article (Chinese)
- [hashicorp-raft-analysis.md](hashicorp-raft-analysis.md) - Detailed analysis (VULNERABLE)
- [sofa-jraft-analysis.md](sofa-jraft-analysis.md) - Detailed analysis (PROTECTED)
- [raft-rs-replication-session-issue.md](raft-rs-replication-session-issue.md) - Original research (Chinese)

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

**Quick Overview** (15 min): README.md → raft-rs-replication-bug.md

**Comprehensive** (1-2 hours): raft-rs-replication-bug.md → SURVEY-REPORT.md → individual analyses

**Maintainers**: Find your implementation in SURVEY-REPORT.md → check protection mechanisms

**Chinese Readers**: raft-rs-replication-bug-zh.md → SURVEY-REPORT.md

## 🎓 Key Takeaways

1. **67% of implementations are vulnerable** - This is a widespread issue
2. **Term-only validation is insufficient** - Need explicit session tracking
3. **Multiple solutions exist** - No protocol changes required
4. **Data safety preserved** - Bug causes operational issues, not data loss
5. **Popular implementations affected** - Including hashicorp/raft, etcd-io/raft, raft-rs

## 💡 For Maintainers

Check your implementation status in [SURVEY-REPORT.md](SURVEY-REPORT.md). If vulnerable, consider adding a version counter or other protection mechanism (see Solutions section).

## 🤝 Contributing

To add more implementations: follow the [methodology](SURVEY-REPORT.md#survey-methodology), update SURVEY-REPORT.md and clone-repos.sh.

---

**Survey**: 16 implementations, 60K+ stars, 67% vulnerable (November 2025)
