# Agent 评测脚本

对真实模型（经 Conduit）跑固定场景，比较不同参数或 prompt 的效果。结果与结论记在 [docs/agent-tuning-log.md](../../docs/agent-tuning-log.md)。

## 测试用 key

所有测试都用 Conduit 里的专用 key **vita-chat-test**，和正式流量分开统计。它存在开发机的 macOS 钥匙串里（账户 `vita`，服务 `vita-chat-test`），不进仓库：

```bash
CONDUIT_KEY=$(security find-generic-password -a vita -s vita-chat-test -w) node tools/agent-eval/continuation.mjs 20
```

默认地址是 `https://conduit.r4s.leonardo-zhu.me`，可用 `CONDUIT_BASE_URL` 覆盖。

## 脚本

- `continuation.mjs [次数]`：确认后接续这一轮（“牛奶已存，接着记拿铁”）。每种参数跑 N 次（默认 20，5 个并发），统计是否真的调了 `proposeRecordChange`、用量与食品 ID 是否都对、耗时与推理 token。系统 prompt 与工具描述读 `shared/config/DefaultConfig.json`，所以改 prompt 后直接重跑就能对比。

判断“有没有调工具”一定要解析响应里 `output` 的 `function_call`：响应会原样带回请求里的 `tools` 和 `instructions`，搜整段文字会误判（见调优记录 §8.1）。
