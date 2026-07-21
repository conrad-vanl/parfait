import Foundation

/// The MCP Apps follow-up card: a self-contained `ui://` HTML resource that hosts
/// supporting the apps extension (ext-apps 2026-01-26) render inline with
/// `get_followups` results. Vanilla HTML/CSS/JS, no external assets (strict CSP);
/// talks JSON-RPC to the host over postMessage (`ui/initialize`, then renders
/// `ui/notifications/tool-result` and calls `update_followup_status` via
/// `tools/call` for the Approve/Dismiss buttons).
///
/// All meeting data is transcript-derived and untrusted: the script only ever
/// writes it to the DOM through `textContent`, never `innerHTML`.
enum FollowupCard {
    static let uri = "ui://parfait/followup-card.html"
    static let mimeType = "text/html;profile=mcp-app"

    static let html = #"""
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Parfait Follow-ups</title>
        <style>
          * { box-sizing: border-box; }
          :root {
            color-scheme: light dark;
            --pf-text: var(--color-text-primary, #17181c);
            --pf-muted: var(--color-text-secondary, #667085);
            --pf-border: var(--color-border-primary, rgba(127, 127, 127, 0.24));
            --pf-accent: var(--color-text-accent, #2563eb);
          }
          :root[data-theme="dark"] {
            --pf-text: var(--color-text-primary, #f2f3f5);
            --pf-muted: var(--color-text-secondary, #9aa1ac);
          }
          body {
            margin: 0;
            padding: 12px 14px;
            background: var(--color-background-primary, transparent);
            color: var(--pf-text);
            font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif);
            font-size: var(--font-text-md-size, 14px);
            line-height: 1.4;
          }
          header { display: flex; align-items: baseline; gap: 8px; margin-bottom: 6px; }
          #meeting-title { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          #count { color: var(--pf-muted); font-size: 12px; flex-shrink: 0; }
          #status-line { color: var(--pf-muted); font-size: 13px; padding: 2px 0; }
          #status-line.error { color: #dc2626; }
          :root[data-theme="dark"] #status-line.error { color: #f87171; }
          ul { list-style: none; margin: 0; padding: 0; }
          li { display: flex; align-items: flex-start; gap: 8px; padding: 7px 0; border-top: 1px solid var(--pf-border); }
          li:first-child { border-top: none; }
          .kind {
            flex-shrink: 0; width: 20px; height: 20px; margin-top: 1px;
            display: flex; align-items: center; justify-content: center;
            border-radius: 50%; font-size: 11px; font-weight: 700;
            color: var(--pf-muted); border: 1px solid var(--pf-border);
          }
          .main { flex: 1; min-width: 0; }
          .title { overflow-wrap: anywhere; }
          .meta { color: var(--pf-muted); font-size: 12px; overflow-wrap: anywhere; }
          .meta a { color: var(--pf-accent); }
          .side { flex-shrink: 0; display: flex; align-items: center; gap: 6px; margin-top: 1px; }
          .badge {
            font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 999px;
            color: var(--pf-muted); background: rgba(127, 127, 127, 0.14); white-space: nowrap;
          }
          .badge.proposed { color: #b45309; background: rgba(245, 158, 11, 0.16); }
          .badge.approved, .badge.done { color: #15803d; background: rgba(34, 197, 94, 0.16); }
          .badge.in_progress { color: #1d4ed8; background: rgba(59, 130, 246, 0.16); }
          :root[data-theme="dark"] .badge.proposed { color: #fbbf24; }
          :root[data-theme="dark"] .badge.approved, :root[data-theme="dark"] .badge.done { color: #4ade80; }
          :root[data-theme="dark"] .badge.in_progress { color: #93c5fd; }
          button {
            font: inherit; font-size: 12px; font-weight: 500; padding: 3px 10px;
            border-radius: var(--border-radius-md, 6px); border: 1px solid var(--pf-border);
            background: transparent; color: var(--pf-text); cursor: pointer;
          }
          button.approve { border-color: transparent; background: var(--pf-accent); color: #fff; }
          button:disabled { opacity: 0.5; cursor: default; }
        </style>
        </head>
        <body data-testid="parfait-followup-card">
        <header>
          <span id="meeting-title">Follow-ups</span>
          <span id="count"></span>
        </header>
        <div id="status-line">Waiting for follow-ups&hellip;</div>
        <ul id="list"></ul>
        <script>
        "use strict";
        (function () {
          // ---- JSON-RPC 2.0 over postMessage (MCP Apps, protocol 2026-01-26) ----
          var nextID = 1;
          var pending = {};
          function post(message) { window.parent.postMessage(message, "*"); }
          function notify(method, params) { post({ jsonrpc: "2.0", method: method, params: params }); }
          function request(method, params) {
            return new Promise(function (resolve, reject) {
              var id = nextID++;
              pending[id] = { resolve: resolve, reject: reject };
              post({ jsonrpc: "2.0", id: id, method: method, params: params });
            });
          }
          window.addEventListener("message", function (event) {
            var msg = event.data;
            if (!msg || msg.jsonrpc !== "2.0") return;
            if (msg.method === undefined && msg.id !== undefined) { // response to one of ours
              var p = pending[msg.id];
              if (!p) return;
              delete pending[msg.id];
              if (msg.error) p.reject(new Error(msg.error.message || "Request failed"));
              else p.resolve(msg.result);
            } else if (msg.method === "ui/notifications/tool-result") {
              receiveToolResult(msg.params || {});
            } else if (msg.method === "ui/notifications/host-context-changed") {
              applyHostContext(msg.params || {});
            }
          });

          function applyHostContext(context) {
            if (!context) return;
            if (context.theme === "dark" || context.theme === "light") {
              document.documentElement.dataset.theme = context.theme;
            }
            var variables = context.styles && context.styles.variables;
            if (variables) {
              for (var name in variables) {
                if (/^--[-a-zA-Z0-9_]+$/.test(name)) {
                  document.documentElement.style.setProperty(name, String(variables[name]));
                }
              }
            }
          }

          document.documentElement.dataset.theme =
            window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches
              ? "dark" : "light";

          request("ui/initialize", {
            protocolVersion: "2026-01-26",
            clientInfo: { name: "parfait-followup-card", version: "1.0" },
            capabilities: {},
            appCapabilities: { availableDisplayModes: ["inline"] },
          }).then(function (result) {
            if (result) applyHostContext(result.hostContext);
            notify("ui/notifications/initialized");
          }).catch(function () { /* host without apps support; card stays inert */ });

          if (window.ResizeObserver) {
            new ResizeObserver(function () {
              notify("ui/notifications/size-changed", {
                width: document.documentElement.scrollWidth,
                height: document.documentElement.scrollHeight,
              });
            }).observe(document.body);
          }

          // ---- Rendering. Data is transcript-derived and untrusted: textContent only. ----
          var state = { meetingID: null, items: [] };
          var KIND_ICONS = { action: "✓", question: "?", followup: "↻" };
          var listEl = document.getElementById("list");
          var statusEl = document.getElementById("status-line");

          function firstText(result) {
            var content = Array.isArray(result.content) ? result.content : [];
            for (var i = 0; i < content.length; i++) {
              var block = content[i];
              if (block && block.type === "text" && typeof block.text === "string") return block.text;
            }
            return null;
          }

          function receiveToolResult(result) {
            if (result.isError) {
              setStatusLine(firstText(result) || "The tool call failed.", true);
              return;
            }
            var data = result.structuredContent;
            if (!data || typeof data !== "object") {
              var text = firstText(result);
              if (text) { try { data = JSON.parse(text); } catch (e) { data = null; } }
            }
            if (!data || typeof data !== "object" || !Array.isArray(data.items)) return;
            state.meetingID = typeof data.meeting_id === "string" ? data.meeting_id : null;
            state.items = data.items.filter(function (item) { return item && typeof item === "object"; });
            document.getElementById("meeting-title").textContent =
              typeof data.meeting_title === "string" && data.meeting_title ? data.meeting_title : "Follow-ups";
            render();
          }

          function setStatusLine(text, isError) {
            statusEl.textContent = text || "";
            statusEl.hidden = !text;
            statusEl.className = isError ? "error" : "";
          }

          function render() {
            listEl.textContent = "";
            document.getElementById("count").textContent =
              state.items.length ? String(state.items.length) : "";
            if (!state.items.length) { setStatusLine("No follow-ups yet", false); return; }
            setStatusLine("", false);
            state.items.forEach(function (item) { listEl.appendChild(row(item)); });
          }

          function isHTTP(url) { return typeof url === "string" && /^https?:\/\//i.test(url); }

          function row(item) {
            var li = document.createElement("li");
            var kind = document.createElement("span");
            kind.className = "kind";
            kind.textContent = KIND_ICONS[item.kind] || KIND_ICONS.followup;
            kind.title = typeof item.kind === "string" ? item.kind : "followup";
            var main = document.createElement("div");
            main.className = "main";
            var title = document.createElement("div");
            title.className = "title";
            title.textContent = typeof item.title === "string" && item.title ? item.title : "(untitled)";
            main.appendChild(title);
            var metaBits = [];
            if (typeof item.owner === "string" && item.owner) metaBits.push(item.owner);
            if (typeof item.suggested_action === "string" && item.suggested_action) metaBits.push(item.suggested_action);
            if (metaBits.length || isHTTP(item.result_url)) {
              var meta = document.createElement("div");
              meta.className = "meta";
              meta.textContent = metaBits.join(" · ");
              if (isHTTP(item.result_url)) {
                if (metaBits.length) meta.appendChild(document.createTextNode(" · "));
                var link = document.createElement("a");
                link.href = item.result_url;
                link.target = "_blank";
                link.rel = "noopener noreferrer";
                link.textContent = "result";
                meta.appendChild(link);
              }
              main.appendChild(meta);
            }
            var side = document.createElement("div");
            side.className = "side";
            var status = typeof item.status === "string" && item.status ? item.status : "proposed";
            var badge = document.createElement("span");
            badge.className = "badge" + (/^[a-z_]+$/.test(status) ? " " + status : "");
            badge.textContent = status.replace(/_/g, " ");
            side.appendChild(badge);
            // Only proposed items are actionable; every other status is read-only.
            if (status === "proposed" && typeof item.id === "string" && state.meetingID) {
              side.appendChild(actionButton("Approve", "approve", item, "approved"));
              side.appendChild(actionButton("Dismiss", "dismiss", item, "dismissed"));
            }
            li.appendChild(kind);
            li.appendChild(main);
            li.appendChild(side);
            return li;
          }

          function actionButton(label, cls, item, newStatus) {
            var button = document.createElement("button");
            button.className = cls;
            button.textContent = label;
            button.addEventListener("click", function () { updateStatus(item, newStatus); });
            return button;
          }

          function updateStatus(item, newStatus) {
            var previous = item.status;
            item.status = newStatus; // optimistic: badge flips now, buttons disappear
            render();
            request("tools/call", {
              name: "update_followup_status",
              arguments: { meeting_id: state.meetingID, followup_id: item.id, status: newStatus },
            }).then(function (result) {
              if (result && result.isError) throw new Error(firstText(result) || "Update failed");
            }).catch(function (error) {
              item.status = previous; // revert
              render();
              setStatusLine(error && error.message ? error.message : "Update failed", true);
            });
          }
        })();
        </script>
        </body>
        </html>
        """#
}
