# Hermes + open-free-router + Telegram Bot 一键部署

## GitHub 一键安装

在全新的 Debian 12 服务器上直接执行：

```bash
curl -fsSL https://raw.githubusercontent.com/wuuduf/hermes-router-telegram-bootstrap/main/install.sh | sudo bash
```

脚本会从 `/dev/tty` 隐藏读取 Telegram Token 和 API Key，因此支持以上管道安装方式。

适用于全新的 Debian 12 服务器。脚本会：

1. 创建独立非 root 账号 `hermesbot`；
2. 安装 Hermes Agent，并跳过 Nous Portal 登录；
3. 安装 open-free-router，配置已有的上游 API Key；
4. 把 Hermes 指向 `http://127.0.0.1:8337/v1`；
5. 配置 Telegram Bot 与用户白名单；
6. 创建并启动 `open-free-router.service`、`hermes-gateway.service`；
7. 验证 Telegram Token、服务状态和一次模型对话。

## 用户需要准备什么

### 必须

- 一台能访问 GitHub、PyPI、Telegram API 和模型上游的 Debian 12 服务器；
- root 或 `sudo` 权限；
- Telegram Bot Token：在 Telegram 联系 [`@BotFather`](https://t.me/BotFather)，执行 `/newbot`；
- 你的 Telegram **数字用户 ID**：可向 `@userinfobot` 发消息获取；
- 建议至少 2 GB 内存、10 GB 可用磁盘。

### 模型 API Key

不是绝对必填：`zen/*-free` 当前可不带 Key 使用，但免费源和额度会变化。建议至少准备一个 OpenRouter Key。

- `OPENROUTER_API_KEY`：[OpenRouter Keys](https://openrouter.ai/settings/keys)，推荐；
- `NVIDIA_API_KEY`：[NVIDIA Build](https://build.nvidia.com/)，可选；
- `GOOGLE_API_KEY`：[Google AI Studio](https://aistudio.google.com/apikey)，可选；
- Nous、Poolside、SenseNova Key：可选。

只填写自己实际拥有的 Key，其他留空。

## 推荐运行方式：交互式

先上传脚本，然后运行：

```bash
chmod +x bootstrap-hermes-router-telegram.sh
sudo ./bootstrap-hermes-router-telegram.sh
```

Token/API Key 使用隐藏输入，不会回显。

## 无人值守运行

```bash
sudo install -m 600 hermes-router.env.example /root/hermes-router.env
sudo nano /root/hermes-router.env
sudo ./bootstrap-hermes-router-telegram.sh --env-file /root/hermes-router.env
sudo rm -f /root/hermes-router.env
```

脚本不会 `source`/`eval` 配置文件，只读取白名单中的 `KEY=VALUE`。

## 安装后测试

在 Telegram 中：

```text
/start
你好，只回复连接成功
/model
```

切换 open-free-router 上的模型时使用 Hermes 的命名自定义 Provider 三段式语法：

```text
/model custom:open-free-router:zen/deepseek-v4-flash-free
```

服务器诊断：

```bash
systemctl status open-free-router hermes-gateway --no-pager
journalctl -u open-free-router -u hermes-gateway -f
curl -fsS http://127.0.0.1:8337/v1/models | jq -r '.data[].id'
```

open-free-router 的 API 和 UI 都绑定在 `127.0.0.1`。不要把 `8337`、`9057` 直接暴露到公网；如需查看 UI，使用 SSH 隧道：

```bash
ssh -L 9057:127.0.0.1:9057 user@server
```

## 安全提示

- Bot Token 相当于机器人密码；泄露后立即在 `@BotFather` 撤销并生成新的 Token。
- `~/.config/open-free-router/registry.yaml` 保存明文上游 Key，脚本将权限设为 `0600`。
- Hermes Gateway 以 `hermesbot` 而非 root 运行，降低 Telegram Agent 使用终端工具时的主机风险。
- `TELEGRAM_ALLOWED_USERS` 是强制白名单，脚本不会开启全员访问。
