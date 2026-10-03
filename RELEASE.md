# 发布流程（RELEASE）

本仓库对外发布受**三道门**约束，全部通过才能发布。规则正则以
[release/release-gate.ps1](release/release-gate.ps1) 为唯一事实源，本文只描述、不复制，
避免文档漂移与隐私门自命中。

## 三道门

| 门 | 载体 | 检查内容 | 性质 |
|---|---|---|---|
| **质量门** | `release-gate.ps1` §1–2 | 文件齐套、单层 UTF-8 BOM、PowerShell 语法、sh 必须 LF、版本号四处一致、`-ReleaseTag` 与版本对应、工作树干净 | 阻断 |
| **隐私门** | `release-gate.ps1` §3 | 全部跟踪文件逐行扫描敏感信息（见下），零容忍；外加发布者人工清单 | 阻断 |
| **监测门** | `.github/workflows/` + §4 | push/PR/tag 时 GitHub Actions 自动复跑整门；本地 §4 跑 `smoke-test.ps1` 冒烟回归 | 阻断 |

本地过门：

```powershell
powershell -NoProfile -File release\release-gate.ps1 -ReleaseTag v1.3.0
```

## 隐私门扫什么

- **网络定位**：工作站固定地址、一切私网地址（10.x / 192.168.x / 172.16–31.x）；
  文档示例一律使用 RFC 5737 保留段（如 192.0.2.10）。
- **个人身份**：电子邮箱、SSH 公钥体、私钥材料。
- **凭据**：密码字面量、疑似 DPAPI 密文的长 base64、`config.json` / 任何密钥文件入库。
- **项目内部信息**：内部账号名、机器/工作组名、个人 Windows 路径、内部凭据文件引用。

人工清单（脚本末尾会再次提醒，需发布者逐条心证）：
真实姓名/学号/工号/房间号/群号/截图未混入；公开历史确为 orphan 单提交；prerelease
转正前完成两平台解压验证与校内外实测。

## 版本号出现位置（发版前统一改，§2 会核对）

1. `zju-common.psm1` → `$script:ToolVersion`
2. `zju-ssh.sh` → `TOOL_VERSION`
3. `README.md` 首行 `> vX.Y.Z`
4. `zju-ssh-gui.ps1` XAML `verText` 占位文本（运行时以 `Get-ToolVersion` 为准）

## 发布步骤

```text
1. 改版本号（上面 4 处）
2. 本地过门  powershell -NoProfile -File release\release-gate.ps1 -ReleaseTag vX.Y.Z
3. 私有主分支提交  git add -A && git commit -m "release: vX.Y.Z"
4. 重建公开历史并打 tag（见下节）
5. 推送  git push origin main vX.Y.Z
      → release.yml：复跑三道门 → package.ps1 打包 → 自动创建 prerelease
6. 到 Releases 页核对资产：两个平台 zip + SHA256SUMS.txt
7. 组内验证通过后转正  gh release edit vX.Y.Z --prerelease=false --latest
```

打本地发布包（与 CI 同源，用于发布前自检）：

```powershell
powershell -NoProfile -File release\package.ps1     # 产物在 dist/（已 gitignore）
```

## 公开历史策略（隐私门的硬性前提）

- 私有开发历史可能含个人化内容，**绝不推送到公开远端**；
  本地备份分支 `archive/private-history` 仅存本地。
- 公开仓库历史 = 发布树的全新单提交（orphan），首次发布时由维护者重建：

```bash
git branch archive/private-history main      # 备份私有历史（仅本地）
git checkout --orphan public-main
git add -A && git commit -m "zju-ssh vX.Y.Z 初始公开版本"
git tag -d v1.0.0 v1.3.0 2>/dev/null; git tag vX.Y.Z
git branch -D main && git branch -m public-main main
git remote add origin https://github.com/<owner>/zju-ssh.git
git push -u origin main && git push origin vX.Y.Z
```

- 因此任何情况下不得对公开远端执行 `git push --mirror`、`git push --all --tags`。

## 组内分发

组员不 clone 仓库：到 [Releases](https://github.com/orangeofcarl0-sys/zju-ssh/releases)
下载对应平台 zip → `SHA256SUMS.txt` 校验 → 解压 → 按 [README](README.md)「快速开始」。
反馈直接开 issue（附 `doctor` 一键复制的诊断信息）。

## prerelease 转正条件

- [ ] GitHub Actions 全绿（ci + release 两条工作流）
- [ ] 两平台包解压可用，脚本能跑
- [ ] 至少一名组员校内 + 一名校外实测 `ssh zju` 通过
- [ ] 隐私门人工清单过一遍
