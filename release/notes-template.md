## zju-ssh（组内试用 prerelease）

> Pre-release：供组员试用与验证，通过后维护者转正为 Latest。完整说明见 [README](https://github.com/orangeofcarl0-sys/zju-ssh#readme)。

### 下载

- `zju-ssh-vX.Y.Z-windows.zip` —— Windows：GUI + CLI + 工作站连接日志 monitor
- `zju-ssh-vX.Y.Z-macos.zip` —— macOS / Linux：CLI（zju-ssh.sh）
- `SHA256SUMS.txt` —— 完整性校验（Windows: `certutil -hashfile <文件> SHA256`；macOS/Linux: `shasum -a 256 -c SHA256SUMS.txt`）

### 上手四步

1. 解压到**纯英文路径**；
2. Windows 双击 `Start-GUI.bat`（或命令行 `zju-ssh.ps1 init`）；macOS/Linux 运行 `./zju-ssh.sh init`；
3. 按提示填写工作站地址与 SSH 账户，点「生成/复制我的公钥」发给工作站管理员；
4. 开通后，任何网络下 `ssh zju` —— 校内直连、校外自动走隧道，配置永不需要改。

### 反馈

开 issue 并附：网络环境（校内/校外）、GUI「自检」一键复制的诊断输出、时间点。
