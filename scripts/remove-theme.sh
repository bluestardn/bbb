#!/usr/bin/env bash

set -Eeuo pipefail

readonly INSTALL_ROOT="/etc/bigbluebutton/edura-theme"
readonly WEB_ROOT="/var/www/bigbluebutton-default/site"
readonly HTML5_CONFIG="/etc/bigbluebutton/bbb-html5.yml"
readonly WEB_CONFIG="/etc/bigbluebutton/bbb-web.properties"
readonly HTML5_LOCALE="/usr/share/bigbluebutton/html5-client/locales/vi_VN.json"
readonly HTML5_LOCALE_GZIP="${HTML5_LOCALE}.gz"
readonly NGINX_CONFIG="/etc/bigbluebutton/nginx/edura-branding.nginx"
readonly APPLY_CONFIG="/etc/bigbluebutton/bbb-conf/apply-config.sh"
readonly STATE_FILE="${INSTALL_ROOT}/previous-config.json"
readonly DEFAULT_PRESENTATION_STATE="${INSTALL_ROOT}/previous-default-presentation.json"
readonly PLAYBACK_ROOT="/var/bigbluebutton/playback/presentation/2.3"
readonly PLAYBACK_INDEX="${PLAYBACK_ROOT}/index.html"
readonly PLAYBACK_STATE="${INSTALL_ROOT}/previous-playback.json"
readonly LOCALE_STATE="${INSTALL_ROOT}/previous-vi_VN.json"
readonly LOCALE_GZIP_STATE="${INSTALL_ROOT}/previous-vi_VN.json.gz"
readonly MARKER_START="# BEGIN EDURA BBB THEME"
readonly MARKER_END="# END EDURA BBB THEME"

NO_RESTART=false

if [[ "${1:-}" == "--no-restart" ]]; then
    NO_RESTART=true
elif [[ $# -gt 0 ]]; then
    printf 'Unknown option: %s\n' "$1" >&2
    exit 2
fi

if [[ "${EUID}" -ne 0 ]]; then
    printf 'Error: run this script as root.\n' >&2
    exit 1
fi

for command_name in jq nginx python3 yq; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf 'Error: required command not found: %s\n' "${command_name}" >&2
        exit 1
    fi
done

restore_html5_string() {
    local state_key="$1"
    local config_path="$2"

    if jq -e ".html5.${state_key}.present == true" "${STATE_FILE}" >/dev/null; then
        RESTORE_VALUE="$(jq -r ".html5.${state_key}.value" "${STATE_FILE}")" \
            yq eval --inplace "${config_path} = strenv(RESTORE_VALUE)" "${HTML5_CONFIG}"
    else
        yq eval --inplace "del(${config_path})" "${HTML5_CONFIG}"
    fi
}

restore_html5_config() {
    restore_html5_string "client_title" ".public.app.clientTitle"
    restore_html5_string "copyright" ".public.app.copyright"
    restore_html5_string "custom_style_url" ".public.app.customStyleUrl"
    restore_html5_string "override_locale" ".public.app.overrideLocale"

    if jq -e '.html5.display_branding_area.present == true' "${STATE_FILE}" >/dev/null; then
        RESTORE_VALUE="$(jq -r '.html5.display_branding_area.value' "${STATE_FILE}")" \
            yq eval --inplace \
                '.public.app.branding.displayBrandingArea = (strenv(RESTORE_VALUE) == "true")' \
                "${HTML5_CONFIG}"
    else
        yq eval --inplace 'del(.public.app.branding.displayBrandingArea)' "${HTML5_CONFIG}"

        if [[ "$(yq eval '.public.app.branding | length' "${HTML5_CONFIG}")" == "0" ]]; then
            yq eval --inplace 'del(.public.app.branding)' "${HTML5_CONFIG}"
        fi
    fi
}

restore_locale() {
    [[ -f "${LOCALE_STATE}" ]] || return

    install -m 0644 "${LOCALE_STATE}" "${HTML5_LOCALE}"

    if [[ -f "${LOCALE_GZIP_STATE}" ]]; then
        install -m 0644 "${LOCALE_GZIP_STATE}" "${HTML5_LOCALE_GZIP}"
    else
        rm -f "${HTML5_LOCALE_GZIP}"
    fi
}

restore_web_config() {
    python3 - "${WEB_CONFIG}" "${STATE_FILE}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
state = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))["web"]
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
keys = set(state)
restored = []
seen = set()

for line in lines:
    key = line.split("=", 1)[0]
    if key not in keys:
        restored.append(line)
        continue

    seen.add(key)
    if state[key]["present"]:
        restored.append(f"{key}={state[key]['value']}")

for key in keys - seen:
    if state[key]["present"]:
        restored.append(f"{key}={state[key]['value']}")

path.write_text("\n".join(restored) + ("\n" if restored else ""), encoding="utf-8")
PY
}

restore_default_presentation() {
    local key="beans.presentationService.defaultUploadedPresentation"

    if [[ ! -f "${DEFAULT_PRESENTATION_STATE}" ]]; then
        sed -i "/^${key}=/d" "${WEB_CONFIG}"
        return
    fi

    python3 - "${WEB_CONFIG}" "${DEFAULT_PRESENTATION_STATE}" "${key}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
state = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
key = sys.argv[3]
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
updated = []
restored = False

for line in lines:
    current_key = line.split("=", 1)[0]
    if current_key != key:
        updated.append(line)
        continue

    if state["present"] and not restored:
        updated.append(f"{key}={state['value']}")
        restored = True

if state["present"] and not restored:
    updated.append(f"{key}={state['value']}")

path.write_text("\n".join(updated) + ("\n" if updated else ""), encoding="utf-8")
PY
}

restore_playback_page() {
    [[ -f "${PLAYBACK_INDEX}" ]] || return

    if [[ ! -f "${PLAYBACK_STATE}" ]]; then
        python3 - "${PLAYBACK_INDEX}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
content = re.sub(
    r'[ \t\r\n]*<link\b(?=[^>]*\bid=["\']edura-playback-theme["\'])[^>]*>',
    "",
    content,
    flags=re.IGNORECASE,
)
path.write_text(content, encoding="utf-8")
PY
        return
    fi

    python3 - "${PLAYBACK_INDEX}" "${PLAYBACK_STATE}" <<'PY'
import json
import re
import sys
from html import escape
from pathlib import Path

path = Path(sys.argv[1])
state = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
content = path.read_text(encoding="utf-8")

content = re.sub(
    r"<title>.*?</title>",
    f"<title>{escape(state['title'])}</title>",
    content,
    count=1,
    flags=re.DOTALL | re.IGNORECASE,
)
if state["favicon"] is not None:
    favicon = escape(state["favicon"], quote=True)
    content = re.sub(
        r'<link\b(?=[^>]*\brel=["\']icon["\'])[^>]*>',
        f'<link rel="icon" href="{favicon}">',
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
if state["stylesheet"] is not None:
    stylesheet = escape(state["stylesheet"], quote=True)
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

if [[ -f "${STATE_FILE}" ]]; then
    restore_html5_config
    restore_web_config
    restore_default_presentation
else
    if [[ -f "${HTML5_CONFIG}" ]]; then
        yq eval --inplace '
            del(.public.app.clientTitle) |
            del(.public.app.copyright) |
            del(.public.app.customStyleUrl) |
            del(.public.app.branding.displayBrandingArea)
        ' "${HTML5_CONFIG}"

        if [[ "$(yq eval '.public.app.branding | length' "${HTML5_CONFIG}")" == "0" ]]; then
            yq eval --inplace 'del(.public.app.branding)' "${HTML5_CONFIG}"
        fi
    fi

    if [[ -f "${WEB_CONFIG}" ]]; then
        sed -i \
            -e '/^beans\.presentationService\.defaultUploadedPresentation=/d' \
            -e '/^defaultWelcomeMessage=/d' \
            -e '/^defaultWelcomeMessageFooter=/d' \
            "${WEB_CONFIG}"
    fi
fi

restore_playback_page
restore_locale

if [[ -f "${APPLY_CONFIG}" ]]; then
    python3 - "${APPLY_CONFIG}" "${MARKER_START}" "${MARKER_END}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
start = sys.argv[2]
end = sys.argv[3]
content = path.read_text(encoding="utf-8")
start_index = content.find(start)
end_index = content.find(end)

if start_index >= 0 and end_index >= start_index:
    end_index += len(end)
    content = content[:start_index].rstrip() + "\n" + content[end_index:].lstrip("\n")
    path.write_text(content, encoding="utf-8")
PY
fi

rm -f \
    "${NGINX_CONFIG}" \
    "${WEB_ROOT}/custom.css" \
    "${WEB_ROOT}/playback.css" \
    "${WEB_ROOT}/favicon.ico" \
    "${WEB_ROOT}/logo.png" \
    "${WEB_ROOT}/slide-1.png"
rmdir "${WEB_ROOT}" 2>/dev/null || true
rm -rf "${INSTALL_ROOT}"

nginx -t

if [[ "${NO_RESTART}" == false ]]; then
    bbb-conf --restart
fi

printf 'Removed the Edura BigBlueButton theme.\n'
