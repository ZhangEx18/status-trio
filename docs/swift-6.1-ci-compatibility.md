# Swift 6.1 CI 兼容性规则

本文记录 Status Trio 在 GitHub Actions 上发布时遇到的工具链兼容问题，以及后续开发和发布必须遵守的规则。

## 结论

最近一次 1.0.1 打包失败，和最早的几次发布失败不是同一个具体错误，但属于同一类问题：**本机使用较新的 Xcode 27 / Swift 6.4 可以编译，而 GitHub Actions 使用 Xcode 16.4 / Swift 6.1.2，两者的语法支持、诊断和代码生成行为不同。**

因此，不能只用本机 `swift test` 证明代码可以发布。CI 工具链必须作为最低兼容标准。

## 失败记录

| Run | 失败阶段 | 根因 | 修复方式 |
| --- | --- | --- | --- |
| `34753548674` | `Run tests` | `isolated deinit` 在 Swift 6.1.2 需要实验开关，默认不可用 | 移除 `isolated deinit`，改为普通 `deinit` 和显式清理 |
| `34753630833` | `Run tests` | 尝试启用 `IsolatedDeinit`，生产编译器不允许 | 不依赖该实验特性，直接改写生命周期清理 |
| `34753843803` | `Run tests` | 测试中的 `weak let` 在 Swift 6.1.2 非法 | 改为 `weak var` |
| `34753912541`、`34754021368`、`34754087160` | `Run tests` | `Bundle.module` 在 CI 中的 `lproj` 资源布局/大小写与本地不同 | 使用路径查找并同时尝试标准名和小写名 |
| `34758026894` | `Run tests` | Swift 6.1.2 IRGen 在处理 `Binding.set: localization.setPreference` 方法引用时崩溃 | 改写为显式闭包，避免触发 thunk 代码生成 |
| `34758129632` | 全部通过 | 1.0.1 / build 2 发布成功 | 保留上述兼容性修复 |

## 当前这次是否和编码有关

有关系，但不是业务逻辑错误。

`set: localization.setPreference` 在 Swift 6.4 中合法，在语义上也没有问题；问题出在 Swift 6.1.2 的 IRGen 对“带 actor isolation 的方法引用转换为函数值”的代码生成存在编译器缺陷。显式闭包没有改变行为，只是避免了触发该编译路径：

```swift
// 不要这样写：会在 Swift 6.1.2 触发 IRGen 崩溃
set: localization.setPreference

// 这样写：行为相同，但不生成触发 crash 的转换
set: { newPreference in
    localization.setPreference(newPreference)
}
```

所以结论是：**代码写法是当前崩溃的触发条件，但根因是 CI 与本地 Swift 工具链不一致。** 后续开发需要同时处理这两件事。

## 强制开发规则

### 1. 以 CI 工具链为准

发布环境的基准是：

- `macos-15`
- Xcode `16.4`
- Swift `6.1.2`

本机 Xcode 27 / Swift 6.4 的通过结果只能作为辅助验证，不能替代 CI。

### 2. 修改 Swift 代码后的最低验证

```bash
swift test
swift build -c release
```

涉及以下内容时，必须额外触发一次 `publish=false` 的发布预检：

- actor isolation、`@MainActor`、`Sendable`
- `deinit` 和生命周期清理
- SwiftUI `Binding`、方法引用和闭包
- 泛型、可选值和复杂类型转换
- `Bundle.module`、本地化资源或 SwiftPM 资源布局

```bash
gh workflow run release.yml \
  --repo lingyired/status-trio \
  --ref <branch> \
  -f version=<next-version> \
  -f build=<next-build> \
  -f publish=false
```

等待并确认该 run 成功后再合并或发布。

### 3. 禁止使用仅在新工具链可用的写法

- 不使用 `isolated deinit`
- 不启用 `IsolatedDeinit` 或其他实验性编译器特性来绕过发布问题
- 不把 actor-isolated 方法直接当作闭包/函数值传递
- 不使用 `weak let`，weak 绑定必须是 `var`
- 不假设本地和 CI 的 `Bundle.module` 资源目录大小写或布局一致
- 不引入低于 CI 编译器版本无法解析的 Swift 6.2+ 语法

### 4. 遇到编译器崩溃时的处理方式

以下症状表示应该缩小或改写触发表达式，而不是重试或改变发布参数：

- `error: compile command failed due to signal 6`
- `IRGenRequest`
- `SmallVector unable to grow`
- `fatal error encountered during compilation`

处理顺序：

1. 从堆栈中的 `While evaluating request IRGenRequest` 找到源文件。
2. 检查该文件最近新增的方法引用、闭包转换、actor isolation 和复杂泛型表达式。
3. 用显式闭包或拆分局部变量改写最小表达式。
4. 重新运行本地测试和 CI 预检。
5. 只有 CI 预检成功后，才允许触发 `publish=true`。

## 发布检查清单

- [ ] 版本号已明确，构建号大于线上 appcast 的最大构建号。
- [ ] `swift test` 通过。
- [ ] `swift build -c release` 通过。
- [ ] 涉及兼容性敏感代码时，`publish=false` 的 GitHub Actions 预检通过。
- [ ] `publish=true` 的发布 workflow 成功。
- [ ] GitHub Release 有 DMG 和 `.sha256` 文件。
- [ ] 线上 `appcast.xml` 的版本、构建号、长度和 EdDSA 签名已更新。
- [ ] 未配置 Developer ID / notarization 时，明确说明 Ad-hoc 签名和首次安装限制。
