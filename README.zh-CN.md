# Git Commit Signer（GCS）

**面向 Windows 的 GitHub 仓库与提交签名只读审计工具。**

[English](README.md)

> **当前稳定版本：[v0.2.1](https://github.com/wjc2821296948/git-commit-signer/releases/tag/v0.2.1)。**
>
> V0.2.1 提供只读的提交签名审计，支持单仓库筛选、逐页进度、单次请求超时、有限重试，以及按 Ctrl+C 中断并保存已完成的部分报告。程序读取 GitHub 返回的提交验证结果并导出报告。它**不会**自动签署提交、重写提交历史、修改 Git 引用、修改仓库设置或向 GitHub 推送内容。

## 功能

- 获取当前 GitHub 登录账号可访问的仓库，包括个人仓库、协作仓库和组织成员仓库。
- 获取每个仓库的全部普通分支。
- 分页读取每个分支可达的全部提交历史。
- 在同一个仓库内按 Commit SHA 去重，并记录该提交出现在哪些分支。
- 根据 GitHub 的提交验证结果分类：
  - `Verified`：GitHub 返回 `verified=true`。
  - `Unsigned`：GitHub 返回 `reason=unsigned`。
  - `UnknownKey`：GitHub 返回 `reason=unknown_key`。
  - `Invalid`：GitHub 返回 `reason=invalid`。
  - `UnverifiedEmail`：GitHub 返回 `reason=unverified_email`。
  - `Unverified`：其他未验证原因。
  - `Unavailable`：API 响应未提供验证信息。
- 导出分支、提交、错误和统计报告，支持 CSV/JSON。
- 检测到 GitHub API 限流时提前停止，并将报告标记为不完整。
- 支持使用 `-Repository owner/name` 只审计指定仓库。
- 实时显示仓库、分支和 API 分页进度。
- 为每次 `gh.exe` 请求设置超时，并对临时网络/服务器故障进行有限重试。
- 使用 Windows 原生控制台控制处理器接收 Ctrl+C 信号，由 PowerShell 主线程停止当前 `gh.exe` 请求并保存已完成的仓库/分支结果，明确标记报告不完整。

## 环境要求

- Windows 10/11
- Windows PowerShell 5.1 或 PowerShell 7+
- Git for Windows
- GitHub CLI（`gh`）
- 已登录 GitHub CLI，且对需要审计的仓库具有读取权限

不需要 Python、Node.js、付费 API 或额外服务。

## 配置

1. 安装 Git for Windows 和 GitHub CLI（如果尚未安装）。
2. 登录 GitHub CLI：

   ```powershell
   gh auth login
   gh auth status
   ```

3. 克隆或下载本仓库。
4. 如果当前 PowerShell 窗口禁止运行本地脚本，只对当前窗口临时放行：

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   ```

## 命令

### 仓库清单扫描（V0.1）

列出当前 GitHub 账号可访问的仓库：

```powershell
.\GCS.ps1 scan -ExpectedLogin YOUR_GITHUB_LOGIN
```

### 提交签名审计（V0.2.1 stable）

扫描所有可访问仓库、它们的分支，以及各分支可达的提交：

```powershell
.\GCS.ps1 audit -ExpectedLogin YOUR_GITHUB_LOGIN
```

该命令只执行 GitHub 读取请求，不会克隆仓库，也不会读取本机 Git 历史。

只审计一个仓库（建议先用这个方式测试）：

```powershell
.\GCS.ps1 audit -ExpectedLogin YOUR_GITHUB_LOGIN -Repository YOUR_GITHUB_LOGIN/REPOSITORY
```

调整请求超时和重试次数：

```powershell
.\GCS.ps1 audit -ExpectedLogin YOUR_GITHUB_LOGIN -RequestTimeoutSeconds 45 -MaxRetries 2
```

`-Repository` 仍会先读取账号可访问的仓库清单以确认权限，但只会读取所选仓库的分支和提交历史。

自定义报告目录：

```powershell
.\GCS.ps1 audit -ExpectedLogin YOUR_GITHUB_LOGIN -OutputDirectory "$env:USERPROFILE\Documents\GCS-Reports"
```

### 环境检查

```powershell
.\GCS.ps1 doctor
```

## 报告文件

默认保存到：

```text
%LOCALAPPDATA%\GitCommitSigner\reports\
```

V0.1 仓库清单文件：

- `repositories.json`：仓库清单。
- `scan-report.csv`：适合电子表格查看的仓库清单。
- `summary.json`：V0.1 扫描统计。

V0.2 签名审计文件：

- `branch-audit.csv`：仓库、分支、分支头 SHA、保护状态、提交数量和扫描状态。
- `commit-signature-audit.csv`：每个仓库内每条唯一提交一行，包含验证状态/原因、作者/提交者信息、所属分支和提交链接。
- `commit-signature-audit.json`：同一份提交审计数据的 JSON 格式。
- `audit-errors.csv`：仓库/分支读取失败及扫描不完整原因。
- `audit-summary.json`：统计数量和 `Complete` 完整性标记。

只有在没有仓库或分支扫描错误且扫描未被中断时，报告才会标记为完整。程序逐页请求 API，并显示当前页进度。每次 `gh.exe` 请求默认超时为 45 秒；临时网络/服务器故障最多重试 2 次，限流和权限错误不会重试。

按 Ctrl+C 时，GCS 会停止当前 `gh.exe` 请求，保存此前已完成的仓库和分支结果，并在 `audit-errors.csv` 记录中断原因；`audit-summary.json` 中 `Cancelled=true`、`Complete=false`。检测到限流时也会停止继续请求。**不完整报告不能作为全账号扫描结果使用。**

相同 Commit SHA 只在同一个仓库内去重。如果同一提交同时出现在 Fork 或另一个仓库中，会分别记录，因为 GitHub 的验证结果是在对应仓库上下文中读取的。

## 只读与隐私保证

- `scan` 和 `audit` 只使用 GitHub 读取接口。
- 不修改提交、Tag、分支、Git 引用或仓库设置。
- 不执行普通推送或强制推送。
- 不读取、复制或上传 SSH 私钥。
- GitHub CLI 管理登录凭据；GCS 不会把 Token 写入报告或打印出来。
- 报告包含仓库和提交元数据。分享报告前请检查内容，特别是审计私有仓库时。

## 开发路线图

- [x] V0.1：账号认证检查、分页获取仓库、所有权/可见性分类、JSON/CSV 报告。
- [x] V0.2：分支清单、分页提交历史、GitHub 验证状态分类、仓库内 SHA 去重和审计报告。
- [x] V0.2.1 stable：单仓库筛选、逐页进度、单次请求超时、临时故障有限重试和可中断的部分报告；已在 Windows PowerShell 5.1 完成多页审计与 Ctrl+C 中断测试，Windows PowerShell 5.1 和 PowerShell 7 的解析及启动冒烟检查均通过 CI。
- [ ] V0.3：提交图分析和改写计划，包括下游子提交。
- [ ] V0.4：重建已签名提交，保留 Merge Commit 的父提交顺序和拓扑。
- [ ] V0.5：本地 bundle 备份、恢复元数据和 Dry Run 审查。
- [ ] V0.6：逐分支人工确认推送，并检查精确的远程 SHA（lease）。
- [ ] V0.7：推送后通过 GitHub API 验证，并生成审计报告。

## 当前限制

- 当前审计功能只覆盖普通分支引用，不扫描 Tag、PR 引用或其他 Git 引用。
- 程序读取每个分支可达的完整提交历史。同一仓库内的共享提交会去重，但每个分支仍会分别请求历史；分支较多、历史较长的仓库可能耗时较长并消耗 GitHub API 配额。建议先用 `-Repository owner/name` 单独测试一个仓库。
- API 权限错误、仓库被删除或触发限流，都可能导致报告不完整。必须检查错误报告。
- 验证状态来自 GitHub API，不等同于使用本地 SSH allowed-signers 文件重新进行密码学验证。
- GCS v0.2.1 只做审计，不执行提交签名或历史重写。

## 许可证

MIT，详见 [LICENSE](LICENSE)。
