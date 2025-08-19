# Runbook: Parameter Threshold Changed Significantly

Summary

- This alert fires when the active optimizer parameter minConfidence changes by a large delta, indicating a policy change that impacts risk acceptance.

Signal

- Prometheus alert: ParamThresholdChanged
- Expression: abs(delta(optimizer_active_min_confidence[15m])) > 0.05
- Severity: info (adjust as needed)

Triage

- Check Grafana dashboard panel "Active Min Confidence" to confirm current value.
- Review recent opt.results and approvals in Notification Manager (notify.events) to validate that an approval occurred.
- Confirm the change was intentional (e.g., in change log or ops channel).

Mitigation

- If the change was accidental, revert by re-approving a prior parameter set or setting the value manually:
  - CLI: `redis-cli HSET optimizer:active_params minConfidence 0.60`
  - Or via Parameter Optimizer API: approve a job with the prior value.
- Communicate the change in the ops channel and update change log.

Verification

- Ensure Risk Manager decisions match the expected minConfidence.
- Verify the Prometheus gauge optimizer_active_min_confidence has stabilized.

Related Docs

- Parameter Optimizer: docs/system_spec_and_setup.md (Section 9)
- Integrations Guide: docs/integrations.md
- Admin cheatsheet: README.md
