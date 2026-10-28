// Port of packages/agent/src/index.ts
//
// export * from "./agent.ts";          -> agent.swift (public API)
// export * from "./agent-loop.ts";     -> agent-loop.swift (public API)
// export * from "./proxy.ts";          -> Not ported: proxy.ts streams through a pi proxy server
//                                         (browser/app-server deployment); this app talks to providers directly.
// export { setDefaultStreamFn } from "./stream-fn.ts";  -> stream-fn.swift (`getDefaultStreamFn` stays internal)
// export * from "./types.ts";          -> types.swift (public API)
