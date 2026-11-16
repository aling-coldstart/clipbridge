# ClipBridge

在 Mac 和 Windows 之间**双向同步剪贴板**，支持**文字、图片和文件**，所有数据都走 SSH。

Two-way clipboard sync (text, images, files) between a Mac and a Windows PC over SSH. No cloud and no extra open ports: the Mac connects to the Windows OpenSSH server, and that's it.

- 在 Mac 上按 ⌘C，到 Windows 上按 Ctrl+V，反过来也一样。
- 文件可以在访达和资源管理器之间直接复制粘贴，单次最大 200 MB。
- 通常 1 秒内到达。
- 连不上 Windows 时几乎不占资源：重试间隔从 2 秒逐步拉长，最长 60 秒一次。
- 密码管理器复制的密码不会被同步。

## 一键安装

先在 **Windows** 上做两件事：
1. 打开“设置 → 系统 → 可选功能”，添加 **OpenSSH 服务器**，然后在“服务”里把 `sshd` 设为自动启动并启动它。
2. 保持要同步的那个账号在桌面上**已登录**。

然后在 **Mac** 的终端里运行（把 `user@windows-ip` 换成你的 Windows 用户名和 IP）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/encorechow/clipbridge/main/install.sh) user@windows-ip
```

如果已经 clone 了这个仓库，也可以直接运行：

```bash
./install.sh user@windows-ip
```

安装脚本会自动完成以下工作：
1. 检查 Mac 上的开发工具。如果缺少 Xcode Command Line Tools，会弹出安装窗口，装好后重新运行一次脚本即可。
2. 配置 SSH 免密登录。如果还没配置，脚本会生成密钥并装到 Windows 上，这一步需要你**输入一次 Windows 密码**，脚本不会保存它。管理员账号会自动使用 `administrators_authorized_keys`。
3. 在本机从源码编译 Mac 端程序，并注册为登录时自启的服务（launchd）。
4. 把接收脚本部署到 Windows 的 `%USERPROFILE%\clipbridge`，并注册一个登录时运行的计划任务。

重复运行安装脚本可以升级程序，或者改连另一台 Windows。

## 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/encorechow/clipbridge/main/uninstall.sh)
```

这会同时清理 Mac 和 Windows 两端。如果当时 Windows 连不上，可以之后在 Windows 上运行：

```
powershell -File %USERPROFILE%\clipbridge\uninstall-windows.ps1
```

## 工作原理

```
 Mac                                         Windows
┌──────────────────────────┐   SSH    ┌──────────────────────────────┐
│ clipbridge（launchd）     │─────────▶│ watch.ps1（SSH 会话中）       │
│  · 每 0.5s 读 changeCount │◀─ CLIP ──│  · 盯着 outbox\latest.txt     │
│  · tar | ssh 推送到 inbox │          ├──────────────────────────────┤
│  · scp 拉取 outbox        │          │ listener.ps1（桌面会话）      │
└──────────────────────────┘          │  · inbox → 写入剪贴板         │
                                      │  · 剪贴板变化 → 导出到 outbox  │
                                      └──────────────────────────────┘
```

- **始终由 Mac 主动连接 Windows**，所以 Mac 不需要打开“远程登录”。
- Mac 与 Windows 之间保持一条 SSH 长连接，Windows 剪贴板一变就通过它通知 Mac；其他传输复用这条连接（ControlMaster）。
- Windows 上必须由**桌面会话**里的进程读写剪贴板，因为 SSH 会话看不到桌面剪贴板，所以接收程序由计划任务在用户登录时启动。
- 同一份剪贴板可能同时包含多种格式，取用顺序是：文件 > 文字 > 图片。例如从 Excel 复制单元格时，传过去的是文字，而不是截图。
- 两端都有防回环机制：收到的内容不会被当成新的复制再传回去。

## 文件位置

| | Mac | Windows |
|---|---|---|
| 程序 | `~/.local/bin/clipbridge` | `%USERPROFILE%\clipbridge\*.ps1` |
| 自启 | `~/Library/LaunchAgents/com.clipbridge.agent.plist` | 计划任务 `ClipBridge` |
| 日志 | `~/Library/Logs/clipbridge.log` | `%USERPROFILE%\clipbridge\listener.log` |
| 临时数据 | `~/.local/share/clipbridge/` | `%USERPROFILE%\clipbridge\inbox`、`outbox` |

两端的日志超过 5 MB 时都会自动清空或轮转。

## 故障排查

- **完全不同步**：先看 Mac 日志里有没有 `connected to ...`。没有的话，在终端运行 `ssh -o BatchMode=yes user@windows-ip echo ok`，确认免密登录是否正常。
- **只有 Windows → Mac 不工作**：在 Windows 上运行 `powershell -File %USERPROFILE%\clipbridge\restart.ps1` 重启接收程序。
- **SSH 密钥带密码短语**：后台服务没法替你输入密码短语。可以把它存进钥匙串（`ssh-add --apple-use-keychain`），或者换用不带密码短语的密钥。
- **Windows 账号是管理员但免密登录失败**：确认公钥在 `C:\ProgramData\ssh\administrators_authorized_keys` 里，并且该文件只有 Administrators 和 SYSTEM 两个账户有权限。
- **粘贴出来的是旧内容**：复制后稍等 1 秒再粘贴。大文件传输需要更长时间，进度可以在日志里看到。

## 安全

- 所有内容都通过你自己的 SSH 连接传输，不经过任何第三方服务。
- 带有 `org.nspasteboard.ConcealedType` 或 `TransientType` 标记的内容（1Password 等密码管理器使用这个标记）不会被同步。
- Windows 端只接受格式正确的剪贴板编号，防止路径穿越。
- 任何能用这个 Windows 账号登录 SSH 的人，都能写入它的剪贴板，所以请保管好你的 SSH 密钥。

## 开发

```bash
xcrun swiftc -O -o clipbridge mac/Sources/*.swift   # 编译 Mac 端
CLIPBRIDGE_HOST=user@windows-ip ./clipbridge        # 前台运行，日志直接输出到终端
```

## License

MIT
