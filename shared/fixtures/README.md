# 跨端样例

- [`ios-1.0-export.json`](ios-1.0-export.json)：iOS 迁移代码导出的一份 1.0 数据（`ImportBundle`，假数据）。由 iOS 的 `LegacyMigrationTests` 生成，API 的 `importer.test.ts` 按契约解析并导入它，两端格式对不上时测试先失败。改了导出格式后重新生成：

```bash
cd ios && TEST_RUNNER_VITA_EXPORT_FIXTURE=$PWD/../shared/fixtures/ios-1.0-export.json xcodebuild test -project Vita.xcodeproj -scheme Vita -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:VitaTests/LegacyMigrationTests
```
