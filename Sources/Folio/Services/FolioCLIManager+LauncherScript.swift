import Foundation

extension FolioCLIManager {

    /// Generates the executable `folio` shell script (similar to VS Code's `code` and Zed's `zed` CLI launcher).
    public static func generateCLIScript(
        fallbackAppBundlePath: String,
        queueFilePath: String = defaultQueueFileURL.path
    ) -> String {
        """
        #!/usr/bin/env bash
        # Folio CLI launcher — opens Markdown files and folders in Folio.app
        set -euo pipefail
        QUEUE_FILE="${FOLIO_CLI_QUEUE_FILE:-\(queueFilePath)}"
        FALLBACK_APP="${FOLIO_FALLBACK_APP:-\(fallbackAppBundlePath)}"
        CALLER_CWD="${FOLIO_CALLER_CWD:-${BUILD_WORKING_DIRECTORY:-$(pwd -P)}}"

        resolve_self_app_bundle() {
            local source="${BASH_SOURCE[0]}"
            while [[ -L "${source}" ]]; do
                local dir
                dir="$(cd -P "$(dirname "${source}")" && pwd)"
                source="$(readlink "${source}")"
                if [[ "${source}" != /* ]]; then source="${dir}/${source}"; fi
            done
            local script_dir
            script_dir="$(cd -P "$(dirname "${source}")" && pwd)"
            local candidate="${script_dir}"
            while [[ "${candidate}" != "/" && "${candidate}" != "." ]]; do
                if [[ "${candidate}" == *.app && -d "${candidate}" ]]; then
                    echo "${candidate}"
                    return 0
                fi
                candidate="$(dirname "${candidate}")"
            done
            return 1
        }

        resolve_app_bundle() {
            if [[ -n "${FOLIO_APP_PATH:-}" && -d "${FOLIO_APP_PATH}" ]]; then
                echo "${FOLIO_APP_PATH}"
                return 0
            fi
            local self_bundle
            if self_bundle="$(resolve_self_app_bundle)"; then
                echo "${self_bundle}"
                return 0
            fi
            for candidate in "/Applications/Folio.app" "$HOME/Applications/Folio.app" "${FALLBACK_APP}"; do
                if [[ -n "${candidate}" && -d "${candidate}" ]]; then
                    echo "${candidate}"
                    return 0
                fi
            done
            local found
            found="$(mdfind "kMDItemCFBundleIdentifier == 'app.folio.macos'" 2>/dev/null | head -n 1 || true)"
            if [[ -n "${found}" && -d "${found}" ]]; then
                echo "${found}"
                return 0
            fi
            return 1
        }

        FOREGROUND=0
        NEW_INSTANCE=0
        PARSE_FLAGS=1
        RAW_PATHS=()
        for arg in "$@"; do
            if (( PARSE_FLAGS == 1 )); then
                case "${arg}" in
                    -h|--help)
                        echo "Usage: folio [options] [path[:line[:column]] ...]"
                        echo "Open files or folders in Folio."
                        exit 0
                        ;;
                    -v|--version)
                        echo "folio 1.0.0"
                        exit 0
                        ;;
                    --foreground) FOREGROUND=1; continue ;;
                    -n|--new) NEW_INSTANCE=1; continue ;;
                    -a|--add|-e|--existing|-w|--wait) continue ;;
                    --) PARSE_FLAGS=0; continue ;;
                    -*) continue ;;
                esac
            fi
            RAW_PATHS+=("${arg}")
        done

        ABS_PATHS=()
        if (( ${#RAW_PATHS[@]} > 0 )); then
            for raw_arg in "${RAW_PATHS[@]}"; do
                cleaned="${raw_arg#file://}"
                line_suffix=""
                path_part="${cleaned}"
                if [[ "${path_part}" == "~" ]]; then
                    path_part="$HOME"
                elif [[ "${path_part}" == "~/"* ]]; then
                    path_part="$HOME/${path_part:2}"
                fi
                if [[ "${path_part}" != /* ]]; then
                    path_part="${CALLER_CWD}/${path_part}"
                fi
                if [[ ! -e "${path_part}" ]]; then
                    if [[ "${path_part}" =~ ^(.+):([0-9]+:[0-9]+)$ ]]; then
                        path_part="${BASH_REMATCH[1]}"
                        line_suffix=":${BASH_REMATCH[2]}"
                    elif [[ "${path_part}" =~ ^(.+):([0-9]+)$ ]]; then
                        path_part="${BASH_REMATCH[1]}"
                        line_suffix=":${BASH_REMATCH[2]}"
                    fi
                fi
                if [[ -d "${path_part}" ]]; then
                    ABS_PATHS+=("$(cd "${path_part}" && pwd -P)${line_suffix}")
                else
                    if [[ ! -e "${path_part}" ]]; then
                        mkdir -p "$(dirname "${path_part}")"
                        touch "${path_part}"
                    fi
                    dir_part="$(cd "$(dirname "${path_part}")" && pwd -P)"
                    ABS_PATHS+=("${dir_part}/$(basename "${path_part}")${line_suffix}")
                fi
            done
        fi

        if (( FOREGROUND == 1 )); then
            if APP_BUNDLE="$(resolve_app_bundle)"; then
                export FOLIO_CALLER_CWD="${CALLER_CWD}"
                APP_EXEC="${APP_BUNDLE}/Contents/MacOS/Folio"
                if [[ ! -x "${APP_EXEC}" && -x "${APP_BUNDLE}/Contents/MacOS/FolioApp" ]]; then
                    APP_EXEC="${APP_BUNDLE}/Contents/MacOS/FolioApp"
                fi
                if (( ${#ABS_PATHS[@]} > 0 )); then
                    exec "${APP_EXEC}" "${ABS_PATHS[@]}"
                else
                    exec "${APP_EXEC}"
                fi
            fi
            echo "folio: could not locate Folio.app. Move Folio.app to /Applications or set FOLIO_APP_PATH." >&2
            exit 1
        fi

        if (( ${#ABS_PATHS[@]} > 0 )); then
            mkdir -p "$(dirname "${QUEUE_FILE}")"
            for p in "${ABS_PATHS[@]}"; do
                printf '%s\\n' "${p}" >> "${QUEUE_FILE}"
            done
        fi

        if (( NEW_INSTANCE == 0 )); then
            RUNNING_PIDS="$(pgrep -x "Folio" 2>/dev/null || pgrep -x "FolioApp" 2>/dev/null || true)"
            if [[ -n "${RUNNING_PIDS}" ]]; then
                for pid in ${RUNNING_PIDS}; do
                    kill -USR1 "${pid}" 2>/dev/null || true
                done
                osascript -e 'tell application "System Events" to set frontmost of every process whose name is "Folio" or name is "FolioApp" to true' >/dev/null 2>&1 || true
                exit 0
            fi
        fi

        if APP_BUNDLE="$(resolve_app_bundle)"; then
            OPEN_FLAGS=(-a "${APP_BUNDLE}")
            if (( NEW_INSTANCE == 1 )); then OPEN_FLAGS=(-n -a "${APP_BUNDLE}"); fi
            if (( ${#ABS_PATHS[@]} > 0 )); then
                open "${OPEN_FLAGS[@]}" --args "${ABS_PATHS[@]}"
            else
                open "${OPEN_FLAGS[@]}"
            fi
        else
            echo "folio: could not locate Folio.app. Move Folio.app to /Applications or set FOLIO_APP_PATH." >&2
            exit 1
        fi
        """
    }
}
