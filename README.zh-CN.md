# Git Commit Signer（GCS）

**面向 Windows 的 GitHub 仓库扫描工具，后续版本将支持安全地为未签名提交补签。**

[English](README.md)

> **当前版本：V0.1，只读仓库发现。**
>
> 本版本从已登录的 GitHub 账号获取可访问仓库清单，并导出 JSON/CSV 报告。当前还不会检查提交签名状态、重写提交、修改 Git 引用或向 GitHub 推送内容。

## 项目目标

- 扫描 GitHub 账号可访问的仓库，而不局限于本机已经克隆的仓库。
- 区分个人拥有的仓库、Fork、协作/组织仓库和归档仓库。
- 后续补签时，不重复处理已经 Verified 的提交。
- 只对身份明确、权限合适的未签名提交进行补签。
- 后续重写提交时保留 Merge Commit 的父提交顺序和合并拓扑。
- 操作前创建本地恢复备份；每个远程分支都必须由用户明确确认后才能更新。
- 复用用户现有 SSH 签名密钥；绝不上传或传输私钥。

## V0.1 环境要求

- Windows 10/11
- Windows PowerShell 5.1 或 PowerShell 7+
- Git for Windows
- GitHub CLI（`gh`）
- 已登录 GitHub CLI，且账号具有所需仓库的读取权限

不需要 Python、Node.js、付费 API 或额外服务。

## 配置

1. 安装 Git for Windows 和 GitHub CLI（如果尚未安装）。
2. 登录 GitHub CLI：

   ```powershell
   gh auth login
   gh auth status
   ```

3. 下载或克隆本仓库。
4. 运行环境检查：

   ```powershell
   .\GCS.ps1 doctor
   ```

## 发布到你的 GitHub 账号

在已经配置 SSH Commit Signing 的 Windows 电脑上操作：

1. 将压缩包解压到一个新文件夹。
2. 打开文件夹，双击 `PUBLISH.cmd`。
3. 确认显示的 GitHub 账号是 `wjc2821296948`，然后输入 `Y`。

脚本会先检查 GitHub CLI 登录账号、`gpg.format=ssh`、`commit.gpgsign=true` 和已配置的公钥文件。检查通过后，它会创建一个带 SSH 签名的初始提交，再通过 `gh repo create` 创建公开仓库 `wjc2821296948/git-commit-signer` 并推送 `main`。如果目录已有 `.git`、账号不匹配或签名配置不正确，脚本会停止。脚本不会读取或上传 SSH 私钥。

如果创建仓库或推送失败，已经创建的本地签名提交会保留在当前文件夹中，可以排除故障后再推送。

## 扫描全部可访问仓库

在 PowerShell 中进入项目目录，然后执行：

```powershell
.\GCS.ps1 scan
```

要求登录账号必须是指定用户：

```powershell
.\GCS.ps1 scan -ExpectedLogin wjc2821296948
```

自定义报告目录：

```powershell
.\GCS.ps1 scan -OutputDirectory "$env:USERPROFILE\Documents\GCS-Reports"
```

脚本使用 GitHub 已认证的 `/user/repos` 接口，并启用分页及 `owner`、`collaborator`、`organization_member` 关联范围。脚本不会输出或保存 GitHub Token。

## 报告文件

默认输出到：

```text
%LOCALAPPDATA%\GitCommitSigner\reports\
```

- `repositories.json`：完整仓库清单。
- `scan-report.csv`：适合电子表格查看的仓库清单。
- `summary.json`：扫描统计和元数据。

只有当仓库属于当前登录账号、未归档且 API 返回可推送权限时，才会标记为“未来可进入改写流程”。这只是权限元数据判断；V0.1 不会执行任何改写。

## 命令

| 命令 | 作用 |
|---|---|
| `scan` | 只读扫描仓库并导出报告 |
| `doctor` | 检查 PowerShell、Git、GitHub CLI、OpenSSH、登录状态和 Git 签名配置 |
| `help` | 显示帮助 |

## V0.1 安全保证

- 对 GitHub 只执行读取操作。
- 不修改提交、Tag、分支或任何 Git 引用。
- 不执行普通推送或强制推送。
- 不读取、复制或上传 SSH 私钥。
- 报告只包含仓库元数据，不包含 GitHub 凭据。

## 开发路线图

- [x] V0.1：账号认证检查、分页获取仓库、所有权/可见性分类、JSON/CSV 报告。
- [ ] V0.2：分支清单和 GitHub 提交签名状态分类（`verified`、`unsigned`、`unknown_key`、`invalid` 等）。
- [ ] V0.3：提交图分析和改写计划，包括下游子提交。
- [ ] V0.4：重建已签名提交，保留 Merge Commit 的父提交顺序和拓扑。
- [ ] V0.5：本地 bundle 备份、恢复元数据和 Dry Run 审查。
- [ ] V0.6：逐分支人工确认推送，并检查精确的远程 SHA（lease）。
- [ ] V0.7：推送后通过 GitHub API 验证，并生成审计报告。

## 后续版本需要处理的特殊情况

重写提交会改变 SHA；父提交 SHA 发生变化的后代提交也必须重新生成并签名，即使它们原本已经 Verified。Merge Commit 必须保留完整且有序的父提交列表和 Tree。不能把其他人的提交悄悄重建成当前用户的提交。受保护分支、开放 PR、Annotated Tag、特殊提交头和远程更新也都需要单独的安全处理。V0.1 尚不处理这些情况。

## 许可证

MIT，详见 [LICENSE](LICENSE)。
