# ReferenceFood resources

此目录保存公共营养参考库的构建产物。2.0 起它有两个用处：随 App 打包，供营养库页面浏览；手动拷到 R4S 的 `/opt/vita-api/reference`，供服务端的 Agent 查询（本地起 API 时用 `VITA_API_REFERENCE_FILE` 指向这里）。

- 上游优先级：已获授权的中国食物成分数据优先；USDA FoodData Central（CC0 1.0/public domain）补充中国库未覆盖的通用/国际食材。
- 选择：USDA 内部按 Foundation Foods 优先、SR Legacy 补充；不含 Branded Foods、FNDDS 或复合菜。
- 产物：`reference-foods.json`，在实际构建并通过审阅前不创建占位数据文件。
- 中国数据在授权条款未核验前不得放入本目录。详细规则、schema、署名与校验见 [公共营养参考库规范](../../docs/reference-food-library.md)。

不要手动将来源不明的 JSON、品牌食品数据库或用户食品记录放入该目录。
