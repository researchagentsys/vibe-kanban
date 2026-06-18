# Vibe Kanban 架构总览

Vibe Kanban 是一个用看板(Kanban)来**规划、运行、审查多个 AI 编码代理**(Claude Code / Codex / Gemini CLI / Copilot / Amp / Cursor / OpenCode / Droid / CCR / Qwen 等 10+)的平台。核心机制是:每个 "workspace" 给代理一个独立的 git worktree、终端和 dev server,代理在其中执行,日志被规范化后实时流式推送到前端,人审查 diff、留评论、最终开 PR 合并。

它是一个 **Rust workspace(30+ crates)+ pnpm 前端 monorepo**,通过 `ts-rs` 在 Rust 与 TypeScript 之间共享类型。整个系统围绕一个 `Deployment` trait 做抽象,有 **本地(local)** 和 **云端(remote)** 两套实现。

> 注:仓库 README 顶部已挂出 "Vibe Kanban is sunsetting" 公告,但代码结构仍完整。本文件为面向开发者的架构参考,所有图均为 Mermaid 源文本,可在 GitHub / VS Code 原生渲染。

---

## 🗺️ 三种部署形态(系统上下文)

_展示同一套"编码代理执行核心"如何通过本地 CLI、Tauri 桌面应用、云端三种形态对外提供,以及云端如何借助 relay 反向触达本地实例。_

```mermaid
flowchart LR
    accTitle: Vibe Kanban Deployment Surfaces
    accDescr: The same coding-agent execution core is delivered through three surfaces — local CLI, Tauri desktop app, and cloud — with a relay tunnel letting the cloud frontend reach a local instance.

    user["👤 开发者"]

    subgraph local_surface["🖥️ 本地 / 桌面"]
        cli["📦 npx vibe-kanban (CLI)"]
        tauri["🪟 Tauri 桌面应用"]
        local_server["server 二进制<br/>(local-deployment)"]
        cli -->|"下载并启动"| local_server
        tauri -->|"内嵌"| local_server
    end

    subgraph cloud_surface["☁️ 云端 (remote crate)"]
        remote_server["Axum API + Postgres + ElectricSQL"]
        remote_web["remote-web SPA"]
        remote_server --- remote_web
    end

    core["🤖 编码代理执行核心<br/>worktree · executor · 日志规范化"]

    user --> cli
    user --> tauri
    user --> remote_web
    local_server --> core
    remote_web -. "relay 隧道 / WebRTC<br/>反向触达本地" .-> local_server

    classDef surface fill:#dbeafe,stroke:#2563eb,color:#1e3a5f
    classDef hub fill:#dcfce7,stroke:#16a34a,color:#14532d
    class local_server,remote_server surface
    class core hub
```

---

## 🏛️ 本地运行时架构(核心)

这是整个项目最重要的一张图:前端 → Axum 服务 → `Deployment` trait → 各服务 → git worktree 与代理进程。

_本地形态下,前端经 REST 与 WS/SSE 与 server 通信;server 把请求转发给 `Deployment` trait;`LocalContainerService` 驱动 executor 拉起编码代理进程,代理又通过 MCP 反向调用 server。_

```mermaid
flowchart TB
    accTitle: Vibe Kanban Local Runtime Architecture
    accDescr: Frontend talks to the Axum server over REST and WebSocket/SSE; the server delegates to the Deployment trait whose local implementation drives executors, worktrees, git, and the database, while spawned agent processes call back through the MCP server.

    subgraph fe["🖥️ 前端 (浏览器 / Tauri webview)"]
        local_web["local-web (Vite SPA)"]
        web_core["web-core (共享 React 库)<br/>TanStack Query/Router · Zustand"]
        ui_kit["ui (Radix + Tailwind 设计系统)"]
        local_web --> web_core --> ui_kit
    end

    subgraph srv["⚙️ server crate (Axum HTTP / WS)"]
        mw["middleware: origin 校验 · relay 签名 · 错误日志"]
        routes["routes: workspaces · execution-processes ·<br/>events(SSE) · terminal(WS) · oauth · search · preview"]
        embed["内嵌 SPA 静态资源 (rust-embed)"]
    end

    deployment["📦 Deployment trait (deployment crate)<br/>统一抽象: db / git / container / events / auth / relay"]

    subgraph ld["local-deployment (具体实现)"]
        container_svc["LocalContainerService<br/>拉起/监控代理进程 · 流式日志"]
        pty_svc["PtyService (终端 PTY)"]
    end

    subgraph svc["🧩 services crate"]
        git_svc["GitService"]
        event_svc["EventService + MsgStore"]
        config_svc["Config (v1→v8 迁移)"]
        fs_watch["文件系统监听"]
        pr_mon["PR 监控"]
        notif["跨平台通知"]
        approvals["审批 (工具/提问)"]
    end

    db_svc["🗄️ db (SQLite + SQLx)"]
    executors["🤖 executors (10 个编码代理)<br/>StandardCodingAgentExecutor trait"]
    ws_mgr["workspace-manager (多仓编排)"]
    wt_mgr["worktree-manager (worktree 生命周期)"]
    git_crate["git (libgit2 封装)"]

    subgraph ext["🌍 外部进程与资源"]
        agent_proc["编码代理进程<br/>Claude / Codex / Gemini / ..."]
        mcp_srv["MCP server<br/>(vibe-kanban-mcp 独立二进制)"]
        worktrees["磁盘上的 git worktrees"]
        github["GitHub (PR · OAuth)"]
    end

    fe -->|"REST /api + WS/SSE"| srv
    srv --> deployment
    deployment --> ld
    deployment --> svc
    container_svc --> executors --> agent_proc
    agent_proc -. "工具调用" .-> mcp_srv -->|"REST 回调"| srv
    container_svc --> db_svc
    container_svc --> event_svc
    event_svc -. "实时推送" .-> srv
    container_svc --> ws_mgr --> wt_mgr --> git_crate --> worktrees
    svc --> db_svc
    git_svc --> git_crate
    pr_mon --> github
    pty_svc -. "PTY" .-> agent_proc

    classDef fenode fill:#dbeafe,stroke:#2563eb,color:#1e3a5f
    classDef trait fill:#fef9c3,stroke:#ca8a04,color:#713f12
    classDef extnode fill:#fae8ff,stroke:#a21caf,color:#581c87
    class local_web,web_core,ui_kit fenode
    class deployment trait
    class agent_proc,mcp_srv,worktrees,github extnode
```

---

## ⏱️ 一次代理运行的时序

_从创建 workspace 到代理执行、日志规范化、实时流式推送、再到进程退出的完整生命周期。_

```mermaid
sequenceDiagram
    accTitle: Coding Agent Run Lifecycle
    accDescr: Sequence from creating a workspace and worktrees, spawning the coding agent through an executor, normalizing and streaming logs back to the browser, agent tool calls via MCP, and process exit handling.

    actor U as 👤 浏览器
    participant S as ⚙️ server (Axum)
    participant C as LocalContainerService
    participant W as workspace/worktree-manager
    participant E as executor
    participant P as 🤖 代理进程
    participant M as MsgStore / EventService
    participant DB as 🗄️ db

    U->>S: POST 创建 workspace
    S->>W: 为各 repo 创建 git worktree
    W-->>S: WorktreeContainer (路径 + 分支)
    S->>DB: 写入 workspace / workspace_repo

    U->>S: POST 运行代理 (execution)
    S->>C: spawn_initial(profile, prompt)
    C->>DB: insert execution_process (Running)
    C->>E: spawn(dir, prompt, env)
    E->>P: tokio 启动进程组
    activate P

    loop 流式输出
        P-->>M: stdout / stderr (原始)
        M->>M: normalize_logs → JSON Patch
        M-->>S: SSE/WS 推送规范化条目
        S-->>U: 实时渲染对话与工具调用
    end

    P->>M: (可选) 经 MCP 调用工具
    M->>S: REST 回调 (创建 issue / workspace 等)

    P-->>E: 进程退出
    deactivate P
    E-->>C: 退出码
    C->>DB: 更新 execution_process (Completed/Failed)
    C->>M: 发出变更事件 → 通知前端
```

---

## 🧱 后端 crate 分层与依赖

_按职责把 30+ 个 crate 分为入口二进制、部署抽象、领域服务、基础设施、连接/relay 五层,依赖方向自上而下。_

```mermaid
flowchart TB
    accTitle: Backend Crate Layering
    accDescr: The Rust workspace grouped into five layers — entry binaries, deployment abstraction, domain services, infrastructure primitives, and relay/connectivity — with dependencies flowing downward.

    subgraph l1["① 入口 / 二进制"]
        c_server["server"]
        c_mcp["mcp"]
        c_tauri["tauri-app"]
        c_review["review"]
        c_relaytunnel["relay-tunnel"]
        c_remote["remote (云端)"]
    end

    subgraph l2["② 部署抽象"]
        c_deploy["deployment (trait)"]
        c_localdeploy["local-deployment"]
    end

    subgraph l3["③ 领域服务"]
        c_services["services"]
        c_executors["executors"]
        c_wsmgr["workspace-manager"]
        c_wtmgr["worktree-manager"]
        c_githost["git-host"]
    end

    subgraph l4["④ 基础设施"]
        c_db["db"]
        c_git["git"]
        c_utils["utils"]
        c_apitypes["api-types"]
        c_preview["preview-proxy"]
    end

    subgraph l5["⑤ 连接 / Relay"]
        c_relayfam["relay-* 家族<br/>(control · protocol · ws · webrtc ·<br/>hosts · tunnel-core · types · client)"]
        c_wsbridge["ws-bridge"]
        c_ssh["embedded-ssh"]
        c_tka["trusted-key-auth"]
        c_deskbridge["desktop-bridge"]
    end

    l1 --> l2
    c_localdeploy --> l3
    c_deploy --> l3
    l3 --> l4
    c_localdeploy --> l5
    c_server --> l5
    c_executors --> c_db
    c_wsmgr --> c_wtmgr --> c_git

    classDef entry fill:#dbeafe,stroke:#2563eb,color:#1e3a5f
    classDef absn fill:#fef9c3,stroke:#ca8a04,color:#713f12
    class c_server,c_mcp,c_tauri,c_review,c_relaytunnel,c_remote entry
    class c_deploy,c_localdeploy absn
```

---

## 🗄️ 领域数据模型(SQLite)

_本地数据库的核心实体与关系:项目/仓库 → workspace(多仓 worktree 容器)→ session → 执行进程 → 日志,以及任务、PR、附件。_

```mermaid
erDiagram
    accTitle: Core Domain Data Model
    accDescr: Principal SQLite entities — projects and repos joined into multi-repo workspaces, which run sessions that spawn execution processes producing logs and repo-state snapshots, plus tasks, pull requests, and attachments.

    PROJECT      ||--o{ REPO                       : registers
    WORKSPACE    ||--o{ WORKSPACE_REPO             : has
    REPO         ||--o{ WORKSPACE_REPO             : "joined in"
    TASK         ||--o{ WORKSPACE                  : "tracked by"
    WORKSPACE    ||--o{ SESSION                    : runs
    SESSION      ||--o{ EXECUTION_PROCESS          : spawns
    SESSION      ||--o{ CODING_AGENT_TURN          : contains
    EXECUTION_PROCESS ||--o{ EXECUTION_PROCESS_LOGS        : streams
    EXECUTION_PROCESS ||--o{ EXECUTION_PROCESS_REPO_STATE  : snapshots
    WORKSPACE    ||--o{ PULL_REQUEST               : opens
    WORKSPACE    ||--o{ FILE                       : attaches

    WORKSPACE {
        uuid id
        string branch
        string container_ref "worktree 父目录"
        uuid task_id
        bool archived
    }
    EXECUTION_PROCESS {
        uuid id
        string run_reason "Setup/CodingAgent/DevServer/Cleanup"
        string status "Running/Completed/Failed/Killed"
        json executor_action
    }
    SESSION {
        uuid id
        uuid workspace_id
    }
```

---

## ☁️ 云端 + Relay 拓扑

_云端用 Postgres + ElectricSQL 做读路径实时同步、REST 写入并回传 txid;relay 隧道让云端前端经签名 WebSocket / WebRTC 反向触达用户本地实例。_

```mermaid
flowchart TB
    accTitle: Cloud and Relay Topology
    accDescr: The cloud backend syncs reads via ElectricSQL over Postgres logical replication and takes writes over REST returning a txid; a relay server with SPAKE2/Ed25519 auth lets the cloud frontend reach a user's local instance over signed WebSocket tunnels or WebRTC.

    subgraph cloud["☁️ 云端 (remote crate)"]
        pg["PostgreSQL<br/>wal_level=logical"]
        electric["ElectricSQL (shape 流)"]
        remote_api["Axum: /v1 (REST) + /shape"]
        remote_web["remote-web SPA"]
        pg --> electric --> remote_api
        remote_api -. "shape 订阅" .-> remote_web
        remote_web -->|"REST 写 → 返回 txid"| remote_api
    end

    subgraph relay["🔁 Relay 服务 (relay-tunnel)"]
        relay_ctrl["认证: SPAKE2 + Ed25519 签名"]
        relay_ws["签名 WebSocket 隧道 (yamux 多路复用)"]
    end

    subgraph localbox["🖥️ 用户机器"]
        relay_hosts["relay-hosts 客户端"]
        local_server["本地 server"]
        ssh["embedded-ssh"]
        preview["preview-proxy (dev 预览)"]
        relay_hosts --> local_server --> ssh
        local_server --> preview
    end

    remote_web -. "请求触达本地" .-> relay_ws
    relay_hosts -->|"已签名 WS"| relay_ws
    relay_hosts -. "WebRTC P2P (relay-webrtc)" .-> remote_web

    classDef cloudn fill:#dbeafe,stroke:#2563eb,color:#1e3a5f
    classDef relayn fill:#fef9c3,stroke:#ca8a04,color:#713f12
    class pg,electric,remote_api,remote_web cloudn
    class relay_ctrl,relay_ws relayn
```

---

## 🔑 关键设计要点

| 主题 | 做法 |
|------|------|
| **统一抽象** | `Deployment` trait 把 db / git / container / events / auth / relay 收拢成一个接口,`local-deployment` 与 `remote` 两套实现可互换 |
| **代理可插拔** | `StandardCodingAgentExecutor` trait + `#[enum_dispatch]`,每个代理一个 `.rs`;输出统一规范化为 `NormalizedEntry`(消息/工具调用/思考/token 用量) |
| **实时流** | `MsgStore`(内存环形缓冲 + broadcast)→ SSE/WebSocket,日志用 **RFC 6902 JSON Patch** 增量推送 |
| **隔离执行** | 每个 workspace 用 `worktree-manager` 创建独立 git worktree;多仓由 `workspace-manager` 原子编排、失败回滚 |
| **类型共享** | `ts-rs` 从 Rust 结构体生成 `shared/types.ts`(本地)与 `shared/remote-types.ts`(云端),禁止手改 |
| **前端复用** | `web-core` 为共享逻辑(TanStack Query/Router + Zustand),`local-web` / `remote-web` 仅为入口,通过 `runtime="local"/"remote"` 分支行为 |
| **连接安全** | relay 链路用 SPAKE2 密码认证 + Ed25519 请求签名;`embedded-ssh` 校验公钥;优先 WebRTC P2P,失败回退隧道 |

---

## 📁 关键路径索引

| 组件 | 路径 |
|------|------|
| Server 入口 | `crates/server/src/main.rs` · `crates/server/src/routes/mod.rs` |
| Deployment trait | `crates/deployment/src/lib.rs` |
| 本地实现 | `crates/local-deployment/src/lib.rs` · `container.rs` · `pty.rs` |
| 编码代理 | `crates/executors/src/executors/mod.rs` + `{claude,codex,gemini,...}.rs` |
| 日志规范化 | `crates/executors/src/logs/` |
| 领域服务 | `crates/services/src/services/` |
| 数据模型 / 迁移 | `crates/db/src/models/` · `crates/db/migrations/` |
| worktree / 多仓 | `crates/worktree-manager/` · `crates/workspace-manager/` |
| MCP server | `crates/mcp/src/bin/vibe_kanban_mcp.rs` |
| 云端 | `crates/remote/`(详见 `crates/remote/AGENTS.md`) |
| 前端共享逻辑 | `packages/web-core/src/`(API: `shared/lib/api.ts`) |
| 前端入口 | `packages/local-web/` · `packages/remote-web/` · 设计系统 `packages/ui/` |
| CLI | `npx-cli/src/cli.ts` |

> 一处待核实点:`crates/remote/AGENTS.md` 描述了 ElectricSQL shape 流 + REST 写回 txid 握手的读写契约(本图据此绘制);但 `remote-web` 前端的 `package.json` 中未直接发现 Electric 客户端依赖。云端前端究竟走 Electric 订阅还是 REST 轮询,需进一步核对 `packages/remote-web`。
