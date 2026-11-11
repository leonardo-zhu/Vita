# Agent 评测脚本

对真实模型（经 Conduit）跑固定场景，比较不同参数或 prompt 的效果。结果与结论记在 [docs/agent-tuning-log.md](../../docs/agent-tuning-log.md)。

## 测试用 key

所有测试都用 Conduit 里的专用 key **vita-chat-test**，和正式流量分开统计。它存在开发机的 macOS 钥匙串里（账户 `vita`，服务 `vita-chat-test`），不进仓库：

```bash
CONDUIT_KEY=$(security find-generic-password -a vita -s vita-chat-test -w) node tools/agent-eval/continuation.mjs 20
```

默认地址是 `https://conduit.r4s.leonardo-zhu.me`，可用 `CONDUIT_BASE_URL` 覆盖。

## 脚本

- `run.mjs`：**固定用例**，每次改 prompt、换模型、调参数前后各跑一遍。用例都来自出过问题的真实对话，只看模型的第一次回应（服务端的兜底不参与）：
  - 接续：牛奶确认后记拿铁（接续轮只说不做）
  - 标签缺净含量：小笼汤包（照片里净含量看不清，应先问；读出了必须是 288 g）
  - 名称简短：摩可纳咖啡（不能照抄标签全称）
  - 归组：拿铁（咖啡和牛奶都要填 `groupName` “拿铁”）
  - 归组：单独的几样不归组（水煮蛋 + 牛奶，都不应填 `groupName`）
  - 历史里有假出卡：重发牛奶（历史里有“已生成确认卡”的假回复，这次要真的出卡，带 950 ml 与钠 60 mg）

  ```bash
  sh tools/agent-eval/fetch-fixtures.sh   # 首次：从 R4S 拷真实标签照片到 fixtures/（不进 git）
  CONDUIT_KEY=$(security find-generic-password -a vita -s vita-chat-test -w) \
    node tools/agent-eval/run.mjs --runs 10 --model vita-chat,ark-agent-plan/doubao-seed-2.1-lite
  ```

  参数：`--runs` 每个用例几次（默认 5），`--model` 逗号分隔的模型（默认 `vita-chat`），`--case` 只跑名称含这段文字的用例，`--effort` 推理强度（默认 low）。新的问题出现后，把那次对话补成一个用例。

- `continuation.mjs [次数]`：确认后接续这一轮（“牛奶已存，接着记拿铁”）。每种参数跑 N 次（默认 20，5 个并发），统计是否真的调了 `proposeRecordChange`、用量与食品 ID 是否都对、耗时与推理 token。系统 prompt 与工具描述读 `shared/config/DefaultConfig.json`，所以改 prompt 后直接重跑就能对比。

判断“有没有调工具”一定要解析响应里 `output` 的 `function_call`：响应会原样带回请求里的 `tools` 和 `instructions`，搜整段文字会误判（见调优记录 §8.1）。
