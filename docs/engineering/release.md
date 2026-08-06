# Release safety

Release is a separate, explicitly authorized workflow. A feature, fix, refactor, test run,
or PR does not imply permission to tag, merge, deploy, upload TestFlight, migrate a
production database, or clean branches/worktrees.

Before any release:

1. Resolve the exact commit, artifact, environment, account, and destination.
2. Confirm user authorization for the named action.
3. Run release gates on that exact candidate.
4. Review configuration, privacy, migration, rollback, and monitoring.
5. Perform only the authorized action and verify deployed state.

See `.agents/workflows/release.md`. Never place credentials or private release evidence in
the repository.
