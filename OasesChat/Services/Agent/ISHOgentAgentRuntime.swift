import Foundation

enum ISHOgentAgentRuntime {
    static let version = "2026.07.16.01"
    /// Pin the upstream server used by the built-in profile. A floating npm
    /// install would make the same iSH rootfs run different MCP code after a
    /// later cold start, which makes a failed train query impossible to
    /// reproduce. The package can still be overridden for development.
    static let upstream12306Package = "12306-mcp@0.3.9"
    static let upstream12306BundlePath = "/usr/local/lib/oases/12306-mcp-0.3.9.mjs"
    static let upstream12306Version = "0.3.9"

    static var scriptContents: String {
        script
    }

    static func install(into dataURL: URL) {
        let fm = FileManager.default
        let binDirectory = dataURL.appendingPathComponent("usr/local/bin", isDirectory: true)
        let scriptURL = binDirectory.appendingPathComponent("ogent-agent")
        let compatibilityURL = binDirectory.appendingPathComponent("minis-agent")
        let mcp12306URL = binDirectory.appendingPathComponent("oases-12306-mcp")

        do {
            try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            let data = script.data(using: .utf8) ?? Data()
            if fm.fileExists(atPath: scriptURL.path) {
                let current = try? Data(contentsOf: scriptURL)
                if current != data {
                    try data.write(to: scriptURL, options: .atomic)
                }
            } else {
                try data.write(to: scriptURL, options: .atomic)
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            let compatibility = """
            #!/bin/sh
            exec /usr/local/bin/ogent-agent "$@"
            """
            try (compatibility.data(using: .utf8) ?? Data()).write(to: compatibilityURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compatibilityURL.path)
            let mcpData = mcp12306Script.data(using: .utf8) ?? Data()
            if fm.fileExists(atPath: mcp12306URL.path) {
                let current = try? Data(contentsOf: mcp12306URL)
                if current != mcpData {
                    try mcpData.write(to: mcp12306URL, options: .atomic)
                }
            } else {
                try mcpData.write(to: mcp12306URL, options: .atomic)
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mcp12306URL.path)
        } catch {
            NSLog("[ISHOgentAgent] install failed: \(error)")
        }
    }

    private static var mcp12306Script: String {
        // i18n-ignore: shell script run inside iSH
        """
        #!/bin/sh
        set -u

        UPSTREAM_12306_PACKAGE="\(upstream12306Package)"
        ROOT="${OGENT_ROOT:-${MINIS_ROOT:-/root/.ogent}}"
        UPSTREAM_12306_DIR="$ROOT/mcp/12306-mcp"
        UPSTREAM_12306_BIN="$UPSTREAM_12306_DIR/node_modules/.bin/12306-mcp"
        UPSTREAM_12306_BUNDLE="\(upstream12306BundlePath)"
        export PATH="$UPSTREAM_12306_DIR/node_modules/.bin:$PATH"

        upstream_12306_bin() {
          if [ -x "$UPSTREAM_12306_BIN" ]; then
            printf '%s\n' "$UPSTREAM_12306_BIN"
            return 0
          fi
          if command -v 12306-mcp >/dev/null 2>&1; then
            command -v 12306-mcp
            return 0
          fi
          return 1
        }

        upstream_12306_bundle_path() {
          if [ -f "$UPSTREAM_12306_BUNDLE" ]; then
            printf '%s\\n' "$UPSTREAM_12306_BUNDLE"
            return 0
          fi
          return 1
        }

        upstream_12306_bundle() {
          if command -v node >/dev/null 2>&1; then
            upstream_12306_bundle_path
            return $?
          fi
          return 1
        }

        upstream_12306_version() {
          if upstream_bundle="$(upstream_12306_bundle_path 2>/dev/null)"; then
            printf '%s\\n' "\(upstream12306Version)"
            return 0
          fi
          package_json="$UPSTREAM_12306_DIR/node_modules/12306-mcp/package.json"
          if [ -f "$package_json" ] && command -v node >/dev/null 2>&1; then
            version="$(node -e 'const fs=require("fs"); try { const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(p.version || "unknown") } catch (_) { process.stdout.write("unknown") }' "$package_json" 2>/dev/null || true)"
            [ -n "$version" ] && { printf '%s\n' "$version"; return 0; }
          fi
          if command -v npm >/dev/null 2>&1; then
            version="$(npm list --prefix "$UPSTREAM_12306_DIR" --depth=0 12306-mcp 2>/dev/null | sed -n 's/.*12306-mcp@//p' | sed -n '1p')"
            [ -n "$version" ] && { printf '%s\n' "$version"; return 0; }
            version="$(npm list -g --depth=0 12306-mcp 2>/dev/null | sed -n 's/.*12306-mcp@//p' | sed -n '1p')"
            [ -n "$version" ] && { printf '%s\n' "$version"; return 0; }
          fi
          printf '%s\n' "unknown"
        }

        if [ "${OASES_12306_MCP_FORCE_SHIM:-0}" != "1" ]; then
          if upstream_bin="$(upstream_12306_bin 2>/dev/null)"; then
            exec "$upstream_bin" "$@"
          fi
          if upstream_bundle="$(upstream_12306_bundle 2>/dev/null)"; then
            exec node "$upstream_bundle" "$@"
          fi
          if [ "${OASES_12306_MCP_USE_NPX:-0}" = "1" ] && command -v npx >/dev/null 2>&1; then
            exec npx -y "$UPSTREAM_12306_PACKAGE" "$@"
          fi
        fi

        json_escape() {
          sed -e 's/\\\\/\\\\\\\\/g' -e 's/"/\\\\"/g' | awk 'BEGIN{ORS=""}{gsub(/\\r/,"\\\\r"); gsub(/\\t/,"\\\\t"); if (NR>1) printf "\\\\n"; printf "%s",$0}'
        }

        send_json() {
          printf '%s\\n' "$1"
        }

        content_response() {
          id="$1"
          text="$2"
          escaped="$(printf '%s' "$text" | json_escape)"
          send_json "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"content\\":[{\\"type\\":\\"text\\",\\"text\\":\\"$escaped\\"}]}}"
        }

        error_response() {
          id="$1"
          code="$2"
          message="$3"
          escaped="$(printf '%s' "$message" | json_escape)"
          send_json "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"error\\":{\\"code\\":$code,\\"message\\":\\"$escaped\\"}}"
        }

        get_field() {
          key="$1"
          line="$2"
          printf '%s' "$line" | sed -n "s/.*\\"$key\\":\\"\\([^\\"]*\\)\\".*/\\1/p"
        }

        get_number_field() {
          key="$1"
          line="$2"
          printf '%s' "$line" | sed -n "s/.*\\"$key\\":\\([0-9][0-9]*\\).*/\\1/p"
        }

        today_shanghai() {
          TZ=Asia/Shanghai date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d
        }

        station_json_for_name() {
          case "$1" in
            北京) printf '{"station_code":"BJP","station_name":"北京"}' ;;
            北京南) printf '{"station_code":"VNP","station_name":"北京南"}' ;;
            北京西) printf '{"station_code":"BXP","station_name":"北京西"}' ;;
            北京北) printf '{"station_code":"VAP","station_name":"北京北"}' ;;
            上海) printf '{"station_code":"SHH","station_name":"上海"}' ;;
            上海虹桥) printf '{"station_code":"AOH","station_name":"上海虹桥"}' ;;
            上海南) printf '{"station_code":"SNH","station_name":"上海南"}' ;;
            广州) printf '{"station_code":"GZQ","station_name":"广州"}' ;;
            广州南) printf '{"station_code":"IZQ","station_name":"广州南"}' ;;
            深圳) printf '{"station_code":"SZQ","station_name":"深圳"}' ;;
            深圳北) printf '{"station_code":"IOQ","station_name":"深圳北"}' ;;
            杭州) printf '{"station_code":"HZH","station_name":"杭州"}' ;;
            杭州东) printf '{"station_code":"HGH","station_name":"杭州东"}' ;;
            南京) printf '{"station_code":"NJH","station_name":"南京"}' ;;
            南京南) printf '{"station_code":"NKH","station_name":"南京南"}' ;;
            成都) printf '{"station_code":"CDW","station_name":"成都"}' ;;
            成都东) printf '{"station_code":"ICW","station_name":"成都东"}' ;;
            重庆北) printf '{"station_code":"CUW","station_name":"重庆北"}' ;;
            西安北) printf '{"station_code":"EAY","station_name":"西安北"}' ;;
            武汉) printf '{"station_code":"WHN","station_name":"武汉"}' ;;
            *) printf '{"error":"未检索到城市。"}' ;;
          esac
        }

        city_json() {
          case "$1" in
            北京) printf '{"station_code":"BJP","station_name":"北京"}' ;;
            上海) printf '{"station_code":"SHH","station_name":"上海"}' ;;
            广州) printf '{"station_code":"GZQ","station_name":"广州"}' ;;
            深圳) printf '{"station_code":"SZQ","station_name":"深圳"}' ;;
            杭州) printf '{"station_code":"HZH","station_name":"杭州"}' ;;
            南京) printf '{"station_code":"NJH","station_name":"南京"}' ;;
            成都) printf '{"station_code":"CDW","station_name":"成都"}' ;;
            重庆) printf '{"station_code":"CQW","station_name":"重庆"}' ;;
            西安) printf '{"station_code":"XAY","station_name":"西安"}' ;;
            武汉) printf '{"station_code":"WHN","station_name":"武汉"}' ;;
            *) printf '{"error":"未检索到城市。"}' ;;
          esac
        }

        station_codes_by_names() {
          names="$1"
          out="{"
          first=1
          oldifs="$IFS"
          IFS='|'
          for name in $names; do
            clean="${name%站}"
            [ "$first" = "1" ] || out="$out,"
            first=0
            out="$out\\"$clean\\":$(station_json_for_name "$clean")"
          done
          IFS="$oldifs"
          out="$out}"
          printf '%s' "$out"
        }

        station_codes_by_citys() {
          citys="$1"
          out="{"
          first=1
          oldifs="$IFS"
          IFS='|'
          for city in $citys; do
            clean="${city%市}"
            [ "$first" = "1" ] || out="$out,"
            first=0
            out="$out\\"$clean\\":$(city_json "$clean")"
          done
          IFS="$oldifs"
          out="$out}"
          printf '%s' "$out"
        }

        live_unavailable_text() {
          tool="$1"
          cat <<EOF
        $tool 当前由 Oases 内置离线 12306 MCP server 响应。站点码和工具发现可离线使用；实时余票/中转/经停需要 12306 网络接口可达。
        offline_mcp=ok
        live_query=unavailable
        next_step=网络可达后重试，或使用 get-station-code-by-names / get-station-code-of-citys 先完成站点解析。
        EOF
        }

        tools_list() {
          id="${1:-3}"
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"get-current-date","description":"获取当前日期，以上海时区为准，返回 yyyy-MM-dd。","inputSchema":{"type":"object","properties":{}}},{"name":"get-stations-code-in-city","description":"通过中文城市名查询该城市火车站名称及 station_code。","inputSchema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}},{"name":"get-station-code-of-citys","description":"通过中文城市名查询代表该城市的 station_code。多个城市用 | 分割。","inputSchema":{"type":"object","properties":{"citys":{"type":"string"}},"required":["citys"]}},{"name":"get-station-code-by-names","description":"通过具体中文车站名查询 station_code。多个站点用 | 分割。","inputSchema":{"type":"object","properties":{"stationNames":{"type":"string"}},"required":["stationNames"]}},{"name":"get-station-by-telecode","description":"通过车站 telecode 查询车站信息。","inputSchema":{"type":"object","properties":{"stationTelecode":{"type":"string"}},"required":["stationTelecode"]}},{"name":"get-tickets","description":"查询 12306 直达余票。实时查询需要网络。","inputSchema":{"type":"object","properties":{"date":{"type":"string"},"fromStation":{"type":"string"},"toStation":{"type":"string"},"trainFilterFlags":{"type":"string"},"format":{"type":"string"}},"required":["date","fromStation","toStation"]}},{"name":"get-interline-tickets","description":"查询 12306 中转余票。实时查询需要网络。","inputSchema":{"type":"object","properties":{"date":{"type":"string"},"fromStation":{"type":"string"},"toStation":{"type":"string"},"middleStation":{"type":"string"},"format":{"type":"string"}},"required":["date","fromStation","toStation"]}},{"name":"get-train-route-stations","description":"查询车次经停信息。实时查询需要网络。","inputSchema":{"type":"object","properties":{"trainCode":{"type":"string"},"departDate":{"type":"string"},"format":{"type":"string"}},"required":["trainCode","departDate"]}}]}}\n' "$id"
        }

        handle_call() {
          line="$1"
          id="${2:-3}"
          name="$(get_field name "$line")"
          case "$name" in
            get-current-date)
              content_response "$id" "$(today_shanghai)"
              ;;
            get-station-code-by-names)
              stationNames="$(get_field stationNames "$line")"
              if [ -z "$stationNames" ]; then
                content_response "$id" '{"error":"stationNames is required"}'
              else
                content_response "$id" "$(station_codes_by_names "$stationNames")"
              fi
              ;;
            get-station-code-of-citys)
              citys="$(get_field citys "$line")"
              if [ -z "$citys" ]; then
                content_response "$id" '{"error":"citys is required"}'
              else
                content_response "$id" "$(station_codes_by_citys "$citys")"
              fi
              ;;
            get-stations-code-in-city)
              city="$(get_field city "$line")"
              if [ -z "$city" ]; then
                content_response "$id" '{"error":"city is required"}'
              else
                content_response "$id" "[$(city_json "${city%市}")]"
              fi
              ;;
            get-station-by-telecode)
              tele="$(get_field stationTelecode "$line")"
              content_response "$id" "{\\"station_code\\":\\"$tele\\",\\"note\\":\\"offline telecode lookup is limited in Oases built-in 12306 MCP\\"}"
              ;;
            get-tickets|get-interline-tickets|get-train-route-stations)
              error_response "$id" -32001 "上游 12306 MCP 未就绪，离线 Oases shim 不提供实时余票、中转或经停查询。请先完成 profile-install 12306 并重试。"
              ;;
            *)
              error_response "$id" -32602 "unknown tool: $name"
              ;;
          esac
        }

        while IFS= read -r line; do
          method="$(printf '%s' "$(get_field method "$line")" | sed 's#\\\\/#/#g')"
          id="$(get_number_field id "$line")"
          [ -n "$id" ] || id=3
          case "$method" in
            initialize)
              send_json "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"protocolVersion\\":\\"2025-06-18\\",\\"capabilities\\":{\\"tools\\":{}},\\"serverInfo\\":{\\"name\\":\\"oases-12306-mcp\\",\\"version\\":\\"1.0.0\\"}}}"
              ;;
            notifications/initialized)
              ;;
            tools/list)
              tools_list "$id"
              ;;
            tools/call)
              handle_call "$line" "$id"
              ;;
            *)
              [ -n "$method" ] && error_response "$id" -32601 "unknown method: $method"
              ;;
          esac
        done
        """
    }

    private static var script: String {
        // i18n-ignore: shell script run inside iSH
        """
        #!/bin/sh
        set -u

        VERSION="\(version)"
        UPSTREAM_12306_PACKAGE="\(upstream12306Package)"
        ROOT="${OGENT_ROOT:-${MINIS_ROOT:-/root/.ogent}}"
        DISPLAY_ROOT="/root/.ogent"
        WORKSPACE="$ROOT/workspace"
        TASK_DIR="$ROOT/tasks"
        MEMORY_DIR="$ROOT/memory"
        WIKI_DIR="$MEMORY_DIR/wiki"
        WIKI_TOPIC_DIR="$WIKI_DIR/topics"
        RAG_INDEX="$MEMORY_DIR/rag.tsv"
        SKILL_DIR="$ROOT/skills"
        SUBAGENT_DIR="$ROOT/subagents"
        AUTOMATION_DIR="$TASK_DIR"
        AUTOMATION_DISPLAY_DIR="$DISPLAY_ROOT/automations"
        INBOX_DIR="$ROOT/inbox"
        ARTIFACT_DIR="$ROOT/artifacts"
        LOG_DIR="$ROOT/logs"
        TMP_DIR="$ROOT/tmp"
        SESSION_DIR="$ROOT/sessions"
        PROJECT_MANIFEST_DIR="$ROOT/project-manifests"
        CHECKPOINT_DIR="$ROOT/checkpoints"
        ENV_DIR="$ROOT/env.d"
        MODEL_DIR="$ROOT/models"
        PROFILE_DIR="$ROOT/rootfs-profiles"
        MCP_DIR="$ROOT/mcp"
        UPSTREAM_12306_DIR="$MCP_DIR/12306-mcp"
        UPSTREAM_12306_BIN="$UPSTREAM_12306_DIR/node_modules/.bin/12306-mcp"
        UPSTREAM_12306_BUNDLE="\(upstream12306BundlePath)"
        MODEL_CONFIG="$MODEL_DIR/config.env"
        MODEL_READINESS="$MODEL_DIR/readiness.env"
        MODEL_LOG="$LOG_DIR/model-runtime.log"
        MODEL_PID="$MODEL_DIR/modeld.pid"
        MODEL_SERVER_SCRIPT="$MODEL_DIR/ogent-local-modeld.py"
        MODEL_NETCAT_SCRIPT="$MODEL_DIR/ogent-local-modeld.sh"
        MODEL_BUILD_LOG="$MODEL_DIR/llama-build.log"
        PLAN_FILE="$ROOT/PLAN.md"
        NOTES_FILE="$ROOT/NOTES.md"
        LATEST_STATUS="$ROOT/LATEST_STATUS"
        CURRENT_SESSION="$ROOT/CURRENT_SESSION"
        CURRENT_PROJECT_MANIFEST="$ROOT/CURRENT_PROJECT_MANIFEST"
        export PATH="$UPSTREAM_12306_DIR/node_modules/.bin:$PATH"

        timestamp() {
          date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date
        }

        safe_name() {
          value="${1:-item}"
          printf '%s' "$value" | tr -c 'A-Za-z0-9_.-' '_' | cut -c 1-80
        }

        count_files() {
          find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
        }

        read_payload() {
          file="${1:-}"
          if [ -n "$file" ] && [ -f "$file" ]; then
            cat "$file"
          fi
        }

        display_path() {
          path="${1:-}"
          case "$path" in
            "$ROOT"*) printf '%s%s' "$DISPLAY_ROOT" "${path#$ROOT}" ;;
            *) printf '%s' "$path" ;;
          esac
        }

        display_automation_path() {
          path="${1:-}"
          case "$path" in
            "$AUTOMATION_DIR"/auto-*) printf '%s/%s' "$AUTOMATION_DISPLAY_DIR" "${path#$AUTOMATION_DIR/}" ;;
            *) display_path "$path" ;;
          esac
        }

        count_automations() {
          find "$AUTOMATION_DIR" -mindepth 2 -maxdepth 2 -name automation.env 2>/dev/null | wc -l | tr -d ' '
        }

        latest_engineering_task_dir() {
          find "$TASK_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while read -r dir; do
            [ -f "$dir/output.log" ] || continue
            [ -f "$dir/automation.env" ] && continue
            case "$(basename "$dir")" in
              auto-*) continue ;;
            esac
            printf '%s\\n' "$dir"
          done | sort | tail -n 1
        }

        log_event() {
          init_runtime
          printf '%s %s\\n' "$(timestamp)" "$*" >> "$LOG_DIR/activity.log"
        }

        init_runtime() {
          ensure_runtime_dir "$ROOT"
          for runtime_dir in "$WORKSPACE" "$TASK_DIR" "$MEMORY_DIR" "$WIKI_DIR" "$WIKI_TOPIC_DIR" "$SKILL_DIR" "$SUBAGENT_DIR" "$INBOX_DIR" "$ARTIFACT_DIR" "$LOG_DIR" "$TMP_DIR" "$SESSION_DIR" "$PROJECT_MANIFEST_DIR" "$CHECKPOINT_DIR" "$ENV_DIR" "$MODEL_DIR" "$PROFILE_DIR" "$MCP_DIR" "$UPSTREAM_12306_DIR"; do
            ensure_runtime_dir "$runtime_dir"
          done
          touch "$LOG_DIR/activity.log" "$NOTES_FILE" "$LATEST_STATUS"
          if [ ! -f "$ROOT/profile" ]; then
            {
              echo "name=Ogent"
              echo "runtime=Alpine Linux on iSH"
              echo "agent=ogent-agent"
              echo "version=$VERSION"
              echo "workspace=$(display_path "$WORKSPACE")"
            } > "$ROOT/profile"
          fi
          if [ ! -f "$ROOT/README.md" ]; then
            {
              echo "# Ogent Linux Agent"
              echo
              echo "This rootfs-local runtime keeps project state under the Ogent workspace."
              echo "It is intentionally shell-first so it runs inside iSH without a server."
            } > "$ROOT/README.md"
          fi
        }

        ensure_runtime_dir() {
          dir="$1"
          if [ -L "$dir" ] && [ ! -d "$dir" ]; then
            rm -f "$dir" 2>/dev/null || true
          fi
          if [ -e "$dir" ] && [ ! -d "$dir" ]; then
            mv "$dir" "$dir.file.$(timestamp)" 2>/dev/null || rm -f "$dir" 2>/dev/null || true
          fi
          mkdir -p "$dir" 2>/dev/null || true
        }

        available_tools() {
          for tool in sh awk sed grep find xargs tar gzip apk wget curl git python3 pip3 node npm vi sqlite3 timeout cmake make gcc g++ c++; do
            if command -v "$tool" >/dev/null 2>&1; then
              printf '%s ' "$tool"
            fi
          done
          printf '\\n'
        }

        profile_packages() {
          profile="${1:-core}"
          case "$profile" in
            core)
              echo "ca-certificates curl wget git python3 py3-pip zip unzip jq sqlite"
              ;;
            mcp|mcp-stdio)
              echo "ca-certificates curl nodejs npm"
              ;;
            12306)
              echo "ca-certificates curl nodejs"
              ;;
            media)
              echo "ca-certificates curl wget python3 py3-pip ffmpeg"
              ;;
            document|artifacts)
              echo "python3 py3-pip zip unzip"
              ;;
            local-model|local_model)
              echo "ca-certificates curl python3 py3-pip git build-base cmake linux-headers"
              ;;
            all)
              echo "ca-certificates curl wget git python3 py3-pip nodejs npm zip unzip jq sqlite ffmpeg"
              ;;
            *)
              echo "ca-certificates curl wget git python3 py3-pip nodejs npm zip unzip jq sqlite"
              ;;
          esac
        }

        profile_commands() {
          profile="${1:-core}"
          case "$profile" in
            core)
              echo "sh curl wget git python3 pip3 zip unzip jq sqlite3"
              ;;
            mcp|mcp-stdio)
              echo "sh curl node npm npx"
              ;;
            12306)
              echo "sh curl node"
              ;;
            media)
              echo "sh curl wget python3 pip3 ffmpeg"
              ;;
            document|artifacts)
              echo "sh python3 pip3 zip unzip"
              ;;
            local-model|local_model)
              echo "sh curl python3 git cmake make g++"
              ;;
            all)
              echo "sh curl wget git python3 pip3 node npm npx zip unzip jq sqlite3 ffmpeg"
              ;;
            *)
              echo "sh curl wget git python3 pip3 node npm npx zip unzip jq sqlite3"
              ;;
          esac
        }

        upstream_12306_bin() {
          if [ -x "$UPSTREAM_12306_BIN" ]; then
            printf '%s\\n' "$UPSTREAM_12306_BIN"
            return 0
          fi
          if command -v 12306-mcp >/dev/null 2>&1; then
            command -v 12306-mcp
            return 0
          fi
          return 1
        }

        upstream_12306_bundle_path() {
          if [ -f "$UPSTREAM_12306_BUNDLE" ]; then
            printf '%s\\n' "$UPSTREAM_12306_BUNDLE"
            return 0
          fi
          return 1
        }

        upstream_12306_bundle() {
          if command -v node >/dev/null 2>&1; then
            upstream_12306_bundle_path
            return $?
          fi
          return 1
        }

        upstream_12306_version() {
          if upstream_bundle="$(upstream_12306_bundle_path 2>/dev/null)"; then
            printf '%s\\n' "\(upstream12306Version)"
            return 0
          fi
          package_json="$UPSTREAM_12306_DIR/node_modules/12306-mcp/package.json"
          if [ -f "$package_json" ] && command -v node >/dev/null 2>&1; then
            version="$(node -e 'const fs=require("fs"); try { const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); process.stdout.write(p.version || "unknown") } catch (_) { process.stdout.write("unknown") }' "$package_json" 2>/dev/null || true)"
            [ -n "$version" ] && { printf '%s\\n' "$version"; return 0; }
          fi
          if command -v npm >/dev/null 2>&1; then
            version="$(npm list --prefix "$UPSTREAM_12306_DIR" --depth=0 12306-mcp 2>/dev/null | sed -n 's/.*12306-mcp@//p' | sed -n '1p')"
            [ -n "$version" ] && { printf '%s\\n' "$version"; return 0; }
            version="$(npm list -g --depth=0 12306-mcp 2>/dev/null | sed -n 's/.*12306-mcp@//p' | sed -n '1p')"
            [ -n "$version" ] && { printf '%s\\n' "$version"; return 0; }
          fi
          printf '%s\\n' "unknown"
        }

        profile_status() {
          init_runtime
          profile="${1:-core}"
          packages="$(profile_packages "$profile")"
          commands="$(profile_commands "$profile")"
          missing_packages=""
          missing_commands=""
          missing_runtime=""
          echo "profile_status profile=$profile"
          echo "packages=$packages"
          for pkg in $packages; do
            if command -v apk >/dev/null 2>&1 && apk info -e "$pkg" >/dev/null 2>&1; then
              echo "package:$pkg=installed"
            else
              echo "package:$pkg=missing"
              missing_packages="$missing_packages $pkg"
            fi
          done
          echo "commands=$commands"
          for cmd in $commands; do
            if command -v "$cmd" >/dev/null 2>&1; then
              echo "command:$cmd=$(command -v "$cmd")"
            else
              echo "command:$cmd=missing"
              missing_commands="$missing_commands $cmd"
            fi
          done
          case "$profile" in
            12306)
              upstream_package="$(pinned_12306_package)"
              if upstream_bin="$(upstream_12306_bin 2>/dev/null)"; then
                upstream_version="$(upstream_12306_version 2>/dev/null)"
                echo "mcp_12306_upstream=available command=$upstream_bin package=$upstream_package version=${upstream_version:-unknown} install_dir=$(display_path "$UPSTREAM_12306_DIR")"
              elif upstream_bundle="$(upstream_12306_bundle 2>/dev/null)"; then
                upstream_version="$(upstream_12306_version 2>/dev/null)"
                echo "mcp_12306_upstream=available command=node bundle=$upstream_bundle package=$upstream_package version=${upstream_version:-unknown} source=bundled"
              elif upstream_bundle="$(upstream_12306_bundle_path 2>/dev/null)"; then
                upstream_version="$(upstream_12306_version 2>/dev/null)"
                echo "mcp_12306_bundle=present path=$upstream_bundle package=$upstream_package version=${upstream_version:-unknown} source=bundled"
                echo "mcp_12306_upstream=missing reason=nodejs_missing package=$upstream_package source=https://github.com/Joooook/12306-mcp"
                missing_runtime="12306_node_runtime"
              else
                echo "mcp_12306_bundle=missing path=\(upstream12306BundlePath) package=$upstream_package source=https://github.com/Joooook/12306-mcp"
                echo "mcp_12306_upstream=missing reason=bundle_missing package=$upstream_package source=https://github.com/Joooook/12306-mcp"
              fi
              if [ -x /usr/local/bin/ogent-agent ] || [ -x /usr/local/bin/oases-12306-mcp ]; then
                echo "mcp_12306_shim=available"
              else
                echo "mcp_12306_shim=missing"
                missing_runtime="12306_mcp_server"
              fi
              ;;
            local-model|local_model)
              if find_llama_server >/dev/null 2>&1; then
                echo "llama_server=available path=$(display_path "$(find_llama_server 2>/dev/null)")"
              else
                echo "llama_server=missing note=install llama.cpp llama-server manually into /root/.ogent/bin or /root/.ogent/models/bin"
              fi
              if ! model_real_readiness; then
                missing_runtime="real_local_model_runtime"
              fi
              ;;
          esac
          if [ -z "$(printf '%s%s' "$missing_packages" "$missing_commands" | tr -d ' ')" ]; then
            echo "profile_dependencies=ok profile=$profile"
            echo "profile_install_needed=0"
          else
            echo "profile_dependencies=missing profile=$profile"
            echo "profile_install_needed=1"
          fi
          if [ -z "$(printf '%s%s%s' "$missing_packages" "$missing_commands" "$missing_runtime" | tr -d ' ')" ]; then
            echo "profile_status=ok profile=$profile"
          else
            echo "profile_status=missing profile=$profile missing_packages=$(printf '%s' "$missing_packages" | xargs 2>/dev/null || printf '%s' "$missing_packages") missing_commands=$(printf '%s' "$missing_commands" | xargs 2>/dev/null || printf '%s' "$missing_commands") missing_runtime=${missing_runtime:-none}"
          fi
        }

        profile_status_line() {
          init_runtime
          profile="${1:-core}"
          tmp="$TMP_DIR/profile-status-$(safe_name "$profile").$$.txt"
          profile_status "$profile" > "$tmp" 2>&1 || true
          tail -n 1 "$tmp" 2>/dev/null || echo "profile_status=missing profile=$profile"
          rm -f "$tmp" 2>/dev/null || true
        }

        alpine_repo_version() {
          if [ -f /etc/apk/repositories ]; then
            version="$(grep -Eo 'v[0-9]+\\.[0-9]+' /etc/apk/repositories 2>/dev/null | sed -n '1p')"
            if [ -n "$version" ]; then
              echo "$version"
              return 0
            fi
          fi
          if [ -f /etc/alpine-release ]; then
            version="$(sed -n '1p' /etc/alpine-release | sed -E 's/^([0-9]+\\.[0-9]+).*/v\\1/')"
            if [ -n "$version" ]; then
              echo "$version"
              return 0
            fi
          fi
          echo "v3.21"
        }

        write_apk_repositories() {
          base="$1"
          version="$(alpine_repo_version)"
          {
            echo "$base/$version/main"
            echo "$base/$version/community"
          } > /etc/apk/repositories
        }

        apk_update_and_add() {
          packages="$1"
          update_limit="${OASES_APK_UPDATE_TIMEOUT:-45}"
          add_limit="${OASES_APK_ADD_TIMEOUT:-120}"
          run_with_deadline() {
            limit="$1"
            shift
            "$@" &
            child="$!"
            elapsed=0
            while kill -0 "$child" 2>/dev/null; do
              if [ "$elapsed" -ge "$limit" ]; then
                kill -TERM "$child" >/dev/null 2>&1 || true
                sleep 1
                kill -KILL "$child" >/dev/null 2>&1 || true
                wait "$child" >/dev/null 2>&1 || true
                return 124
              fi
              sleep 1
              elapsed=$((elapsed + 1))
            done
            wait "$child"
          }
          if command -v timeout >/dev/null 2>&1; then
            timeout "$update_limit" apk update && timeout "$add_limit" apk add --no-cache $packages
          else
            run_with_deadline "$update_limit" apk update && run_with_deadline "$add_limit" apk add --no-cache $packages
          fi
        }

        # npm spec for the upstream 12306 MCP. OASES_12306_MCP_PACKAGE may
        # override it only with an exact version (name@x.y.z); ranges, tags or
        # a bare name fall back to the pinned default, so npm install / npx -y
        # never pull whatever version is latest.
        pinned_12306_package() {
          spec="${OASES_12306_MCP_PACKAGE:-}"
          version=""
          case "$spec" in
            ?*@*) version="${spec##*@}" ;;
          esac
          case "$version" in
            ''|*[!0-9.]*|.*|*.|*..*) printf '%s' "$UPSTREAM_12306_PACKAGE" ;;
            *.*.*) printf '%s' "$spec" ;;
            *) printf '%s' "$UPSTREAM_12306_PACKAGE" ;;
          esac
        }

        npm_install_12306_mcp() {
          registry="${1:-}"
          package_spec="$(pinned_12306_package)"
          limit="${OASES_12306_MCP_INSTALL_TIMEOUT:-120}"
          install_dir="$UPSTREAM_12306_DIR"
          mkdir -p "$install_dir" 2>/dev/null || return 1
          (
            if [ -n "$registry" ]; then
              npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false npm_config_fetch_retries=1 npm_config_fetch_timeout=15000 npm --registry="$registry" install --prefix "$install_dir" --no-save --no-package-lock "$package_spec"
            else
              npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false npm_config_fetch_retries=1 npm_config_fetch_timeout=15000 npm install --prefix "$install_dir" --no-save --no-package-lock "$package_spec"
            fi
          ) &
          child="$!"
          elapsed=0
          while kill -0 "$child" 2>/dev/null; do
            if [ "$elapsed" -ge "$limit" ]; then
              kill "$child" >/dev/null 2>&1 || true
              wait "$child" >/dev/null 2>&1 || true
              echo "profile_install=12306_upstream_timeout seconds=$limit"
              return 124
            fi
            sleep 1
            elapsed=$((elapsed + 1))
          done
          wait "$child"
        }

        ensure_12306_mcp_upstream() {
          if upstream_bin="$(upstream_12306_bin 2>/dev/null)"; then
            echo "profile_install=12306_upstream_present command=$upstream_bin install_dir=$(display_path "$UPSTREAM_12306_DIR")"
            return 0
          fi
          if upstream_bundle="$(upstream_12306_bundle 2>/dev/null)"; then
            echo "profile_install=12306_upstream_bundled command=node bundle=$upstream_bundle version=\(upstream12306Version)"
            return 0
          fi
          if upstream_bundle="$(upstream_12306_bundle_path 2>/dev/null)"; then
            echo "profile_install=12306_upstream_blocked reason=nodejs_missing bundle=$upstream_bundle version=\(upstream12306Version)"
            return 1
          fi
          if ! command -v npm >/dev/null 2>&1; then
            echo "profile_install=12306_upstream_skipped reason=npm_unavailable"
            return 1
          fi
          echo "profile_install=12306_upstream_install package=$(pinned_12306_package) source=https://github.com/Joooook/12306-mcp install_dir=$(display_path "$UPSTREAM_12306_DIR")"
          if npm_install_12306_mcp ""; then
            :
          else
            echo "profile_install=12306_upstream_default_registry_failed"
            npm_install_12306_mcp "https://registry.npmmirror.com" || true
          fi
          if upstream_bin="$(upstream_12306_bin 2>/dev/null)"; then
            echo "profile_install=12306_upstream_ok command=$upstream_bin install_dir=$(display_path "$UPSTREAM_12306_DIR") version=$(upstream_12306_version 2>/dev/null || echo unknown)"
            return 0
          fi
          echo "profile_install=12306_upstream_failed fallback=oases_shim"
          return 1
        }

        ensure_dns_resolver() {
          if [ ! -f /etc/resolv.conf ] || ! grep -q '^nameserver ' /etc/resolv.conf 2>/dev/null; then
            {
              echo "nameserver 223.5.5.5"
              echo "nameserver 8.8.8.8"
              echo "nameserver 1.1.1.1"
            } > /etc/resolv.conf 2>/dev/null || true
            echo "profile_install=dns_resolver_written"
          fi
        }

        profile_install() {
          init_runtime
          profile="${1:-core}"
          packages="$(profile_packages "$profile")"
          profile_limit="${OASES_PROFILE_INSTALL_TIMEOUT:-240}"
          profile_started="$(date +%s 2>/dev/null || echo 0)"
          profile_deadline_reached() {
            now="$(date +%s 2>/dev/null || echo 0)"
            if [ "$profile_started" -gt 0 ] && [ "$now" -gt 0 ] && [ $((now - profile_started)) -ge "$profile_limit" ]; then
              echo "profile_install=timeout profile=$profile seconds=$profile_limit"
              return 0
            fi
            return 1
          }
          if ! command -v apk >/dev/null 2>&1; then
            echo "profile_install=failed profile=$profile reason=apk_unavailable"
            return 69
          fi
          ensure_dns_resolver
          if [ "$profile" = "12306" ] && command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 && command -v npx >/dev/null 2>&1; then
            echo "profile_install=start profile=$profile packages=$packages mode=fast"
            ensure_12306_mcp_upstream || true
            init_runtime
            mkdir -p "$ROOT" "$PROFILE_DIR" 2>/dev/null || true
            {
              echo "profile=$profile"
              echo "packages=$packages"
              echo "installed_at=$(timestamp)"
            } > "$PROFILE_DIR/${profile}.env" 2>/dev/null || true
            log_event "profile_install profile=$profile mode=fast"
            profile_status "$profile"
            echo "profile_install=ok profile=$profile"
            find "$ENV_DIR" -maxdepth 1 -type f 2>/dev/null | sort | while read -r file; do
              key="$(basename "$file")"
              bytes="$(wc -c < "$file" | tr -d ' ')"
              echo "$key=*** ($bytes bytes)"
            done
            return 0
          fi
          echo "profile_install=start profile=$profile packages=$packages"
          repo_backup=""
          if [ -f /etc/apk/repositories ]; then
            repo_backup="$TMP_DIR/apk-repositories.$(date +%s 2>/dev/null || echo now).bak"
            cp /etc/apk/repositories "$repo_backup" 2>/dev/null || repo_backup=""
          fi
          install_ok=0
          if profile_deadline_reached; then
            return 124
          elif apk_update_and_add "$packages"; then
            install_ok=1
          else
            echo "profile_install=default_repo_failed profile=$profile"
            for mirror in \
              "http://mirrors.tuna.tsinghua.edu.cn/alpine" \
              "http://mirrors.ustc.edu.cn/alpine" \
              "http://mirrors.aliyun.com/alpine" \
              "http://dl-cdn.alpinelinux.org/alpine" \
              "https://mirrors.tuna.tsinghua.edu.cn/alpine" \
              "https://mirrors.ustc.edu.cn/alpine" \
              "https://mirrors.aliyun.com/alpine" \
              "https://dl-cdn.alpinelinux.org/alpine"; do
              if profile_deadline_reached; then
                break
              fi
              echo "profile_install=try_mirror profile=$profile mirror=$mirror version=$(alpine_repo_version)"
              write_apk_repositories "$mirror"
              if apk_update_and_add "$packages"; then
                echo "profile_install=mirror_ok profile=$profile mirror=$mirror"
                install_ok=1
                break
              fi
            done
          fi
          if [ "$install_ok" = "1" ]; then
            case "$profile" in
              12306) ensure_12306_mcp_upstream || true ;;
            esac
            init_runtime
            mkdir -p "$ROOT" "$PROFILE_DIR" 2>/dev/null || true
            {
              echo "profile=$profile"
              echo "packages=$packages"
              echo "installed_at=$(timestamp)"
            } > "$PROFILE_DIR/${profile}.env"
            log_event "profile_install profile=$profile"
            profile_status "$profile"
            echo "profile_install=ok profile=$profile"
          else
            if [ -n "$repo_backup" ] && [ -f "$repo_backup" ]; then
              cp "$repo_backup" /etc/apk/repositories 2>/dev/null || true
            fi
            echo "profile_install=failed profile=$profile"
            return 70
          fi
        }

        current_session_id() {
          if [ -f "$CURRENT_SESSION" ]; then
            sed -n '1p' "$CURRENT_SESSION"
          else
            printf 'none\\n'
          fi
        }

        rootfs_overlay_line() {
          overlay_version="missing"
          overlay_marker="missing"
          profile_hook="missing"
          motd="missing"
          if [ -f /ish/overlay-version ]; then
            overlay_version="$(sed -n '1p' /ish/overlay-version 2>/dev/null | tr -d '[:space:]')"
            [ -n "$overlay_version" ] || overlay_version="empty"
          fi
          if [ -f /etc/oases-rootfs-overlay ]; then
            overlay_marker="$(sed -n 's/^oases-rootfs-overlay-version=//p' /etc/oases-rootfs-overlay 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
            [ -n "$overlay_marker" ] || overlay_marker="present"
          fi
          if [ -f /etc/profile.d/oases-ogent.sh ]; then
            if grep -q 'OGENT_ROOT' /etc/profile.d/oases-ogent.sh 2>/dev/null; then
              profile_hook="ok"
            else
              profile_hook="present"
            fi
          fi
          [ -f /etc/motd ] && motd="present"
          if [ "$overlay_version" != "missing" ] && [ "$overlay_marker" != "missing" ] && [ "$profile_hook" != "missing" ]; then
            echo "rootfs_overlay=ok version=$overlay_version marker=$overlay_marker profile_hook=$profile_hook motd=$motd"
          else
            echo "rootfs_overlay=missing version=$overlay_version marker=$overlay_marker profile_hook=$profile_hook motd=$motd"
          fi
        }

        rootfs_overlay_status() {
          init_runtime
          echo "rootfs_overlay_status_start version=$VERSION"
          rootfs_overlay_line
          echo "overlay_version_file=/ish/overlay-version"
          if [ -f /ish/overlay-version ]; then
            echo "overlay_version_value=$(sed -n '1p' /ish/overlay-version 2>/dev/null | tr -d '[:space:]')"
          else
            echo "overlay_version_value=missing"
          fi
          echo "overlay_manifest=/etc/oases-rootfs-overlay"
          if [ -f /etc/oases-rootfs-overlay ]; then
            sed -n '1,40p' /etc/oases-rootfs-overlay
          else
            echo "overlay_manifest=missing"
          fi
          if [ -f /etc/profile.d/oases-ogent.sh ]; then
            echo "profile_hook=/etc/profile.d/oases-ogent.sh"
            grep -E '^(export )?(OGENT_ROOT|MINIS_ROOT|PATH|PAGER|EDITOR|PS1)=' /etc/profile.d/oases-ogent.sh 2>/dev/null | sed -n '1,20p'
          else
            echo "profile_hook=missing"
          fi
          echo "rootfs_overlay_status_ok"
        }

        status_runtime() {
          init_runtime
          echo "Ogent Agent Runtime $VERSION"
          echo "mode=local-linux-ish"
          echo "pattern=device-local-agent-runtime"
          echo "root=$(display_path "$ROOT")"
          echo "workspace=$(display_path "$WORKSPACE")"
          echo "shell=/bin/sh"
          echo "user=$(whoami 2>/dev/null || echo root)"
          echo "kernel=$(uname -a 2>/dev/null || echo unknown)"
          rootfs_overlay_line
          echo "current_session=$(current_session_id)"
          echo "current_project=$(current_project_manifest_id)"
          echo "tools=$(available_tools)"
          echo "tasks=$(count_files "$TASK_DIR")"
          echo "sessions=$(count_files "$SESSION_DIR")"
          echo "project_manifests=$(count_files "$PROJECT_MANIFEST_DIR")"
          echo "checkpoints=$(count_files "$CHECKPOINT_DIR")"
          echo "memory=$(count_files "$MEMORY_DIR")"
          echo "wiki_topic_pages=$(find "$WIKI_TOPIC_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
          if [ -f "$RAG_INDEX" ]; then
            echo "rag_chunks=$(wc -l < "$RAG_INDEX" 2>/dev/null | tr -d ' ')"
          else
            echo "rag_chunks=0"
          fi
          echo "skills=$(count_files "$SKILL_DIR")"
          echo "subagents=$(count_files "$SUBAGENT_DIR")"
          echo "automations=$(count_automations)"
          echo "profiles=$(find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.env' 2>/dev/null | wc -l | tr -d ' ')"
          echo "inbox=$(count_files "$INBOX_DIR")"
          echo "artifacts=$(count_files "$ARTIFACT_DIR")"
          if [ -f "$PLAN_FILE" ]; then
            echo "plan=$(display_path "$PLAN_FILE")"
          else
            echo "plan=not-created"
          fi
        }

        rootfs_doctor() {
          init_runtime
          echo "rootfs_doctor_start version=$VERSION"
          echo "mode=local-linux-ish"
          echo "agent=$(command -v ogent-agent 2>/dev/null || echo /usr/local/bin/ogent-agent)"
          if [ -x /usr/local/bin/ogent-agent ]; then
            echo "agent_executable=ok"
          else
            echo "agent_executable=missing"
          fi
          echo "root=$(display_path "$ROOT")"
          echo "workspace=$(display_path "$WORKSPACE")"
          echo "artifacts=$(display_path "$ARTIFACT_DIR")"
          echo "sessions=$(display_path "$SESSION_DIR")"
          echo "project_manifests=$(display_path "$PROJECT_MANIFEST_DIR")"
          echo "memory=$(display_path "$MEMORY_DIR")"
          echo "profiles_dir=$(display_path "$PROFILE_DIR")"
          rootfs_overlay_line
          rootfs_overlay_status | sed -n '1,80p'
          for dir in "$ROOT" "$WORKSPACE" "$ARTIFACT_DIR" "$SESSION_DIR" "$PROJECT_MANIFEST_DIR" "$MEMORY_DIR" "$WIKI_TOPIC_DIR" "$SKILL_DIR" "$SUBAGENT_DIR" "$CHECKPOINT_DIR" "$ENV_DIR" "$PROFILE_DIR"; do
            if [ -d "$dir" ]; then
              echo "dir:$(display_path "$dir")=ok"
            else
              echo "dir:$(display_path "$dir")=missing"
            fi
          done
          echo "shell=/bin/sh"
          echo "apk=$(command -v apk 2>/dev/null || echo missing)"
          echo "tools=$(available_tools)"
          echo "--- profile summary ---"
          core_line="$(profile_status_line core)"
          echo "core=$core_line"
          echo "mcp=$(profile_status_line mcp)"
          echo "12306=$(profile_status_line 12306)"
          echo "document=$(profile_status_line document)"
          missing_dirs="$(for dir in "$ROOT" "$WORKSPACE" "$ARTIFACT_DIR" "$SESSION_DIR" "$PROJECT_MANIFEST_DIR" "$MEMORY_DIR" "$PROFILE_DIR"; do [ -d "$dir" ] || printf '%s ' "$(display_path "$dir")"; done)"
          if [ -x /usr/local/bin/ogent-agent ] && [ -z "$(printf '%s' "$missing_dirs" | tr -d ' ')" ]; then
            echo "rootfs_doctor_structure_ok"
          else
            echo "rootfs_doctor_structure_missing missing_dirs=$(printf '%s' "$missing_dirs" | xargs 2>/dev/null || printf '%s' "$missing_dirs")"
          fi
          if [ -x /usr/local/bin/ogent-agent ] && printf '%s\n' "$core_line" | grep -q 'profile_status=ok profile=core' && [ -z "$(printf '%s' "$missing_dirs" | tr -d ' ')" ]; then
            echo "rootfs_doctor_status=ok"
            echo "rootfs_doctor_ok"
          else
            echo "rootfs_doctor_status=repair_needed missing_dirs=$(printf '%s' "$missing_dirs" | xargs 2>/dev/null || printf '%s' "$missing_dirs") core=$core_line"
          fi
        }

        rootfs_repair() {
          check_only="0"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --check-only) check_only="1"; shift ;;
              *) shift ;;
            esac
          done
          init_runtime
          echo "rootfs_repair_start version=$VERSION check_only=$check_only"
          if [ -f /usr/local/bin/ogent-agent ]; then
            chmod +x /usr/local/bin/ogent-agent 2>/dev/null || true
          fi
          ensure_dns_resolver
          before="$(profile_status_line core)"
          echo "rootfs_repair_before=$before"
          if [ "$check_only" != "1" ] && ! printf '%s\n' "$before" | grep -q 'profile_status=ok profile=core'; then
            echo "rootfs_repair=install_core_profile"
            if profile_install core; then
              echo "rootfs_repair=install_core_profile_ok"
            else
              install_status="$?"
              echo "rootfs_repair=install_core_profile_deferred status=$install_status"
            fi
          fi
          after="$(profile_status_line core)"
          echo "rootfs_repair_after=$after"
          log_event "rootfs_repair check_only=$check_only status=$after"
          missing_dirs="$(for dir in "$ROOT" "$WORKSPACE" "$ARTIFACT_DIR" "$SESSION_DIR" "$PROJECT_MANIFEST_DIR" "$MEMORY_DIR" "$PROFILE_DIR"; do [ -d "$dir" ] || printf '%s ' "$(display_path "$dir")"; done)"
          if [ -x /usr/local/bin/ogent-agent ] && printf '%s\n' "$after" | grep -q 'profile_status=ok profile=core'; then
            echo "rootfs_repair_status=ok"
            echo "rootfs_repair_ok"
          elif [ -x /usr/local/bin/ogent-agent ] && [ -z "$(printf '%s' "$missing_dirs" | tr -d ' ')" ]; then
            echo "rootfs_repair_status=partial profile=$after"
            echo "rootfs_repair_ok"
          else
            echo "rootfs_repair_status=failed missing_dirs=$(printf '%s' "$missing_dirs" | xargs 2>/dev/null || printf '%s' "$missing_dirs")"
          fi
        }

        plan_write() {
          init_runtime
          title="工程计划"
          payload_file=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --title) title="${2:-工程计划}"; shift 2 ;;
              --file) payload_file="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          body="$(read_payload "$payload_file")"
          {
            echo "# $title"
            echo
            if [ -n "$body" ]; then
              printf '%s\\n' "$body"
            else
              echo "- [ ] 1. Define the next concrete step"
            fi
            echo
            echo "_updated_at=$(timestamp)_"
          } > "$PLAN_FILE"
          log_event "plan_write title=$(safe_name "$title")"
          echo "plan saved -> $(display_path "$PLAN_FILE")"
        }

        plan_read() {
          init_runtime
          if [ ! -f "$PLAN_FILE" ]; then
            echo "no plan yet. call plan-write first."
            exit 0
          fi
          cat "$PLAN_FILE"
        }

        note_append() {
          init_runtime
          payload_file=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --file) payload_file="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          note="$(read_payload "$payload_file")"
          if [ -z "$note" ]; then
            echo "usage: ogent-agent note-append --file <payload>"
            exit 64
          fi
          {
            echo
            echo "## $(timestamp)"
            printf '%s\\n' "$note"
          } >> "$NOTES_FILE"
          log_event "note_append"
          echo "note appended -> $(display_path "$NOTES_FILE")"
        }

        inbox_add() {
          init_runtime
          payload_file=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --file) payload_file="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          message="$(read_payload "$payload_file")"
          if [ -z "$message" ]; then
            echo "usage: ogent-agent inbox-add --file <payload>"
            exit 64
          fi
          id="$(date +%Y%m%d%H%M%S 2>/dev/null)-$$"
          file="$INBOX_DIR/$id.md"
          {
            echo "# Inbox $id"
            echo
            echo "received_at=$(timestamp)"
            echo
            printf '%s\\n' "$message"
          } > "$file"
          log_event "inbox_add id=$id"
          echo "message queued -> $(display_path "$file")"
        }

        inbox_read() {
          init_runtime
          if [ "$(count_files "$INBOX_DIR")" = "0" ]; then
            echo "inbox empty"
            exit 0
          fi
          find "$INBOX_DIR" -maxdepth 1 -type f 2>/dev/null | sort | tail -n 20 | while read -r file; do
            echo "--- $(display_path "$file") ---"
            sed -n '1,80p' "$file"
          done
        }

        session_start() {
          init_runtime
          title="工程会话"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --title) title="${2:-工程会话}"; shift 2 ;;
              *) shift ;;
            esac
          done
          # Include the guest shell pid so two sessions started in the same
          # second with the same title cannot overwrite the current pointer.
          sid="$(date +%Y%m%d%H%M%S 2>/dev/null)-$$-$(safe_name "$title")"
          dir="$SESSION_DIR/$sid"
          mkdir -p "$dir"
          {
            echo "session_id=$sid"
            echo "title=$title"
            echo "started_at=$(timestamp)"
            echo "workspace=$(display_path "$WORKSPACE")"
          } > "$dir/session.env"
          {
            echo "# Session $sid"
            echo
            echo "title=$title"
            echo "started_at=$(timestamp)"
          } > "$dir/transcript.md"
          printf '%s\\n' "$sid" > "$CURRENT_SESSION"
          log_event "session_start id=$sid title=$(safe_name "$title")"
          echo "session started -> $sid"
        }

        session_note() {
          init_runtime
          sid="$(current_session_id)"
          payload_file=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --id) sid="${2:-$sid}"; shift 2 ;;
              --file) payload_file="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          if [ "$sid" = "none" ]; then
            session_start --title "auto"
            sid="$(current_session_id)"
          fi
          note="$(read_payload "$payload_file")"
          dir="$SESSION_DIR/$sid"
          mkdir -p "$dir"
          {
            echo
            echo "## $(timestamp)"
            printf '%s\\n' "$note"
          } >> "$dir/transcript.md"
          log_event "session_note id=$sid"
          echo "session note appended -> $sid"
        }

        session_read() {
          init_runtime
          sid="$(current_session_id)"
          tail_lines=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --id) sid="${2:-$sid}"; shift 2 ;;
              --tail) tail_lines="${2:-180}"; shift 2 ;;
              *) shift ;;
            esac
          done
          if [ "$sid" = "none" ]; then
            echo "no active session"
            exit 0
          fi
          file="$SESSION_DIR/$sid/transcript.md"
          if [ ! -f "$file" ]; then
            echo "session not found: $sid"
            exit 66
          fi
          if [ -n "$tail_lines" ]; then
            tail -n "$tail_lines" "$file" 2>/dev/null || sed -n '1,180p' "$file"
          else
            sed -n '1,180p' "$file"
          fi
        }

        current_project_manifest_id() {
          if [ -f "$CURRENT_PROJECT_MANIFEST" ]; then
            sed -n '1p' "$CURRENT_PROJECT_MANIFEST"
          else
            printf 'none\\n'
          fi
        }

        manifest_set_key() {
          file="$1"
          key="$2"
          value="$3"
          tmp="$TMP_DIR/manifest.$$.tmp"
          if [ -f "$file" ]; then
            awk -v k="$key" -v v="$value" 'BEGIN{found=0} index($0,k"=")==1 {print k"="v; found=1; next} {print} END{if(found==0) print k"="v}' "$file" > "$tmp" 2>/dev/null && mv "$tmp" "$file"
          else
            printf '%s=%s\\n' "$key" "$value" > "$file"
          fi
        }

        project_manifest_start() {
          init_runtime
          title="工程任务"
          sid="$(current_session_id)"
          payload_file=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --title) title="${2:-工程任务}"; shift 2 ;;
              --session-id) sid="${2:-$sid}"; shift 2 ;;
              --file) payload_file="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          [ -n "$sid" ] || sid="$(current_session_id)"
          pid="$(date +%Y%m%d%H%M%S 2>/dev/null)-$(safe_name "$title")"
          dir="$PROJECT_MANIFEST_DIR/$pid"
          mkdir -p "$dir"
          body="$(read_payload "$payload_file")"
          {
            echo "project_id=$pid"
            echo "session_id=$sid"
            echo "title=$title"
            echo "status=running"
            echo "started_at=$(timestamp)"
            echo "updated_at=$(timestamp)"
            echo "workspace=$(display_path "$WORKSPACE")"
            echo "artifacts=$(display_path "$ARTIFACT_DIR")"
          } > "$dir/manifest.env"
          {
            echo "# Project Manifest $pid"
            echo
            echo "project_id=$pid"
            echo "session_id=$sid"
            echo "title=$title"
            echo "created_at=$(timestamp)"
            echo
            printf '%s\\n' "$body"
          } > "$dir/context.md"
          {
            echo "# Events"
            echo
            echo "- $(timestamp) event=start status=running session=$sid"
          } > "$dir/events.md"
          printf '%s\\n' "$pid" > "$CURRENT_PROJECT_MANIFEST"
          log_event "project_manifest_start id=$pid session=$sid title=$(safe_name "$title")"
          echo "project_manifest_start_ok"
          echo "project_id=$pid"
          echo "session_id=$sid"
          echo "project_manifest=$(display_path "$dir")"
        }

        project_manifest_update() {
          init_runtime
          pid="$(current_project_manifest_id)"
          status=""
          event="update"
          payload_file=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --id) pid="${2:-$pid}"; shift 2 ;;
              --status) status="${2:-}"; shift 2 ;;
              --event) event="${2:-update}"; shift 2 ;;
              --file) payload_file="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          if [ -z "$pid" ] || [ "$pid" = "none" ]; then
            echo "project_manifest_update_failed reason=no_current_project"
            exit 66
          fi
          dir="$PROJECT_MANIFEST_DIR/$pid"
          mkdir -p "$dir"
          env_file="$dir/manifest.env"
          [ -f "$env_file" ] || {
            echo "project_id=$pid"
            echo "status=unknown"
            echo "created_at=$(timestamp)"
          } > "$env_file"
          [ -n "$status" ] && manifest_set_key "$env_file" status "$status"
          manifest_set_key "$env_file" updated_at "$(timestamp)"
          body="$(read_payload "$payload_file")"
          {
            echo
            echo "## $(timestamp)"
            echo "event=$event"
            [ -n "$status" ] && echo "status=$status"
            [ -n "$body" ] && printf '%s\\n' "$body"
          } >> "$dir/events.md"
          log_event "project_manifest_update id=$pid event=$(safe_name "$event") status=$(safe_name "$status")"
          echo "project_manifest_update_ok"
          echo "project_id=$pid"
          [ -n "$status" ] && echo "status=$status"
        }

        project_manifest_read() {
          init_runtime
          pid="$(current_project_manifest_id)"
          tail_lines="120"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --id) pid="${2:-$pid}"; shift 2 ;;
              --tail) tail_lines="${2:-120}"; shift 2 ;;
              *) shift ;;
            esac
          done
          echo "project_manifest_ok"
          if [ -z "$pid" ] || [ "$pid" = "none" ]; then
            echo "project_manifest=none"
            exit 0
          fi
          dir="$PROJECT_MANIFEST_DIR/$pid"
          if [ ! -d "$dir" ]; then
            echo "project_manifest_missing id=$pid"
            exit 66
          fi
          echo "project_id=$pid"
          echo "project_manifest=$(display_path "$dir")"
          echo
          echo "--- manifest env ---"
          sed -n '1,120p' "$dir/manifest.env" 2>/dev/null || true
          echo
          echo "--- context ---"
          sed -n '1,120p' "$dir/context.md" 2>/dev/null || true
          echo
          echo "--- events ---"
          tail -n "$tail_lines" "$dir/events.md" 2>/dev/null || true
          echo
          echo "--- artifact manifest ---"
          artifact_manifest | sed -n '1,120p'
        }

        run_task() {
          init_runtime
          title="工程任务"
          script_file=""
          timeout_s="0"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --title) title="${2:-工程任务}"; shift 2 ;;
              --script-file) script_file="${2:-}"; shift 2 ;;
              --timeout) timeout_s="${2:-0}"; shift 2 ;;
              *) shift ;;
            esac
          done
          task_id="$(date +%Y%m%d%H%M%S 2>/dev/null)-$$"
          task_dir="$TASK_DIR/$task_id"
          mkdir -p "$task_dir"
          log="$task_dir/output.log"
          script_copy="$task_dir/script.sh"
          out="$TMP_DIR/$task_id.out"
          if [ ! -f "$script_file" ]; then
            echo "missing script file: $script_file" | tee -a "$log"
            exit 64
          fi
          cp "$script_file" "$script_copy"
          chmod 700 "$script_copy" 2>/dev/null || true
          # Host payload files are one-shot temps; the task keeps its copy.
          case "$script_file" in
            "$TMP_DIR"/*) rm -f "$script_file" ;;
          esac
          {
            echo "task_id=$task_id"
            echo "title=$title"
            echo "started_at=$(timestamp)"
            echo "workspace=$(display_path "$WORKSPACE")"
            echo "script=$(display_path "$script_copy")"
            echo "--- output ---"
          } > "$log"
          cd "$WORKSPACE" || exit 65
          export OGENT_ROOT="$ROOT"
          export MINIS_ROOT="$ROOT"
          export OGENT_WORKSPACE="$WORKSPACE"
          export OGENT_ARTIFACTS="$ARTIFACT_DIR"
          if [ "$timeout_s" != "0" ] && command -v timeout >/dev/null 2>&1; then
            timeout "$timeout_s" /bin/sh "$script_copy" > "$out" 2>&1
          else
            /bin/sh "$script_copy" > "$out" 2>&1
          fi
          code=$?
          cat "$out" | tee -a "$log"
          rm -f "$out"
          {
            echo "--- status ---"
            echo "exit=$code"
            echo "finished_at=$(timestamp)"
            echo "--- workspace files ---"
            find "$WORKSPACE" -maxdepth 3 -type f 2>/dev/null | sed "s#$WORKSPACE/##" | sort | tail -n 120
          } >> "$log"
          {
            echo "last_task=$task_id"
            echo "title=$title"
            echo "exit=$code"
            echo "log=$(display_path "$log")"
            echo "updated_at=$(timestamp)"
          } > "$LATEST_STATUS"
          sid="$(current_session_id)"
          if [ "$sid" != "none" ]; then
            session_note --id "$sid" --file "$log" >/dev/null 2>&1 || true
          fi
          pid="$(current_project_manifest_id)"
          if [ "$pid" != "none" ]; then
            status_value="tool_failed"
            [ "$code" = "0" ] && status_value="tool_completed"
            {
              echo "tool=run_script"
              echo "task_id=$task_id"
              echo "title=$title"
              echo "exit=$code"
              echo "task_log=$(display_path "$log")"
            } > "$TMP_DIR/project-task-$task_id.txt"
            project_manifest_update --id "$pid" --status "$status_value" --event "run_script:$task_id" --file "$TMP_DIR/project-task-$task_id.txt" >/dev/null 2>&1 || true
            rm -f "$TMP_DIR/project-task-$task_id.txt" 2>/dev/null || true
          fi
          log_event "run_task id=$task_id exit=$code title=$(safe_name "$title")"
          echo "[ogent-task id=$task_id exit=$code log=$(display_path "$log")]"
          exit "$code"
        }

        memory_set() {
          init_runtime
          key=""
          payload_file=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --key) key="${2:-}"; shift 2 ;;
              --file) payload_file="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          if [ -z "$key" ]; then
            echo "usage: ogent-agent memory-set --key <key> --file <payload>"
            exit 64
          fi
          file="$MEMORY_DIR/$(safe_name "$key").txt"
          read_payload "$payload_file" > "$file"
          log_event "memory_set key=$(safe_name "$key")"
          echo "remembered $key -> $(display_path "$file")"
        }

        memory_add() {
          init_runtime
          title="工程记忆"
          payload_file=""
          tags=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --title) title="${2:-工程记忆}"; shift 2 ;;
              --file) payload_file="${2:-}"; shift 2 ;;
              --tags) tags="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          body="$(read_payload "$payload_file")"
          if [ -z "$body" ]; then
            echo "usage: ogent-agent memory-add --title <title> --file <payload> [--tags <tags>]"
            exit 64
          fi
          id="$(date +%Y%m%d%H%M%S 2>/dev/null)-$(safe_name "$title")"
          file="$WIKI_DIR/$id.md"
          {
            echo "# $title"
            echo
            echo "- captured_at: $(timestamp)"
            echo "- tags: ${tags:-general}"
            echo "- source: Ogent 工程模式"
            echo
            printf '%s\\n' "$body"
          } > "$file"
          {
            echo "- $(timestamp) [$title]($(display_path "$file")) tags=${tags:-general}"
          } >> "$MEMORY_DIR/INDEX.md"
          rag_rebuild >/dev/null 2>&1 || true
          log_event "memory_add title=$(safe_name "$title")"
          echo "memory page saved -> $(display_path "$file")"
        }

        wiki_upsert() {
          init_runtime
          topic=""
          title=""
          payload_file=""
          tags=""
          related=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --topic) topic="${2:-}"; shift 2 ;;
              --title) title="${2:-}"; shift 2 ;;
              --file) payload_file="${2:-}"; shift 2 ;;
              --tags) tags="${2:-}"; shift 2 ;;
              --related) related="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          body="$(read_payload "$payload_file")"
          if [ -z "$topic" ] || [ -z "$body" ]; then
            echo "usage: ogent-agent wiki-upsert --topic <topic> --file <payload> [--title <title>] [--tags <tags>] [--related <a,b,c>]"
            exit 64
          fi
          topic_id="$(safe_name "$topic")"
          file="$WIKI_TOPIC_DIR/$topic_id.md"
          now="$(timestamp)"
          if [ -z "$title" ]; then
            title="$topic"
          fi
          if [ ! -f "$file" ]; then
            {
              echo "# $title"
              echo
              echo "- topic: $topic"
              echo "- created_at: $now"
              echo "- updated_at: $now"
              echo "- tags: ${tags:-general}"
              echo "- source: Ogent 工程模式"
              echo
              echo "## Related"
              if [ -n "$related" ]; then
                printf '%s\\n' "$related" | tr ',' '\n' | while read -r item; do
                  item="$(printf '%s' "$item" | sed 's/^ *//; s/ *$//')"
                  [ -n "$item" ] && echo "- [[$(safe_name "$item")]]"
                done
              else
                echo "- none"
              fi
              echo
              echo "## Updates"
            } > "$file"
          else
            {
              echo
              echo "<!-- updated_at: $now tags=${tags:-general} related=${related:-none} -->"
              if [ -n "$related" ]; then
                echo
                echo "## Related update $now"
                printf '%s\\n' "$related" | tr ',' '\n' | while read -r item; do
                  item="$(printf '%s' "$item" | sed 's/^ *//; s/ *$//')"
                  [ -n "$item" ] && echo "- [[$(safe_name "$item")]]"
                done
              fi
            } >> "$file"
          fi
          {
            echo
            echo "### $now"
            echo
            echo "- tags: ${tags:-general}"
            if [ -n "$related" ]; then
              echo "- related: $related"
            fi
            echo
            printf '%s\\n' "$body"
          } >> "$file"
          {
            echo "- $now wiki-upsert [$title]($(display_path "$file")) tags=${tags:-general} related=${related:-none}"
          } >> "$MEMORY_DIR/INDEX.md"
          rag_rebuild >/dev/null 2>&1 || true
          log_event "wiki_upsert topic=$topic_id"
          echo "wiki topic updated -> $(display_path "$file")"
          echo "topic=$topic"
          echo "topic_id=$topic_id"
          echo "related=${related:-none}"
          echo "wiki_upsert_ok"
        }

        rag_rebuild() {
          init_runtime
          tmp="$TMP_DIR/rag.$$"
          : > "$tmp"
          find "$WIKI_DIR" -type f -name '*.md' 2>/dev/null | sort | while read -r file; do
            line=0
            start=1
            para=""
            flush_para() {
              if [ ${#para} -gt 20 ]; then
                clean="$(printf '%s' "$para" | tr '\t\r' '  ')"
                printf '%s\t%s\t%s\n' "$file" "$start" "$clean" >> "$tmp"
              fi
              para=""
            }
            while IFS= read -r row || [ -n "$row" ]; do
              line=$((line + 1))
              if [ -z "$row" ]; then
                flush_para
              elif [ -z "$para" ]; then
                start="$line"
                para="$row"
              else
                para="$para $row"
              fi
            done < "$file"
            flush_para
          done
          mv "$tmp" "$RAG_INDEX"
          chunks="$(wc -l < "$RAG_INDEX" 2>/dev/null | tr -d ' ')"
          log_event "rag_rebuild chunks=${chunks:-0}"
          echo "rag index rebuilt -> $(display_path "$RAG_INDEX")"
          echo "chunks=${chunks:-0}"
        }

        rag_search() {
          init_runtime
          query="$*"
          if [ -z "$query" ]; then
            echo "usage: ogent-agent rag-search <query>"
            exit 64
          fi
          if [ ! -s "$RAG_INDEX" ]; then
            rag_rebuild >/dev/null 2>&1 || true
          fi
          if [ ! -s "$RAG_INDEX" ]; then
            echo "no rag index yet"
            exit 0
          fi
          normalized="$(printf '%s' "$query" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' ' ')"
          hits_file="$TMP_DIR/rag_hits.$$"
          : > "$hits_file"
          while IFS="$(printf '\t')" read -r file line text; do
            base="$(printf '%s' "$text" | tr 'A-Z' 'a-z')"
            score=0
            for term in $normalized; do
              [ ${#term} -lt 2 ] && continue
              case "$base" in
                *"$term"*) score=$((score + 1)) ;;
              esac
            done
            if [ "$score" -gt 0 ]; then
              printf '%06d\t%s\t%s\t%s\n' "$score" "$file" "$line" "$text" >> "$hits_file"
            fi
          done < "$RAG_INDEX"
          echo "Ogent RAG search"
          echo "query=$query"
          echo "index=$(display_path "$RAG_INDEX")"
          echo
          if [ ! -s "$hits_file" ]; then
            rm -f "$hits_file"
            echo "no rag matches"
            exit 0
          fi
          sort -rn "$hits_file" | head -n 12 | while IFS="$(printf '\t')" read -r score file line text; do
            score_text="$(printf '%s' "$score" | sed 's/^0*//')"
            [ -n "$score_text" ] || score_text=0
            printf '%s\n' "--- score=$score_text file=$(display_path "$file") line=$line ---"
            printf '%s\n\n' "$text"
          done
          rm -f "$hits_file"
        }

        memory_get() {
          init_runtime
          key="${1:-}"
          if [ -z "$key" ]; then
            echo "memory keys:"
            find "$MEMORY_DIR" -maxdepth 1 -type f 2>/dev/null | sed 's#.*/##; s#\\.txt$##' | sort
            echo
            echo "recent wiki memory:"
            find "$WIKI_DIR" -type f -name '*.md' 2>/dev/null | sort | tail -n 20 | sed "s#$WIKI_DIR/##"
            exit 0
          fi
          file="$MEMORY_DIR/$(safe_name "$key").txt"
          if [ ! -f "$file" ]; then
            echo "memory not found: $key"
            exit 66
          fi
          cat "$file"
        }

        memory_search() {
          init_runtime
          query="${1:-}"
          if [ -z "$query" ]; then
            echo "recent wiki memory:"
            find "$WIKI_DIR" -type f -name '*.md' 2>/dev/null | sort | tail -n 30 | while read -r file; do
              echo "--- $(display_path "$file") ---"
              sed -n '1,24p' "$file"
            done
            exit 0
          fi
          echo "Ogent memory search"
          echo "query=$query"
          echo "root=$(display_path "$MEMORY_DIR")"
          echo
          rag_search "$query"
        }

                wiki_summary() {
                  init_runtime
                  if [ ! -s "$RAG_INDEX" ]; then
                    rag_rebuild >/dev/null 2>&1 || true
                  fi
          pages="$(find "$WIKI_DIR" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
          topic_pages="$(find "$WIKI_TOPIC_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
          chunks="$(wc -l < "$RAG_INDEX" 2>/dev/null | tr -d ' ')"
          echo "Ogent wiki summary"
          echo "wiki_root=$(display_path "$WIKI_DIR")"
          echo "topic_root=$(display_path "$WIKI_TOPIC_DIR")"
          echo "index=$(display_path "$MEMORY_DIR/INDEX.md")"
          echo "rag_index=$(display_path "$RAG_INDEX")"
          echo "pages=${pages:-0}"
          echo "topic_pages=${topic_pages:-0}"
          echo "rag_chunks=${chunks:-0}"
          echo
          echo "--- topic pages ---"
          if [ "${topic_pages:-0}" = "0" ]; then
            echo "no topic pages yet"
          else
            find "$WIKI_TOPIC_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort | tail -n 12 | while read -r file; do
              title="$(sed -n '1s/^# //p' "$file" | head -n 1)"
              bytes="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"
              echo "- title=${title:-$(basename "$file")}"
              echo "  file=$(display_path "$file")"
              echo "  bytes=${bytes:-0}"
            done
          fi
          echo
          echo "--- recent pages ---"
          if [ "${pages:-0}" = "0" ]; then
            echo "no wiki pages yet"
          else
            find "$WIKI_DIR" -type f -name '*.md' 2>/dev/null | sort | tail -n 16 | while read -r file; do
              title="$(sed -n '1s/^# //p' "$file" | head -n 1)"
              captured="$(sed -n 's/^- captured_at: //p' "$file" | head -n 1)"
              tags="$(sed -n 's/^- tags: //p' "$file" | head -n 1)"
              bytes="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"
              echo "- title=${title:-$(basename "$file")}"
              echo "  file=$(display_path "$file")"
              echo "  captured_at=${captured:-unknown}"
              echo "  tags=${tags:-general}"
              echo "  bytes=${bytes:-0}"
            done
          fi
          echo
                  echo "--- recent index ---"
                  tail -n 20 "$MEMORY_DIR/INDEX.md" 2>/dev/null || true
                }

                wiki_graph() {
                  init_runtime
                  if [ ! -s "$RAG_INDEX" ]; then
                    rag_rebuild >/dev/null 2>&1 || true
                  fi
                  pages="$(find "$WIKI_DIR" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
                  topic_pages="$(find "$WIKI_TOPIC_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
                  chunks="$(wc -l < "$RAG_INDEX" 2>/dev/null | tr -d ' ')"
                  topic_list="$TMP_DIR/wiki_graph_topics.$$"
                  links_list="$TMP_DIR/wiki_graph_links.$$"
                  backlinks_list="$TMP_DIR/wiki_graph_backlinks.$$"
                  find "$WIKI_TOPIC_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort > "$topic_list"
                  edges=0
                  echo "Ogent wiki graph"
                  echo "wiki_root=$(display_path "$WIKI_DIR")"
                  echo "topic_root=$(display_path "$WIKI_TOPIC_DIR")"
                  echo "rag_index=$(display_path "$RAG_INDEX")"
                  echo "pages=${pages:-0}"
                  echo "topic_pages=${topic_pages:-0}"
                  echo "rag_chunks=${chunks:-0}"
                  echo
                  echo "--- topic graph ---"
                  if [ "${topic_pages:-0}" = "0" ]; then
                    echo "no topic pages yet"
                  else
                    while IFS= read -r file; do
                      [ -f "$file" ] || continue
                      topic_id="$(basename "$file" .md)"
                      title="$(sed -n '1s/^# //p' "$file" | head -n 1)"
                      bytes="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"
                      sed -n 's/.*\\[\\[\\([^]]*\\)\\]\\].*/\\1/p' "$file" | sort -u > "$links_list"
                      related=""
                      while IFS= read -r link; do
                        link="$(printf '%s' "$link" | sed 's/^ *//; s/ *$//')"
                        [ -n "$link" ] || continue
                        [ "$link" = "none" ] && continue
                        edges=$((edges + 1))
                        if [ -z "$related" ]; then
                          related="$link"
                        else
                          related="$related,$link"
                        fi
                      done < "$links_list"
                      : > "$backlinks_list"
                      while IFS= read -r other; do
                        [ -f "$other" ] || continue
                        [ "$other" = "$file" ] && continue
                        if grep -F "[[$topic_id]]" "$other" >/dev/null 2>&1; then
                          basename "$other" .md >> "$backlinks_list"
                        fi
                      done < "$topic_list"
                      backlinks=""
                      while IFS= read -r backlink; do
                        [ -n "$backlink" ] || continue
                        if [ -z "$backlinks" ]; then
                          backlinks="$backlink"
                        else
                          backlinks="$backlinks,$backlink"
                        fi
                      done < "$backlinks_list"
                      echo "- topic=$topic_id"
                      echo "  title=${title:-$topic_id}"
                      echo "  file=$(display_path "$file")"
                      echo "  related=${related:-none}"
                      echo "  backlinks=${backlinks:-none}"
                      echo "  bytes=${bytes:-0}"
                    done < "$topic_list"
                  fi
                  rm -f "$topic_list" "$links_list" "$backlinks_list"
                  echo
                  echo "edges=$edges"
                  echo "wiki_graph_ok"
                }

                skill_list() {
                  init_runtime
                  if [ "$(count_files "$SKILL_DIR")" = "0" ]; then
            echo "no Linux-side skills installed in $(display_path "$SKILL_DIR")"
            exit 0
          fi
          find "$SKILL_DIR" -maxdepth 3 -type f 2>/dev/null | sort | while read -r file; do
            display_path "$file"
            printf '\n'
          done
        }

        skill_install() {
          init_runtime
          name=""
          payload_file=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --name) name="${2:-}"; shift 2 ;;
              --file) payload_file="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          if [ -z "$name" ] || [ -z "$payload_file" ] || [ ! -f "$payload_file" ]; then
            echo "usage: ogent-agent skill-install --name <name> --file <payload>"
            exit 64
          fi
          dir="$SKILL_DIR/$(safe_name "$name")"
          mkdir -p "$dir"
          cp "$payload_file" "$dir/SKILL.md"
          log_event "skill_install name=$(safe_name "$name")"
          echo "skill installed -> $(display_path "$dir/SKILL.md")"
        }

        subagent_create() {
          init_runtime
          name=""
          payload_file=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --name) name="${2:-}"; shift 2 ;;
              --file) payload_file="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          if [ -z "$name" ] || [ -z "$payload_file" ] || [ ! -f "$payload_file" ]; then
            echo "usage: ogent-agent subagent-create --name <name> --file <instructions>"
            exit 64
          fi
          id="$(safe_name "$name")"
          subagent_dir="$SUBAGENT_DIR/$id"
          mkdir -p "$subagent_dir/tasks"
          {
            echo "# $name"
            echo
            echo "- created_at: $(timestamp)"
            echo "- workspace: $(display_path "$WORKSPACE")"
            echo
            echo "## Instructions"
            echo
            cat "$payload_file"
          } > "$subagent_dir/AGENT.md"
          log_event "subagent_create name=$id"
          echo "subagent saved -> $(display_path "$subagent_dir/AGENT.md")"
        }

        subagent_list() {
          init_runtime
          if [ "$(count_files "$SUBAGENT_DIR")" = "0" ]; then
            echo "no subagents installed in $(display_path "$SUBAGENT_DIR")"
            exit 0
          fi
          find "$SUBAGENT_DIR" -maxdepth 2 -name AGENT.md 2>/dev/null | sort | while read -r file; do
            name="$(basename "$(dirname "$file")")"
            title="$(sed -n '1s/^# //p' "$file")"
            dir="$(dirname "$file")"
            for env_file in "$dir"/tasks/*.env; do
              [ -f "$env_file" ] || continue
              status="$(sed -n 's/^status=//p' "$env_file" | sed -n '1p')"
              [ "$status" = "running" ] || continue
              result_file="$(sed -n 's/^result_file=//p' "$env_file" | sed -n '1p')"
              new_status=""
              stale_reason=""
              if [ -z "$result_file" ] || [ ! -f "$result_file" ]; then
                new_status="failed"
                stale_reason="stale_running_no_result"
              elif grep -q '^subagent_run=ok$' "$result_file" 2>/dev/null; then
                new_status="completed"
              elif grep -q '^subagent_run=failed$' "$result_file" 2>/dev/null; then
                new_status="failed"
              fi
              [ -n "$new_status" ] || continue
              tmp_env="$env_file.tmp"
              while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in
                  status=*) echo "status=$new_status" ;;
                  updated_at=*) echo "updated_at=$(timestamp)" ;;
                  stale_reason=*) [ -n "$stale_reason" ] && echo "stale_reason=$stale_reason" ;;
                  *) echo "$line" ;;
                esac
              done < "$env_file" > "$tmp_env" && mv "$tmp_env" "$env_file"
              if [ -n "$stale_reason" ] && ! grep -q '^stale_reason=' "$env_file" 2>/dev/null; then
                echo "stale_reason=$stale_reason" >> "$env_file"
              fi
            done
            queued="$(grep -l '^status=queued$' "$dir"/tasks/*.env 2>/dev/null | wc -l | tr -d ' ')"
            running="$(grep -l '^status=running$' "$dir"/tasks/*.env 2>/dev/null | wc -l | tr -d ' ')"
            completed="$(grep -l '^status=completed$' "$dir"/tasks/*.env 2>/dev/null | wc -l | tr -d ' ')"
            failed="$(grep -l '^status=failed$' "$dir"/tasks/*.env 2>/dev/null | wc -l | tr -d ' ')"
            runs="$(find "$dir/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
            printf '%s\\t%s\\tqueued=%s\\trunning=%s\\tcompleted=%s\\tfailed=%s\\truns=%s\\n' "$name" "${title:-$name}" "${queued:-0}" "${running:-0}" "${completed:-0}" "${failed:-0}" "${runs:-0}"
          done
        }

        subagent_task() {
          init_runtime
          name=""
          payload_file=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --name) name="${2:-}"; shift 2 ;;
              --file) payload_file="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          if [ -z "$name" ] || [ -z "$payload_file" ] || [ ! -f "$payload_file" ]; then
            echo "usage: ogent-agent subagent-task --name <name> --file <task>"
            exit 64
          fi
          id="$(safe_name "$name")"
          subagent_dir="$SUBAGENT_DIR/$id"
          if [ ! -f "$subagent_dir/AGENT.md" ]; then
            echo "subagent not found: $name"
            exit 66
          fi
          task_id="$(date +%Y%m%d%H%M%S 2>/dev/null)-$$"
          task_file="$subagent_dir/tasks/$task_id.md"
          task_env="$subagent_dir/tasks/$task_id.env"
          {
            echo "# Subagent Task $task_id"
            echo
            echo "- assigned_at: $(timestamp)"
            echo "- subagent: $id"
            echo
            echo "## Role"
            sed -n '1,120p' "$subagent_dir/AGENT.md"
            echo
            echo "## Task"
            cat "$payload_file"
          } > "$task_file"
          {
            echo "task_id=$task_id"
            echo "subagent=$id"
            echo "status=queued"
            echo "assigned_at=$(timestamp)"
            echo "task_file=$(display_path "$task_file")"
            echo "run_id="
            echo "result_file="
            echo "model_kind="
            echo "updated_at=$(timestamp)"
          } > "$task_env"
          log_event "subagent_task name=$id task=$task_id"
          echo "subagent task queued -> $(display_path "$task_file")"
          echo "task_id=$task_id"
          echo "task_status=queued"
        }

        subagent_run() {
          init_runtime
          name=""
          task_id="latest"
          allow_harness="0"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --name) name="${2:-}"; shift 2 ;;
              --task|--task-id) task_id="${2:-latest}"; shift 2 ;;
              --allow-harness) allow_harness="1"; shift ;;
              --require-real-model) allow_harness="0"; shift ;;
              *) shift ;;
            esac
          done
          if [ -z "$name" ]; then
            echo "usage: ogent-agent subagent-run --name <name> [--task <task-id|latest>] [--allow-harness]"
            exit 64
          fi
          id="$(safe_name "$name")"
          subagent_dir="$SUBAGENT_DIR/$id"
          if [ ! -f "$subagent_dir/AGENT.md" ]; then
            echo "subagent not found: $name"
            exit 66
          fi
          if [ "$task_id" = "latest" ] || [ -z "$task_id" ]; then
            task_file="$(find "$subagent_dir/tasks" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort | tail -n 1)"
            task_id="$(basename "$task_file" .md)"
          else
            task_id="$(safe_name "$task_id")"
            task_file="$subagent_dir/tasks/$task_id.md"
          fi
          if [ -z "$task_file" ] || [ ! -f "$task_file" ]; then
            echo "subagent task not found: $task_id"
            exit 66
          fi
          run_id="$(date +%Y%m%d%H%M%S 2>/dev/null)-$$"
          task_env="$subagent_dir/tasks/$task_id.env"
          run_dir="$subagent_dir/runs/$run_id"
          mkdir -p "$run_dir"
          request_json="$run_dir/request.json"
          response_json="$run_dir/response.json"
          result_file="$run_dir/result.md"
          probe_file="$run_dir/model-probe.txt"
          err_file="$run_dir/error.log"
          {
            echo "task_id=$task_id"
            echo "subagent=$id"
            echo "status=running"
            echo "assigned_at=$(timestamp)"
            echo "task_file=$(display_path "$task_file")"
            echo "run_id=$run_id"
            echo "result_file=$(display_path "$result_file")"
            echo "model_kind="
            echo "updated_at=$(timestamp)"
          } > "$task_env"
          if ! model_probe > "$probe_file" 2>&1; then
            if [ "$allow_harness" = "1" ]; then
              # Diagnostics may exercise the complete subagent lifecycle even
              # when no real local model is installed. Keep this path explicit
              # and label it as a compatibility harness; production runs still
              # fail closed below when the model is unavailable.
              model_kind="compatibility_harness"
              {
                echo "# Subagent Result $run_id"
                echo
                echo "subagent_run=ok"
                echo "subagent=$id"
                echo "task_id=$task_id"
                echo "model_kind=$model_kind"
                echo "reason=diagnostic_harness_no_local_model"
                echo "probe=$(display_path "$probe_file")"
                echo
                echo "subagent_run_selftest_ok"
                echo "Compatibility harness completed the subagent lifecycle without model inference."
                echo "This is diagnostics-only and does not prove a real local model."
                echo
                sed -n '1,80p' "$probe_file"
              } > "$result_file"
              {
                echo "task_id=$task_id"
                echo "subagent=$id"
                echo "status=completed"
                echo "assigned_at=$(timestamp)"
                echo "task_file=$(display_path "$task_file")"
                echo "run_id=$run_id"
                echo "result_file=$(display_path "$result_file")"
                echo "model_kind=$model_kind"
                echo "updated_at=$(timestamp)"
              } > "$task_env"
              sid="$(current_session_id)"
              if [ "$sid" != "none" ]; then
                session_note --id "$sid" --file "$result_file" >/dev/null 2>&1 || true
              fi
              log_event "subagent_run name=$id task=$task_id model_kind=$model_kind diagnostic_harness=1"
              echo "subagent_run=ok name=$id task=$task_id run=$run_id model_kind=$model_kind diagnostic_harness=1 result=$(display_path "$result_file")"
              sed -n '1,120p' "$result_file"
              exit 0
            fi
            {
              echo "# Subagent Result $run_id"
              echo
              echo "subagent_run=failed"
              echo "reason=local_model_unavailable"
              echo "next_step=run ogent-agent model-bootstrap, then retry subagent-run"
              echo "probe=$(display_path "$probe_file")"
              echo
              sed -n '1,80p' "$probe_file"
            } > "$result_file"
            {
              echo "task_id=$task_id"
              echo "subagent=$id"
              echo "status=failed"
              echo "assigned_at=$(timestamp)"
              echo "task_file=$(display_path "$task_file")"
              echo "run_id=$run_id"
              echo "result_file=$(display_path "$result_file")"
              echo "model_kind=unavailable"
              echo "updated_at=$(timestamp)"
            } > "$task_env"
            log_event "subagent_run name=$id task=$task_id failed=local_model_unavailable"
            cat "$result_file"
            exit 78
          fi
          load_model_config
          base_url="${OGENT_LOCAL_MODEL_BASE_URL:-$(model_default_base_url)}"
          api_base_url="$(model_api_base_url "$base_url")"
          model_id="${OGENT_LOCAL_MODEL_ID:-$(model_default_id)}"
          api_key="${OGENT_LOCAL_MODEL_API_KEY:-}"
          model_kind="$(sed -n 's/.*model_kind=\\([^ ]*\\).*/\\1/p' "$probe_file" | tail -n 1)"
          [ -n "$model_kind" ] || model_kind="unknown"
          if [ "$model_kind" = "compatibility_harness" ] && [ "$allow_harness" != "1" ]; then
            {
              echo "# Subagent Result $run_id"
              echo
              echo "subagent_run=failed"
              echo "reason=local_model_not_real"
              echo "model_kind=$model_kind"
              echo "next_step=run ogent-agent model-provision --url <GGUF_URL>, or import llama-server and a GGUF model, then retry subagent-run"
              echo "probe=$(display_path "$probe_file")"
              echo
              sed -n '1,80p' "$probe_file"
            } > "$result_file"
            {
              echo "task_id=$task_id"
              echo "subagent=$id"
              echo "status=failed"
              echo "assigned_at=$(timestamp)"
              echo "task_file=$(display_path "$task_file")"
              echo "run_id=$run_id"
              echo "result_file=$(display_path "$result_file")"
              echo "model_kind=$model_kind"
              echo "updated_at=$(timestamp)"
            } > "$task_env"
            log_event "subagent_run name=$id task=$task_id failed=local_model_not_real"
            cat "$result_file"
            exit 78
          fi
          if ensure_python3; then
            OGENT_SUBAGENT_AGENT="$subagent_dir/AGENT.md" \
            OGENT_SUBAGENT_TASK="$task_file" \
            OGENT_SUBAGENT_REQUEST="$request_json" \
            OGENT_SUBAGENT_MODEL="$model_id" \
            python3 - <<'PY'
        import json
        import os

        def read(path):
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                return handle.read()

        agent = read(os.environ["OGENT_SUBAGENT_AGENT"])
        task = read(os.environ["OGENT_SUBAGENT_TASK"])
        payload = {
            "model": os.environ.get("OGENT_SUBAGENT_MODEL") or "ogent-local-echo",
            "stream": False,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "You are a local Ogent subagent running inside iSH Linux. "
                        "Use the role instructions, complete the assigned task, and return a concise auditable result. "
                        "This command requires a real local model by default; diagnostics must pass --allow-harness explicitly."
                    )
                },
                {
                    "role": "user",
                    "content": "## Subagent Role\\n\\n" + agent + "\\n\\n## Assigned Task\\n\\n" + task
                }
            ]
        }
        with open(os.environ["OGENT_SUBAGENT_REQUEST"], "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False)
        PY
          else
            subagent_write_request_json_sh "$subagent_dir/AGENT.md" "$task_file" "$request_json" "$model_id"
          fi
          post_url="${api_base_url%/}/chat/completions"
          post_ok="0"
          if model_http_post_json "$post_url" "$request_json" "$response_json" "$err_file" "$api_key"; then
            post_ok="1"
          elif [ "$allow_harness" = "1" ] && [ "$model_kind" = "compatibility_harness" ]; then
            {
              echo "subagent_post_retry=compatibility_harness_bootstrap"
              echo "first_error:"
              sed -n '1,20p' "$err_file" 2>/dev/null || true
            } >> "$err_file.retry"
            model_bootstrap >/dev/null 2>>"$err_file.retry" || true
            if model_http_post_json "$post_url" "$request_json" "$response_json" "$err_file" "$api_key"; then
              post_ok="1"
            fi
          fi

          subagent_synthesize_harness_response() {
            synth_reason="${1:-post_failed}"
            if ensure_python3; then
              OGENT_SUBAGENT_RESPONSE="$response_json" \
              OGENT_SUBAGENT_SYNTH_REASON="$synth_reason" \
              python3 - <<'PY' 2>>"$err_file.retry"
        import json
        import os

        reason = os.environ.get("OGENT_SUBAGENT_SYNTH_REASON") or "post_failed"
        payload = {
            "id": "chatcmpl-ogent-subagent-harness",
            "object": "chat.completion",
            "model": "ogent-local-echo",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": (
                        "subagent_run_selftest_ok\n"
                        "Compatibility harness synthesized a diagnostic subagent response because "
                        "the local endpoint exposed /models but did not complete a valid /chat/completions response. "
                        "reason=" + reason + "\n"
                        "This verifies subagent lifecycle only; it is not real model inference."
                    )
                },
                "finish_reason": "stop"
            }]
        }
        with open(os.environ["OGENT_SUBAGENT_RESPONSE"], "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False)
        PY
            else
              printf '%s\n' '{"choices":[{"index":0,"message":{"role":"assistant","content":"subagent_run_selftest_ok\nCompatibility harness synthesized a diagnostic subagent response because the local endpoint exposed /models but did not complete a valid /chat/completions response. This verifies subagent lifecycle only; it is not real model inference."},"finish_reason":"stop"}]}' > "$response_json"
            fi
            echo "subagent_post_fallback=compatibility_harness_synthesized reason=$synth_reason" >> "$err_file.retry"
            post_ok="1"
          }

          if [ "$post_ok" != "1" ] && [ "$allow_harness" = "1" ] && [ "$model_kind" = "compatibility_harness" ]; then
            subagent_synthesize_harness_response "post_failed"
          elif [ "$post_ok" = "1" ] && [ "$allow_harness" = "1" ] && [ "$model_kind" = "compatibility_harness" ]; then
            subagent_synthesize_harness_response "compatibility_harness_diagnostic"
          fi
          if [ "$post_ok" != "1" ]; then
            {
              echo "# Subagent Result $run_id"
              echo
              echo "subagent_run=failed"
              echo "reason=model_post_failed"
              echo "model_kind=$model_kind"
              echo "post_url=$post_url"
              echo "request=$(display_path "$request_json")"
              echo "response=$(display_path "$response_json")"
              echo "error=$(display_path "$err_file")"
              [ -f "$err_file.retry" ] && echo "retry_log=$(display_path "$err_file.retry")"
              echo
              sed -n '1,80p' "$err_file" 2>/dev/null || true
              sed -n '1,80p' "$err_file.retry" 2>/dev/null || true
            } > "$result_file"
            {
              echo "task_id=$task_id"
              echo "subagent=$id"
              echo "status=failed"
              echo "assigned_at=$(timestamp)"
              echo "task_file=$(display_path "$task_file")"
              echo "run_id=$run_id"
              echo "result_file=$(display_path "$result_file")"
              echo "model_kind=$model_kind"
              echo "updated_at=$(timestamp)"
            } > "$task_env"
            log_event "subagent_run name=$id task=$task_id failed=model_post"
            cat "$result_file"
            exit 1
          fi
          if ensure_python3; then
            OGENT_SUBAGENT_RESPONSE="$response_json" \
            OGENT_SUBAGENT_RESULT="$result_file" \
            OGENT_SUBAGENT_RUN="$run_id" \
            OGENT_SUBAGENT_NAME="$id" \
            OGENT_SUBAGENT_TASK_ID="$task_id" \
            OGENT_SUBAGENT_MODEL_KIND="$model_kind" \
            python3 - <<'PY'
        import json
        import os

        response_path = os.environ["OGENT_SUBAGENT_RESPONSE"]
        result_path = os.environ["OGENT_SUBAGENT_RESULT"]
        with open(response_path, "r", encoding="utf-8", errors="replace") as handle:
            data = json.load(handle)
        content = ""
        choices = data.get("choices") or []
        if choices:
            message = choices[0].get("message") or {}
            content = message.get("content") or ""
        if not content:
            content = json.dumps(data, ensure_ascii=False)[:2000]
        with open(result_path, "w", encoding="utf-8") as handle:
            handle.write("# Subagent Result " + os.environ["OGENT_SUBAGENT_RUN"] + "\\n\\n")
            handle.write("subagent_run=ok\\n")
            handle.write("subagent=" + os.environ["OGENT_SUBAGENT_NAME"] + "\\n")
            handle.write("task_id=" + os.environ["OGENT_SUBAGENT_TASK_ID"] + "\\n")
            handle.write("model_kind=" + os.environ["OGENT_SUBAGENT_MODEL_KIND"] + "\\n")
            handle.write("\\n## Result\\n\\n")
            handle.write(content.strip() + "\\n")
        PY
          else
            content="$(subagent_extract_response_text_sh "$response_json")"
            if [ -z "$content" ]; then
              content="$(sed -n '1,40p' "$response_json" 2>/dev/null)"
            fi
            {
              echo "# Subagent Result $run_id"
              echo
              echo "subagent_run=ok"
              echo "subagent=$id"
              echo "task_id=$task_id"
              echo "model_kind=$model_kind"
              echo
              echo "## Result"
              echo
              printf '%s\n' "$content"
            } > "$result_file"
          fi
          if [ ! -f "$result_file" ] || ! grep -q '^subagent_run=ok$' "$result_file" 2>/dev/null; then
            {
              echo "# Subagent Result $run_id"
              echo
              echo "subagent_run=failed"
              echo "reason=result_file_missing_or_invalid"
              echo "model_kind=$model_kind"
              echo "request=$(display_path "$request_json")"
              echo "response=$(display_path "$response_json")"
              echo "error=$(display_path "$err_file")"
            } > "$result_file"
            {
              echo "task_id=$task_id"
              echo "subagent=$id"
              echo "status=failed"
              echo "assigned_at=$(timestamp)"
              echo "task_file=$(display_path "$task_file")"
              echo "run_id=$run_id"
              echo "result_file=$(display_path "$result_file")"
              echo "model_kind=$model_kind"
              echo "updated_at=$(timestamp)"
            } > "$task_env"
            log_event "subagent_run name=$id task=$task_id failed=result_file_missing_or_invalid"
            cat "$result_file"
            exit 1
          fi
          {
            echo "task_id=$task_id"
            echo "subagent=$id"
            echo "status=completed"
            echo "assigned_at=$(timestamp)"
            echo "task_file=$(display_path "$task_file")"
            echo "run_id=$run_id"
            echo "result_file=$(display_path "$result_file")"
            echo "model_kind=$model_kind"
            echo "updated_at=$(timestamp)"
          } > "$task_env"
          sid="$(current_session_id)"
          if [ "$sid" != "none" ]; then
            session_note --id "$sid" --file "$result_file" >/dev/null 2>&1 || true
          fi
          log_event "subagent_run name=$id task=$task_id model_kind=$model_kind"
          echo "subagent_run=ok name=$id task=$task_id run=$run_id model_kind=$model_kind result=$(display_path "$result_file")"
          sed -n '1,120p' "$result_file"
        }

        automation_create() {
          init_runtime
          name="automation"
          trigger="manual"
          payload_file=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --name) name="${2:-automation}"; shift 2 ;;
              --trigger) trigger="${2:-manual}"; shift 2 ;;
              --file) payload_file="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          if [ -z "$payload_file" ] || [ ! -f "$payload_file" ]; then
            echo "usage: ogent-agent automation-create --name <name> --trigger <manual|hourly|daily|interval:seconds|on_boot> --file <script>"
            exit 64
          fi
          case "$trigger" in
            manual|hourly|daily|on_boot|interval:[0-9]*) ;;
            *) echo "invalid trigger: $trigger"; exit 64 ;;
          esac
          id="auto-$(date +%Y%m%d%H%M%S 2>/dev/null)-$(safe_name "$name")"
          dir="$AUTOMATION_DIR/$id"
          mkdir -p "$dir/runs" || { echo "automation mkdir failed: $(display_automation_path "$dir")"; exit 65; }
          cp "$payload_file" "$dir/run.sh" || { echo "automation script copy failed"; exit 65; }
          chmod 700 "$dir/run.sh" 2>/dev/null || true
          printf '%s\\n' "$name" > "$dir/title.txt" || { echo "automation title write failed"; exit 65; }
          {
            echo "id=$id"
            echo "trigger=$trigger"
            echo "enabled=1"
            echo "created_at=$(timestamp)"
            echo "last_run=never"
            echo "last_run_epoch=0"
            echo "last_exit=unknown"
            echo "run_count=0"
          } > "$dir/automation.env" || { echo "automation metadata write failed"; exit 65; }
          log_event "automation_create id=$id trigger=$trigger"
          echo "automation saved -> id=$id trigger=$trigger script=$(display_automation_path "$dir/run.sh")"
        }

        automation_list() {
          init_runtime
          env_files="$(find "$AUTOMATION_DIR" -mindepth 2 -maxdepth 2 -name automation.env 2>/dev/null | sort || true)"
          if [ -z "$env_files" ]; then
            echo "no automations installed in $AUTOMATION_DISPLAY_DIR"
            exit 0
          fi
          printf '%s\\n' "$env_files" | while read -r env_file; do
            [ -n "$env_file" ] || continue
            dir="$(dirname "$env_file")"
            id="$(basename "$dir")"
            trigger="manual"; enabled="1"; last_run="never"; last_exit="unknown"; run_count="0"
            . "$env_file" 2>/dev/null || true
            title="$(sed -n '1p' "$dir/title.txt" 2>/dev/null || echo "$id")"
            printf '%s\\t%s\\ttrigger=%s\\tenabled=%s\\tlast_run=%s\\tlast_exit=%s\\trun_count=%s\\n' "$id" "$title" "$trigger" "$enabled" "$last_run" "$last_exit" "$run_count"
          done
        }

        automation_should_run() {
          trigger="${1:-manual}"
          last_run_epoch="${2:-0}"
          now_epoch="$(date +%s 2>/dev/null || echo 0)"
          case "$trigger" in
            on_boot)
              [ "$last_run_epoch" = "0" ] && return 0 || return 1
              ;;
            hourly)
              [ $((now_epoch - last_run_epoch)) -ge 3600 ] && return 0 || return 1
              ;;
            daily)
              [ $((now_epoch - last_run_epoch)) -ge 86400 ] && return 0 || return 1
              ;;
            interval:*)
              seconds="${trigger#interval:}"
              [ "${seconds:-0}" -gt 0 ] 2>/dev/null || return 1
              [ $((now_epoch - last_run_epoch)) -ge "$seconds" ] && return 0 || return 1
              ;;
            *)
              return 1
              ;;
          esac
        }

        automation_run_one() {
          id="$(safe_name "${1:-}")"
          if [ -z "$id" ]; then
            echo "usage: ogent-agent automation-run <automation-id>"
            exit 64
          fi
          dir="$AUTOMATION_DIR/$id"
          env_file="$dir/automation.env"
          script_file="$dir/run.sh"
          if [ ! -f "$env_file" ] || [ ! -f "$script_file" ]; then
            echo "automation not found: $id"
            exit 66
          fi
          trigger="manual"; enabled="1"; run_count="0"; last_run="never"; last_run_epoch="0"; last_exit="unknown"; timeout_s="600"
          . "$env_file" 2>/dev/null || true
          case "$timeout_s" in ''|*[!0-9]*) timeout_s="600" ;; esac
          if [ "$enabled" != "1" ]; then
            echo "automation disabled: $id"
            exit 67
          fi
          now="$(timestamp)"
          now_epoch="$(date +%s 2>/dev/null || echo 0)"
          run_id="$(date +%Y%m%d%H%M%S 2>/dev/null)-$$"
          out="$dir/runs/$run_id.log"
          cd "$WORKSPACE" || exit 65
          export OGENT_ROOT="$ROOT"
          export MINIS_ROOT="$ROOT"
          export OGENT_WORKSPACE="$WORKSPACE"
          export OGENT_ARTIFACTS="$ARTIFACT_DIR"
          {
            echo "automation_id=$id"
            echo "started_at=$now"
            echo "--- output ---"
          } > "$out"
          # One hung automation must not hold up the others (automation_due runs them in
          # turn) or outlive the app's run budget; exit 124 marks a timeout.
          if [ "$timeout_s" != "0" ] && command -v timeout >/dev/null 2>&1; then
            timeout "$timeout_s" /bin/sh "$script_file" >> "$out" 2>&1
          else
            /bin/sh "$script_file" >> "$out" 2>&1
          fi
          code=$?
          {
            echo "--- status ---"
            echo "exit=$code"
            echo "finished_at=$(timestamp)"
          } >> "$out"
          run_count=$((run_count + 1))
          {
            echo "id=$id"
            echo "trigger=$trigger"
            echo "enabled=$enabled"
            echo "created_at=${created_at:-$now}"
            echo "last_run=$now"
            echo "last_run_epoch=$now_epoch"
            echo "last_exit=$code"
            echo "run_count=$run_count"
            echo "timeout_s=$timeout_s"
          } > "$env_file"
          log_event "automation_run id=$id exit=$code"
          echo "[ogent-automation id=$id exit=$code log=$(display_automation_path "$out")]"
          tail -n 80 "$out"
          return "$code"
        }

        automation_due() {
          init_runtime
          run_due="${1:-list}"
          env_files="$(find "$AUTOMATION_DIR" -mindepth 2 -maxdepth 2 -name automation.env 2>/dev/null | sort || true)"
          if [ -z "$env_files" ]; then
            echo "no automations installed in $AUTOMATION_DISPLAY_DIR"
            exit 0
          fi
          due_file="$TMP_DIR/automation_due.$$"
          : > "$due_file"
          printf '%s\\n' "$env_files" | while read -r env_file; do
            [ -n "$env_file" ] || continue
            dir="$(dirname "$env_file")"
            id="$(basename "$dir")"
            trigger="manual"; enabled="1"; last_run_epoch="0"; last_run="never"
            . "$env_file" 2>/dev/null || true
            [ "$enabled" = "1" ] || continue
            if automation_should_run "$trigger" "$last_run_epoch"; then
              echo "$id" >> "$due_file"
              title="$(sed -n '1p' "$dir/title.txt" 2>/dev/null || echo "$id")"
              if [ "$run_due" = "run" ]; then
                automation_run_one "$id"
              else
                printf '%s\\t%s\\ttrigger=%s\\tlast_run=%s\\n' "$id" "$title" "$trigger" "$last_run"
              fi
            fi
          done
          if [ ! -s "$due_file" ]; then
            echo "no automations due"
          fi
          rm -f "$due_file"
        }

        task_log() {
          init_runtime
          id="$(safe_name "${1:-}")"
          log="$TASK_DIR/$id/output.log"
          if [ ! -f "$log" ]; then
            echo "task log not found: $id"
            exit 66
          fi
          tail -n 180 "$log"
        }

        task_status() {
          init_runtime
          echo "Ogent task status"
          echo "root=$(display_path "$ROOT")"
          echo "workspace=$(display_path "$WORKSPACE")"
          echo "artifacts=$(display_path "$ARTIFACT_DIR")"
          echo "current_session=$(current_session_id)"
          echo
          echo "--- plan progress ---"
          if [ -f "$PLAN_FILE" ]; then
            total="$(grep -c '^- \\[' "$PLAN_FILE" 2>/dev/null || true)"
            done_count="$(grep -ci '^- \\[x\\]' "$PLAN_FILE" 2>/dev/null || true)"
            open_count="$(grep -ci '^- \\[ \\]' "$PLAN_FILE" 2>/dev/null || true)"
            [ -n "$total" ] || total=0
            [ -n "$done_count" ] || done_count=0
            [ -n "$open_count" ] || open_count=0
            echo "plan=$(display_path "$PLAN_FILE")"
            echo "plan_items=$total done=$done_count open=$open_count"
            sed -n '1,80p' "$PLAN_FILE"
          else
            echo "plan=not-created"
            echo "plan_items=0 done=0 open=0"
          fi
          echo
          echo "--- latest task ---"
          latest_task_dir="$(latest_engineering_task_dir)"
          if [ -n "$latest_task_dir" ] && [ -d "$latest_task_dir" ]; then
            latest_task="$(basename "$latest_task_dir")"
            echo "latest_task=$latest_task"
            echo "latest_task_log=$(display_path "$latest_task_dir/output.log")"
            grep -E '^(title|exit|finished_at)=' "$latest_task_dir/output.log" 2>/dev/null | tail -n 8 || true
            echo "--- latest task tail ---"
            tail -n 24 "$latest_task_dir/output.log" 2>/dev/null || true
          else
            echo "latest_task=none"
          fi
          echo
          echo "--- deliverables ---"
          artifact_count="$(find "$ARTIFACT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
          [ -n "$artifact_count" ] || artifact_count=0
          echo "artifact_count=$artifact_count"
          if [ "$artifact_count" != "0" ]; then
            find "$ARTIFACT_DIR" -maxdepth 3 -type f 2>/dev/null | sort | tail -n 40 | sed "s#$ARTIFACT_DIR/#$(display_path "$ARTIFACT_DIR")/#"
            echo "delivery_state=ready_to_summarize"
          else
            echo "delivery_state=needs_artifact_if_user_requested_file"
          fi
          echo
          echo "--- memory and automation ---"
          echo "wiki_topic_pages=$(find "$WIKI_TOPIC_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
          if [ -f "$RAG_INDEX" ]; then
            echo "rag_chunks=$(wc -l < "$RAG_INDEX" 2>/dev/null | tr -d ' ')"
          else
            echo "rag_chunks=0"
          fi
          echo "automations=$(count_automations)"
          echo "task_status_ok"
        }

        artifact_list() {
          init_runtime
          echo "artifacts=$(display_path "$ARTIFACT_DIR")"
          if [ "$(count_files "$ARTIFACT_DIR")" != "0" ]; then
            find "$ARTIFACT_DIR" -maxdepth 3 -type f 2>/dev/null | sort | sed "s#$ARTIFACT_DIR/##" | head -n 160
            exit 0
          fi
          echo "no explicit artifacts; workspace files:"
          find "$WORKSPACE" -maxdepth 3 -type f 2>/dev/null | sort | sed "s#$WORKSPACE/##" | head -n 160
        }

        artifact_manifest() {
          init_runtime
          echo "artifact_manifest_ok"
          echo "artifacts=$(display_path "$ARTIFACT_DIR")"
          count="$(find "$ARTIFACT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
          [ -n "$count" ] || count=0
          echo "artifact_count=$count"
          if [ "$count" = "0" ]; then
            echo "artifact_manifest_empty=true"
            exit 0
          fi
          find "$ARTIFACT_DIR" -maxdepth 3 -type f 2>/dev/null | sort | tail -n 80 | while read -r file; do
            rel="${file#$ARTIFACT_DIR/}"
            size="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"
            [ -n "$size" ] || size=0
            modified="$(date -r "$file" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || echo unknown)"
            mime="$(file -b "$file" 2>/dev/null | sed 's/[[:space:]]\\+/ /g' | cut -c 1-90)"
            echo "artifact=$rel"
            echo "  path=$(display_path "$file")"
            echo "  bytes=$size"
            echo "  modified=$modified"
            echo "  kind=${mime:-unknown}"
          done
        }

        workspace_snapshot() {
          init_runtime
          echo "Ogent workspace snapshot"
          echo "root=$(display_path "$ROOT")"
          echo "workspace=$(display_path "$WORKSPACE")"
          echo "artifacts=$(display_path "$ARTIFACT_DIR")"
          echo "current_session=$(current_session_id)"
          echo "current_project=$(current_project_manifest_id)"
          echo "disk=$(du -sh "$ROOT" 2>/dev/null | awk '{print $1}')"
          echo
          echo "--- latest status ---"
          sed -n '1,80p' "$LATEST_STATUS"
          echo
          echo "--- plan ---"
          if [ -f "$PLAN_FILE" ]; then
            sed -n '1,100p' "$PLAN_FILE"
          else
            echo "no plan"
          fi
          echo
          echo "--- recent session ---"
          session_read --tail 60 2>/dev/null || true
          echo
          echo "--- project manifest ---"
          project_manifest_read | sed -n '1,180p'
          echo
          echo "--- recent notes ---"
          tail -n 60 "$NOTES_FILE" 2>/dev/null || true
          echo
          echo "--- recent activity ---"
          tail -n 40 "$LOG_DIR/activity.log" 2>/dev/null || true
          echo
          echo "--- workspace files ---"
          find "$WORKSPACE" -maxdepth 3 -type f 2>/dev/null | sort | sed "s#$WORKSPACE/##" | head -n 160
          echo
          echo "--- artifacts ---"
          find "$ARTIFACT_DIR" -maxdepth 3 -type f 2>/dev/null | sort | sed "s#$ARTIFACT_DIR/##" | head -n 160
          echo
          echo "--- artifact manifest ---"
          artifact_manifest | sed -n '1,120p'
          echo
          echo "--- automations ---"
          automation_list | sed -n '1,80p'
        }

        finalizer_snapshot() {
          init_runtime
          echo "Ogent finalizer checkpoint"
          echo "finalizer_snapshot_ok"
          echo "version=$VERSION"
          echo "root=$(display_path "$ROOT")"
          echo "workspace=$(display_path "$WORKSPACE")"
          echo "artifacts=$(display_path "$ARTIFACT_DIR")"
          echo "current_session=$(current_session_id)"
          echo "current_project=$(current_project_manifest_id)"
          echo
          echo "--- completion gates ---"
          artifact_count="$(find "$ARTIFACT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
          [ -n "$artifact_count" ] || artifact_count=0
          active_session_head="$(session_read 2>/dev/null || true)"
          active_session_recent="$(session_read --tail 60 2>/dev/null || true)"
          active_session="$(printf '%s\\n%s\\n' "$active_session_head" "$active_session_recent")"
          completion_contract="$(printf '%s\\n' "$active_session_head" | awk '/^- completion_contract:/{value=$0; sub(/^- completion_contract:[[:space:]]*/, "", value)} END{print value}')"
          expected_output="$(printf '%s\\n' "$active_session_head" | awk '/^- expected_output:/{value=$0; sub(/^- expected_output:[[:space:]]*/, "", value)} END{print value}')"
          requires_artifact="$(printf '%s\\n' "$active_session_head" | awk '/^- requires_artifact:/{value=$0; sub(/^- requires_artifact:[[:space:]]*/, "", value)} END{print value}')"
          finalizer_gate="$(printf '%s\\n' "$active_session_head" | awk '/^- finalizer_gate:/{value=$0; sub(/^- finalizer_gate:[[:space:]]*/, "", value)} END{print value}')"
          [ -n "$completion_contract" ] || completion_contract="unknown"
          [ -n "$expected_output" ] || expected_output="unknown"
          [ -n "$requires_artifact" ] || requires_artifact="false"
          [ -n "$finalizer_gate" ] || finalizer_gate="unknown"
          if [ -f "$PLAN_FILE" ]; then
            plan_state="present"
            plan_total="$(grep -c '^- \\[' "$PLAN_FILE" 2>/dev/null || true)"
            plan_done="$(grep -ci '^- \\[x\\]' "$PLAN_FILE" 2>/dev/null || true)"
            plan_open="$(grep -ci '^- \\[ \\]' "$PLAN_FILE" 2>/dev/null || true)"
          else
            plan_state="missing"
            plan_total=0
            plan_done=0
            plan_open=0
          fi
          latest_task_dir="$(latest_engineering_task_dir)"
          latest_task="none"
          latest_task_exit="none"
          if [ -n "$latest_task_dir" ] && [ -d "$latest_task_dir" ]; then
            latest_task="$(basename "$latest_task_dir")"
            latest_task_exit="$(grep -E '^exit=' "$latest_task_dir/output.log" 2>/dev/null | tail -n 1 | cut -d= -f2-)"
            [ -n "$latest_task_exit" ] || latest_task_exit="unknown"
          fi
          echo "plan_state=$plan_state plan_items=${plan_total:-0} done=${plan_done:-0} open=${plan_open:-0}"
          echo "latest_task=$latest_task latest_task_exit=$latest_task_exit"
          echo "completion_contract=$completion_contract"
          echo "expected_output=$expected_output"
          echo "requires_artifact=$requires_artifact"
          echo "finalizer_gate=$finalizer_gate"
          echo "artifact_count=$artifact_count"
          echo "artifact_manifest_ok"
          if [ "$artifact_count" != "0" ]; then
            latest_artifact="$(find "$ARTIFACT_DIR" -maxdepth 3 -type f 2>/dev/null | sort | tail -n 1)"
            if [ -n "$latest_artifact" ]; then
              latest_rel="${latest_artifact#$ARTIFACT_DIR/}"
              latest_bytes="$(wc -c < "$latest_artifact" 2>/dev/null | tr -d ' ')"
              [ -n "$latest_bytes" ] || latest_bytes=0
              echo "latest_artifact=$latest_rel"
              echo "latest_artifact_path=$(display_path "$latest_artifact")"
              echo "latest_artifact_bytes=$latest_bytes"
            fi
          fi
          echo "session_state=$(current_session_id)"
          project_id="$(current_project_manifest_id)"
          project_status="unknown"
          project_session="unknown"
          echo "project_manifest_state=$project_id"
          if [ "$project_id" != "none" ] && [ -f "$PROJECT_MANIFEST_DIR/$project_id/manifest.env" ]; then
            project_status="$(sed -n 's/^status=//p' "$PROJECT_MANIFEST_DIR/$project_id/manifest.env" | tail -n 1)"
            project_session="$(sed -n 's/^session_id=//p' "$PROJECT_MANIFEST_DIR/$project_id/manifest.env" | tail -n 1)"
            [ -n "$project_status" ] || project_status="unknown"
            [ -n "$project_session" ] || project_session="unknown"
            echo "project_manifest_status=$project_status"
            echo "project_manifest_session=$project_session"
          fi
          echo "wiki_topic_pages=$(find "$WIKI_TOPIC_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
          if [ -f "$RAG_INDEX" ]; then
            echo "rag_chunks=$(wc -l < "$RAG_INDEX" 2>/dev/null | tr -d ' ')"
          else
            echo "rag_chunks=0"
          fi
          echo "skills=$(count_files "$SKILL_DIR")"
          echo "subagents=$(find "$SUBAGENT_DIR" -maxdepth 2 -name AGENT.md 2>/dev/null | wc -l | tr -d ' ')"
          echo "queued_subagent_tasks=$(grep -l '^status=queued$' "$SUBAGENT_DIR"/*/tasks/*.env 2>/dev/null | wc -l | tr -d ' ')"
          echo "running_subagent_tasks=$(grep -l '^status=running$' "$SUBAGENT_DIR"/*/tasks/*.env 2>/dev/null | wc -l | tr -d ' ')"
          echo "completed_subagent_tasks=$(grep -l '^status=completed$' "$SUBAGENT_DIR"/*/tasks/*.env 2>/dev/null | wc -l | tr -d ' ')"
          echo "failed_subagent_tasks=$(grep -l '^status=failed$' "$SUBAGENT_DIR"/*/tasks/*.env 2>/dev/null | wc -l | tr -d ' ')"
          echo "automations=$(count_automations)"
          echo "profiles=$(find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.env' 2>/dev/null | wc -l | tr -d ' ')"
          rootfs_overlay_line
          project_manifest_failed=0
          project_manifest_running=0
          case "$project_status" in
            tool_failed|recovering|tool_canceled) project_manifest_failed=1 ;;
            running|tool_running) project_manifest_running=1 ;;
          esac
          latest_task_failed=0
          if [ "$latest_task_exit" != "none" ] && [ "$latest_task_exit" != "0" ]; then
            latest_task_failed=1
          fi
          ready_warning=0
          if [ "$project_manifest_failed" = "1" ] || [ "$latest_task_failed" = "1" ]; then
            ready_warning=1
          fi
          if [ "$requires_artifact" = "true" ] && [ "$artifact_count" = "0" ]; then
            echo "delivery_state=artifact_required_missing"
          elif [ "$artifact_count" = "0" ] && [ "$project_manifest_failed" = "1" ]; then
            echo "delivery_state=project_manifest_failed"
          elif [ "$artifact_count" = "0" ] && [ "$project_manifest_running" = "1" ]; then
            echo "delivery_state=project_manifest_in_progress"
          elif [ "$artifact_count" != "0" ] && [ "$ready_warning" = "1" ]; then
            echo "delivery_state=ready_with_warnings"
          elif [ "$artifact_count" != "0" ]; then
            echo "delivery_state=ready_to_summarize"
          elif [ "${plan_open:-0}" != "0" ]; then
            echo "delivery_state=plan_open_no_artifact"
          elif [ "$latest_task_failed" = "1" ]; then
            echo "delivery_state=latest_task_failed"
          else
            echo "delivery_state=needs_final_explanation"
          fi
          echo
          echo "--- recent session ---"
          printf '%s\\n' "$active_session_recent" | sed -n '1,80p'
          echo
          echo "--- project manifest ---"
          project_manifest_read | sed -n '1,180p'
          echo
          echo "--- task status ---"
          task_status | sed -n '1,140p'
          echo
          echo "--- active session head ---"
          printf '%s\\n' "$active_session_head" | sed -n '1,100p'
          echo
          echo "--- artifacts ---"
          artifact_list | sed -n '1,120p'
          echo
          echo "--- artifact manifest ---"
          artifact_manifest | sed -n '1,140p'
          echo
          echo "--- memory wiki/rag ---"
          wiki_summary | sed -n '1,80p'
          echo
          echo "--- skills ---"
          skill_list | sed -n '1,80p'
          echo
          echo "--- subagents ---"
          subagent_list | sed -n '1,80p'
          echo
          echo "--- automations ---"
          automation_list | sed -n '1,80p'
          echo
          echo "--- rootfs profiles ---"
          rootfs_overlay_status | sed -n '1,80p'
          profile_status core | tail -n 1
          profile_status mcp | tail -n 1
          profile_status 12306 | tail -n 1
          profile_status document | tail -n 1
          profile_status media | tail -n 1
          profile_status local-model | tail -n 1
          echo
          echo "--- local model readiness ---"
          model_readiness_print | sed -n '1,40p'
          echo
          echo "--- recent activity ---"
          tail -n 60 "$LOG_DIR/activity.log" 2>/dev/null || true
          echo "finalizer_snapshot_ok"
        }

        checkpoint_create() {
          init_runtime
          name="checkpoint"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --name) name="${2:-checkpoint}"; shift 2 ;;
              *) shift ;;
            esac
          done
          id="$(date +%Y%m%d%H%M%S 2>/dev/null)-$(safe_name "$name")"
          file="$CHECKPOINT_DIR/$id.tar.gz"
          tar -czf "$file" -C "$ROOT" workspace PLAN.md NOTES.md LATEST_STATUS memory skills subagents inbox tasks artifacts sessions env.d profile README.md 2>/dev/null
          code=$?
          if [ "$code" != "0" ]; then
            rm -f "$file"
            echo "checkpoint failed: tar exit $code"
            exit "$code"
          fi
          log_event "checkpoint_create id=$id"
          echo "checkpoint created -> $(display_path "$file")"
        }

        checkpoint_list() {
          init_runtime
          if [ "$(count_files "$CHECKPOINT_DIR")" = "0" ]; then
            echo "no checkpoints"
            exit 0
          fi
          find "$CHECKPOINT_DIR" -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | sort | while read -r file; do
            printf '%s\\t%s\\n' "$(basename "$file")" "$(du -h "$file" 2>/dev/null | awk '{print $1}')"
          done
        }

        checkpoint_restore() {
          init_runtime
          id="$(safe_name "${1:-}")"
          if [ -z "$id" ]; then
            echo "usage: ogent-agent checkpoint-restore <checkpoint-id.tar.gz>"
            exit 64
          fi
          file="$CHECKPOINT_DIR/$id"
          case "$file" in
            *.tar.gz) ;;
            *) file="$file.tar.gz" ;;
          esac
          if [ ! -f "$file" ]; then
            echo "checkpoint not found: $id"
            exit 66
          fi
          # Refuse archives with members that would land outside $ROOT
          # (absolute paths or `..` components) before extracting anything.
          members="$TMP_DIR/checkpoint-restore-$$.list"
          if ! tar -tzf "$file" > "$members" 2>/dev/null; then
            rm -f "$members"
            echo "checkpoint restore failed: unreadable archive"
            exit 65
          fi
          while IFS= read -r member; do
            case "$member" in
              /*|..|../*|*/..|*/../*)
                rm -f "$members"
                echo "checkpoint restore refused: unsafe member path: $member"
                exit 65
                ;;
            esac
          done < "$members"
          rm -f "$members"
          tar -xzf "$file" -C "$ROOT"
          code=$?
          if [ "$code" != "0" ]; then
            echo "checkpoint restore failed: tar exit $code"
            exit "$code"
          fi
          log_event "checkpoint_restore id=$id"
          echo "checkpoint restored <- $(display_path "$file")"
        }

        shell_assign() {
          key="$1"
          value="${2:-}"
          escaped="$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
          printf "%s='%s'\\n" "$key" "$escaped"
        }

        shell_quote_value() {
          value="${1:-}"
          escaped="$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
          printf "'%s'" "$escaped"
        }

        model_readiness_write() {
          state="${1:-unknown}"
          reason="${2:-unknown}"
          runner="${3:-unknown}"
          model="${4:-unknown}"
          runtime="${5:-unknown}"
          next="${6:-unknown}"
          base_url="${7:-${OGENT_LOCAL_MODEL_BASE_URL:-}}"
          model_id="${8:-${OGENT_LOCAL_MODEL_ID:-}}"
          tmp="$MODEL_READINESS.tmp.$$"
          {
            shell_assign LOCAL_MODEL_READINESS_STATE "$state"
            shell_assign LOCAL_MODEL_READINESS_REASON "$reason"
            shell_assign LOCAL_MODEL_RUNNER_STATE "$runner"
            shell_assign LOCAL_MODEL_GGUF_STATE "$model"
            shell_assign LOCAL_MODEL_RUNTIME_STATE "$runtime"
            shell_assign LOCAL_MODEL_NEXT_COMMAND "$next"
            shell_assign LOCAL_MODEL_BASE_URL "$base_url"
            shell_assign LOCAL_MODEL_ID "$model_id"
            shell_assign LOCAL_MODEL_UPDATED_AT "$(timestamp)"
          } > "$tmp"
          chmod 600 "$tmp" 2>/dev/null || true
          mv "$tmp" "$MODEL_READINESS" 2>/dev/null || cp "$tmp" "$MODEL_READINESS" 2>/dev/null || true
          rm -f "$tmp" 2>/dev/null || true
        }

        model_readiness_print() {
          if [ -f "$MODEL_READINESS" ]; then
            . "$MODEL_READINESS" 2>/dev/null || true
            echo "readiness_manifest=$(display_path "$MODEL_READINESS")"
            echo "local_model_readiness_state=${LOCAL_MODEL_READINESS_STATE:-unknown}"
            echo "local_model_readiness_reason=${LOCAL_MODEL_READINESS_REASON:-unknown}"
            echo "local_model_runner_state=${LOCAL_MODEL_RUNNER_STATE:-unknown}"
            echo "local_model_gguf_state=${LOCAL_MODEL_GGUF_STATE:-unknown}"
            echo "local_model_runtime_state=${LOCAL_MODEL_RUNTIME_STATE:-unknown}"
            echo "local_model_next_command=${LOCAL_MODEL_NEXT_COMMAND:-unknown}"
            echo "local_model_base_url=${LOCAL_MODEL_BASE_URL:-unknown}"
            echo "local_model_id=${LOCAL_MODEL_ID:-unknown}"
            echo "local_model_readiness_updated_at=${LOCAL_MODEL_UPDATED_AT:-unknown}"
          else
            echo "readiness_manifest=not-created"
            echo "local_model_readiness_state=unknown"
            echo "local_model_readiness_reason=not_scanned"
            echo "local_model_next_command=/bin/sh /usr/local/bin/ogent-agent model-scan"
          fi
        }

        load_model_config() {
          OGENT_LOCAL_MODEL_BASE_URL="${OGENT_LOCAL_MODEL_BASE_URL:-${OASES_LOCAL_MODEL_BASE_URL:-}}"
          OGENT_LOCAL_MODEL_ID="${OGENT_LOCAL_MODEL_ID:-${OASES_LOCAL_MODEL_ID:-}}"
          OGENT_LOCAL_MODEL_API_KEY="${OGENT_LOCAL_MODEL_API_KEY:-${OASES_LOCAL_MODEL_API_KEY:-}}"
          OGENT_LOCAL_MODEL_START_COMMAND="${OGENT_LOCAL_MODEL_START_COMMAND:-}"
          OGENT_LOCAL_MODEL_RUNTIME_KIND="${OGENT_LOCAL_MODEL_RUNTIME_KIND:-}"
          OGENT_LOCAL_MODEL_FILE="${OGENT_LOCAL_MODEL_FILE:-}"
          OGENT_LOCAL_MODEL_EXTRA_ARGS="${OGENT_LOCAL_MODEL_EXTRA_ARGS:-}"
          if [ -f "$MODEL_CONFIG" ]; then
            . "$MODEL_CONFIG"
          fi
        }

        model_config() {
          init_runtime
          load_model_config
          base_url="$OGENT_LOCAL_MODEL_BASE_URL"
          model_id="$OGENT_LOCAL_MODEL_ID"
          api_key="$OGENT_LOCAL_MODEL_API_KEY"
          start_command="$OGENT_LOCAL_MODEL_START_COMMAND"
          runtime_kind="$OGENT_LOCAL_MODEL_RUNTIME_KIND"
          model_file="$OGENT_LOCAL_MODEL_FILE"
          extra_args="$OGENT_LOCAL_MODEL_EXTRA_ARGS"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --base-url) base_url="${2:-}"; shift 2 ;;
              --model|--model-id) model_id="${2:-}"; shift 2 ;;
              --api-key) api_key="${2:-}"; shift 2 ;;
              --start-command) start_command="${2:-}"; shift 2 ;;
              --runtime-kind) runtime_kind="${2:-}"; shift 2 ;;
              --model-file) model_file="${2:-}"; shift 2 ;;
              --extra-args) extra_args="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          {
            shell_assign OGENT_LOCAL_MODEL_BASE_URL "$base_url"
            shell_assign OGENT_LOCAL_MODEL_ID "$model_id"
            shell_assign OGENT_LOCAL_MODEL_API_KEY "$api_key"
            shell_assign OGENT_LOCAL_MODEL_START_COMMAND "$start_command"
            shell_assign OGENT_LOCAL_MODEL_RUNTIME_KIND "$runtime_kind"
            shell_assign OGENT_LOCAL_MODEL_FILE "$model_file"
            shell_assign OGENT_LOCAL_MODEL_EXTRA_ARGS "$extra_args"
          } > "$MODEL_CONFIG"
          chmod 600 "$MODEL_CONFIG" 2>/dev/null || true
          log_event "model_config base_url=$(safe_name "$base_url") model=$(safe_name "$model_id")"
          echo "model_config_saved config=$(display_path "$MODEL_CONFIG")"
          echo "local_model_base_url=${base_url:-not-configured}"
          echo "local_model_id=${model_id:-not-configured}"
          if [ -n "$start_command" ]; then
            echo "local_model_start_command=configured"
          else
            echo "local_model_start_command=not-configured"
          fi
          echo "local_model_runtime_kind=${runtime_kind:-not-configured}"
          echo "local_model_file=${model_file:-not-configured}"
          model_readiness_write "configured" "model_config_saved" "unknown" "unknown" "unknown" "/bin/sh /usr/local/bin/ogent-agent model-scan" "$base_url" "$model_id"
          model_readiness_print
        }

        model_default_base_url() {
          printf '%s\n' "${OGENT_DEFAULT_LOCAL_MODEL_BASE_URL:-http://127.0.0.1:11434/v1}"
        }

        model_default_id() {
          printf '%s\n' "${OGENT_DEFAULT_LOCAL_MODEL_ID:-ogent-local-echo}"
        }

        model_api_base_url() {
          value="${1:-}"
          value="${value%/}"
          case "$value" in
            */chat/completions) value="${value%/chat/completions}" ;;
          esac
          case "$value" in
            */models) value="${value%/models}" ;;
          esac
          printf '%s\n' "$value"
        }

        model_current_pid() {
          if [ -f "$MODEL_PID" ]; then
            sed -n '1p' "$MODEL_PID" 2>/dev/null | tr -cd '0-9'
          fi
        }

        model_is_running() {
          pid="$(model_current_pid)"
          [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
        }

        model_url_host() {
          printf '%s\n' "$1" | awk -F/ '{print $3}' | awk -F: '{print $1}'
        }

        model_url_port() {
          parsed="$(printf '%s\n' "$1" | awk -F/ '{print $3}' | awk -F: 'NF > 1 {print $NF}')"
          if [ -n "$parsed" ]; then
            printf '%s\n' "$parsed"
          else
            printf '%s\n' "${OGENT_DEFAULT_LOCAL_MODEL_PORT:-11434}"
          fi
        }

        expected_guest_arch() {
          arch="$(uname -m 2>/dev/null || true)"
          case "$arch" in
            aarch64|arm64) echo "aarch64"; return 0 ;;
            i386|i486|i586|i686|x86) echo "i386"; return 0 ;;
          esac
          if [ -e /lib/ld-musl-aarch64.so.1 ] || [ -e /lib/libc.musl-aarch64.so.1 ]; then
            echo "aarch64"
          else
            echo "i386"
          fi
        }

        file_is_ish_elf() {
          file="${1:-}"
          [ -f "$file" ] || return 1
          bytes="$(od -An -t u1 -N 20 "$file" 2>/dev/null | tr -s ' ' ' ' | sed 's/^ //;s/ $//')"
          [ -n "$bytes" ] || return 1
          set -- $bytes
          [ "${1:-}" = "127" ] || return 1
          [ "${2:-}" = "69" ] || return 1
          [ "${3:-}" = "76" ] || return 1
          [ "${4:-}" = "70" ] || return 1
          [ "${6:-}" = "1" ] || return 1
          case "${17:-}" in
            2|3) ;;
            *) return 1 ;;
          esac
          [ "${18:-}" = "0" ] || return 1
          case "$(expected_guest_arch)" in
            aarch64)
              [ "${5:-}" = "2" ] || return 1
              [ "${19:-}" = "183" ] || return 1
              [ "${20:-}" = "0" ] || return 1
              ;;
            *)
              [ "${5:-}" = "1" ] || return 1
              [ "${19:-}" = "3" ] || return 1
              [ "${20:-}" = "0" ] || return 1
              ;;
          esac
          return 0
        }

        find_llama_server() {
          for candidate in \
            "${OGENT_LLAMA_SERVER:-}" \
            "$ROOT/bin/llama-server" \
            "$MODEL_DIR/bin/llama-server" \
            "$WORKSPACE/llama.cpp/build/bin/llama-server" \
            "$WORKSPACE/llama.cpp/server" \
            "/usr/local/bin/llama-server" \
            "/usr/bin/llama-server"; do
            [ -n "$candidate" ] && [ -x "$candidate" ] && file_is_ish_elf "$candidate" && { printf '%s\n' "$candidate"; return 0; }
          done
          if command -v llama-server >/dev/null 2>&1 && file_is_ish_elf "$(command -v llama-server)"; then
            command -v llama-server
            return 0
          fi
          return 1
        }

        find_incompatible_llama_server() {
          for candidate in \
            "${OGENT_LLAMA_SERVER:-}" \
            "$ROOT/bin/llama-server" \
            "$MODEL_DIR/bin/llama-server" \
            "$WORKSPACE/llama.cpp/build/bin/llama-server" \
            "$WORKSPACE/llama.cpp/server" \
            "/usr/local/bin/llama-server" \
            "/usr/bin/llama-server"; do
            [ -n "$candidate" ] && [ -x "$candidate" ] && ! file_is_ish_elf "$candidate" && { printf '%s\n' "$candidate"; return 0; }
          done
          if command -v llama-server >/dev/null 2>&1 && ! file_is_ish_elf "$(command -v llama-server)"; then
            command -v llama-server
            return 0
          fi
          return 1
        }

        write_elf_fixture() {
          file="$1"
          class_byte="$2"
          machine_low="$3"
          case "$class_byte:$machine_low" in
            2:183)
              printf '\\177ELF\\002\\001\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\002\\000\\267\\000' > "$file"
              ;;
            1:3)
              printf '\\177ELF\\001\\001\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\002\\000\\003\\000' > "$file"
              ;;
            2:62)
              printf '\\177ELF\\002\\001\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\002\\000\\076\\000' > "$file"
              ;;
            1:40)
              printf '\\177ELF\\001\\001\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\002\\000\\050\\000' > "$file"
              ;;
            *)
              printf '\\000' > "$file"
              ;;
          esac
          chmod 755 "$file" 2>/dev/null || true
        }

        model_runner_validation_selftest() {
          init_runtime
          dir="$TMP_DIR/model-runner-validation-$$"
          mkdir -p "$dir"
          guest_arch="$(expected_guest_arch)"
          valid="$dir/llama-server-$guest_arch"
          i386="$dir/llama-server-i386"
          x8664="$dir/llama-server-x86_64"
          arm="$dir/llama-server-arm"
          macho="$dir/llama-server-macho"
          if [ "$guest_arch" = "aarch64" ]; then
            write_elf_fixture "$valid" 2 183
            write_elf_fixture "$i386" 1 3
          else
            write_elf_fixture "$valid" 1 3
            write_elf_fixture "$i386" 2 183
          fi
          write_elf_fixture "$x8664" 2 62
          write_elf_fixture "$arm" 1 40
          printf '\\317\\372\\355\\376' > "$macho"
          chmod 755 "$macho" 2>/dev/null || true

          ok=1
          file_is_ish_elf "$valid" || ok=0
          file_is_ish_elf "$i386" && ok=0
          file_is_ish_elf "$x8664" && ok=0
          file_is_ish_elf "$arm" && ok=0
          file_is_ish_elf "$macho" && ok=0
          rm -rf "$dir" 2>/dev/null || true
          if [ "$ok" = "1" ]; then
            echo "model_runner_validation_selftest_ok accepted=$guest_arch rejected=wrong_guest_arch,x86_64,arm,macho"
            return 0
          fi
          echo "model_runner_validation_selftest_failed"
          return 70
        }

        model_file_is_gguf() {
          file="${1:-}"
          [ -f "$file" ] || return 1
          head -c 4 "$file" 2>/dev/null | grep -q '^GGUF'
        }

        find_model_file() {
          if [ -n "${OGENT_LOCAL_MODEL_FILE:-}" ] && model_file_is_gguf "$OGENT_LOCAL_MODEL_FILE"; then
            printf '%s\n' "$OGENT_LOCAL_MODEL_FILE"
            return 0
          fi
          found_model="$(
            find "$MODEL_DIR" "$WORKSPACE" -maxdepth 4 -type f -name '*.gguf' 2>/dev/null | sort | while IFS= read -r candidate; do
              if model_file_is_gguf "$candidate"; then
                printf '%s\n' "$candidate"
                break
              fi
            done | sed -n '1p'
          )"
          if [ -n "$found_model" ]; then
            printf '%s\n' "$found_model"
            return 0
          fi
          return 1
        }

        model_real_readiness() {
          runner_status="missing"
          runner_path=""
          if runner_path="$(find_llama_server 2>/dev/null)"; then
            runner_status="available"
          elif runner_path="$(find_incompatible_llama_server 2>/dev/null)"; then
            runner_status="invalid_ish_elf"
          fi
          model_status="missing"
          model_path=""
          if model_path="$(find_model_file 2>/dev/null)" && [ -n "$model_path" ] && [ -f "$model_path" ]; then
            model_status="available"
          fi
          echo "real_runtime_runner=$runner_status${runner_path:+ path=$(display_path "$runner_path")}"
          echo "real_runtime_model=$model_status${model_path:+ path=$(display_path "$model_path")}"
          if [ "$runner_status" = "available" ] && [ "$model_status" = "available" ]; then
            model_readiness_write "ready_to_start" "runner_and_gguf_available" "$runner_status" "$model_status" "not_probed" "/bin/sh /usr/local/bin/ogent-agent model-bootstrap --require-real" "${OGENT_LOCAL_MODEL_BASE_URL:-$(model_default_base_url)}" "${OGENT_LOCAL_MODEL_ID:-llama-local}"
            echo "real_local_model_runtime=ready"
            return 0
          fi
          missing=""
          [ "$runner_status" = "available" ] || missing="$missing llama_server_${runner_status}"
          [ "$model_status" = "available" ] || missing="$missing gguf_model"
          clean_missing="$(printf '%s' "$missing" | xargs 2>/dev/null || printf '%s' "$missing")"
          if [ "$runner_status" != "available" ]; then
            next="/bin/sh /usr/local/bin/ogent-agent model-provision --install-deps --build-runner --jobs 1"
            [ -n "$model_path" ] && next="$next --model-file $(shell_quote_value "$model_path")"
          elif [ "$model_status" != "available" ]; then
            next="provide_gguf_url_or_import_gguf"
          else
            next="/bin/sh /usr/local/bin/ogent-agent model-scan"
          fi
          model_readiness_write "missing" "$clean_missing" "$runner_status" "$model_status" "not_ready" "$next" "${OGENT_LOCAL_MODEL_BASE_URL:-$(model_default_base_url)}" "${OGENT_LOCAL_MODEL_ID:-llama-local}"
          echo "real_local_model_runtime=missing missing=$clean_missing"
          return 78
        }

        model_runtime_scan() {
          init_runtime
          load_model_config
          echo "Ogent local model runtime scan"
          echo "expected_runner_arch=$(expected_guest_arch)"
          if llama_server="$(find_llama_server 2>/dev/null)"; then
            echo "llama_server=available path=$(display_path "$llama_server")"
          elif incompatible_llama_server="$(find_incompatible_llama_server 2>/dev/null)"; then
            echo "llama_server=invalid_ish_elf path=$(display_path "$incompatible_llama_server")"
          else
            echo "llama_server=missing"
          fi
          if [ -n "${OGENT_LOCAL_MODEL_FILE:-}" ] && model_file_is_gguf "$OGENT_LOCAL_MODEL_FILE"; then
            echo "configured_model_file=present path=$(display_path "$OGENT_LOCAL_MODEL_FILE")"
          elif [ -n "${OGENT_LOCAL_MODEL_FILE:-}" ] && [ -f "$OGENT_LOCAL_MODEL_FILE" ]; then
            echo "configured_model_file=invalid_gguf_magic path=$(display_path "$OGENT_LOCAL_MODEL_FILE")"
          elif [ -n "${OGENT_LOCAL_MODEL_FILE:-}" ]; then
            echo "configured_model_file=missing path=$(display_path "$OGENT_LOCAL_MODEL_FILE")"
          else
            first_model_candidate="$(find "$MODEL_DIR" "$WORKSPACE" -maxdepth 4 -type f -name '*.gguf' 2>/dev/null | sort | sed -n '1p')"
            found_model="$(find_model_file 2>/dev/null || true)"
            if [ -n "$found_model" ]; then
              echo "discovered_model_file=$(display_path "$found_model")"
            elif [ -n "$first_model_candidate" ]; then
              echo "discovered_model_file=invalid_gguf_magic path=$(display_path "$first_model_candidate")"
            else
              echo "discovered_model_file=missing"
            fi
          fi
          model_real_readiness || true
          model_readiness_print
        }

        model_deployment_plan() {
          init_runtime
          load_model_config
          url=""
          sha256=""
          name=""
          model_id="${OGENT_LOCAL_MODEL_ID:-}"
          model_file="${OGENT_LOCAL_MODEL_FILE:-}"
          runner_url=""
          runner_sha256=""
          repo=""
          ref="${OGENT_LLAMA_CPP_REF:-}"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --url|--model-url) url="${2:-}"; shift 2 ;;
              --sha256) sha256="${2:-}"; shift 2 ;;
              --name|--filename) name="${2:-}"; shift 2 ;;
              --model|--model-id) model_id="${2:-}"; shift 2 ;;
              --model-file|--gguf-file) model_file="${2:-}"; shift 2 ;;
              --runner-url|--llama-server-url) runner_url="${2:-}"; shift 2 ;;
              --runner-sha256|--llama-server-sha256) runner_sha256="${2:-}"; shift 2 ;;
              --repo) repo="${2:-}"; shift 2 ;;
              --ref|--git-ref) ref="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          base_url="${OGENT_LOCAL_MODEL_BASE_URL:-$(model_default_base_url)}"
          [ -n "$model_id" ] || model_id="llama-local"
          plan_url="$url"
          plan_sha256="$sha256"
          plan_name="$name"
          plan_model_id="$model_id"
          plan_model_file="$model_file"
          plan_repo="$repo"
          plan_ref="$ref"
          plan_runner_url="$runner_url"
          plan_runner_sha256="$runner_sha256"
          echo "model_deployment_plan=start"
          echo "goal=real_iSH_llama_cpp_compat_endpoint"
          echo "base_url=$base_url"
          echo "model_id=$plan_model_id"
          expected_arch="$(expected_guest_arch)"
          echo "expected_runner_arch=$expected_arch"
          echo "runner_build_supported=1"
          echo "model_url=${plan_url:-missing}"
          echo "model_file=${plan_model_file:-auto-discover}"
          echo "runner_url=${plan_runner_url:-missing}"
          [ -n "$plan_runner_url" ] && echo "runner_sha256=${plan_runner_sha256:-missing_required}"
          provision_cmd="/bin/sh /usr/local/bin/ogent-agent model-provision --install-deps --build-runner --jobs 1 --model $(shell_quote_value "$plan_model_id")"
          [ -n "$plan_url" ] && provision_cmd="$provision_cmd --url $(shell_quote_value "$plan_url")"
          [ -n "$plan_sha256" ] && provision_cmd="$provision_cmd --sha256 $(shell_quote_value "$plan_sha256")"
          [ -n "$plan_name" ] && provision_cmd="$provision_cmd --name $(shell_quote_value "$plan_name")"
          [ -n "$plan_model_file" ] && provision_cmd="$provision_cmd --model-file $(shell_quote_value "$plan_model_file")"
          [ -n "$plan_runner_url" ] && provision_cmd="$provision_cmd --runner-url $(shell_quote_value "$plan_runner_url")"
          [ -n "$plan_runner_sha256" ] && provision_cmd="$provision_cmd --runner-sha256 $(shell_quote_value "$plan_runner_sha256")"
          [ -n "$plan_repo" ] && provision_cmd="$provision_cmd --repo $(shell_quote_value "$plan_repo")"
          [ -n "$plan_ref" ] && provision_cmd="$provision_cmd --ref $(shell_quote_value "$plan_ref")"
          build_runner_cmd="/bin/sh /usr/local/bin/ogent-agent model-build-llama --install-deps --jobs 1"
          [ -n "$plan_repo" ] && build_runner_cmd="$build_runner_cmd --repo $(shell_quote_value "$plan_repo")"
          [ -n "$plan_ref" ] && build_runner_cmd="$build_runner_cmd --ref $(shell_quote_value "$plan_ref")"
          echo "model_provision_command=$provision_cmd"
          echo "model_build_runner_command=$build_runner_cmd"
          if [ -n "$plan_model_file" ]; then
            OGENT_LOCAL_MODEL_FILE="$plan_model_file"
          fi

          dep_file="$TMP_DIR/model-deployment-dependencies.$$.txt"
          profile_status local-model > "$dep_file" 2>&1 || true
          if grep -q 'profile_dependencies=ok profile=local-model' "$dep_file"; then
            echo "stage_dependencies=ready"
          else
            dep_line="$(grep 'profile_status=missing profile=local-model' "$dep_file" | tail -n 1)"
            echo "stage_dependencies=missing ${dep_line:-see profile-status local-model}"
          fi

          if runner_path="$(find_llama_server 2>/dev/null)"; then
            echo "stage_runner=ready path=$(display_path "$runner_path")"
          elif runner_path="$(find_incompatible_llama_server 2>/dev/null)"; then
            if [ -n "$plan_runner_url" ]; then
              echo "stage_runner=invalid_ish_elf action=model_install_runner url=$plan_runner_url path=$(display_path "$runner_path")"
            else
              echo "stage_runner=invalid_ish_elf action=replace_with_current_guest_arch_runner expected=$expected_arch path=$(display_path "$runner_path")"
            fi
          else
            if [ -n "$plan_runner_url" ]; then
              echo "stage_runner=missing action=model_install_runner url=$plan_runner_url"
            else
              echo "stage_runner=missing action=model_build_llama_or_import_runner"
            fi
          fi

          if [ -n "$plan_model_file" ] && model_file_is_gguf "$plan_model_file"; then
            echo "stage_model=ready path=$(display_path "$plan_model_file") source=argument"
          elif [ -n "$plan_model_file" ] && [ -f "$plan_model_file" ]; then
            echo "stage_model=invalid_gguf_magic path=$(display_path "$plan_model_file") action=import_valid_gguf_or_download"
          elif [ -n "$plan_model_file" ]; then
            echo "stage_model=missing path=$(display_path "$plan_model_file") action=import_gguf_or_download"
          elif model_path="$(find_model_file 2>/dev/null)" && [ -n "$model_path" ]; then
            echo "stage_model=ready path=$(display_path "$model_path")"
          elif [ -n "$plan_url" ]; then
            echo "stage_model=missing action=model_install_gguf url=$plan_url"
          else
            echo "stage_model=missing action=provide_gguf_url_or_import_gguf"
          fi

          if [ -n "${OGENT_LOCAL_MODEL_BASE_URL:-}" ] && [ -n "${OGENT_LOCAL_MODEL_ID:-}" ]; then
            echo "stage_config=ready runtime_kind=${OGENT_LOCAL_MODEL_RUNTIME_KIND:-not-configured} model_file=${OGENT_LOCAL_MODEL_FILE:-auto-discover}"
          else
            echo "stage_config=missing action=model_config"
          fi

          probe_file="$TMP_DIR/model-deployment-probe.$$.txt"
          model_probe > "$probe_file" 2>&1 || true
          if grep -q 'local_model_probe=ok' "$probe_file" && ! grep -q 'model_kind=compatibility_harness' "$probe_file"; then
            echo "stage_runtime=ready"
          elif grep -q 'model_kind=compatibility_harness' "$probe_file"; then
            echo "stage_runtime=blocked_compatibility_harness"
          else
            echo "stage_runtime=missing_or_unreachable"
          fi
          sed -n '1,6p' "$probe_file" | sed 's/^/runtime_probe_/'

          deployment_blockers=""
          grep -q 'profile_dependencies=ok profile=local-model' "$dep_file" || deployment_blockers="$deployment_blockers dependencies"
          find_llama_server >/dev/null 2>&1 || deployment_blockers="$deployment_blockers runner"
          find_model_file >/dev/null 2>&1 || deployment_blockers="$deployment_blockers gguf"

          next_command=""
          if ! grep -q 'profile_dependencies=ok profile=local-model' "$dep_file"; then
            if [ -n "$plan_url" ] || [ -n "$plan_model_file" ] || [ -n "$plan_runner_url" ] || ! find_llama_server >/dev/null 2>&1; then
              next_command="$provision_cmd"
            else
              next_command="/bin/sh /usr/local/bin/ogent-agent profile-install local-model"
            fi
          elif ! find_llama_server >/dev/null 2>&1; then
            next_command="$provision_cmd"
          elif ! find_model_file >/dev/null 2>&1; then
            if [ -n "$plan_model_file" ]; then
              next_command="import_valid_gguf_or_fix_model_file:$(display_path "$plan_model_file")"
            elif [ -n "$plan_url" ]; then
              next_command="$provision_cmd"
            else
              next_command="provide_gguf_url_or_import_gguf"
            fi
          elif ! model_real_readiness >/dev/null 2>&1; then
            next_command="/bin/sh /usr/local/bin/ogent-agent model-scan"
          elif ! grep -q 'local_model_probe=ok' "$probe_file" || grep -q 'model_kind=compatibility_harness' "$probe_file"; then
            next_command="/bin/sh /usr/local/bin/ogent-agent model-bootstrap --require-real"
          else
            next_command="none"
          fi
          clean_blockers="$(printf '%s' "$deployment_blockers" | xargs 2>/dev/null || printf '%s' "$deployment_blockers")"
          [ -n "$clean_blockers" ] || clean_blockers="none"
          echo "model_deployment_blockers=$clean_blockers"
          echo "model_deployment_next_command=$next_command"

          if model_real_readiness >/dev/null 2>&1 && grep -q 'local_model_probe=ok' "$probe_file" && ! grep -q 'model_kind=compatibility_harness' "$probe_file"; then
            echo "model_deployment_plan=ready"
            model_readiness_write "ready" "real_local_model_probe_ok" "available" "available" "ready" "$next_command" "$base_url" "$plan_model_id"
          else
            echo "model_deployment_plan=incomplete"
            runner_state="missing"
            if find_llama_server >/dev/null 2>&1; then
              runner_state="available"
            elif find_incompatible_llama_server >/dev/null 2>&1; then
              runner_state="invalid_ish_elf"
            fi
            model_state="missing"
            find_model_file >/dev/null 2>&1 && model_state="available"
            runtime_state="missing_or_unreachable"
            grep -q 'model_kind=compatibility_harness' "$probe_file" && runtime_state="blocked_compatibility_harness"
            model_readiness_write "incomplete" "deployment_plan_incomplete" "$runner_state" "$model_state" "$runtime_state" "$next_command" "$base_url" "$plan_model_id"
          fi
          model_readiness_print
          rm -f "$dep_file" "$probe_file" 2>/dev/null || true
        }

        model_doctor() {
          init_runtime
          load_model_config
          report="$MODEL_DIR/model-doctor-last.txt"
          mkdir -p "$MODEL_DIR" "$TMP_DIR"
          model_deployment_plan "$@" > "$report" 2>&1 || true

          dep_line="$(grep '^stage_dependencies=' "$report" | tail -n 1)"
          runner_line="$(grep '^stage_runner=' "$report" | tail -n 1)"
          model_line="$(grep '^stage_model=' "$report" | tail -n 1)"
          config_line="$(grep '^stage_config=' "$report" | tail -n 1)"
          runtime_line="$(grep '^stage_runtime=' "$report" | tail -n 1)"
          next_line="$(grep '^model_deployment_next_command=' "$report" | tail -n 1)"
          provision_line="$(grep '^model_provision_command=' "$report" | tail -n 1)"
          build_runner_line="$(grep '^model_build_runner_command=' "$report" | tail -n 1)"
          expected_arch_line="$(grep '^expected_runner_arch=' "$report" | tail -n 1)"
          blockers_line="$(grep '^model_deployment_blockers=' "$report" | tail -n 1)"
          readiness_line="$(grep '^local_model_readiness_state=' "$report" | tail -n 1)"

          dep_state="missing"
          printf '%s\n' "$dep_line" | grep -q '^stage_dependencies=ready' && dep_state="ready"

          runner_state="missing"
          case "$runner_line" in
            stage_runner=ready*) runner_state="available" ;;
            stage_runner=invalid_ish_elf*) runner_state="invalid_ish_elf" ;;
          esac

          gguf_state="missing"
          case "$model_line" in
            stage_model=ready*) gguf_state="available" ;;
            stage_model=*invalid_gguf_magic*) gguf_state="invalid_gguf_magic" ;;
          esac

          config_state="missing"
          case "$config_line" in
            stage_config=ready*) config_state="ready" ;;
          esac

          endpoint_state="unreachable"
          case "$runtime_line" in
            stage_runtime=ready*) endpoint_state="real_local_model_ready" ;;
            stage_runtime=blocked_compatibility_harness*) endpoint_state="compatibility_harness" ;;
            stage_runtime=missing_or_unreachable*) endpoint_state="missing_or_unreachable" ;;
          esac

          subagent_gate="missing_real_model"
          case "$endpoint_state" in
            real_local_model_ready) subagent_gate="ready" ;;
            compatibility_harness) subagent_gate="blocked_compatibility_harness" ;;
          esac

          next_command="${next_line#model_deployment_next_command=}"
          [ -n "$next_command" ] || next_command="/bin/sh /usr/local/bin/ogent-agent model-plan"
          next_reason="inspect_model_plan"
          case "$next_command" in
            *"profile-install local-model"*) next_reason="install_local_model_profile" ;;
            *"model-provision"*) next_reason="provision_model_runtime" ;;
            *"model-install-runner"*) next_reason="install_llama_server_runner" ;;
            *"model-build-llama"*) next_reason="build_llama_server_runner" ;;
            *"model-install-gguf"*) next_reason="install_gguf_model" ;;
            *"provide_gguf_url_or_import_gguf"*) next_reason="provide_or_import_gguf" ;;
            *"model-bootstrap --require-real"*) next_reason="start_real_local_runtime" ;;
            "none") next_reason="none" ;;
          esac

          echo "model_doctor_start"
          echo "model_doctor_report=$(display_path "$report")"
          [ -n "$expected_arch_line" ] && echo "$expected_arch_line"
          echo "profile_dependencies_state=$dep_state"
          [ -n "$dep_line" ] && echo "profile_dependencies_detail=$dep_line"
          echo "runner_state=$runner_state"
          [ -n "$runner_line" ] && echo "runner_detail=$runner_line"
          echo "gguf_state=$gguf_state"
          [ -n "$model_line" ] && echo "gguf_detail=$model_line"
          echo "config_state=$config_state"
          [ -n "$config_line" ] && echo "config_detail=$config_line"
          echo "endpoint_state=$endpoint_state"
          [ -n "$runtime_line" ] && echo "endpoint_detail=$runtime_line"
          echo "subagent_inference_gate=$subagent_gate"
          [ -n "$readiness_line" ] && echo "$readiness_line"
          [ -n "$blockers_line" ] && echo "$blockers_line"
          [ -n "$provision_line" ] && echo "$provision_line"
          [ -n "$build_runner_line" ] && echo "$build_runner_line"
          echo "model_doctor_next_reason=$next_reason"
          echo "model_doctor_next_command=$next_command"
          if [ "$dep_state" = "ready" ] && [ "$runner_state" = "available" ] && [ "$gguf_state" = "available" ] && [ "$endpoint_state" = "real_local_model_ready" ]; then
            echo "model_doctor_status=ready"
            echo "model_doctor_ok"
          else
            echo "model_doctor_status=incomplete"
            echo "model_doctor_incomplete"
          fi
        }

        model_build_llama() {
          init_runtime
          repo="${OGENT_LLAMA_CPP_REPO:-https://github.com/ggml-org/llama.cpp.git}"
          fallback_repo="https://github.com/ggerganov/llama.cpp.git"
          ref="${OGENT_LLAMA_CPP_REF:-}"
          jobs="${OGENT_LLAMA_BUILD_JOBS:-1}"
          clean="0"
          install_deps="0"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --repo) repo="${2:-$repo}"; shift 2 ;;
              --ref|--git-ref) ref="${2:-}"; shift 2 ;;
              --jobs|-j) jobs="${2:-1}"; shift 2 ;;
              --clean) clean="1"; shift ;;
              --install-deps) install_deps="1"; shift ;;
              *) shift ;;
            esac
          done
          case "$jobs" in
            ''|*[!0-9]*) jobs=1 ;;
          esac
          [ "$jobs" -lt 1 ] && jobs=1
          [ "$jobs" -gt 4 ] && jobs=4

          src="$WORKSPACE/llama.cpp"
          build="$src/build"
          runner_dest="$MODEL_DIR/bin/llama-server"
          mkdir -p "$MODEL_DIR/bin" "$WORKSPACE" "$(dirname "$MODEL_BUILD_LOG")"
          : > "$MODEL_BUILD_LOG"
          echo "model_build_llama=start repo=$repo ref=${ref:-default} jobs=$jobs source=$(display_path "$src") log=$(display_path "$MODEL_BUILD_LOG")"
          {
            echo "build_env_uname=$(uname -m 2>/dev/null || echo unknown)"
            echo "build_env_cc=$(command -v cc 2>/dev/null || true)"
            echo "build_env_cxx=$(command -v c++ 2>/dev/null || command -v g++ 2>/dev/null || true)"
            cmake --version 2>/dev/null | sed -n '1p' | sed 's/^/build_env_/'
          } | tee -a "$MODEL_BUILD_LOG"

          if [ "$install_deps" = "1" ]; then
            profile_install local-model | tee -a "$MODEL_BUILD_LOG"
          else
            dep_status="$(profile_status local-model)"
            printf '%s\n' "$dep_status" | tee -a "$MODEL_BUILD_LOG"
            if printf '%s\n' "$dep_status" | grep -q 'profile_dependencies=missing'; then
              echo "model_build_llama=missing_dependencies action=profile_install profile=local-model"
              exit 78
            fi
          fi

          missing_build_tools=""
          for cmd in git cmake make g++; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
              missing_build_tools="$missing_build_tools $cmd"
            fi
          done
          if [ -n "$(printf '%s' "$missing_build_tools" | tr -d ' ')" ]; then
            echo "model_build_llama=missing_tools tools=$(printf '%s' "$missing_build_tools" | xargs 2>/dev/null || printf '%s' "$missing_build_tools")"
            exit 78
          fi

          if [ "$clean" = "1" ]; then
            rm -rf "$build"
          fi
          if [ -d "$src/.git" ]; then
            echo "model_build_llama=update_source path=$(display_path "$src")" | tee -a "$MODEL_BUILD_LOG"
            git -C "$src" pull --ff-only >> "$MODEL_BUILD_LOG" 2>&1 || true
          else
            rm -rf "$src"
            echo "model_build_llama=clone repo=$repo" | tee -a "$MODEL_BUILD_LOG"
            if ! git clone --depth 1 "$repo" "$src" >> "$MODEL_BUILD_LOG" 2>&1; then
              if [ "$repo" != "$fallback_repo" ]; then
                rm -rf "$src"
                echo "model_build_llama=clone_fallback repo=$fallback_repo" | tee -a "$MODEL_BUILD_LOG"
                git clone --depth 1 "$fallback_repo" "$src" >> "$MODEL_BUILD_LOG" 2>&1 || {
                  echo "model_build_llama=failed phase=clone log=$(display_path "$MODEL_BUILD_LOG")"
                  exit 70
                }
              else
                echo "model_build_llama=failed phase=clone log=$(display_path "$MODEL_BUILD_LOG")"
                exit 70
              fi
            fi
          fi
          if [ -n "$ref" ]; then
            echo "model_build_llama=checkout ref=$ref" | tee -a "$MODEL_BUILD_LOG"
            if ! git -C "$src" fetch --depth 1 origin "$ref" >> "$MODEL_BUILD_LOG" 2>&1; then
              echo "model_build_llama=ref_fetch_skipped ref=$ref" | tee -a "$MODEL_BUILD_LOG"
            fi
            if ! git -C "$src" checkout "$ref" >> "$MODEL_BUILD_LOG" 2>&1; then
              echo "model_build_llama=failed phase=checkout ref=$ref log=$(display_path "$MODEL_BUILD_LOG")"
              tail -n 50 "$MODEL_BUILD_LOG" 2>/dev/null || true
              exit 70
            fi
          fi
          git -C "$src" rev-parse --short HEAD 2>/dev/null | sed 's/^/model_build_llama_source_commit=/' | tee -a "$MODEL_BUILD_LOG" || true

          guest_arch="$(expected_guest_arch)"
          if [ "$guest_arch" = "aarch64" ]; then
            arch_cflags="-march=armv8-a"
            arch_log="aarch64"
          else
            arch_cflags="-march=i686"
            arch_log="i686"
          fi
          cmake_flags="
            -DCMAKE_BUILD_TYPE=Release
            -DCMAKE_C_FLAGS=$arch_cflags
            -DCMAKE_CXX_FLAGS=$arch_cflags
            -DBUILD_SHARED_LIBS=OFF
            -DGGML_NATIVE=OFF
            -DGGML_OPENMP=OFF
            -DGGML_AVX=OFF
            -DGGML_AVX2=OFF
            -DGGML_FMA=OFF
            -DGGML_F16C=OFF
            -DGGML_LLAMAFILE=OFF
            -DLLAMA_BUILD_TESTS=OFF
            -DLLAMA_BUILD_EXAMPLES=ON
            -DLLAMA_BUILD_SERVER=ON
            -DLLAMA_CURL=OFF
          "
          if [ -n "${OGENT_LLAMA_CMAKE_FLAGS:-}" ]; then
            cmake_flags="$cmake_flags ${OGENT_LLAMA_CMAKE_FLAGS}"
          fi
          echo "model_build_llama=configure examples=on server=on native=off openmp=off arch=$arch_log" | tee -a "$MODEL_BUILD_LOG"
          printf '%s\n' "$cmake_flags" | xargs 2>/dev/null | sed 's/^/model_build_llama_cmake_flags=/' | tee -a "$MODEL_BUILD_LOG" || true
          if ! cmake -S "$src" -B "$build" \
              $cmake_flags >> "$MODEL_BUILD_LOG" 2>&1; then
            echo "model_build_llama=failed phase=configure log=$(display_path "$MODEL_BUILD_LOG")"
            tail -n 40 "$MODEL_BUILD_LOG" 2>/dev/null || true
            exit 70
          fi

          echo "model_build_llama=compile target=llama-server" | tee -a "$MODEL_BUILD_LOG"
          if ! cmake --build "$build" --target llama-server --parallel "$jobs" >> "$MODEL_BUILD_LOG" 2>&1; then
            echo "model_build_llama=compile_fallback target=server" | tee -a "$MODEL_BUILD_LOG"
            if ! cmake --build "$build" --target server --parallel "$jobs" >> "$MODEL_BUILD_LOG" 2>&1; then
              echo "model_build_llama=compile_fallback target=all" | tee -a "$MODEL_BUILD_LOG"
              cmake --build "$build" --parallel "$jobs" >> "$MODEL_BUILD_LOG" 2>&1 || {
                echo "model_build_llama=failed phase=compile log=$(display_path "$MODEL_BUILD_LOG")"
                tail -n 60 "$MODEL_BUILD_LOG" 2>/dev/null || true
                exit 70
              }
            fi
          fi

          built_runner=""
          for candidate in \
            "$build/bin/llama-server" \
            "$build/bin/server" \
            "$build/examples/server/llama-server" \
            "$build/examples/server/server" \
            "$build/llama-server" \
            "$build/server"; do
            if [ -x "$candidate" ]; then
              built_runner="$candidate"
              break
            fi
          done
          if [ -z "$built_runner" ]; then
            built_runner="$(find "$build" -type f 2>/dev/null | while read -r file; do
              base="$(basename "$file")"
              case "$base" in
                llama-server|server)
                  [ -x "$file" ] && printf '%s\n' "$file"
                  ;;
              esac
            done | sort | sed -n '1p')"
          fi
          if [ -z "$built_runner" ]; then
            echo "model_build_llama=failed phase=find_runner log=$(display_path "$MODEL_BUILD_LOG")"
            find "$build" -maxdepth 4 -type f -name '*server*' 2>/dev/null | sed -n '1,20p'
            exit 70
          fi
          cp "$built_runner" "$runner_dest"
          chmod 755 "$runner_dest" 2>/dev/null || true
          if ! file_is_ish_elf "$runner_dest"; then
            echo "model_build_llama=failed phase=validate reason=wrong_guest_arch_linux_elf expected=$(expected_guest_arch) runner=$(display_path "$runner_dest")"
            rm -f "$runner_dest" 2>/dev/null || true
            exit 70
          fi
          log_event "model_build_llama runner=$(safe_name "$runner_dest")"
          echo "model_build_llama=ok runner=$(display_path "$runner_dest") built_from=$(display_path "$built_runner") log=$(display_path "$MODEL_BUILD_LOG")"
          model_runtime_scan
        }

        model_install_runner() {
          init_runtime
          url=""
          sha256=""
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --url|--runner-url|--llama-server-url) url="${2:-}"; shift 2 ;;
              --sha256|--runner-sha256|--llama-server-sha256) sha256="${2:-}"; shift 2 ;;
              *) shift ;;
            esac
          done
          case "$url" in
            http://*|https://*) ;;
            *)
              echo "model_install_runner=failed reason=invalid_or_missing_url"
              echo "usage: ogent-agent model-install-runner --url <https://.../llama-server> --sha256 <64-hex>"
              exit 64
              ;;
          esac
          # The runner is an executable fetched from a caller-supplied URL, so
          # an expected sha256 is mandatory: only that exact binary installs.
          sha256="$(printf '%s' "$sha256" | tr 'A-F' 'a-f')"
          sha256_ok=0
          case "$sha256" in
            ''|*[!0-9a-f]*) ;;
            *) [ "${#sha256}" -eq 64 ] && sha256_ok=1 ;;
          esac
          if [ "$sha256_ok" != "1" ]; then
            echo "model_install_runner=failed reason=missing_or_invalid_sha256"
            echo "usage: ogent-agent model-install-runner --url <https://.../llama-server> --sha256 <64-hex>"
            exit 64
          fi

          mkdir -p "$MODEL_DIR/bin"
          dest="$MODEL_DIR/bin/llama-server"
          part="$dest.part"
          rm -f "$part" 2>/dev/null || true
          echo "model_install_runner=start url=$url dest=$(display_path "$dest")"
          if command -v curl >/dev/null 2>&1; then
            if ! curl -L --fail --connect-timeout 30 --retry 2 -o "$part" "$url"; then
              echo "model_install_runner=failed phase=download downloader=curl"
              rm -f "$part" 2>/dev/null || true
              exit 70
            fi
          elif command -v wget >/dev/null 2>&1; then
            if ! wget -O "$part" "$url"; then
              echo "model_install_runner=failed phase=download downloader=wget"
              rm -f "$part" 2>/dev/null || true
              exit 70
            fi
          else
            echo "model_install_runner=missing_downloader need=curl_or_wget"
            exit 78
          fi

          bytes="$(wc -c < "$part" 2>/dev/null | tr -d ' ')"
          case "$bytes" in
            ''|*[!0-9]*) bytes=0 ;;
          esac
          if [ "$bytes" -lt 20 ]; then
            echo "model_install_runner=failed phase=validate reason=file_too_small bytes=$bytes"
            rm -f "$part" 2>/dev/null || true
            exit 70
          fi
          chmod 755 "$part" 2>/dev/null || true
          if ! file_is_ish_elf "$part"; then
            echo "model_install_runner=failed phase=validate reason=wrong_guest_arch_linux_elf expected=$(expected_guest_arch) bytes=$bytes"
            rm -f "$part" 2>/dev/null || true
            exit 70
          fi
          if [ -n "$sha256" ]; then
            if ! command -v sha256sum >/dev/null 2>&1; then
              echo "model_install_runner=failed phase=sha256 reason=sha256sum_missing"
              rm -f "$part" 2>/dev/null || true
              exit 78
            fi
            expected="$(printf '%s' "$sha256" | tr 'A-F' 'a-f')"
            actual="$(sha256sum "$part" | awk '{print $1}' | tr 'A-F' 'a-f')"
            if [ "$actual" != "$expected" ]; then
              echo "model_install_runner=failed phase=sha256 expected=$expected actual=$actual"
              rm -f "$part" 2>/dev/null || true
              exit 70
            fi
            echo "model_install_runner_sha256=ok"
          fi

          if [ -e "$dest" ] && ! file_is_ish_elf "$dest"; then
            mv "$dest" "$dest.incompatible.$(date +%s)" 2>/dev/null || rm -f "$dest"
          fi
          mv "$part" "$dest"
          chmod 755 "$dest" 2>/dev/null || true
          log_event "model_install_runner file=$(safe_name "$dest") bytes=$bytes"
          echo "model_install_runner=ok runner=$(display_path "$dest") bytes=$bytes"
          model_runtime_scan
        }

        model_install_gguf() {
          init_runtime
          load_model_config
          url=""
          sha256=""
          name=""
          model_id=""
          set_default="1"
          extra_args="${OGENT_LOCAL_MODEL_EXTRA_ARGS:-}"
          [ -n "$extra_args" ] || extra_args="--ctx-size 4096"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --url) url="${2:-}"; shift 2 ;;
              --sha256) sha256="${2:-}"; shift 2 ;;
              --name|--filename) name="${2:-}"; shift 2 ;;
              --model|--model-id) model_id="${2:-}"; shift 2 ;;
              --extra-args) extra_args="${2:-}"; shift 2 ;;
              --no-default) set_default="0"; shift ;;
              *) shift ;;
            esac
          done
          case "$url" in
            http://*|https://*) ;;
            *)
              echo "model_install_gguf=failed reason=invalid_or_missing_url"
              echo "usage: ogent-agent model-install-gguf --url <https://.../*.gguf> [--sha256 <hex>] [--name <file.gguf>] [--model <id>] [--no-default]"
              exit 64
              ;;
          esac
          if [ -z "$name" ]; then
            clean_url="$(printf '%s' "$url" | awk -F'?' '{print $1}')"
            name="$(basename "$clean_url")"
          fi
          name="$(safe_name "${name:-model.gguf}")"
          case "$name" in
            *.gguf) ;;
            *) name="$name.gguf" ;;
          esac
          dest="$MODEL_DIR/$name"
          part="$dest.part"
          mkdir -p "$MODEL_DIR"
          echo "model_install_gguf=start url=$url dest=$(display_path "$dest")"
          if command -v curl >/dev/null 2>&1; then
            if ! curl -L --fail --connect-timeout 30 --retry 2 --continue-at - -o "$part" "$url"; then
              echo "model_install_gguf=failed phase=download downloader=curl"
              exit 70
            fi
          elif command -v wget >/dev/null 2>&1; then
            if ! wget -O "$part" "$url"; then
              echo "model_install_gguf=failed phase=download downloader=wget"
              exit 70
            fi
          else
            echo "model_install_gguf=missing_downloader need=curl_or_wget"
            exit 78
          fi
          bytes="$(wc -c < "$part" 2>/dev/null | tr -d ' ')"
          case "$bytes" in
            ''|*[!0-9]*) bytes=0 ;;
          esac
          if [ "$bytes" -lt 32 ]; then
            echo "model_install_gguf=failed phase=validate reason=file_too_small bytes=$bytes"
            exit 70
          fi
          if ! head -c 4 "$part" 2>/dev/null | grep -q '^GGUF'; then
            echo "model_install_gguf=failed phase=validate reason=not_gguf_magic bytes=$bytes"
            exit 70
          fi
          if [ -n "$sha256" ]; then
            if ! command -v sha256sum >/dev/null 2>&1; then
              echo "model_install_gguf=failed phase=sha256 reason=sha256sum_missing"
              exit 78
            fi
            expected="$(printf '%s' "$sha256" | tr 'A-F' 'a-f')"
            actual="$(sha256sum "$part" | awk '{print $1}' | tr 'A-F' 'a-f')"
            if [ "$actual" != "$expected" ]; then
              echo "model_install_gguf=failed phase=sha256 expected=$expected actual=$actual"
              exit 70
            fi
            echo "model_install_gguf_sha256=ok"
          fi
          mv "$part" "$dest"
          chmod 600 "$dest" 2>/dev/null || true
          if [ -z "$model_id" ]; then
            model_id="${name%.gguf}"
          fi
          if [ "$set_default" = "1" ]; then
            base_url="${OGENT_LOCAL_MODEL_BASE_URL:-$(model_default_base_url)}"
            model_config --base-url "$base_url" --model "$model_id" --runtime-kind "llama.cpp" --model-file "$dest" --extra-args "$extra_args" >/dev/null
            echo "model_install_gguf_config=updated base_url=$base_url model_id=$model_id"
          else
            echo "model_install_gguf_config=skipped"
          fi
          log_event "model_install_gguf file=$(safe_name "$dest") bytes=$bytes"
          echo "model_install_gguf=ok model_file=$(display_path "$dest") bytes=$bytes model_id=$model_id"
          echo "model_file=$(display_path "$dest")"
          echo "model_id=$model_id"
          echo "model_bytes=$bytes"
          model_runtime_scan
        }

        model_provision() {
          init_runtime
          load_model_config
          url=""
          sha256=""
          name=""
          model_id="${OGENT_LOCAL_MODEL_ID:-}"
          model_file="${OGENT_LOCAL_MODEL_FILE:-}"
          extra_args="${OGENT_LOCAL_MODEL_EXTRA_ARGS:-}"
          [ -n "$extra_args" ] || extra_args="--ctx-size 4096"
          runner_url=""
          runner_sha256=""
          repo=""
          ref="${OGENT_LLAMA_CPP_REF:-}"
          jobs="${OGENT_LLAMA_BUILD_JOBS:-1}"
          clean="0"
          install_deps="auto"
          build_runner="auto"
          start_server="1"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --url|--model-url) url="${2:-}"; shift 2 ;;
              --sha256) sha256="${2:-}"; shift 2 ;;
              --name|--filename) name="${2:-}"; shift 2 ;;
              --model|--model-id) model_id="${2:-}"; shift 2 ;;
              --model-file|--gguf-file) model_file="${2:-}"; shift 2 ;;
              --extra-args) extra_args="${2:-}"; shift 2 ;;
              --runner-url|--llama-server-url) runner_url="${2:-}"; shift 2 ;;
              --runner-sha256|--llama-server-sha256) runner_sha256="${2:-}"; shift 2 ;;
              --repo) repo="${2:-}"; shift 2 ;;
              --ref|--git-ref) ref="${2:-}"; shift 2 ;;
              --jobs|-j) jobs="${2:-1}"; shift 2 ;;
              --clean) clean="1"; shift ;;
              --install-deps) install_deps="1"; shift ;;
              --no-install-deps) install_deps="0"; shift ;;
              --build-runner) build_runner="1"; shift ;;
              --no-build-runner) build_runner="0"; shift ;;
              --no-start) start_server="0"; shift ;;
              *) shift ;;
            esac
          done
          case "$jobs" in
            ''|*[!0-9]*) jobs=1 ;;
          esac
          [ "$jobs" -lt 1 ] && jobs=1
          [ "$jobs" -gt 4 ] && jobs=4
          if [ -n "$model_file" ]; then
            OGENT_LOCAL_MODEL_FILE="$model_file"
          fi

          echo "model_provision=start"
          echo "model_provision_expected_runner_arch=$(expected_guest_arch)"
          [ -n "$model_file" ] && echo "model_provision_model_file=$(display_path "$model_file")"
          model_runtime_scan | sed 's/^/before_/'
          missing_model_input="0"
          if ! find_model_file >/dev/null 2>&1 && [ -z "$url" ] && [ -z "$model_file" ]; then
            missing_model_input="1"
            echo "model_provision=missing_model_url deferred=1 action=model_install_gguf"
            if [ -z "$runner_url" ] && [ "$build_runner" = "0" ]; then
              echo "usage: ogent-agent model-provision --url <https://.../*.gguf> [--sha256 <hex>] [--model <id>] [--no-start]"
              model_real_readiness || true
              exit 78
            fi
          fi

          dep_status="$(profile_status local-model)"
          if [ "$install_deps" = "1" ] || { [ "$install_deps" = "auto" ] && printf '%s\n' "$dep_status" | grep -q 'profile_dependencies=missing'; }; then
            echo "model_provision=install_dependencies profile=local-model"
            profile_install local-model
          else
            printf '%s\n' "$dep_status" | sed 's/^/dependency_/' | sed -n '1,80p'
          fi

          if ! find_llama_server >/dev/null 2>&1; then
            if [ -n "$runner_url" ]; then
              echo "model_provision=install_runner action=model_install_runner"
              model_install_runner --url "$runner_url" --sha256 "$runner_sha256"
            elif [ "$build_runner" = "0" ]; then
              echo "model_provision=missing_runner action=model_build_llama_or_import_runner"
              model_real_readiness || true
              exit 78
            elif incompatible_runner="$(find_incompatible_llama_server 2>/dev/null)"; then
              echo "model_provision=replace_incompatible_runner action=model_build_llama path=$(display_path "$incompatible_runner")"
              if [ -n "$repo" ]; then
                if [ "$clean" = "1" ]; then
                  model_build_llama --jobs "$jobs" --clean --repo "$repo" --ref "$ref"
                else
                  model_build_llama --jobs "$jobs" --repo "$repo" --ref "$ref"
                fi
              else
                if [ "$clean" = "1" ]; then
                  model_build_llama --jobs "$jobs" --clean --ref "$ref"
                else
                  model_build_llama --jobs "$jobs" --ref "$ref"
                fi
              fi
            else
              echo "model_provision=build_runner action=model_build_llama"
              if [ -n "$repo" ]; then
                if [ "$clean" = "1" ]; then
                  model_build_llama --jobs "$jobs" --clean --repo "$repo" --ref "$ref"
                else
                  model_build_llama --jobs "$jobs" --repo "$repo" --ref "$ref"
                fi
              else
                if [ "$clean" = "1" ]; then
                  model_build_llama --jobs "$jobs" --clean --ref "$ref"
                else
                  model_build_llama --jobs "$jobs" --ref "$ref"
                fi
              fi
            fi
          else
            echo "model_provision=runner_ready path=$(display_path "$(find_llama_server 2>/dev/null)")"
          fi

          if ! find_model_file >/dev/null 2>&1; then
            if [ -n "$model_file" ]; then
              if [ ! -f "$model_file" ]; then
                echo "model_provision=missing_model_file path=$(display_path "$model_file") action=import_gguf_or_download"
                model_real_readiness || true
                exit 78
              fi
              echo "model_provision=invalid_model_file path=$(display_path "$model_file") reason=not_gguf_magic"
              model_real_readiness || true
              exit 70
            fi
            if [ -z "$url" ]; then
              echo "model_provision=missing_model_url action=model_install_gguf"
              [ "$missing_model_input" = "1" ] && echo "model_provision_auto_steps=completed_until_model_required"
              echo "usage: ogent-agent model-provision --url <https://.../*.gguf> [--sha256 <hex>] [--model <id>] [--no-start]"
              model_real_readiness || true
              exit 78
            fi
            echo "model_provision=install_model action=model_install_gguf"
            model_install_gguf --url "$url" --sha256 "$sha256" --name "$name" --model "$model_id" --extra-args "$extra_args"
          else
            model_path="$(find_model_file 2>/dev/null)"
            echo "model_provision=model_ready path=$(display_path "$model_path")"
            base_url="${OGENT_LOCAL_MODEL_BASE_URL:-$(model_default_base_url)}"
            model_id="${model_id:-${OGENT_LOCAL_MODEL_ID:-llama-local}}"
            model_config --base-url "$base_url" --model "$model_id" --runtime-kind "llama.cpp" --model-file "$model_path" --extra-args "$extra_args" >/dev/null
          fi

          if ! model_real_readiness; then
            echo "model_provision=failed phase=readiness"
            exit 78
          fi

          if [ "$start_server" = "1" ]; then
            load_model_config
            if model_is_running; then
              echo "model_provision=restart_existing_runtime pid=$(model_current_pid)"
              model_stop || true
            fi
            echo "model_provision=start_real_runtime"
            if ! model_bootstrap --require-real; then
              echo "model_provision=failed phase=start_or_probe"
              exit 70
            fi
          else
            echo "model_provision=ready start=skipped"
          fi
          echo "model_provision=ok"
        }

        ensure_python3() {
          command -v python3 >/dev/null 2>&1
        }

        # JSON string body for $1: backslash and quote escaped, tab/CR/newline
        # as \\t \\r \\n, other control characters dropped.
        json_escape_text() {
          printf '%s' "$1" | tr -d '\\001-\\010\\013\\014\\016-\\037' | sed -e 's/\\\\/\\\\\\\\/g' -e 's/"/\\\\"/g' | awk 'BEGIN{ORS=""}{gsub(/\\r/,"\\\\r"); gsub(/\\t/,"\\\\t"); if (NR>1) printf "\\\\n"; printf "%s",$0}'
        }

        json_escape_file() {
          file="$1"
          first=1
          while IFS= read -r line || [ -n "$line" ]; do
            if [ "$first" = "0" ]; then
              printf '\\n'
            fi
            json_escape_text "$line"
            first=0
          done < "$file"
        }

        json_unescape_text() {
          sed 's/\\"/"/g'
        }

        subagent_write_request_json_sh() {
          agent_file="$1"
          task_file="$2"
          output_file="$3"
          model="$4"
          {
            printf '{"model":"'
            json_escape_text "$model"
            printf '","stream":false,"messages":[{"role":"system","content":"You are a local Ogent subagent running inside iSH Linux. Use the role instructions, complete the assigned task, and return a concise auditable result. This command requires a real local model by default; diagnostics must pass --allow-harness explicitly."},{"role":"user","content":"## Subagent Role\\n\\n'
            json_escape_file "$agent_file"
            printf '\\n\\n## Assigned Task\\n\\n'
            json_escape_file "$task_file"
            printf '"}]}'
          } > "$output_file"
        }

        subagent_extract_response_text_sh() {
          response_file="$1"
          sed -n -E 's/.*"content"[[:space:]]*:[[:space:]]*"([^"]*)".*/\\1/p' "$response_file" 2>/dev/null \
            | sed -n '1p' \
            | json_unescape_text
        }

        netcat_command() {
          if command -v nc >/dev/null 2>&1; then
            command -v nc
            return 0
          fi
          if command -v busybox >/dev/null 2>&1 && busybox nc --help >/dev/null 2>&1; then
            printf '%s\n' "busybox nc"
            return 0
          fi
          return 1
        }

        model_write_builtin_server() {
          init_runtime
          cat > "$MODEL_SERVER_SCRIPT" <<'PY'
        #!/usr/bin/env python3
        import argparse
        import json
        import time
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        class OgentLocalModelHandler(BaseHTTPRequestHandler):
            server_version = 'OgentLocalModel/0.1'

            def log_message(self, fmt, *args):
                return

            def _json(self, status, payload):
                body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
                self.send_response(status)
                self.send_header('Content-Type', 'application/json; charset=utf-8')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                path = self.path.split('?', 1)[0]
                if path.endswith('/models') or path == '/models':
                    self._json(200, {
                        'object': 'list',
                        'data': [{
                            'id': self.server.model_id,
                            'object': 'model',
                            'owned_by': 'oases-ogent',
                            'model_kind': 'compatibility_harness'
                        }]
                    })
                    return
                if path.endswith('/health') or path == '/health':
                    self._json(200, {
                        'ok': True,
                        'model': self.server.model_id,
                        'model_kind': 'compatibility_harness'
                    })
                    return
                self._json(404, {'error': 'not_found'})

            def do_POST(self):
                path = self.path.split('?', 1)[0]
                if not path.endswith('/chat/completions') and path != '/chat/completions':
                    self._json(404, {'error': 'not_found'})
                    return
                length = int(self.headers.get('Content-Length') or '0')
                raw = self.rfile.read(length) if length > 0 else b'{}'
                try:
                    payload = json.loads(raw.decode('utf-8') or '{}')
                except Exception:
                    payload = {}
                content = self._content_for(payload)
                if payload.get('stream'):
                    self._stream_completion(content)
                else:
                    self._json(200, {
                        'id': 'chatcmpl-ogent-local',
                        'object': 'chat.completion',
                        'created': int(time.time()),
                        'model': self.server.model_id,
                        'choices': [{
                            'index': 0,
                            'message': {'role': 'assistant', 'content': content},
                            'finish_reason': 'stop'
                        }]
                    })

            def _content_for(self, payload):
                last_user = ''
                messages = payload.get('messages') or []
                for msg in messages:
                    if msg.get('role') != 'user':
                        continue
                    value = msg.get('content')
                    if isinstance(value, str):
                        last_user = value
                    elif isinstance(value, list):
                        pieces = []
                        for part in value:
                            if isinstance(part, dict) and isinstance(part.get('text'), str):
                                pieces.append(part.get('text'))
                        last_user = ' '.join(pieces)
                head = last_user.strip()
                if len(head) > 160:
                    head = head[:160] + '...'
                lines = [
                    '最终交付',
                    '',
                    '本机 iSH local model compatibility harness 已响应。',
                    '这证明兼容格式的 /models 与流式 /chat/completions 路由可用。',
                    '注意：这不是实际大模型推理；真实本机模型仍需要接入 llama.cpp、MLX 或 Metal-backed runtime。',
                    '最近用户输入：' + (head or '未提供')
                ]
                return chr(10).join(lines)

            def _stream_completion(self, content):
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
                self.send_header('Cache-Control', 'no-cache')
                self.send_header('Connection', 'keep-alive')
                self.end_headers()
                chunks = [
                    {'choices': [{'index': 0, 'delta': {'content': content}, 'finish_reason': None}]},
                    {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]}
                ]
                for chunk in chunks:
                    line = 'data: ' + json.dumps(chunk, ensure_ascii=False)
                    self.wfile.write((line + chr(10) + chr(10)).encode('utf-8'))
                    self.wfile.flush()
                    time.sleep(0.02)
                self.wfile.write(('data: [DONE]' + chr(10) + chr(10)).encode('utf-8'))
                self.wfile.flush()

        def main():
            parser = argparse.ArgumentParser()
            parser.add_argument('--host', default='127.0.0.1')
            parser.add_argument('--port', type=int, default=11434)
            parser.add_argument('--model', default='ogent-local-echo')
            args = parser.parse_args()
            server = ThreadingHTTPServer((args.host, args.port), OgentLocalModelHandler)
            server.model_id = args.model
            server.serve_forever()

        if __name__ == '__main__':
            main()
        PY
          chmod 700 "$MODEL_SERVER_SCRIPT" 2>/dev/null || true
        }

        model_write_netcat_server() {
          init_runtime
          cat > "$MODEL_NETCAT_SCRIPT" <<'SH'
        #!/bin/sh
        host="${1:-127.0.0.1}"
        port="${2:-11434}"
        model="${3:-ogent-local-echo}"
        nc_cmd="${4:-nc}"

        serve_once() {
          {
            printf 'HTTP/1.1 200 OK\\r\\n'
            printf 'Content-Type: text/event-stream; charset=utf-8\\r\\n'
            printf 'Cache-Control: no-cache\\r\\n'
            printf 'Connection: close\\r\\n'
            printf '\\r\\n'
            printf 'data: {"id":"%s","object":"list","data":[{"id":"%s","object":"model","model_kind":"compatibility_harness"}]}\\n\\n' "$model" "$model"
            printf 'data: {"choices":[{"index":0,"delta":{"content":"最终交付 - 本机 iSH local model compatibility harness 已响应。这证明兼容格式的 /models 与流式 /chat/completions 路由可用。注意：这不是实际大模型推理；真实本机模型仍需要接入 llama.cpp、MLX 或 Metal-backed runtime。"},"finish_reason":null}]}\\n\\n'
            printf 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\\n\\n'
            printf 'data: [DONE]\\n\\n'
          } | sh -c "$nc_cmd -l -p '$port' -s '$host' 2>/dev/null || $nc_cmd -l -p '$port'"
        }

        while :; do
          serve_once
          sleep 0.05
        done
        SH
          chmod 700 "$MODEL_NETCAT_SCRIPT" 2>/dev/null || true
        }

        model_http_get() {
          url="$1"
          output="$2"
          errfile="$3"
          api_key="${4:-}"
          if command -v curl >/dev/null 2>&1; then
            if [ -n "$api_key" ]; then
              curl -fsS --max-time 6 -H "Authorization: Bearer $api_key" "$url" > "$output" 2>"$errfile"
            else
              curl -fsS --max-time 6 "$url" > "$output" 2>"$errfile"
            fi
            return $?
          fi
          if command -v python3 >/dev/null 2>&1; then
            OGENT_PROBE_URL="$url" OGENT_PROBE_OUTPUT="$output" OGENT_PROBE_API_KEY="$api_key" python3 - <<'PY' 2>"$errfile"
        import os
        import urllib.request
        url = os.environ.get('OGENT_PROBE_URL', '')
        output = os.environ.get('OGENT_PROBE_OUTPUT', '')
        key = os.environ.get('OGENT_PROBE_API_KEY', '')
        req = urllib.request.Request(url)
        if key:
            req.add_header('Authorization', 'Bearer ' + key)
        with urllib.request.urlopen(req, timeout=6) as resp:
            data = resp.read()
        with open(output, 'wb') as handle:
            handle.write(data)
        PY
            return $?
          fi
          if nc_path="$(netcat_command 2>/dev/null)"; then
            case "$url" in
              http://*) ;;
              *) echo "netcat probe only supports http urls" > "$errfile"; return 127 ;;
            esac
            host="$(model_url_host "$url")"
            port="$(model_url_port "$url")"
            path="/$(printf '%s\n' "$url" | cut -d/ -f4-)"
            [ "$path" = "/" ] && path="/"
            raw="$output.raw"
            {
              printf 'GET %s HTTP/1.1\\r\\n' "$path"
              printf 'Host: %s\\r\\n' "$host"
              printf 'Connection: close\\r\\n'
              printf '\\r\\n'
            } | sh -c "$nc_path '$host' '$port'" > "$raw" 2>"$errfile"
            code=$?
            if [ "$code" = "0" ]; then
              tr -d '\\r' < "$raw" | sed '1,/^$/d' > "$output"
            fi
            return "$code"
          fi
          echo "no curl or python3 available" > "$errfile"
          return 127
        }

        model_http_post_json() {
          url="$1"
          payload="$2"
          output="$3"
          errfile="$4"
          api_key="${5:-}"
          if command -v curl >/dev/null 2>&1; then
            if [ -n "$api_key" ]; then
              curl -fsS --max-time 90 \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $api_key" \
                --data-binary "@$payload" \
                "$url" > "$output" 2>"$errfile"
            else
              curl -fsS --max-time 90 \
                -H "Content-Type: application/json" \
                --data-binary "@$payload" \
                "$url" > "$output" 2>"$errfile"
            fi
            return $?
          fi
          if command -v python3 >/dev/null 2>&1; then
            OGENT_POST_URL="$url" \
            OGENT_POST_PAYLOAD="$payload" \
            OGENT_POST_OUTPUT="$output" \
            OGENT_POST_API_KEY="$api_key" \
            python3 - <<'PY' 2>"$errfile"
        import os
        import urllib.request

        url = os.environ.get("OGENT_POST_URL", "")
        payload_path = os.environ.get("OGENT_POST_PAYLOAD", "")
        output_path = os.environ.get("OGENT_POST_OUTPUT", "")
        api_key = os.environ.get("OGENT_POST_API_KEY", "")
        with open(payload_path, "rb") as handle:
            body = handle.read()
        req = urllib.request.Request(url, data=body, method="POST")
        req.add_header("Content-Type", "application/json")
        if api_key:
            req.add_header("Authorization", "Bearer " + api_key)
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = resp.read()
            with open(output_path, "wb") as handle:
                handle.write(data)
        PY
            return $?
          fi
          if nc_path="$(netcat_command 2>/dev/null)"; then
            host="$(model_url_host "$url")"
            port="$(model_url_port "$url")"
            path="/$(printf '%s\n' "$url" | cut -d/ -f4-)"
            [ "$path" = "/" ] && path="/"
            raw="$output.raw"
            length="$(wc -c < "$payload" 2>/dev/null | tr -d ' ')"
            {
              printf 'POST %s HTTP/1.1\\r\\n' "$path"
              printf 'Host: %s\\r\\n' "$host"
              printf 'Content-Type: application/json\\r\\n'
              if [ -n "$api_key" ]; then
                printf 'Authorization: Bearer %s\\r\\n' "$api_key"
              fi
              printf 'Content-Length: %s\\r\\n' "${length:-0}"
              printf 'Connection: close\\r\\n'
              printf '\\r\\n'
              cat "$payload"
            } | sh -c "$nc_path '$host' '$port'" > "$raw" 2>"$errfile"
            code=$?
            if [ "$code" = "0" ]; then
              tr -d '\\r' < "$raw" | sed '1,/^$/d' > "$output"
            fi
            return "$code"
          fi
          echo "no curl or python3 available for POST" > "$errfile"
          return 127
        }

        model_status() {
          init_runtime
          load_model_config
          echo "Ogent local model runtime"
          echo "mode=local-ish-model"
          echo "config=$(display_path "$MODEL_CONFIG")"
          if [ -n "${OGENT_LOCAL_MODEL_BASE_URL:-}" ]; then
            echo "configured=1"
            echo "base_url=$OGENT_LOCAL_MODEL_BASE_URL"
          else
            echo "configured=0"
            echo "base_url=not-configured"
          fi
          echo "model_id=${OGENT_LOCAL_MODEL_ID:-not-configured}"
          if [ -n "${OGENT_LOCAL_MODEL_START_COMMAND:-}" ]; then
            echo "start_command=configured"
          else
            echo "start_command=not-configured"
          fi
          echo "runtime_kind=${OGENT_LOCAL_MODEL_RUNTIME_KIND:-not-configured}"
          if [ -n "${OGENT_LOCAL_MODEL_FILE:-}" ]; then
            if [ -f "$OGENT_LOCAL_MODEL_FILE" ]; then
              echo "model_file=$(display_path "$OGENT_LOCAL_MODEL_FILE")"
            else
              echo "model_file=missing path=$(display_path "$OGENT_LOCAL_MODEL_FILE")"
            fi
          else
            echo "model_file=not-configured"
          fi
          if [ -n "${OGENT_LOCAL_MODEL_EXTRA_ARGS:-}" ]; then
            echo "extra_args=configured"
          else
            echo "extra_args=not-configured"
          fi
          if command -v curl >/dev/null 2>&1; then
            echo "curl=available"
          else
            echo "curl=missing"
          fi
          if command -v python3 >/dev/null 2>&1; then
            echo "python3=available"
          else
            echo "python3=missing"
          fi
          if nc_path="$(netcat_command 2>/dev/null)"; then
            echo "netcat=available command=$nc_path"
          else
            echo "netcat=missing"
          fi
          if model_is_running; then
            echo "local_model_server=running pid=$(model_current_pid)"
          else
            echo "local_model_server=stopped"
          fi
          if [ -f "$MODEL_SERVER_SCRIPT" ]; then
            echo "builtin_server_script=$(display_path "$MODEL_SERVER_SCRIPT")"
          else
            echo "builtin_server_script=not-created"
          fi
          if [ -f "$MODEL_NETCAT_SCRIPT" ]; then
            echo "builtin_netcat_script=$(display_path "$MODEL_NETCAT_SCRIPT")"
          else
            echo "builtin_netcat_script=not-created"
          fi
          echo "model_dir=$(display_path "$MODEL_DIR")"
          echo "model_files=$(find "$MODEL_DIR" -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')"
          model_runtime_scan | sed 's/^/scan_/'
          model_readiness_print
          if [ -f "$MODEL_LOG" ]; then
            echo "log=$(display_path "$MODEL_LOG")"
          else
            echo "log=not-created"
          fi
        }

        model_probe() {
          init_runtime
          load_model_config
          base_url="${OGENT_LOCAL_MODEL_BASE_URL:-}"
          api_key="${OGENT_LOCAL_MODEL_API_KEY:-}"
          if [ -z "$base_url" ]; then
            echo "local_model_probe=missing reason=no_base_url config=$(display_path "$MODEL_CONFIG")"
            model_readiness_write "missing" "no_base_url" "unknown" "unknown" "not_configured" "/bin/sh /usr/local/bin/ogent-agent model-config --base-url $(shell_quote_value "$(model_default_base_url)") --model llama-local" "" "${OGENT_LOCAL_MODEL_ID:-}"
            model_readiness_print
            return 78
          fi
          api_base_url="$(model_api_base_url "$base_url")"
          if ! command -v curl >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1 && ! netcat_command >/dev/null 2>&1; then
            echo "local_model_probe=missing reason=http_client_unavailable"
            model_readiness_write "missing" "http_client_unavailable" "unknown" "unknown" "not_probeable" "/bin/sh /usr/local/bin/ogent-agent profile-install local-model" "$api_base_url" "${OGENT_LOCAL_MODEL_ID:-}"
            model_readiness_print
            return 78
          fi
          url="${api_base_url%/}/models"
          output="$TMP_DIR/local-model-probe.json"
          model_http_get "$url" "$output" "$TMP_DIR/local-model-probe.err" "$api_key"
          code=$?
          if [ "$code" = "0" ]; then
            bytes="$(wc -c < "$output" 2>/dev/null | tr -d ' ')"
            first_model="$(awk -F'"' '/"id"[[:space:]]*:/ { for (i = 1; i < NF; i++) { if ($i == "id") { print $(i + 2); exit } } }' "$output" 2>/dev/null || true)"
            model_kind="real_or_external"
            case " ${OGENT_LOCAL_MODEL_ID:-} ${first_model:-} " in
              *" ogent-local-echo "*|*" ogent-local-selftest "*) model_kind="compatibility_harness" ;;
            esac
            if [ "${OGENT_LOCAL_MODEL_RUNTIME_KIND:-}" = "llama.cpp" ] && [ "$model_kind" != "compatibility_harness" ]; then
              model_kind="real_local_llama_cpp"
            fi
            if [ "$model_kind" = "compatibility_harness" ]; then
              model_readiness_write "blocked_compatibility_harness" "compatibility_harness_not_real_inference" "unknown" "unknown" "blocked_compatibility_harness" "/bin/sh /usr/local/bin/ogent-agent model-plan" "$api_base_url" "${OGENT_LOCAL_MODEL_ID:-unknown}"
            else
              runner_state="unknown"
              model_state="unknown"
              if [ "$model_kind" = "real_local_llama_cpp" ]; then
                runner_state="available"
                model_state="available"
              fi
              model_readiness_write "ready" "$model_kind" "$runner_state" "$model_state" "ready" "none" "$api_base_url" "${OGENT_LOCAL_MODEL_ID:-unknown}"
            fi
            echo "local_model_probe=ok base_url=$api_base_url model_id=${OGENT_LOCAL_MODEL_ID:-unknown} models_bytes=$bytes first_model=${first_model:-unknown} model_kind=$model_kind"
            model_readiness_print
            return 0
          fi
          err="$(sed -n '1p' "$TMP_DIR/local-model-probe.err" 2>/dev/null | cut -c 1-220)"
          echo "local_model_probe=failed base_url=$api_base_url curl_exit=$code error=${err:-unknown}"
          model_readiness_write "missing" "probe_failed_curl_exit_$code" "unknown" "unknown" "unreachable" "/bin/sh /usr/local/bin/ogent-agent model-bootstrap --require-real" "$api_base_url" "${OGENT_LOCAL_MODEL_ID:-unknown}"
          model_readiness_print
          return "$code"
        }

        model_start() {
          init_runtime
          load_model_config
          base_url="${OGENT_LOCAL_MODEL_BASE_URL:-}"
          model_id="${OGENT_LOCAL_MODEL_ID:-}"
          command_line="${OGENT_LOCAL_MODEL_START_COMMAND:-}"
          runtime_kind="${OGENT_LOCAL_MODEL_RUNTIME_KIND:-}"
          model_file="${OGENT_LOCAL_MODEL_FILE:-}"
          extra_args="${OGENT_LOCAL_MODEL_EXTRA_ARGS:-}"
          require_real="0"
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --base-url) base_url="${2:-}"; shift 2 ;;
              --model|--model-id) model_id="${2:-}"; shift 2 ;;
              --start-command) command_line="${2:-}"; shift 2 ;;
              --runtime-kind) runtime_kind="${2:-}"; shift 2 ;;
              --model-file) model_file="${2:-}"; shift 2 ;;
              --extra-args) extra_args="${2:-}"; shift 2 ;;
              --require-real) require_real="1"; shift ;;
              *) shift ;;
            esac
          done
          if [ -z "$command_line" ]; then
            base_url="${base_url:-$(model_default_base_url)}"
            model_id="${model_id:-$(model_default_id)}"
            host="$(model_url_host "$base_url")"
            port="$(model_url_port "$base_url")"
            host="${host:-127.0.0.1}"
            port="${port:-11434}"
            if model_is_running; then
              if [ "$require_real" = "1" ]; then
                echo "local_model_start=restart_existing_for_real pid=$(model_current_pid)"
                model_stop || true
              else
                {
                  shell_assign OGENT_LOCAL_MODEL_BASE_URL "$base_url"
                  shell_assign OGENT_LOCAL_MODEL_ID "$model_id"
                  shell_assign OGENT_LOCAL_MODEL_API_KEY "${OGENT_LOCAL_MODEL_API_KEY:-}"
                  shell_assign OGENT_LOCAL_MODEL_START_COMMAND ""
                  shell_assign OGENT_LOCAL_MODEL_RUNTIME_KIND "${runtime_kind:-compatibility_harness}"
                  shell_assign OGENT_LOCAL_MODEL_FILE "$model_file"
                  shell_assign OGENT_LOCAL_MODEL_EXTRA_ARGS "$extra_args"
                } > "$MODEL_CONFIG"
                chmod 600 "$MODEL_CONFIG" 2>/dev/null || true
                echo "local_model_start=already_running mode=${runtime_kind:-compatibility_harness} pid=$(model_current_pid) base_url=$base_url model_id=$model_id"
                return 0
              fi
            fi
            server_mode=""
            if [ -z "$model_file" ] || ! model_file_is_gguf "$model_file"; then
              model_file="$(find_model_file 2>/dev/null || true)"
            fi
            if { [ "$runtime_kind" = "llama.cpp" ] || [ -n "$model_file" ]; } \
              && [ -n "$model_file" ] \
              && model_file_is_gguf "$model_file" \
              && llama_server="$(find_llama_server 2>/dev/null)"; then
              model_id="${model_id:-llama-local}"
              nohup "$llama_server" --host "$host" --port "$port" --model "$model_file" $extra_args >> "$MODEL_LOG" 2>&1 &
              server_mode="llama.cpp"
              runtime_kind="llama.cpp"
            elif [ "$require_real" = "1" ]; then
              echo "local_model_start=missing reason=real_runtime_required"
              model_real_readiness || true
              model_readiness_print
              exit 78
            elif ensure_python3; then
              model_write_builtin_server
              nohup python3 "$MODEL_SERVER_SCRIPT" --host "$host" --port "$port" --model "$model_id" >> "$MODEL_LOG" 2>&1 &
              server_mode="python"
              runtime_kind="compatibility_harness"
            elif nc_path="$(netcat_command 2>/dev/null)"; then
              model_write_netcat_server
              nohup /bin/sh "$MODEL_NETCAT_SCRIPT" "$host" "$port" "$model_id" "$nc_path" >> "$MODEL_LOG" 2>&1 &
              server_mode="netcat"
              runtime_kind="compatibility_harness"
            else
              echo "local_model_start=missing reason=python3_or_netcat_unavailable log=$(display_path "$MODEL_LOG")"
              exit 78
            fi
            {
              shell_assign OGENT_LOCAL_MODEL_BASE_URL "$base_url"
              shell_assign OGENT_LOCAL_MODEL_ID "$model_id"
              shell_assign OGENT_LOCAL_MODEL_API_KEY "${OGENT_LOCAL_MODEL_API_KEY:-}"
              shell_assign OGENT_LOCAL_MODEL_START_COMMAND ""
              shell_assign OGENT_LOCAL_MODEL_RUNTIME_KIND "$runtime_kind"
              shell_assign OGENT_LOCAL_MODEL_FILE "$model_file"
              shell_assign OGENT_LOCAL_MODEL_EXTRA_ARGS "$extra_args"
            } > "$MODEL_CONFIG"
            chmod 600 "$MODEL_CONFIG" 2>/dev/null || true
            pid="$!"
            printf '%s\n' "$pid" > "$MODEL_PID"
            sleep 1
            if ! kill -0 "$pid" 2>/dev/null; then
              echo "local_model_start=failed mode=$runtime_kind server=$server_mode log=$(display_path "$MODEL_LOG")"
              model_readiness_write "missing" "start_failed" "unknown" "unknown" "start_failed" "/bin/sh /usr/local/bin/ogent-agent model-plan" "$base_url" "$model_id"
              model_readiness_print
              exit 1
            fi
            log_event "model_start mode=$runtime_kind pid=$pid"
            echo "local_model_start=started mode=$runtime_kind server=$server_mode pid=$pid base_url=$base_url model_id=$model_id log=$(display_path "$MODEL_LOG")"
            if [ "$runtime_kind" = "llama.cpp" ]; then
              model_readiness_write "starting" "llama_cpp_process_started" "available" "available" "starting" "/bin/sh /usr/local/bin/ogent-agent model-probe" "$base_url" "$model_id"
            else
              model_readiness_write "blocked_compatibility_harness" "compatibility_harness_started" "unknown" "unknown" "blocked_compatibility_harness" "/bin/sh /usr/local/bin/ogent-agent model-plan" "$base_url" "$model_id"
            fi
            model_readiness_print
            return 0
          fi
          nohup /bin/sh -c "$command_line" >> "$MODEL_LOG" 2>&1 &
          pid="$!"
          printf '%s\n' "$pid" > "$MODEL_PID"
          log_event "model_start mode=custom pid=$pid"
          echo "local_model_start=started mode=custom pid=$pid log=$(display_path "$MODEL_LOG")"
          model_readiness_write "starting" "custom_start_command_started" "custom" "custom" "starting" "/bin/sh /usr/local/bin/ogent-agent model-probe" "${base_url:-${OGENT_LOCAL_MODEL_BASE_URL:-}}" "${model_id:-${OGENT_LOCAL_MODEL_ID:-}}"
          model_readiness_print
        }

        model_stop() {
          init_runtime
          pid="$(model_current_pid)"
          if [ -z "$pid" ]; then
            echo "local_model_stop=skipped reason=no_pid"
            exit 0
          fi
          if kill "$pid" 2>/dev/null; then
            rm -f "$MODEL_PID" 2>/dev/null || true
            log_event "model_stop pid=$pid"
            echo "local_model_stop=ok pid=$pid"
            model_readiness_write "stopped" "user_or_runtime_stop" "unknown" "unknown" "stopped" "/bin/sh /usr/local/bin/ogent-agent model-plan" "${OGENT_LOCAL_MODEL_BASE_URL:-}" "${OGENT_LOCAL_MODEL_ID:-}"
          else
            rm -f "$MODEL_PID" 2>/dev/null || true
            echo "local_model_stop=skipped reason=not_running pid=$pid"
            model_readiness_write "stopped" "process_not_running" "unknown" "unknown" "stopped" "/bin/sh /usr/local/bin/ogent-agent model-plan" "${OGENT_LOCAL_MODEL_BASE_URL:-}" "${OGENT_LOCAL_MODEL_ID:-}"
          fi
          model_readiness_print
        }

        model_bootstrap() {
          model_start "$@"
          model_probe
        }

        env_list() {
          init_runtime
          if [ "$(count_files "$ENV_DIR")" = "0" ]; then
            echo "no env vars configured"
            exit 0
          fi
          find "$ENV_DIR" -maxdepth 1 -type f 2>/dev/null | sort | while read -r file; do
            key="$(basename "$file")"
            bytes="$(wc -c < "$file" | tr -d ' ')"
            echo "$key=*** ($bytes bytes)"
          done
        }

        tool_inventory() {
          init_runtime
          echo "Ogent tool inventory"
          echo "core=ogent-agent shell_local mcp_status mcp_tools mcp_call"
          echo "linux=$(available_tools)"
          echo "paths:"
          echo "  workspace=$(display_path "$WORKSPACE")"
          echo "  artifacts=$(display_path "$ARTIFACT_DIR")"
          echo "  memory=$(display_path "$MEMORY_DIR")"
          echo "  wiki_memory=$(display_path "$WIKI_DIR")"
          echo "  skills=$(display_path "$SKILL_DIR")"
          echo "  subagents=$(display_path "$SUBAGENT_DIR")"
          echo "  automations=$AUTOMATION_DISPLAY_DIR"
          echo "  sessions=$(display_path "$SESSION_DIR")"
          echo "  checkpoints=$(display_path "$CHECKPOINT_DIR")"
          echo "  model_runtime=$(display_path "$MODEL_DIR")"
          echo "rootfs_overlay:"
          echo "  $(rootfs_overlay_line)"
          echo "profiles:"
          echo "  core=$(profile_status core | tail -n 1)"
          echo "  mcp=$(profile_status mcp | tail -n 1)"
          echo "  12306=$(profile_status 12306 | tail -n 1)"
          echo "  local_model=$(profile_status local-model | tail -n 1)"
        }

        mcp_12306_json_escape() {
          sed -e 's/\\\\/\\\\\\\\/g' -e 's/"/\\\\"/g' | awk 'BEGIN{ORS=""}{gsub(/\\r/,"\\\\r"); gsub(/\\t/,"\\\\t"); if (NR>1) printf "\\\\n"; printf "%s",$0}'
        }

        mcp_12306_send() {
          printf '%s\\n' "$1"
        }

        mcp_12306_content() {
          id="$1"
          text="$2"
          escaped="$(printf '%s' "$text" | mcp_12306_json_escape)"
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s"}]}}\\n' "$id" "$escaped"
        }

        mcp_12306_error() {
          id="$1"
          code="$2"
          message="$3"
          escaped="$(printf '%s' "$message" | mcp_12306_json_escape)"
          printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s"}}\\n' "$id" "$code" "$escaped"
        }

        mcp_12306_field() {
          key="$1"
          line="$2"
          printf '%s' "$line" | sed -n "s/.*\\"$key\\":\\"\\([^\\"]*\\)\\".*/\\1/p"
        }

        mcp_12306_id() {
          line="$1"
          value="$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')"
          printf '%s' "${value:-3}"
        }

        mcp_12306_station_json() {
          case "$1" in
            北京) printf '{"station_code":"BJP","station_name":"北京"}' ;;
            北京南) printf '{"station_code":"VNP","station_name":"北京南"}' ;;
            北京西) printf '{"station_code":"BXP","station_name":"北京西"}' ;;
            北京北) printf '{"station_code":"VAP","station_name":"北京北"}' ;;
            上海) printf '{"station_code":"SHH","station_name":"上海"}' ;;
            上海虹桥) printf '{"station_code":"AOH","station_name":"上海虹桥"}' ;;
            上海南) printf '{"station_code":"SNH","station_name":"上海南"}' ;;
            广州) printf '{"station_code":"GZQ","station_name":"广州"}' ;;
            广州南) printf '{"station_code":"IZQ","station_name":"广州南"}' ;;
            深圳) printf '{"station_code":"SZQ","station_name":"深圳"}' ;;
            深圳北) printf '{"station_code":"IOQ","station_name":"深圳北"}' ;;
            杭州) printf '{"station_code":"HZH","station_name":"杭州"}' ;;
            杭州东) printf '{"station_code":"HGH","station_name":"杭州东"}' ;;
            南京) printf '{"station_code":"NJH","station_name":"南京"}' ;;
            南京南) printf '{"station_code":"NKH","station_name":"南京南"}' ;;
            成都) printf '{"station_code":"CDW","station_name":"成都"}' ;;
            成都东) printf '{"station_code":"ICW","station_name":"成都东"}' ;;
            重庆北) printf '{"station_code":"CUW","station_name":"重庆北"}' ;;
            西安北) printf '{"station_code":"EAY","station_name":"西安北"}' ;;
            武汉) printf '{"station_code":"WHN","station_name":"武汉"}' ;;
            *) printf '{"error":"station_not_found","station_name":"%s"}' "$1" ;;
          esac
        }

        mcp_12306_city_json() {
          case "$1" in
            北京) printf '{"station_code":"BJP","station_name":"北京"}' ;;
            上海) printf '{"station_code":"SHH","station_name":"上海"}' ;;
            广州) printf '{"station_code":"GZQ","station_name":"广州"}' ;;
            深圳) printf '{"station_code":"SZQ","station_name":"深圳"}' ;;
            杭州) printf '{"station_code":"HZH","station_name":"杭州"}' ;;
            南京) printf '{"station_code":"NJH","station_name":"南京"}' ;;
            成都) printf '{"station_code":"CDW","station_name":"成都"}' ;;
            重庆) printf '{"station_code":"CQW","station_name":"重庆"}' ;;
            西安) printf '{"station_code":"XAY","station_name":"西安"}' ;;
            武汉) printf '{"station_code":"WHN","station_name":"武汉"}' ;;
            *) printf '{"error":"city_not_found","city":"%s"}' "$1" ;;
          esac
        }

        mcp_12306_names_json() {
          names="$1"
          out="{"
          first=1
          oldifs="$IFS"
          IFS='|'
          for name in $names; do
            clean="${name%站}"
            [ "$first" = "1" ] || out="$out,"
            first=0
            out="$out\\"$clean\\":$(mcp_12306_station_json "$clean")"
          done
          IFS="$oldifs"
          printf '%s}' "$out"
        }

        mcp_12306_citys_json() {
          citys="$1"
          out="{"
          first=1
          oldifs="$IFS"
          IFS='|'
          for city in $citys; do
            clean="${city%市}"
            [ "$first" = "1" ] || out="$out,"
            first=0
            out="$out\\"$clean\\":$(mcp_12306_city_json "$clean")"
          done
          IFS="$oldifs"
          printf '%s}' "$out"
        }

        mcp_12306_live_unavailable() {
          tool="$1"
          cat <<EOF
        $tool 当前由 Oases 内置离线 12306 MCP server 响应。站点码和工具发现可离线使用；实时余票/中转/经停需要 12306 网络接口可达。
        offline_mcp=ok
        live_query=unavailable
        next_step=网络可达后重试，或使用 get-station-code-by-names / get-station-code-of-citys 先完成站点解析。
        EOF
        }

        mcp_12306_tools_list() {
          id="$1"
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"get-current-date","description":"获取当前日期，以上海时区为准，返回 yyyy-MM-dd。","inputSchema":{"type":"object","properties":{}}},{"name":"get-stations-code-in-city","description":"通过中文城市名查询该城市火车站名称及 station_code。","inputSchema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}},{"name":"get-station-code-of-citys","description":"通过中文城市名查询代表该城市的 station_code。多个城市用 | 分割。","inputSchema":{"type":"object","properties":{"citys":{"type":"string"}},"required":["citys"]}},{"name":"get-station-code-by-names","description":"通过具体中文车站名查询 station_code。多个站点用 | 分割。","inputSchema":{"type":"object","properties":{"stationNames":{"type":"string"}},"required":["stationNames"]}},{"name":"get-station-by-telecode","description":"通过车站 telecode 查询车站信息。","inputSchema":{"type":"object","properties":{"stationTelecode":{"type":"string"}},"required":["stationTelecode"]}},{"name":"get-tickets","description":"查询 12306 直达余票。实时查询需要网络。","inputSchema":{"type":"object","properties":{"date":{"type":"string"},"fromStation":{"type":"string"},"toStation":{"type":"string"},"trainFilterFlags":{"type":"string"},"format":{"type":"string"}},"required":["date","fromStation","toStation"]}},{"name":"get-interline-tickets","description":"查询 12306 中转余票。实时查询需要网络。","inputSchema":{"type":"object","properties":{"date":{"type":"string"},"fromStation":{"type":"string"},"toStation":{"type":"string"},"middleStation":{"type":"string"},"format":{"type":"string"}},"required":["date","fromStation","toStation"]}},{"name":"get-train-route-stations","description":"查询车次经停信息。实时查询需要网络。","inputSchema":{"type":"object","properties":{"trainCode":{"type":"string"},"departDate":{"type":"string"},"format":{"type":"string"}},"required":["trainCode","departDate"]}}]}}\\n' "$id"
        }

        mcp_12306_call() {
          line="$1"
          id="$2"
          name="$(mcp_12306_field name "$line")"
          case "$name" in
            get-current-date)
              mcp_12306_content "$id" "$(TZ=Asia/Shanghai date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
              ;;
            get-station-code-by-names)
              stationNames="$(mcp_12306_field stationNames "$line")"
              if [ -z "$stationNames" ]; then
                mcp_12306_content "$id" '{"error":"stationNames is required"}'
              else
                mcp_12306_content "$id" "$(mcp_12306_names_json "$stationNames")"
              fi
              ;;
            get-station-code-of-citys)
              citys="$(mcp_12306_field citys "$line")"
              if [ -z "$citys" ]; then
                mcp_12306_content "$id" '{"error":"citys is required"}'
              else
                mcp_12306_content "$id" "$(mcp_12306_citys_json "$citys")"
              fi
              ;;
            get-stations-code-in-city)
              city="$(mcp_12306_field city "$line")"
              if [ -z "$city" ]; then
                mcp_12306_content "$id" '{"error":"city is required"}'
              else
                mcp_12306_content "$id" "[$(mcp_12306_city_json "${city%市}")]"
              fi
              ;;
            get-station-by-telecode)
              tele="$(mcp_12306_field stationTelecode "$line")"
              mcp_12306_content "$id" "{\\"station_code\\":\\"$tele\\",\\"note\\":\\"offline telecode lookup is limited in Oases built-in 12306 MCP\\"}"
              ;;
            get-tickets|get-interline-tickets|get-train-route-stations)
              mcp_12306_error "$id" -32001 "上游 12306 MCP 未就绪，离线 Oases shim 不提供实时余票、中转或经停查询。请先完成 profile-install 12306 并重试。"
              ;;
            *)
              mcp_12306_error "$id" -32602 "unknown tool: $name"
              ;;
          esac
        }

        mcp_12306_server() {
          init_runtime
          upstream_package="$(pinned_12306_package)"
          if [ "${OASES_12306_MCP_AUTO_INSTALL:-0}" = "1" ]; then
            if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 && command -v npx >/dev/null 2>&1; then
              ensure_12306_mcp_upstream || true
            else
              profile_install 12306 >/dev/null 2>&1 || true
            fi
          fi
          if [ "${OASES_12306_MCP_FORCE_SHIM:-0}" != "1" ]; then
            if upstream_bin="$(upstream_12306_bin 2>/dev/null)"; then
              exec "$upstream_bin" "$@"
            fi
            if upstream_bundle="$(upstream_12306_bundle 2>/dev/null)"; then
              exec node "$upstream_bundle" "$@"
            fi
            if [ "${OASES_12306_MCP_USE_NPX:-0}" = "1" ] && command -v npx >/dev/null 2>&1; then
              exec npx -y "$upstream_package" "$@"
            fi
          fi
          while IFS= read -r line; do
            method="$(printf '%s' "$(mcp_12306_field method "$line")" | sed 's#\\\\/#/#g')"
            id="$(mcp_12306_id "$line")"
            case "$method" in
              initialize)
                printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"oases-12306-mcp","version":"1.0.0"}}}\\n' "$id"
                ;;
              notifications/initialized)
                ;;
              tools/list)
                mcp_12306_tools_list "$id"
                ;;
              tools/call)
                mcp_12306_call "$line" "$id"
                ;;
              *)
                [ -n "$method" ] && mcp_12306_error "$id" -32601 "unknown method: $method"
                ;;
            esac
          done
        }

        usage() {
          cat <<'EOF'
        ogent-agent commands:
          status
          rootfs-doctor
          rootfs-repair [--check-only]
          rootfs-overlay-status
          workspace-snapshot
          plan-write --title <title> --file <payload>
          plan-read
          run-script --title <title> --script-file <path> --timeout <seconds>
          note-append --file <payload>
          inbox-add --file <payload>
          inbox-read
          session-start --title <title>
          session-note [--id <session>] --file <payload>
          session-read [--id <session>]
          project-manifest-start --title <title> [--session-id <session>] --file <payload>
          project-manifest-update [--id <project>] [--status <status>] [--event <event>] --file <payload>
          project-manifest-read [--id <project>]
          memory-set --key <key> --file <payload>
          memory-get [key]
          memory-add --title <title> --file <payload> [--tags <tags>]
                  memory-search [query]
                  wiki-upsert --topic <topic> --file <payload> [--title <title>] [--tags <tags>] [--related <a,b,c>]
                  wiki-summary
                  wiki-graph
                  rag-rebuild
                  rag-search <query>
          skill-list
          skill-install --name <name> --file <payload>
          subagent-create --name <name> --file <instructions>
          subagent-list
          subagent-task --name <name> --file <task>
          subagent-run --name <name> [--task <task-id|latest>] [--allow-harness]
          automation-create --name <name> --trigger <manual|hourly|daily|interval:seconds|on_boot> --file <script>
          automation-list
          automation-due
          automation-run <automation-id>
          automation-run-due
          task-log <task-id>
          task-status
          finalizer-snapshot
          artifact-list
          artifact-manifest
          checkpoint-create --name <name>
          checkpoint-list
          checkpoint-restore <checkpoint-id>
          model-config --base-url <url> [--model <id>] [--api-key <key>] [--start-command <cmd>] [--runtime-kind llama.cpp] [--model-file <file.gguf>]
          model-status
          model-readiness
          model-scan
          model-probe
          model-start [--require-real]
          model-stop
          model-bootstrap [--require-real]
          model-deployment-plan [--url <https://.../*.gguf>] [--model-file </root/.ogent/models/model.gguf>] [--runner-url <https://.../llama-server>] [--repo <git-url>] [--ref <git-ref>] [--model <id>]
          model-doctor [--url <https://.../*.gguf>] [--model-file </root/.ogent/models/model.gguf>] [--runner-url <https://.../llama-server>] [--repo <git-url>] [--ref <git-ref>] [--model <id>]
          model-build-llama [--install-deps] [--repo <git-url>] [--ref <git-ref>] [--jobs <n>] [--clean]
          model-install-runner --url <https://.../llama-server> [--sha256 <hex>]
          model-install-gguf --url <https://.../*.gguf> [--sha256 <hex>] [--name <file.gguf>] [--model <id>] [--no-default]
          model-provision [--url <https://.../*.gguf> | --model-file </root/.ogent/models/model.gguf>] [--runner-url <https://.../llama-server>] [--repo <git-url>] [--ref <git-ref>] [--sha256 <hex>] [--model <id>] [--install-deps] [--no-start]
          model-runner-validation-selftest
          profile-status [core|mcp|12306|media|document|local-model|all]
          profile-install [core|mcp|12306|media|document|local-model|all]
          mcp-12306-server
          env-list
          tool-inventory
        EOF
        }

        command="${1:-status}"
        if [ "$#" -gt 0 ]; then
          shift
        fi

        case "$command" in
          bootstrap-check|bootstrap_check) echo "ogent_bootstrap_ok version=$VERSION" ;;
          status) status_runtime "$@" ;;
          rootfs-doctor|rootfs_doctor) rootfs_doctor "$@" ;;
          rootfs-repair|rootfs_repair) rootfs_repair "$@" ;;
          rootfs-overlay-status|rootfs_overlay_status) rootfs_overlay_status "$@" ;;
          workspace-snapshot|workspace_snapshot) workspace_snapshot "$@" ;;
          plan-write|plan_write) plan_write "$@" ;;
          plan-read|plan_read) plan_read "$@" ;;
          run-script|run_script) run_task "$@" ;;
          note-append|note_append) note_append "$@" ;;
          inbox-add|inbox_add) inbox_add "$@" ;;
          inbox-read|inbox_read) inbox_read "$@" ;;
          session-start|session_start) session_start "$@" ;;
          session-note|session_note) session_note "$@" ;;
          session-read|session_read) session_read "$@" ;;
          project-manifest-start|project_manifest_start) project_manifest_start "$@" ;;
          project-manifest-update|project_manifest_update) project_manifest_update "$@" ;;
          project-manifest-read|project_manifest_read) project_manifest_read "$@" ;;
          memory-set|remember|memory_set) memory_set "$@" ;;
          memory-get|recall|memory_get) memory_get "$@" ;;
          memory-add|memory_add) memory_add "$@" ;;
                  memory-search|memory_search) memory_search "$@" ;;
                  wiki-upsert|wiki_upsert) wiki_upsert "$@" ;;
                  wiki-summary|wiki_summary) wiki_summary "$@" ;;
                  wiki-graph|wiki_graph) wiki_graph "$@" ;;
                  rag-rebuild|rag_rebuild) rag_rebuild "$@" ;;
          rag-search|rag_search) rag_search "$@" ;;
          skill-list|skill_list) skill_list "$@" ;;
          skill-install|skill_install) skill_install "$@" ;;
          subagent-create|subagent_create) subagent_create "$@" ;;
          subagent-list|subagent_list) subagent_list "$@" ;;
          subagent-task|subagent_task) subagent_task "$@" ;;
          subagent-run|subagent_run) subagent_run "$@" ;;
          automation-create|automation_create) automation_create "$@" ;;
          automation-list|automation_list) automation_list "$@" ;;
          automation-due|automation_due) automation_due list "$@" ;;
          automation-run|automation_run) automation_run_one "$@" ;;
          automation-run-due|automation_run_due) automation_due run "$@" ;;
          task-log|task_log) task_log "$@" ;;
          task-status|task_status) task_status "$@" ;;
          finalizer-snapshot|finalizer_snapshot) finalizer_snapshot "$@" ;;
          artifact-list|artifact_list) artifact_list "$@" ;;
          artifact-manifest|artifact_manifest) artifact_manifest "$@" ;;
          checkpoint-create|checkpoint_create) checkpoint_create "$@" ;;
          checkpoint-list|checkpoint_list) checkpoint_list "$@" ;;
          checkpoint-restore|checkpoint_restore) checkpoint_restore "$@" ;;
          model-config|model_config) model_config "$@" ;;
          model-status|model_status) model_status "$@" ;;
          model-readiness|model_readiness) init_runtime; load_model_config; model_readiness_print "$@" ;;
          model-scan|model_scan) model_runtime_scan "$@" ;;
          model-probe|model_probe) model_probe "$@" ;;
          model-start|model_start) model_start "$@" ;;
          model-stop|model_stop) model_stop "$@" ;;
          model-bootstrap|model_bootstrap) model_bootstrap "$@" ;;
          model-deployment-plan|model_deployment_plan|model-plan|model_plan) model_deployment_plan "$@" ;;
          model-doctor|model_doctor) model_doctor "$@" ;;
          model-build-llama|model_build_llama) model_build_llama "$@" ;;
          model-install-runner|model_install_runner) model_install_runner "$@" ;;
          model-install-gguf|model_install_gguf) model_install_gguf "$@" ;;
          model-provision|model_provision) model_provision "$@" ;;
          model-runner-validation-selftest|model_runner_validation_selftest) model_runner_validation_selftest "$@" ;;
          profile-status|profile_status) profile_status "$@" ;;
          profile-install|profile_install) profile_install "$@" ;;
          mcp-12306-server|mcp_12306_server) mcp_12306_server "$@" ;;
          env-list|env_list) env_list "$@" ;;
          tool-inventory|tool_inventory) tool_inventory "$@" ;;
          help|-h|--help) usage ;;
          *) echo "unknown ogent-agent command: $command"; usage; exit 64 ;;
        esac
        """
    }
}
