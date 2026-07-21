import Foundation

/// The MCP Apps follow-up card: a self-contained `ui://` HTML resource that hosts
/// supporting the apps extension (ext-apps 2026-01-26) render inline with
/// `get_followups` / `get_all_followups` results. Vanilla HTML/CSS/JS, no external
/// assets (strict CSP); talks JSON-RPC to the host over `window.parent.postMessage`.
///
/// Handshake (validated against the official @modelcontextprotocol/ext-apps SDK
/// schemas): request `ui/initialize` with `{appInfo, appCapabilities,
/// protocolVersion}` — exactly those keys; the SDK host zod-rejects anything else
/// — then notify `ui/notifications/initialized`. The host pushes results via
/// `ui/notifications/tool-result` and theme/styles via the initialize result's
/// `hostContext` + `ui/notifications/host-context-changed`.
///
/// The card is the "curate then hand off" surface: per-meeting sections, editable
/// per-item instructions (saved via `update_followup`), Done/Dismiss, and a
/// checkbox selection handed to the chat in one `ui/message` batch prompt.
///
/// Rendering is legible before (or without) any handshake: static header + status
/// line styled with CSS `light-dark()` fallbacks, so a failed handshake shows its
/// error in the card instead of a blank box.
///
/// All meeting data is transcript-derived and untrusted: the script only ever
/// writes it to the DOM through `textContent` / `value`, never `innerHTML`.
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
          /* Every color has a light-dark() fallback so the card is readable in both
             themes with zero handshake; host style variables override when present. */
          :root {
            color-scheme: light dark;
            --pf-text: var(--color-text-primary, light-dark(#17181c, #f2f3f5));
            --pf-muted: var(--color-text-secondary, light-dark(#667085, #9aa1ac));
            --pf-border: var(--color-border-primary, light-dark(rgba(23, 24, 28, 0.16), rgba(242, 243, 245, 0.22)));
            --pf-accent: var(--color-text-accent, light-dark(#2563eb, #8ab4f8));
            --pf-bg: var(--color-background-primary, light-dark(#ffffff, #1e1f23));
            --pf-field-bg: var(--color-background-secondary, light-dark(#f6f7f8, #26272c));
            --pf-error: light-dark(#b91c1c, #f87171);
          }
          :root[data-theme="light"] { color-scheme: light; }
          :root[data-theme="dark"] { color-scheme: dark; }
          body {
            margin: 0;
            padding: 12px 14px;
            background: var(--pf-bg);
            color: var(--pf-text);
            font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif);
            font-size: var(--font-text-md-size, 14px);
            line-height: 1.45;
          }
          header { display: flex; align-items: baseline; gap: 8px; }
          #card-title { font-weight: 600; }
          #status-line { color: var(--pf-muted); font-size: 12px; margin-top: 3px; }
          #status-line.error { color: var(--pf-error); }
          .meeting { margin-top: 12px; }
          .meeting-head {
            display: flex; align-items: baseline; gap: 8px;
            padding-bottom: 4px; border-bottom: 1px solid var(--pf-border);
          }
          .meeting-title {
            font-weight: 600; font-size: 13px; min-width: 0;
            overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
          }
          .meeting-count { color: var(--pf-muted); font-size: 12px; flex-shrink: 0; }
          ul { list-style: none; margin: 0; padding: 0; }
          li { display: flex; align-items: flex-start; gap: 8px; padding: 8px 0; border-top: 1px solid var(--pf-border); }
          li:first-child { border-top: none; }
          li.closed { opacity: 0.55; padding: 5px 0; }
          input.pick { margin: 3px 0 0; accent-color: var(--pf-accent); flex-shrink: 0; }
          .kind {
            flex-shrink: 0; width: 20px; height: 20px; margin-top: 1px;
            display: flex; align-items: center; justify-content: center;
            border-radius: 50%; font-size: 11px; font-weight: 700;
            color: var(--pf-muted); border: 1px solid var(--pf-border);
          }
          .main { flex: 1; min-width: 0; }
          .title-row { display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; }
          .title { overflow-wrap: anywhere; }
          .owner { color: var(--pf-muted); font-size: 12px; }
          .badge {
            font-size: 11px; font-weight: 600; padding: 1px 8px; border-radius: 999px;
            color: var(--pf-muted); background: rgba(127, 127, 127, 0.14); white-space: nowrap;
          }
          .badge.proposed { color: light-dark(#b45309, #fbbf24); background: rgba(245, 158, 11, 0.16); }
          .badge.approved, .badge.done { color: light-dark(#15803d, #4ade80); background: rgba(34, 197, 94, 0.16); }
          .badge.in_progress { color: light-dark(#1d4ed8, #93c5fd); background: rgba(59, 130, 246, 0.16); }
          textarea.instructions {
            display: block; width: 100%; margin-top: 6px; padding: 5px 8px;
            font: inherit; font-size: 13px; line-height: 1.4; resize: vertical;
            color: var(--pf-text); background: var(--pf-field-bg);
            border: 1px solid var(--pf-border); border-radius: var(--border-radius-md, 6px);
          }
          textarea.instructions:disabled { opacity: 0.6; }
          .item-actions { display: flex; align-items: center; gap: 6px; margin-top: 5px; }
          .item-actions .spacer { flex: 1; }
          .meta { color: var(--pf-muted); font-size: 12px; margin-top: 4px; overflow-wrap: anywhere; }
          .meta a { color: var(--pf-accent); }
          button {
            font: inherit; font-size: 12px; font-weight: 500; padding: 3px 10px;
            border-radius: var(--border-radius-md, 6px); border: 1px solid var(--pf-border);
            background: transparent; color: var(--pf-text); cursor: pointer;
          }
          button.primary, button.save {
            border-color: transparent; background: var(--pf-accent);
            color: light-dark(#ffffff, #17181c);
          }
          button:disabled { opacity: 0.5; cursor: default; }
          footer { margin-top: 12px; padding-top: 10px; border-top: 1px solid var(--pf-border); }
          #fallback { margin-top: 10px; }
          #fallback .hint { color: var(--pf-muted); font-size: 12px; margin-bottom: 5px; }
          #fallback textarea {
            display: block; width: 100%; padding: 5px 8px; margin-bottom: 6px;
            font: inherit; font-size: 12px; resize: vertical;
            color: var(--pf-text); background: var(--pf-field-bg);
            border: 1px solid var(--pf-border); border-radius: var(--border-radius-md, 6px);
          }
        </style>
        </head>
        <body data-testid="parfait-followup-card">
        <header>
          <span id="card-title">Parfait follow-ups</span>
        </header>
        <!-- Static + self-diagnostic: readable with zero JS/handshake, and any
             handshake failure surfaces its error text here instead of a blank box. -->
        <div id="status-line">Connecting to host&hellip;</div>
        <div id="groups"></div>
        <footer id="footer" hidden>
          <button id="work" class="primary" type="button">Work on selected (0)</button>
        </footer>
        <div id="fallback" hidden>
          <div class="hint">This host couldn't accept the message. Copy the prompt below and paste it into the chat:</div>
          <textarea id="fallback-text" readonly rows="4"></textarea>
          <button id="fallback-copy" type="button">Copy</button>
        </div>
        <script>
        "use strict";
        (function () {
          // ---- JSON-RPC 2.0 over postMessage (MCP Apps, ext-apps 2026-01-26) ----
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
            // Opened standalone (no host), our own posts echo back; ignore them.
            if (event.source === window) return;
            var msg = event.data;
            if (!msg || msg.jsonrpc !== "2.0") return;
            if (msg.method === undefined && msg.id !== undefined) { // response to one of ours
              var p = pending[msg.id];
              if (!p) return;
              delete pending[msg.id];
              if (msg.error) p.reject(new Error(msg.error.message || "Request failed"));
              else p.resolve(msg.result);
            } else if (msg.method !== undefined && msg.id !== undefined) {
              // Host-initiated request. We implement none, but always answer so the
              // host can't hang waiting (teardown gets an empty success).
              if (msg.method === "ui/resource-teardown") {
                post({ jsonrpc: "2.0", id: msg.id, result: {} });
              } else {
                post({ jsonrpc: "2.0", id: msg.id,
                       error: { code: -32601, message: "Method not found: " + msg.method } });
              }
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

          var statusEl = document.getElementById("status-line");
          function setStatus(text, isError) {
            statusEl.textContent = text || "";
            statusEl.hidden = !text;
            statusEl.className = isError ? "error" : "";
          }

          // ---- Handshake. The SDK host requires exactly these three params. ----
          request("ui/initialize", {
            appInfo: { name: "parfait-followup-card", version: "2.0" },
            appCapabilities: { availableDisplayModes: ["inline"] },
            protocolVersion: "2026-01-26",
          }).then(function (result) {
            if (result && result.hostContext) applyHostContext(result.hostContext);
            notify("ui/notifications/initialized", {});
            if (!groups) setStatus("Connected (waiting for data)", false);
          }).catch(function (error) {
            setStatus("Host handshake failed: "
              + (error && error.message ? error.message : "unknown error"), true);
          });

          function sendSize() {
            notify("ui/notifications/size-changed", {
              width: document.documentElement.scrollWidth,
              height: document.documentElement.scrollHeight,
            });
          }
          if (window.ResizeObserver) new ResizeObserver(sendSize).observe(document.body);

          // ---- State. Data is transcript-derived and untrusted: textContent only. ----
          var groups = null;   // [{meetingID, meetingTitle, items}]
          var uiState = {};    // "meetingID/itemID" -> {selected, draft} — survives re-renders
          var handedOff = false;
          var OPEN = { proposed: true, approved: true, in_progress: true };
          var KIND_ICONS = { action: "✓", question: "?", followup: "↻" };
          var groupsEl = document.getElementById("groups");
          var footerEl = document.getElementById("footer");
          var workBtn = document.getElementById("work");

          function statusOf(item) {
            return typeof item.status === "string" && item.status ? item.status : "proposed";
          }
          function isOpen(item) { return OPEN[statusOf(item)] === true; }
          function stateOf(group, item) {
            var key = group.meetingID + "/" + item.id;
            return uiState[key] || (uiState[key] = {});
          }
          function isSelected(group, item) {
            var s = stateOf(group, item);
            return s.selected !== undefined ? s.selected : isOpen(item);
          }
          function isHTTP(url) { return typeof url === "string" && /^https?:\/\//i.test(url); }

          function firstText(result) {
            var content = Array.isArray(result.content) ? result.content : [];
            for (var i = 0; i < content.length; i++) {
              var block = content[i];
              if (block && block.type === "text" && typeof block.text === "string") return block.text;
            }
            return null;
          }

          // Both envelopes normalize to per-meeting groups:
          //   get_followups      -> {meeting_id, meeting_title, items}
          //   get_all_followups  -> {meetings: [{meeting_id, meeting_title, items}]}
          function normalize(data) {
            var raw;
            if (Array.isArray(data.meetings)) raw = data.meetings;
            else if (Array.isArray(data.items)) raw = [data];
            else return null;
            var out = [];
            raw.forEach(function (m) {
              if (!m || typeof m !== "object") return;
              if (typeof m.meeting_id !== "string" || !Array.isArray(m.items)) return;
              out.push({
                meetingID: m.meeting_id,
                meetingTitle: typeof m.meeting_title === "string" && m.meeting_title
                  ? m.meeting_title : "Untitled meeting",
                items: m.items.filter(function (item) {
                  return item && typeof item === "object" && typeof item.id === "string";
                }),
              });
            });
            return out;
          }

          function receiveToolResult(result) {
            if (result.isError) {
              setStatus(firstText(result) || "The tool call failed.", true);
              return;
            }
            var data = result.structuredContent;
            if (!data || typeof data !== "object") {
              var text = firstText(result);
              if (text) { try { data = JSON.parse(text); } catch (e) { data = null; } }
            }
            if (!data || typeof data !== "object") return;
            var next = normalize(data);
            if (!next) return;
            groups = next;
            render();
          }

          // ---- Rendering ----
          function render() {
            groupsEl.textContent = "";
            var total = 0, open = 0;
            groups.forEach(function (group) {
              group.items.forEach(function (item) { total++; if (isOpen(item)) open++; });
            });
            if (!total) {
              setStatus("No follow-ups — you're clear.", false);
            } else {
              setStatus(total + " follow-up" + (total === 1 ? "" : "s")
                + (open !== total ? " (" + open + " open)" : ""), false);
            }
            groups.forEach(function (group) {
              if (group.items.length) groupsEl.appendChild(section(group));
            });
            updateFooter();
            sendSize();
          }

          function section(group) {
            var div = document.createElement("div");
            div.className = "meeting";
            var head = document.createElement("div");
            head.className = "meeting-head";
            var title = document.createElement("span");
            title.className = "meeting-title";
            title.textContent = group.meetingTitle;
            var count = document.createElement("span");
            count.className = "meeting-count";
            var openCount = group.items.filter(isOpen).length;
            count.textContent = openCount + " open / " + group.items.length;
            head.appendChild(title);
            head.appendChild(count);
            div.appendChild(head);
            var ul = document.createElement("ul");
            group.items.filter(isOpen).forEach(function (item) { ul.appendChild(openRow(group, item)); });
            group.items.filter(function (item) { return !isOpen(item); })
              .forEach(function (item) { ul.appendChild(closedRow(item)); });
            div.appendChild(ul);
            return div;
          }

          function kindGlyph(item) {
            var kind = document.createElement("span");
            kind.className = "kind";
            kind.textContent = KIND_ICONS[item.kind] || KIND_ICONS.followup;
            kind.title = typeof item.kind === "string" ? item.kind : "followup";
            return kind;
          }

          function badge(item) {
            var status = statusOf(item);
            var el = document.createElement("span");
            el.className = "badge" + (/^[a-z_]+$/.test(status) ? " " + status : "");
            el.textContent = status.replace(/_/g, " ");
            return el;
          }

          function titleRow(item) {
            var row = document.createElement("div");
            row.className = "title-row";
            var title = document.createElement("span");
            title.className = "title";
            title.textContent = typeof item.title === "string" && item.title ? item.title : "(untitled)";
            row.appendChild(title);
            if (typeof item.owner === "string" && item.owner) {
              var owner = document.createElement("span");
              owner.className = "owner";
              owner.textContent = item.owner;
              row.appendChild(owner);
            }
            row.appendChild(badge(item));
            return row;
          }

          function openRow(group, item) {
            var li = document.createElement("li");
            var pick = document.createElement("input");
            pick.type = "checkbox";
            pick.className = "pick";
            pick.checked = isSelected(group, item);
            pick.addEventListener("change", function () {
              stateOf(group, item).selected = pick.checked;
              updateFooter();
            });
            li.appendChild(pick);
            li.appendChild(kindGlyph(item));

            var main = document.createElement("div");
            main.className = "main";
            main.appendChild(titleRow(item));

            // Editable instructions; Save appears only when dirty.
            var saved = typeof item.suggested_action === "string" ? item.suggested_action : "";
            var itemState = stateOf(group, item);
            var area = document.createElement("textarea");
            area.className = "instructions";
            area.rows = 2;
            area.placeholder = "Instructions for Claude…";
            area.value = itemState.draft !== undefined ? itemState.draft : saved;
            main.appendChild(area);

            var actions = document.createElement("div");
            actions.className = "item-actions";
            var save = document.createElement("button");
            save.type = "button";
            save.className = "save";
            save.textContent = "Save";
            save.hidden = area.value === saved;
            area.addEventListener("input", function () {
              itemState.draft = area.value;
              save.hidden = area.value ===
                (typeof item.suggested_action === "string" ? item.suggested_action : "");
            });
            save.addEventListener("click", function () {
              var draft = area.value;
              save.disabled = true;
              area.disabled = true;
              callUpdate(group, item, { suggested_action: draft }).then(function () {
                item.suggested_action = draft;
                delete itemState.draft;
                render();
              }).catch(function (error) {
                // Keep the draft — losing typed instructions on a transient
                // failure is worse than showing a stale Save button.
                setStatus(errorText(error, "Couldn't save instructions"), true);
                render();
              });
            });
            actions.appendChild(save);
            var spacer = document.createElement("span");
            spacer.className = "spacer";
            actions.appendChild(spacer);
            actions.appendChild(statusButton("Done", group, item, "done"));
            actions.appendChild(statusButton("Dismiss", group, item, "dismissed"));
            main.appendChild(actions);
            appendResultLink(main, item);
            li.appendChild(main);
            return li;
          }

          function closedRow(item) {
            var li = document.createElement("li");
            li.className = "closed";
            li.appendChild(kindGlyph(item));
            var main = document.createElement("div");
            main.className = "main";
            main.appendChild(titleRow(item));
            appendResultLink(main, item);
            li.appendChild(main);
            return li;
          }

          function appendResultLink(main, item) {
            if (!isHTTP(item.result_url)) return;
            var meta = document.createElement("div");
            meta.className = "meta";
            var link = document.createElement("a");
            link.href = item.result_url;
            link.target = "_blank";
            link.rel = "noopener noreferrer";
            link.textContent = "result";
            meta.appendChild(link);
            main.appendChild(meta);
          }

          function statusButton(label, group, item, newStatus) {
            var button = document.createElement("button");
            button.type = "button";
            button.textContent = label;
            button.addEventListener("click", function () {
              var previous = item.status;
              item.status = newStatus; // optimistic: row collapses now
              render();
              callUpdate(group, item, { status: newStatus }).catch(function (error) {
                item.status = previous; // revert
                setStatus(errorText(error, "Couldn't update"), true);
                render();
              });
            });
            return button;
          }

          function callUpdate(group, item, fields) {
            var args = { meeting_id: group.meetingID, followup_id: item.id };
            for (var key in fields) args[key] = fields[key];
            return request("tools/call", { name: "update_followup", arguments: args })
              .then(function (result) {
                if (result && result.isError) {
                  throw new Error(firstText(result) || "update_followup failed");
                }
                return result;
              });
          }

          function errorText(error, fallback) {
            return error && error.message ? fallback + ": " + error.message : fallback;
          }

          // ---- Batch hand-off ----
          function selectedItems() {
            var out = [];
            if (!groups) return out;
            groups.forEach(function (group) {
              group.items.forEach(function (item) {
                if (isOpen(item) && isSelected(group, item)) out.push({ group: group, item: item });
              });
            });
            return out;
          }

          function updateFooter() {
            var anyOpen = false;
            if (groups) {
              groups.forEach(function (group) {
                group.items.forEach(function (item) { if (isOpen(item)) anyOpen = true; });
              });
            }
            footerEl.hidden = !anyOpen;
            if (handedOff) return;
            var n = selectedItems().length;
            workBtn.disabled = n === 0;
            workBtn.textContent = "Work on selected (" + n + ")";
          }

          // Titles are untrusted transcript text headed into a chat prompt:
          // collapse whitespace/quotes and cap the length.
          function promptTitle(item) {
            var title = typeof item.title === "string" ? item.title : "";
            title = title.replace(/["\n\r]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 140);
            return title || "(untitled)";
          }

          function handoffText(selection) {
            var lines = selection.map(function (s) {
              return "- item " + s.group.meetingID + " " + s.item.id + " — \"" + promptTitle(s.item) + "\"";
            });
            return "Work on my Parfait follow-ups:\n" + lines.join("\n")
              + "\nUse the parfait followups skill: do each item's instructions and record results with update_followup.";
          }

          workBtn.addEventListener("click", function () {
            if (handedOff) return;
            var selection = selectedItems();
            if (!selection.length) return;
            var text = handoffText(selection);
            workBtn.disabled = true;
            request("ui/message", {
              role: "user",
              content: [{ type: "text", text: text }],
            }).then(function (result) {
              if (result && result.isError) throw new Error("The host declined the message.");
              handedOff = true;
              workBtn.textContent = "Handed off ✓";
            }).catch(function () {
              // Host without ui/message support: never dead-end — show the prompt to copy.
              workBtn.disabled = false;
              updateFooter();
              showFallback(text);
            });
          });

          function showFallback(text) {
            var box = document.getElementById("fallback");
            box.hidden = false;
            document.getElementById("fallback-text").value = text;
            sendSize();
          }

          document.getElementById("fallback-copy").addEventListener("click", function () {
            var area = document.getElementById("fallback-text");
            var button = document.getElementById("fallback-copy");
            function flash() { button.textContent = "Copied ✓"; }
            area.select();
            if (navigator.clipboard && navigator.clipboard.writeText) {
              navigator.clipboard.writeText(area.value).then(flash, function () {
                try { if (document.execCommand("copy")) flash(); } catch (e) {}
              });
            } else {
              try { if (document.execCommand("copy")) flash(); } catch (e) {}
            }
          });
        })();
        </script>
        </body>
        </html>
        """#
}
