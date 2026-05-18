import assert from "node:assert/strict";
import test from "node:test";

test("usage budget evaluation reports not connected without a positive monthly limit", async () => {
  const { evaluateUsageBudget } = await import("../src/runtime/usage-budget-policy");

  const evaluation = evaluateUsageBudget({ usedCost: 1.25 });

  assert.equal(evaluation.status, "not_connected");
  assert.equal(evaluation.usedCost, 1.25);
  assert.equal(evaluation.limitCost, undefined);
});

test("usage budget evaluation warns near the limit and blocks over the limit", async () => {
  const { evaluateUsageBudget } = await import("../src/runtime/usage-budget-policy");

  const warn = evaluateUsageBudget({ usedCost: 8.5, monthlyLimitCost: 10, warnRatio: 0.8 });
  const over = evaluateUsageBudget({ usedCost: 11, monthlyLimitCost: 10, warnRatio: 0.8 });

  assert.equal(warn.status, "warn");
  assert.equal(warn.usagePercent, 85);
  assert.equal(warn.remainingCost, 1.5);
  assert.equal(warn.warnAtCost, 8);
  assert.equal(over.status, "over");
  assert.equal(over.remainingCost, 0);
});

test("usage budget policy update accepts form-style strings and persists runtime policy", async () => {
  const { buildUsageBudgetPolicyUpdate, loadUsageBudgetPolicy, writeUsageBudgetPolicy } = await import("../src/runtime/usage-budget-policy");

  const update = buildUsageBudgetPolicyUpdate({
    currency: "usd",
    monthlyLimitCost: "12.5",
    warnRatio: "0.75",
  });

  assert.deepEqual(update.issues, []);
  assert.deepEqual(update.policy, {
    currency: "USD",
    monthlyLimitCost: 12.5,
    warnRatio: 0.75,
  });

  await writeUsageBudgetPolicy(update.policy);
  const loaded = await loadUsageBudgetPolicy();

  assert.equal(loaded.loadedFromFile, true);
  assert.equal(loaded.policy.monthlyLimitCost, 12.5);
  assert.equal(loaded.policy.warnRatio, 0.75);
});
