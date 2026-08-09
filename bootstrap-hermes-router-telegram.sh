#!/usr/bin/env bash

# Debian 12 一键部署：
#   Hermes Agent + open-free-router + Telegram Bot + systemd
#
# 默认使用独立的非 root 账号 hermesbot 运行服务。
# 脚本可重复执行；改写配置前会保留时间戳备份。

set -Eeuo pipefail
umask 077

SCRIPT_VERSION="1.0.4"
ENV_FILE=""
TMP_DIR=""

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
on_error() {
  local rc=$?
  local failed_line="${BASH_LINENO[0]:-$LINENO}"
  printf '\033[1;31m[x]\033[0m 安装在第 %s 行失败（退出码 %s）。\n' "$failed_line" "$rc" >&2
  exit "$rc"
}
trap cleanup EXIT
trap on_error ERR

usage() {
  cat <<EOF
用法：
  sudo bash $0 [--env-file /root/hermes-router.env]

选项：
  --env-file FILE   从受限的 KEY=VALUE 文件读取配置（不会执行文件内容）
  -h, --help        显示帮助
  --version         显示版本

不传 --env-file 时，脚本会交互式隐藏输入 Token/API Key。
EOF
}

while (($#)); do
  case "$1" in
    --env-file)
      (($# >= 2)) || die "--env-file 后缺少文件路径"
      ENV_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --version)
      printf '%s\n' "$SCRIPT_VERSION"
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请用 root 运行：sudo bash $0"

# 只解析允许的 dotenv 键，不 source/eval，避免以 root 执行配置文件内容。
load_env_file() {
  local file="$1" line key value
  [[ -f "$file" ]] || die "配置文件不存在：$file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == export[[:space:]]* ]]; then
      line="${line#export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi
    [[ "$line" == *=* ]] || die "配置文件存在无效行（应为 KEY=VALUE）"
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ ${#value} -ge 2 ]]; then
      if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]] || \
         [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi

    case "$key" in
      SERVICE_USER|DEFAULT_MODEL|INSTALL_BROWSER|HERMES_BRANCH|OPEN_FREE_ROUTER_REPO|\
      TELEGRAM_BOT_TOKEN|TELEGRAM_ALLOWED_USERS|\
      OPENROUTER_API_KEY|NVIDIA_API_KEY|GOOGLE_API_KEY|\
      NOUS_API_KEY|POOLSIDE_API_KEY|SENSENOVA_API_KEY)
        printf -v "$key" '%s' "$value"
        export "$key"
        ;;
      *)
        warn "忽略不支持的配置键：$key"
        ;;
    esac
  done < "$file"
}

if [[ -n "$ENV_FILE" ]]; then
  load_env_file "$ENV_FILE"
fi

SERVICE_USER="${SERVICE_USER:-hermesbot}"
DEFAULT_MODEL="${DEFAULT_MODEL:-zen/deepseek-v4-flash-free}"
INSTALL_BROWSER="${INSTALL_BROWSER:-0}"
HERMES_BRANCH="${HERMES_BRANCH:-main}"
OPEN_FREE_ROUTER_REPO="${OPEN_FREE_ROUTER_REPO:-https://github.com/NoelJudeNoel/open-free-router.git}"

OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
NVIDIA_API_KEY="${NVIDIA_API_KEY:-}"
GOOGLE_API_KEY="${GOOGLE_API_KEY:-}"
NOUS_API_KEY="${NOUS_API_KEY:-}"
POOLSIDE_API_KEY="${POOLSIDE_API_KEY:-}"
SENSENOVA_API_KEY="${SENSENOVA_API_KEY:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"

# 支持 `curl ... | sudo bash`：脚本内容来自 stdin 时，交互输入改从
# /dev/tty 读取，避免把后续脚本文本误当成 Token。
PROMPT_INPUT=""
if (: </dev/tty) 2>/dev/null; then
  PROMPT_INPUT="/dev/tty"
elif [[ -t 0 ]]; then
  PROMPT_INPUT="/dev/stdin"
fi

[[ "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "SERVICE_USER 格式不合法"
[[ "$SERVICE_USER" != root ]] || die "为降低风险，本脚本不允许 Hermes 以 root 运行"
[[ "$HERMES_BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "HERMES_BRANCH 格式不合法"
[[ "$INSTALL_BROWSER" =~ ^(0|1|true|false|yes|no)$ ]] || die "INSTALL_BROWSER 只能是 0/1/true/false/yes/no"
[[ "$DEFAULT_MODEL" != *[$'\r\n\t ']* ]] || die "DEFAULT_MODEL 不能包含空白字符"

for secret_name in OPENROUTER_API_KEY NVIDIA_API_KEY GOOGLE_API_KEY NOUS_API_KEY POOLSIDE_API_KEY SENSENOVA_API_KEY TELEGRAM_BOT_TOKEN; do
  [[ "${!secret_name}" != *$'\n'* && "${!secret_name}" != *$'\r'* ]] || die "$secret_name 不能包含换行"
done

prompt_secret_optional() {
  local var_name="$1" prompt_text="$2" value="${!1:-}"
  if [[ -z "$value" && -n "$PROMPT_INPUT" ]]; then
    read -r -s -p "$prompt_text" value < "$PROMPT_INPUT"
    printf '\n'
    printf -v "$var_name" '%s' "$value"
    export "$var_name"
  fi
}

prompt_secret_required() {
  local var_name="$1" prompt_text="$2" value="${!1:-}"
  if [[ -z "$value" ]]; then
    [[ -n "$PROMPT_INPUT" ]] || die "缺少 $var_name；非交互运行时请通过 --env-file 提供"
    read -r -s -p "$prompt_text" value < "$PROMPT_INPUT"
    printf '\n'
    [[ -n "$value" ]] || die "$var_name 不能为空"
    printf -v "$var_name" '%s' "$value"
    export "$var_name"
  fi
}

prompt_value_required() {
  local var_name="$1" prompt_text="$2" value="${!1:-}"
  if [[ -z "$value" ]]; then
    [[ -n "$PROMPT_INPUT" ]] || die "缺少 $var_name；非交互运行时请通过 --env-file 提供"
    read -r -p "$prompt_text" value < "$PROMPT_INPUT"
    [[ -n "$value" ]] || die "$var_name 不能为空"
    printf -v "$var_name" '%s' "$value"
    export "$var_name"
  fi
}

prompt_secret_required TELEGRAM_BOT_TOKEN "Telegram Bot Token（来自 @BotFather）："
prompt_value_required TELEGRAM_ALLOWED_USERS "允许使用 Bot 的 Telegram 数字用户 ID（多个用逗号）："

if [[ -z "$ENV_FILE" && -n "$PROMPT_INPUT" ]]; then
  printf '\n以下上游 Key 均可选；没有就直接回车。至少准备 OpenRouter Key 会更稳定。\n'
  prompt_secret_optional OPENROUTER_API_KEY "OpenRouter API Key（可选）："
  prompt_secret_optional NVIDIA_API_KEY "NVIDIA NIM API Key（可选）："
  prompt_secret_optional GOOGLE_API_KEY "Google AI Studio API Key（可选）："
fi

TELEGRAM_ALLOWED_USERS="$(printf '%s' "$TELEGRAM_ALLOWED_USERS" | tr -d '[:space:]')"
[[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || die "TELEGRAM_BOT_TOKEN 格式不正确"
[[ "$TELEGRAM_ALLOWED_USERS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "TELEGRAM_ALLOWED_USERS 必须是逗号分隔的数字 ID"

if [[ -z "$OPENROUTER_API_KEY" && -z "$NVIDIA_API_KEY" && -z "$GOOGLE_API_KEY" && \
      -z "$NOUS_API_KEY" && -z "$POOLSIDE_API_KEY" && -z "$SENSENOVA_API_KEY" ]]; then
  warn "未配置任何上游 API Key，将仅依赖不需要 Key 的免费源；可用性和限额可能波动。"
fi

[[ -r /etc/os-release ]] || die "无法识别操作系统"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  debian)
    [[ "${VERSION_ID:-}" == 12* ]] || warn "脚本主要针对 Debian 12；当前是 Debian ${VERSION_ID:-unknown}"
    ;;
  ubuntu)
    warn "当前是 Ubuntu；通常可用，但本脚本主要针对 Debian 12"
    ;;
  *)
    die "仅支持 Debian/Ubuntu（当前：${ID:-unknown}）"
    ;;
esac

command -v systemctl >/dev/null 2>&1 || die "未找到 systemd/systemctl"
command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get"

TMP_DIR="$(mktemp -d /tmp/hermes-router-bootstrap.XXXXXX)"
chmod 700 "$TMP_DIR"

log "安装系统依赖"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get update -qq
apt-get install -y -qq \
  ca-certificates curl git xz-utils jq ripgrep util-linux \
  python3 python3-venv python3-dev build-essential pkg-config libffi-dev

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  log "创建独立服务账号：$SERVICE_USER"
  useradd --create-home --shell /bin/bash "$SERVICE_USER"
  passwd -l "$SERVICE_USER" >/dev/null 2>&1 || true
fi

SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
[[ -n "$SERVICE_HOME" && "$SERVICE_HOME" == /* ]] || die "无法确定 $SERVICE_USER 的 home"

HERMES_HOME="$SERVICE_HOME/.hermes"
HERMES_INSTALL_DIR="$HERMES_HOME/hermes-agent"
ROUTER_HOME="$SERVICE_HOME/.local/open-free-router"
ROUTER_CONFIG_DIR="$SERVICE_HOME/.config/open-free-router"
ROUTER_CONFIG="$ROUTER_CONFIG_DIR/config.yaml"
ROUTER_REGISTRY="$ROUTER_CONFIG_DIR/registry.yaml"
WORKSPACE_DIR="$SERVICE_HOME/workspace"

# 先显式创建并归属顶层用户目录。`install -d /home/u/.local/bin` 在部分
# coreutils 版本上只会给最终的 bin 应用 -o/-g，中间的 .local 仍可能是
# root:root，进而导致 uv 无法创建 ~/.local/share/uv/python。
install -d -m 700 -o "$SERVICE_USER" -g "$SERVICE_GROUP" \
  "$SERVICE_HOME/.local" "$SERVICE_HOME/.config" "$SERVICE_HOME/.cache"
install -d -m 700 -o "$SERVICE_USER" -g "$SERVICE_GROUP" \
  "$HERMES_HOME" "$ROUTER_CONFIG_DIR" "$WORKSPACE_DIR" \
  "$SERVICE_HOME/.local/bin" "$SERVICE_HOME/.local/share"

# 支持从中断/旧版本安装中恢复：root 调用过 Hermes CLI 后，现有 venv、
# logs 或 __pycache__ 可能归 root 所有，导致无特权安装器连旧 venv 都删不掉。
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$HERMES_HOME"

USER_ENV=(
  "HOME=$SERVICE_HOME"
  "USER=$SERVICE_USER"
  "LOGNAME=$SERVICE_USER"
  "HERMES_HOME=$HERMES_HOME"
  "PATH=$SERVICE_HOME/.local/bin:$HERMES_HOME/bin:/usr/local/bin:/usr/bin:/bin"
  "LANG=C.UTF-8"
  "LC_ALL=C.UTF-8"
)
for proxy_var in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
  if [[ -n "${!proxy_var:-}" ]]; then
    USER_ENV+=("$proxy_var=${!proxy_var}")
  fi
done

as_service_user() {
  runuser -u "$SERVICE_USER" -- env -i "${USER_ENV[@]}" \
    bash -c 'cd "$HOME" && exec "$@"' _ "$@"
}

as_service_user_timeout() {
  local duration="$1"
  shift
  timeout "$duration" runuser -u "$SERVICE_USER" -- env -i "${USER_ENV[@]}" \
    bash -c 'cd "$HOME" && exec "$@"' _ "$@"
}

HERMES_INSTALLER="$TMP_DIR/hermes-install.sh"
ROUTER_INSTALLER="$TMP_DIR/open-free-router-install.sh"

log "下载官方安装器"
curl --proto '=https' --tlsv1.2 -fsSL \
  "https://raw.githubusercontent.com/NousResearch/hermes-agent/$HERMES_BRANCH/scripts/install.sh" \
  -o "$HERMES_INSTALLER"
curl --proto '=https' --tlsv1.2 -fsSL \
  "https://raw.githubusercontent.com/NoelJudeNoel/open-free-router/main/scripts/install.sh" \
  -o "$ROUTER_INSTALLER"
# 安装器要由无特权账号读取。临时目录只有 traverse 权限，目录内后续的
# Token/Key 文件仍保持 root:root 0600。
chmod 711 "$TMP_DIR"
chown "$SERVICE_USER:$SERVICE_GROUP" "$HERMES_INSTALLER" "$ROUTER_INSTALLER"
chmod 500 "$HERMES_INSTALLER" "$ROUTER_INSTALLER"

log "安装/更新 Hermes Agent（跳过 Nous Portal 登录向导）"
HERMES_INSTALL_ARGS=(--skip-setup --branch "$HERMES_BRANCH")
case "${INSTALL_BROWSER,,}" in
  1|true|yes) ;;
  *) HERMES_INSTALL_ARGS+=(--skip-browser) ;;
esac
as_service_user bash "$HERMES_INSTALLER" "${HERMES_INSTALL_ARGS[@]}" </dev/null

HERMES_BIN="$SERVICE_HOME/.local/bin/hermes"
if [[ ! -x "$HERMES_BIN" ]]; then
  HERMES_BIN="$HERMES_INSTALL_DIR/venv/bin/hermes"
fi
[[ -x "$HERMES_BIN" ]] || die "Hermes 安装后未找到可执行文件"

log "安装 Hermes Telegram/messaging 依赖"
if [[ -x "$HERMES_HOME/bin/uv" ]]; then
  as_service_user "$HERMES_HOME/bin/uv" pip install \
    --python "$HERMES_INSTALL_DIR/venv/bin/python" \
    -e "$HERMES_INSTALL_DIR[messaging]"
else
  as_service_user "$HERMES_INSTALL_DIR/venv/bin/python" -m ensurepip --upgrade
  as_service_user "$HERMES_INSTALL_DIR/venv/bin/python" -m pip install -e "$HERMES_INSTALL_DIR[messaging]"
fi

log "安装/更新 open-free-router"
as_service_user env \
  "OPEN_FREE_ROUTER_HOME=$ROUTER_HOME" \
  "OPEN_FREE_ROUTER_CONFIG_HOME=$ROUTER_CONFIG_DIR" \
  bash "$ROUTER_INSTALLER" "$OPEN_FREE_ROUTER_REPO" </dev/null

ROUTER_BIN="$ROUTER_HOME/.venv/bin/open-free-router"
ROUTER_PYTHON="$ROUTER_HOME/.venv/bin/python"
[[ -x "$ROUTER_BIN" && -x "$ROUTER_PYTHON" ]] || die "open-free-router 安装不完整"
ln -sfn "$ROUTER_BIN" /usr/local/bin/open-free-router

if [[ ! -f "$ROUTER_REGISTRY" ]]; then
  DEFAULT_REGISTRY="$ROUTER_HOME/src/open_free_router/registry.default.yaml"
  [[ -f "$DEFAULT_REGISTRY" ]] || die "未找到 open-free-router 默认 registry 模板"
  install -m 600 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$DEFAULT_REGISTRY" "$ROUTER_REGISTRY"
fi

[[ -f "$ROUTER_CONFIG" ]] || die "未找到 open-free-router config.yaml"
chown "$SERVICE_USER:$SERVICE_GROUP" "$ROUTER_CONFIG" "$ROUTER_REGISTRY"
chmod 600 "$ROUTER_CONFIG" "$ROUTER_REGISTRY"

PROVIDER_SECRETS="$TMP_DIR/provider-keys.env"
{
  printf 'OPENROUTER_API_KEY=%s\n' "$OPENROUTER_API_KEY"
  printf 'NVIDIA_API_KEY=%s\n' "$NVIDIA_API_KEY"
  printf 'GOOGLE_API_KEY=%s\n' "$GOOGLE_API_KEY"
  printf 'NOUS_API_KEY=%s\n' "$NOUS_API_KEY"
  printf 'POOLSIDE_API_KEY=%s\n' "$POOLSIDE_API_KEY"
  printf 'SENSENOVA_API_KEY=%s\n' "$SENSENOVA_API_KEY"
} > "$PROVIDER_SECRETS"
chmod 600 "$PROVIDER_SECRETS"

log "写入 open-free-router 上游配置"
"$ROUTER_PYTHON" - "$ROUTER_REGISTRY" "$PROVIDER_SECRETS" <<'PY'
from pathlib import Path
import os
import sys
import tempfile
import yaml

registry_path = Path(sys.argv[1])
secret_path = Path(sys.argv[2])

secrets = {}
for raw in secret_path.read_text(encoding="utf-8").splitlines():
    if "=" in raw:
        key, value = raw.split("=", 1)
        secrets[key] = value

data = yaml.safe_load(registry_path.read_text(encoding="utf-8")) or {}
mapping = {
    "openrouter": "OPENROUTER_API_KEY",
    "nvidia-nim": "NVIDIA_API_KEY",
    "google-ai-studio": "GOOGLE_API_KEY",
    "nous": "NOUS_API_KEY",
    "poolside": "POOLSIDE_API_KEY",
    "sensenova": "SENSENOVA_API_KEY",
}
for provider, env_name in mapping.items():
    value = secrets.get(env_name, "").strip()
    if value and provider in data and isinstance(data[provider], dict):
        data[provider]["api_key"] = value

fd, tmp_name = tempfile.mkstemp(prefix="registry.", suffix=".yaml", dir=registry_path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        yaml.safe_dump(data, fh, allow_unicode=True, sort_keys=False)
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, registry_path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
PY
chown "$SERVICE_USER:$SERVICE_GROUP" "$ROUTER_REGISTRY"
chmod 600 "$ROUTER_REGISTRY"

log "刷新免费模型列表（失败不会中断安装）"
if ! as_service_user_timeout 240s "$ROUTER_BIN" refresh; then
  warn "模型刷新失败或超时，将继续使用 registry 内置模型列表"
fi

log "创建 open-free-router systemd 服务"
cat > /etc/systemd/system/open-free-router.service <<EOF
[Unit]
Description=open-free-router local LLM router
Wants=network-online.target
After=network-online.target
Before=hermes-gateway.service

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$ROUTER_HOME
Environment=HOME=$SERVICE_HOME
Environment=PYTHONUNBUFFERED=1
ExecStart=$ROUTER_BIN serve
Restart=always
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
chmod 644 /etc/systemd/system/open-free-router.service
systemctl daemon-reload
systemctl enable --now open-free-router.service

MODELS_JSON="$TMP_DIR/models.json"
log "等待 open-free-router API 就绪"
router_ready=0
for _ in $(seq 1 60); do
  if curl --noproxy '*' -fsS --max-time 3 http://127.0.0.1:8337/v1/models -o "$MODELS_JSON"; then
    router_ready=1
    break
  fi
  sleep 1
done
if [[ "$router_ready" -ne 1 ]]; then
  journalctl -u open-free-router.service -n 60 --no-pager >&2 || true
  die "open-free-router 未能在 60 秒内启动"
fi

SELECTED_MODEL="$(python3 - "$MODELS_JSON" "$DEFAULT_MODEL" <<'PY'
import json
import sys

path, requested = sys.argv[1], sys.argv[2]
payload = json.load(open(path, encoding="utf-8"))
ids = [str(item.get("id", "")) for item in payload.get("data", []) if item.get("id")]
if not ids:
    raise SystemExit("empty model list")

if requested in ids:
    print(requested)
    raise SystemExit(0)

preferred = [
    "zen/deepseek-v4-flash-free",
    "zen/big-pickle",
    "zen/north-mini-code-free",
]
for candidate in preferred:
    if candidate in ids:
        print(candidate)
        raise SystemExit(0)
for model_id in ids:
    if model_id.startswith("or/") and "gpt-oss-20b" in model_id:
        print(model_id)
        raise SystemExit(0)
for model_id in ids:
    if model_id.startswith("zen/"):
        print(model_id)
        raise SystemExit(0)
print(ids[0])
PY
)"
[[ -n "$SELECTED_MODEL" ]] || die "无法选择模型"
if [[ "$SELECTED_MODEL" != "$DEFAULT_MODEL" ]]; then
  warn "请求的默认模型 '$DEFAULT_MODEL' 当前不在 /v1/models，已改用 '$SELECTED_MODEL'"
fi
log "Hermes 默认模型：$SELECTED_MODEL"

HERMES_CONFIG="$HERMES_HOME/config.yaml"
if [[ -f "$HERMES_CONFIG" ]]; then
  cp -a "$HERMES_CONFIG" "$HERMES_CONFIG.bak.$(date -u +%Y%m%dT%H%M%SZ)"
fi

log "配置 Hermes 命名自定义 Provider"
"$ROUTER_PYTHON" - "$HERMES_CONFIG" "$SELECTED_MODEL" "$WORKSPACE_DIR" <<'PY'
from pathlib import Path
import os
import sys
import tempfile
import yaml

config_path = Path(sys.argv[1])
model_id = sys.argv[2]
workspace = sys.argv[3]

if config_path.exists():
    data = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
else:
    data = {}
if not isinstance(data, dict):
    data = {}

providers = data.setdefault("providers", {})
providers["open-free-router"] = {
    "name": "open-free-router",
    "api": "http://127.0.0.1:8337/v1",
    "api_key": "sk-local",
    "transport": "chat_completions",
    "default_model": model_id,
    "discover_models": True,
}

# 清掉本脚本旧版本/open-free-router sync 可能留下的同名 legacy 条目，
# 避免 /model 菜单出现两个指向同一端点的 Provider。
legacy = data.get("custom_providers")
if isinstance(legacy, list):
    legacy = [
        item for item in legacy
        if not (
            isinstance(item, dict)
            and (
                str(item.get("name", "")) in {"open-free-router", "open_free_router"}
                or str(item.get("base_url", item.get("api", ""))).rstrip("/")
                   == "http://127.0.0.1:8337/v1"
            )
        )
    ]
    if legacy:
        data["custom_providers"] = legacy
    else:
        data.pop("custom_providers", None)

model = data.setdefault("model", {})
for stale in ("base_url", "api_key", "api_mode", "transport"):
    model.pop(stale, None)
model["provider"] = "custom:open-free-router"
model["default"] = model_id

terminal = data.setdefault("terminal", {})
terminal.setdefault("backend", "local")
terminal.setdefault("cwd", workspace)

config_path.parent.mkdir(parents=True, exist_ok=True)
fd, tmp_name = tempfile.mkstemp(prefix="config.", suffix=".yaml", dir=config_path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        yaml.safe_dump(data, fh, allow_unicode=True, sort_keys=False)
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, config_path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
PY
chown "$SERVICE_USER:$SERVICE_GROUP" "$HERMES_CONFIG"
chmod 600 "$HERMES_CONFIG"

TELEGRAM_SECRETS="$TMP_DIR/telegram.env"
FIRST_TELEGRAM_USER="${TELEGRAM_ALLOWED_USERS%%,*}"
{
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TELEGRAM_BOT_TOKEN"
  printf 'TELEGRAM_ALLOWED_USERS=%s\n' "$TELEGRAM_ALLOWED_USERS"
  printf 'TELEGRAM_HOME_CHANNEL=%s\n' "$FIRST_TELEGRAM_USER"
  printf 'GATEWAY_ALLOW_ALL_USERS=false\n'
} > "$TELEGRAM_SECRETS"
chmod 600 "$TELEGRAM_SECRETS"

HERMES_ENV="$HERMES_HOME/.env"
log "配置 Telegram Bot 与用户白名单"
python3 - "$HERMES_ENV" "$TELEGRAM_SECRETS" <<'PY'
from pathlib import Path
import os
import sys
import tempfile

env_path = Path(sys.argv[1])
secret_path = Path(sys.argv[2])
updates = {}
for raw in secret_path.read_text(encoding="utf-8").splitlines():
    if "=" in raw:
        key, value = raw.split("=", 1)
        updates[key] = value

kept = []
if env_path.exists():
    for raw in env_path.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        probe = stripped[7:].lstrip() if stripped.startswith("export ") else stripped
        key = probe.split("=", 1)[0].strip() if "=" in probe else ""
        if key not in updates:
            kept.append(raw)
if kept and kept[-1] != "":
    kept.append("")
kept.extend(f"{key}={value}" for key, value in updates.items())
content = "\n".join(kept).rstrip() + "\n"

env_path.parent.mkdir(parents=True, exist_ok=True)
fd, tmp_name = tempfile.mkstemp(prefix=".env.", dir=env_path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, env_path)
finally:
    if os.path.exists(tmp_name):
        os.unlink(tmp_name)
PY
chown "$SERVICE_USER:$SERVICE_GROUP" "$HERMES_ENV"
chmod 600 "$HERMES_ENV"

log "验证 Telegram Bot Token"
trap - ERR
if BOT_USERNAME="$(TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

token = os.environ["TELEGRAM_BOT_TOKEN"]
url = f"https://api.telegram.org/bot{token}/getMe"
try:
    with urllib.request.urlopen(url, timeout=20) as response:
        data = json.load(response)
except urllib.error.HTTPError:
    raise SystemExit(2)
except Exception:
    raise SystemExit(3)
if not data.get("ok"):
    raise SystemExit(2)
print(data.get("result", {}).get("username", "unknown"))
PY
)"; then
  bot_check_rc=0
else
  bot_check_rc=$?
fi
trap on_error ERR
case "$bot_check_rc" in
  0) log "Telegram Bot 验证成功：@$BOT_USERNAME" ;;
  2) die "Telegram Bot Token 被 Telegram API 拒绝，请重新生成 Token 后再运行" ;;
  *) warn "当前服务器无法访问 Telegram API，跳过在线 Token 验证" ;;
esac

log "安装 Hermes Gateway systemd 服务"
env \
  "HOME=$SERVICE_HOME" \
  "USER=$SERVICE_USER" \
  "LOGNAME=$SERVICE_USER" \
  "HERMES_HOME=$HERMES_HOME" \
  "PATH=$SERVICE_HOME/.local/bin:$HERMES_HOME/bin:/usr/local/bin:/usr/bin:/bin" \
  "$HERMES_BIN" gateway install \
    --system \
    --run-as-user "$SERVICE_USER" \
    --force \
    --no-start-now \
    --start-on-login

# 上面的 system-scope 安装命令必须由 root 执行；Python 导入和日志初始化
# 可能在 HERMES_HOME 内留下 root 所有的 __pycache__/logs。正式启动无特权
# gateway 前，统一把这个专用账号的 Hermes 树归还给它。
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$HERMES_HOME"

install -d -m 755 /etc/systemd/system/hermes-gateway.service.d
cat > /etc/systemd/system/hermes-gateway.service.d/open-free-router.conf <<'EOF'
[Unit]
Requires=open-free-router.service
After=open-free-router.service
EOF
chmod 644 /etc/systemd/system/hermes-gateway.service.d/open-free-router.conf
systemctl daemon-reload
systemctl enable open-free-router.service hermes-gateway.service >/dev/null
systemctl restart open-free-router.service
systemctl restart hermes-gateway.service

sleep 3
systemctl is-active --quiet open-free-router.service || die "open-free-router 服务未运行"
systemctl is-active --quiet hermes-gateway.service || {
  journalctl -u hermes-gateway.service -n 80 --no-pager >&2 || true
  die "Hermes Gateway 服务未运行"
}

# restart 后再等一次 HTTP 端点，避免在进程刚拉起时误报连接失败。
for _ in $(seq 1 30); do
  if curl --noproxy '*' -fsS --max-time 3 http://127.0.0.1:8337/v1/models >/dev/null; then
    break
  fi
  sleep 1
done

log "执行一次模型对话冒烟测试（上游免费额度不足时只告警）"
REQUEST_JSON="$TMP_DIR/request.json"
RESPONSE_JSON="$TMP_DIR/response.json"
jq -n --arg model "$SELECTED_MODEL" '{
  model: $model,
  messages: [{role: "user", content: "只回复：连接成功"}],
  stream: false
}' > "$REQUEST_JSON"
trap - ERR
if HTTP_CODE="$(curl --noproxy '*' -sS --max-time 120 \
  -o "$RESPONSE_JSON" -w '%{http_code}' \
  http://127.0.0.1:8337/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer sk-local' \
  --data-binary "@$REQUEST_JSON")"; then
  curl_rc=0
else
  curl_rc=$?
fi
trap on_error ERR
if [[ "$curl_rc" -eq 0 && "$HTTP_CODE" =~ ^2 && \
      "$(jq -r '.choices[0].message.content // empty' "$RESPONSE_JSON" 2>/dev/null)" != "" ]]; then
  MODEL_REPLY="$(jq -r '.choices[0].message.content' "$RESPONSE_JSON" | tr '\n' ' ' | cut -c1-160)"
  log "模型调用成功：$MODEL_REPLY"
else
  ERROR_SUMMARY="$(python3 - "$RESPONSE_JSON" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
    error = data.get("error", "unexpected response") if isinstance(data, dict) else data
    if isinstance(error, dict):
        error = error.get("message") or error.get("type") or str(error)
    print(str(error).replace("\n", " ")[:300])
except Exception:
    print("request failed or response was not JSON")
PY
)"
  warn "模型冒烟测试未通过（HTTP ${HTTP_CODE:-000}）：$ERROR_SUMMARY"
  warn "这通常是免费上游 429/额度波动，不影响安装完成；稍后可在 Telegram 用 /model 切换。"
fi

log "运行 Hermes doctor（仅诊断，不因可选组件告警而中断）"
if ! as_service_user_timeout 120s "$HERMES_BIN" doctor; then
  warn "hermes doctor 返回了告警；请按下面的 journalctl 命令查看详情"
fi

cat <<EOF

============================================================
部署完成
============================================================
运行账号：       $SERVICE_USER
Hermes Home：    $HERMES_HOME
默认模型：       $SELECTED_MODEL
Router API：     http://127.0.0.1:8337/v1（仅本机）
Router UI：      http://127.0.0.1:9057（仅本机）
Telegram Bot：   @$BOT_USERNAME

现在打开 Telegram：
  1. 给 @$BOT_USERNAME 发送 /start
  2. 再发送：你好，只回复连接成功
  3. 输入 /model 查看模型
  4. 切换示例：/model custom:open-free-router:zen/deepseek-v4-flash-free

查看状态：
  systemctl status open-free-router hermes-gateway --no-pager

查看日志：
  journalctl -u open-free-router -u hermes-gateway -f

列出模型：
  curl -fsS http://127.0.0.1:8337/v1/models | jq -r '.data[].id'

重要：不要把 8337/9057 直接开放到公网。
EOF
