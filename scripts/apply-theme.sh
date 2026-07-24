#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly INSTALL_ROOT="/etc/bigbluebutton/edura-theme"
readonly INSTALLED_THEME_DIR="${INSTALL_ROOT}/theme"
readonly WEB_ROOT="/var/www/bigbluebutton-default/site"
readonly HTML5_CONFIG="/etc/bigbluebutton/bbb-html5.yml"
readonly WEB_CONFIG="/etc/bigbluebutton/bbb-web.properties"
readonly LOCALE_FILE="/usr/share/bigbluebutton/html5-client/locales/vi_VN.json"
readonly LOCALE_GZIP="${LOCALE_FILE}.gz"
readonly NGINX_CONFIG="/etc/bigbluebutton/nginx/edura-branding.nginx"
readonly APPLY_CONFIG="/etc/bigbluebutton/bbb-conf/apply-config.sh"
readonly STATE_FILE="${INSTALL_ROOT}/previous-config.json"
readonly PLAYBACK_ROOT="/var/bigbluebutton/playback/presentation/2.3"
readonly PLAYBACK_INDEX="${PLAYBACK_ROOT}/index.html"
readonly PLAYBACK_STATE="${INSTALL_ROOT}/previous-playback.json"
readonly LOCALE_STATE="${INSTALL_ROOT}/previous-vi_VN.json"
readonly LOCALE_GZIP_STATE="${INSTALL_ROOT}/previous-vi_VN.json.gz"
readonly MARKER_START="# BEGIN EDURA BBB THEME"
readonly MARKER_END="# END EDURA BBB THEME"

if [[ "${SCRIPT_DIR}" == "${INSTALL_ROOT}" ]]; then
    readonly SOURCE_THEME_DIR="${INSTALLED_THEME_DIR}"
    readonly RUNNING_INSTALLED=true
else
    readonly SOURCE_THEME_DIR="${REPO_ROOT}/theme"
    readonly RUNNING_INSTALLED=false
fi

NO_RESTART=false

if [[ "${1:-}" == "--no-restart" ]]; then
    NO_RESTART=true
elif [[ $# -gt 0 ]]; then
    printf 'Unknown option: %s\n' "$1" >&2
    exit 2
fi

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

read_branding_value() {
    local filter="$1"

    jq -er "${filter} | select(type == \"string\" and length > 0)" \
        "${INSTALLED_THEME_DIR}/branding.json"
}

resolve_bbb_domain() {
    local secret_output
    local api_url

    if [[ -n "${BBB_DOMAIN:-}" ]]; then
        printf '%s\n' "${BBB_DOMAIN}"
        return
    fi

    secret_output="$(bbb-conf --secret 2>/dev/null)"
    api_url="$(awk '/^[[:space:]]*URL:/ {print $2; exit}' <<<"${secret_output}")"

    python3 - "${api_url}" <<'PY'
import sys
from urllib.parse import urlparse

hostname = urlparse(sys.argv[1]).hostname
if not hostname:
    raise SystemExit(1)

print(hostname)
PY
}

render_stylesheet() {
    local template_file="$1"
    local output_file="$2"

    env \
    PRIMARY_COLOR="${PRIMARY_COLOR}" \
    SECONDARY_COLOR="${SECONDARY_COLOR}" \
    BACKGROUND_COLOR="${BACKGROUND_COLOR}" \
    TEXT_COLOR="${TEXT_COLOR}" \
    HOTLINE="${HOTLINE}" \
    SUPPORT_EMAIL="${SUPPORT_EMAIL}" \
    python3 - "${template_file}" "${output_file}" <<'PY'
import os
import sys
from pathlib import Path

template = Path(sys.argv[1]).read_text(encoding="utf-8")


def css_string(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


replacements = {
    "{{PRIMARY_COLOR}}": os.environ["PRIMARY_COLOR"],
    "{{SECONDARY_COLOR}}": os.environ["SECONDARY_COLOR"],
    "{{BACKGROUND_COLOR}}": os.environ["BACKGROUND_COLOR"],
    "{{TEXT_COLOR}}": os.environ["TEXT_COLOR"],
    "{{HOTLINE}}": css_string(os.environ["HOTLINE"]),
    "{{SUPPORT_EMAIL}}": css_string(os.environ["SUPPORT_EMAIL"]),
}

for placeholder, value in replacements.items():
    template = template.replace(placeholder, value)

if "{{" in template or "}}" in template:
    raise SystemExit("Unresolved stylesheet placeholder.")

Path(sys.argv[2]).write_text(template, encoding="utf-8")
PY
}

capture_previous_playback() {
    [[ -f "${PLAYBACK_STATE}" || ! -f "${PLAYBACK_INDEX}" ]] && return

    python3 - "${PLAYBACK_INDEX}" "${PLAYBACK_STATE}" <<'PY'
import json
import sys
from html.parser import HTMLParser
from pathlib import Path


class PlaybackHeadParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.favicon = None
        self.in_title = False
        self.stylesheet = None
        self.title = ""

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "title":
            self.in_title = True
        elif tag == "link" and attributes.get("rel") == "icon":
            self.favicon = attributes.get("href")
        elif tag == "link" and (
            attributes.get("id") == "edura-playback-theme"
            or attributes.get("href", "").endswith("/styles/edura-playback.css")
        ):
            self.stylesheet = attributes.get("href")

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False

    def handle_data(self, data):
        if self.in_title:
            self.title += data


parser = PlaybackHeadParser()
parser.feed(Path(sys.argv[1]).read_text(encoding="utf-8"))
state = {
    "title": parser.title,
    "favicon": parser.favicon,
    "stylesheet": parser.stylesheet,
}
Path(sys.argv[2]).write_text(
    json.dumps(state, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
}

update_playback_page() {
    [[ -f "${PLAYBACK_INDEX}" ]] || return

    env \
    PLAYBACK_TITLE="${CENTER_NAME} - Xem lại bài giảng" \
    PLAYBACK_STYLE_URL="${PLAYBACK_STYLE_URL}" \
    python3 - "${PLAYBACK_INDEX}" <<'PY'
import os
import re
import sys
from html import escape
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
title = escape(os.environ["PLAYBACK_TITLE"])
stylesheet = escape(os.environ["PLAYBACK_STYLE_URL"], quote=True)

content = re.sub(
    r"<title>.*?</title>",
    f"<title>{title}</title>",
    content,
    count=1,
    flags=re.DOTALL | re.IGNORECASE,
)
content = re.sub(
    r'<link\b(?=[^>]*\brel=["\']icon["\'])[^>]*>',
    '<link rel="icon" href="/favicon.ico">',
    content,
    count=1,
    flags=re.IGNORECASE,
)
content = re.sub(
    r'[ \t\r\n]*<link\b(?=[^>]*\bid=["\']edura-playback-theme["\'])[^>]*>',
    "",
    content,
    flags=re.IGNORECASE,
)
content = re.sub(
    r'[ \t\r\n]*<link\b(?=[^>]*\bhref=["\'][^"\']*/styles/edura-playback\.css["\'])[^>]*>',
    "",
    content,
    flags=re.IGNORECASE,
)
theme_link = (
    f'<link id="edura-playback-theme" rel="stylesheet" href="{stylesheet}">'
)
content = re.sub(
    r"</head>",
    f"\n{theme_link}\n</head>",
    content,
    count=1,
    flags=re.IGNORECASE,
)
path.write_text(content, encoding="utf-8")
PY
}

update_web_properties() {
    env \
    CENTER_NAME="${CENTER_NAME}" \
    HOTLINE="${HOTLINE}" \
    SUPPORT_EMAIL="${SUPPORT_EMAIL}" \
    python3 - "${WEB_CONFIG}" <<'PY'
import os
import sys
from html import escape
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []


def java_escape(value):
    return "".join(
        f"\\u{ord(character):04x}" if ord(character) > 127 else character
        for character in value
    )


values = {
    "defaultWelcomeMessage": java_escape(
        f"Chào mừng bạn đến với lớp học trực tuyến của "
        f"<b>{escape(os.environ['CENTER_NAME'])}</b>."
    ),
    "defaultWelcomeMessageFooter": java_escape(
        f"Hỗ trợ kỹ thuật: Hotline <b>{escape(os.environ['HOTLINE'])}</b> | "
        f"Email <b>{escape(os.environ['SUPPORT_EMAIL'])}</b>."
    ),
}

seen = set()
updated = []
for line in lines:
    key = line.split("=", 1)[0]
    if key in values:
        updated.append(f"{key}={values[key]}")
        seen.add(key)
    else:
        updated.append(line)

for key, value in values.items():
    if key not in seen:
        updated.append(f"{key}={value}")

path.write_text("\n".join(updated) + "\n", encoding="utf-8")
PY
}

capture_previous_config() {
    local temporary_html5
    local temporary_state

    [[ -f "${STATE_FILE}" ]] && return

    temporary_html5="$(mktemp)"
    temporary_state="$(mktemp)"
    yq eval -o=json '.' "${HTML5_CONFIG}" >"${temporary_html5}"
    python3 - "${WEB_CONFIG}" "${temporary_html5}" >"${temporary_state}" <<'PY'
import json
import sys
from pathlib import Path

html5 = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8")) or {}
web_path = Path(sys.argv[1])
web_lines = web_path.read_text(encoding="utf-8").splitlines() if web_path.exists() else []
web_values = {}

for line in web_lines:
    key, separator, value = line.partition("=")
    if separator and key in {"defaultWelcomeMessage", "defaultWelcomeMessageFooter"}:
        web_values[key] = value


def setting(container, key):
    return {
        "present": key in container,
        "value": container.get(key),
    }


public = html5.get("public") or {}
app = public.get("app") or {}
branding = app.get("branding") or {}
state = {
    "html5": {
        "client_title": setting(app, "clientTitle"),
        "copyright": setting(app, "copyright"),
        "custom_style_url": setting(app, "customStyleUrl"),
        "display_branding_area": setting(branding, "displayBrandingArea"),
        "override_locale": setting(app, "overrideLocale"),
    },
    "web": {
        key: {
            "present": key in web_values,
            "value": web_values.get(key),
        }
        for key in ("defaultWelcomeMessage", "defaultWelcomeMessageFooter")
    },
}

json.dump(state, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PY
    install -m 0644 "${temporary_state}" "${STATE_FILE}"
    rm -f "${temporary_html5}" "${temporary_state}"
}

capture_previous_locale() {
    if [[ ! -f "${LOCALE_STATE}" && -f "${LOCALE_FILE}" ]]; then
        install -m 0644 "${LOCALE_FILE}" "${LOCALE_STATE}"
    fi

    if [[ ! -f "${LOCALE_GZIP_STATE}" && -f "${LOCALE_GZIP}" ]]; then
        install -m 0644 "${LOCALE_GZIP}" "${LOCALE_GZIP_STATE}"
    fi
}

update_locale() {
    local temporary_locale_gzip

    [[ -f "${LOCALE_FILE}" ]] || fail "Missing BigBlueButton Vietnamese locale."

    python3 - "${LOCALE_FILE}" "${INSTALLED_THEME_DIR}/locale-overrides.json" <<'PY'
import json
import sys
from pathlib import Path

locale_path = Path(sys.argv[1])
override_path = Path(sys.argv[2])
locale = json.loads(locale_path.read_text(encoding="utf-8"))
overrides = json.loads(override_path.read_text(encoding="utf-8"))
locale.update(overrides)
locale_path.write_text(
    json.dumps(locale, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

    temporary_locale_gzip="$(mktemp)"
    gzip -c -9 "${LOCALE_FILE}" >"${temporary_locale_gzip}"
    install -m 0644 "${temporary_locale_gzip}" "${LOCALE_GZIP}"
    rm -f "${temporary_locale_gzip}"
}

install_apply_config_hook() {
    python3 - "${APPLY_CONFIG}" "${MARKER_START}" "${MARKER_END}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
start = sys.argv[2]
end = sys.argv[3]
block = (
    f"{start}\n"
    "if [[ -x /etc/bigbluebutton/edura-theme/apply-theme.sh ]]; then\n"
    "    /etc/bigbluebutton/edura-theme/apply-theme.sh --no-restart\n"
    "fi\n"
    f"{end}"
)

content = path.read_text(encoding="utf-8") if path.exists() else "#!/bin/bash\n"
start_index = content.find(start)
end_index = content.find(end)

if start_index >= 0 and end_index >= start_index:
    end_index += len(end)
    content = content[:start_index].rstrip() + "\n\n" + block + content[end_index:]
else:
    content = content.rstrip() + "\n\n" + block + "\n"

path.write_text(content, encoding="utf-8")
PY

    chmod 0755 "${APPLY_CONFIG}"
}

if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this script as root."
fi

for command_name in bbb-conf gzip install jq nginx python3 sha256sum yq; do
    require_command "${command_name}"
done

for required_file in \
    branding.json \
    custom.css.template \
    playback.css.template \
    locale-overrides.json \
    favicon.ico \
    logo.png; do
    [[ -f "${SOURCE_THEME_DIR}/${required_file}" ]] \
        || fail "Missing theme file: ${SOURCE_THEME_DIR}/${required_file}"
done

install -d -m 0755 "${INSTALLED_THEME_DIR}" "${WEB_ROOT}"
touch "${HTML5_CONFIG}" "${WEB_CONFIG}"

if [[ "${RUNNING_INSTALLED}" == false ]]; then
    install -m 0644 "${SOURCE_THEME_DIR}/branding.json" "${INSTALLED_THEME_DIR}/branding.json"
    install -m 0644 "${SOURCE_THEME_DIR}/custom.css.template" "${INSTALLED_THEME_DIR}/custom.css.template"
    install -m 0644 "${SOURCE_THEME_DIR}/playback.css.template" "${INSTALLED_THEME_DIR}/playback.css.template"
    install -m 0644 "${SOURCE_THEME_DIR}/locale-overrides.json" "${INSTALLED_THEME_DIR}/locale-overrides.json"
    install -m 0644 "${SOURCE_THEME_DIR}/favicon.ico" "${INSTALLED_THEME_DIR}/favicon.ico"
    install -m 0644 "${SOURCE_THEME_DIR}/logo.png" "${INSTALLED_THEME_DIR}/logo.png"
    install -m 0755 "${BASH_SOURCE[0]}" "${INSTALL_ROOT}/apply-theme.sh"
fi

capture_previous_config
capture_previous_playback
capture_previous_locale

CENTER_NAME="$(read_branding_value '.center_name')"
readonly CENTER_NAME
CLIENT_TITLE="$(read_branding_value '.client_title')"
readonly CLIENT_TITLE
COPYRIGHT_TEXT="$(read_branding_value '.copyright')"
readonly COPYRIGHT_TEXT
HOTLINE="$(read_branding_value '.hotline')"
readonly HOTLINE
SUPPORT_EMAIL="$(read_branding_value '.support_email')"
readonly SUPPORT_EMAIL
PRIMARY_COLOR="$(read_branding_value '.colors.primary')"
readonly PRIMARY_COLOR
SECONDARY_COLOR="$(read_branding_value '.colors.secondary')"
readonly SECONDARY_COLOR
BACKGROUND_COLOR="$(read_branding_value '.colors.background')"
readonly BACKGROUND_COLOR
TEXT_COLOR="$(read_branding_value '.colors.text')"
readonly TEXT_COLOR
BBB_DOMAIN="$(resolve_bbb_domain)"
readonly BBB_DOMAIN

[[ "${BBB_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] || fail "Invalid BBB domain."
[[ "${SUPPORT_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
    || fail "Invalid support email."

for text_value in \
    "${CENTER_NAME}" \
    "${CLIENT_TITLE}" \
    "${COPYRIGHT_TEXT}" \
    "${HOTLINE}" \
    "${SUPPORT_EMAIL}"; do
    [[ "${text_value}" != *$'\n'* && "${text_value}" != *$'\r'* ]] \
        || fail "Branding text must use a single line."
done

for color in \
    "${PRIMARY_COLOR}" \
    "${SECONDARY_COLOR}" \
    "${BACKGROUND_COLOR}" \
    "${TEXT_COLOR}"; do
    [[ "${color}" =~ ^#[0-9A-Fa-f]{6}$ ]] || fail "Invalid branding color: ${color}"
done

temporary_css="$(mktemp)"
temporary_playback_css="$(mktemp)"
trap 'rm -f "${temporary_css}" "${temporary_playback_css}"' EXIT
render_stylesheet "${INSTALLED_THEME_DIR}/custom.css.template" "${temporary_css}"
render_stylesheet "${INSTALLED_THEME_DIR}/playback.css.template" "${temporary_playback_css}"

STYLE_VERSION="$(sha256sum "${temporary_css}" | awk '{print substr($1, 1, 12)}')"
readonly STYLE_VERSION
STYLE_URL="https://${BBB_DOMAIN}/branding/custom.css?v=${STYLE_VERSION}"
readonly STYLE_URL
PLAYBACK_STYLE_VERSION="$(sha256sum "${temporary_playback_css}" | awk '{print substr($1, 1, 12)}')"
readonly PLAYBACK_STYLE_VERSION
PLAYBACK_STYLE_URL="https://${BBB_DOMAIN}/branding/playback.css?v=${PLAYBACK_STYLE_VERSION}"
readonly PLAYBACK_STYLE_URL

install -m 0644 "${temporary_css}" "${WEB_ROOT}/custom.css"
install -m 0644 "${temporary_playback_css}" "${WEB_ROOT}/playback.css"
install -m 0644 "${INSTALLED_THEME_DIR}/favicon.ico" "${WEB_ROOT}/favicon.ico"
install -m 0644 "${INSTALLED_THEME_DIR}/logo.png" "${WEB_ROOT}/logo.png"

cat >"${NGINX_CONFIG}" <<'NGINX'
location = /favicon.ico {
    alias /var/www/bigbluebutton-default/site/favicon.ico;
    access_log off;
    expires 7d;
}

location = /logo.png {
    alias /var/www/bigbluebutton-default/site/logo.png;
    access_log off;
    expires 1h;
}

location /branding/ {
    alias /var/www/bigbluebutton-default/site/;
    access_log off;
    expires 1h;
}
NGINX

env \
CLIENT_TITLE="${CLIENT_TITLE}" \
COPYRIGHT_TEXT="${COPYRIGHT_TEXT}" \
STYLE_URL="${STYLE_URL}" \
yq eval --inplace '
    .public.app.clientTitle = strenv(CLIENT_TITLE) |
    .public.app.copyright = strenv(COPYRIGHT_TEXT) |
    .public.app.customStyleUrl = strenv(STYLE_URL) |
    .public.app.overrideLocale = "vi-VN" |
    .public.app.branding.displayBrandingArea = true |
    del(.public.branding)
' "${HTML5_CONFIG}"

update_web_properties
update_locale
update_playback_page
install_apply_config_hook

nginx -t

if [[ "${NO_RESTART}" == false ]]; then
    bbb-conf --restart
fi

printf 'Applied the %s theme for %s.\n' "${CENTER_NAME}" "${BBB_DOMAIN}"
