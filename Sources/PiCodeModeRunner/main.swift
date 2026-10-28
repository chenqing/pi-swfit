import Foundation
import JavaScriptCore
import Security
import Darwin

// Only a JSON tool bridge is exposed. No native object, filesystem, network or process API is exported.
func sandboxedSignature() -> Bool {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let values = info as? [String: Any], let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
    let allowed: Set<String> = ["com.apple.security.app-sandbox", "com.apple.application-identifier", "application-identifier", "com.apple.developer.team-identifier"]
    return entitlements["com.apple.security.app-sandbox"] as? Bool == true && Set(entitlements.keys).isSubset(of: allowed)
}
func fail(_ text: String) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: ["error": String(text.prefix(1000))])) ?? Data()
    FileHandle.standardOutput.write(data)
    exit(1)
}
guard sandboxedSignature() else { fail("插件运行器没有有效的独立沙箱签名，拒绝执行。") }
#if DEBUG
// Native sandbox smoke test; never exposes native operations to JavaScript.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--sandbox-check" {
    let path = CommandLine.arguments[2]
    let readDenied = open(path, O_RDONLY) == -1 && errno == EPERM
    let writeDenied = open(path + ".write", O_WRONLY | O_CREAT, 0o600) == -1 && errno == EPERM
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(9).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    let networkDenied = result == -1 && errno == EPERM
    if socketFD >= 0 { close(socketFD) }
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: ["readDenied": readDenied, "writeDenied": writeDenied, "networkDenied": networkDenied]))
    exit(readDenied && writeDenied && networkDenied ? 0 : 1)
}
#endif
var cpu = rlimit(rlim_cur: 30, rlim_max: 30)
guard setrlimit(RLIMIT_CPU, &cpu) == 0 else { fail("无法设置插件 CPU 限额。") }
var core = rlimit(rlim_cur: 0, rlim_max: 0)
_ = setrlimit(RLIMIT_CORE, &core)
let monitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
monitor.schedule(deadline: .now(), repeating: .milliseconds(100))
nonisolated func checkMemory() {
    var usage = rusage()
    if getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 256 * 1024 * 1024 { _exit(72) }
}
monitor.setEventHandler(handler: checkMemory)
monitor.resume()
func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message), data.count <= 12 * 1024 * 1024 else { _exit(73) }
    FileHandle.standardOutput.write(data + Data([10]))
}
func response(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func rpcError(_ id: Any, _ message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": String(message.prefix(2000))]]) }
var context: JSContext?
var executionID: Any?
while let line = readLine() {
    guard line.utf8.count <= 12 * 1024 * 1024,
          let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { _exit(74) }
    if let method = message["method"] as? String {
        guard let id = message["id"] else { continue }
        if method == "initialize" {
            response(id, ["protocolVersion": "2025-11-25", "capabilities": [:], "serverInfo": ["name": "pi-swift-codemode", "version": "1"]]); continue
        }
        guard method == "codemode/run", context == nil,
              let params = message["params"] as? [String: Any], let source = params["code"] as? String,
              source.utf8.count <= 1024 * 1024, let js = JSContext(),
              let setup = try? JSONSerialization.data(withJSONObject: params) else { rpcError(id, "Invalid codemode request"); continue }
        context = js; executionID = id
        let bridge: @convention(block) (String, String, String) -> Void = { callID, name, input in
            guard callID.utf8.count <= 128, name.utf8.count <= 128, input.utf8.count <= 2 * 1024 * 1024,
                  let bytes = input.data(using: .utf8), let arguments = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { _exit(75) }
            send(["jsonrpc": "2.0", "id": callID, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        }
        js.setObject(bridge, forKeyedSubscript: "__piCall" as NSString)
        let bootstrap = #"""
        (() => {
          const setup = __SETUP__;
          const encode = JSON.stringify, parse = JSON.parse, hostCall = globalThis.__piCall;
          const outputs = [], logs = [], pending = new Map(), storeData = Object.assign(Object.create(null), setup.store || {});
          const known = new Map(setup.tools.map(t => [t.name, t])); let sequence = 0;
          function text(value) { const out = typeof value === 'string' ? value : encode(value); if(out !== undefined) outputs.push({type:'text',text:out}); }
          function image(value) {
            if(typeof value === 'string') { const match = /^data:(image\/[a-zA-Z0-9.+-]+);base64,(.*)$/.exec(value); if(!match) throw Error('image expects a data URL'); outputs.push({type:'image',mimeType:match[1],data:match[2]}); }
            else if(value && value.type === 'image' && typeof value.data === 'string') outputs.push({type:'image',mimeType:value.mimeType,data:value.data});
            else throw Error('Invalid image');
          }
          const tools = new Proxy(Object.create(null), {get(_, name) {
            if(typeof name !== 'string' || !known.has(name)) return undefined;
            return (args = {}) => new Promise((resolve,reject) => {
              if(++sequence > 1024) throw Error('Too many tool calls');
              const id = 'tool-' + sequence; pending.set(id,{resolve,reject}); hostCall(id,name,encode(args));
            });
          }});
          globalThis.__piReceive = raw => { const m=parse(raw), p=pending.get(m.id); if(!p)return; pending.delete(m.id); if(m.error)p.reject(Error(m.error.message)); else p.resolve(m.result.value); };
          const ALL_TOOLS = setup.tools.map(t => ({name:t.name,description:t.description,namespace:t.namespace}));
          async function searchTools(query, options={}) {
            const args={query,limit:options.limit || 8,namespace:options.namespace};
            return new Promise((resolve,reject)=>{const id='search-'+(++sequence);pending.set(id,{resolve,reject});hostCall(id,'__pi_search',encode(args));});
          }
          async function describeTool(name) { const tool=known.get(name); if(!tool)throw Error('Unknown tool: '+name); return tool; }
          async function describeNamespace(name) { return setup.tools.filter(t=>t.namespace===name); }
          function store(key,value) { if(typeof key!=='string')throw Error('store key must be a string'); if(value===undefined)delete storeData[key];else storeData[key]=parse(encode(value)); if(encode(storeData).length>2*1024*1024)throw Error('Store exceeds size limit'); }
          function load(key) { const value=storeData[key]; return value===undefined ? undefined : parse(encode(value)); }
          const stop=Object.freeze({}); function exit(){throw stop;}
          const console=Object.freeze({log:(...args)=>logs.push(args.map(x=>typeof x==='string'?x:encode(x)).join(' ')),warn:(...args)=>logs.push(args.join(' ')),error:(...args)=>logs.push(args.join(' '))});
          const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
          globalThis.__piDone=false;
          Promise.resolve().then(()=>new AsyncFunction('tools','text','image','store','load','searchTools','describeTool','describeNamespace','ALL_TOOLS','console','exit',setup.code)(tools,text,image,store,load,searchTools,describeTool,describeNamespace,ALL_TOOLS,console,exit))
          .then(value=>{if(value!==undefined)text(value);},error=>{if(error!==stop)throw error;})
          .then(()=>{
            if(logs.length)outputs.push({type:'text',text:'<console_output>\n'+logs.join('\n')+'\n</console_output>'});
            const result=encode({content:outputs,store:storeData}); if(result.length>8*1024*1024)throw Error('Output exceeds size limit');
            globalThis.__piResult=result;globalThis.__piDone=true;
          }).catch(error=>{globalThis.__piError=String(error).slice(0,2000);globalThis.__piDone=true;});
        })();
        """#.replacingOccurrences(of: "__SETUP__", with: String(decoding: setup, as: UTF8.self))
        js.evaluateScript(bootstrap)
    } else if let context {
        context.objectForKeyedSubscript("__piReceive")?.call(withArguments: [line])
    }
    if let context, let executionID {
        if let error = context.exception { rpcError(executionID, error.toString() ?? "Script failed"); exit(1) }
        if context.objectForKeyedSubscript("__piDone")?.toBool() == true {
            if let error = context.objectForKeyedSubscript("__piError"), !error.isUndefined { rpcError(executionID, error.toString() ?? "Script failed"); exit(1) }
            guard let raw = context.objectForKeyedSubscript("__piResult")?.toString(), raw.utf8.count <= 8 * 1024 * 1024,
                  let bytes = raw.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { rpcError(executionID, "Invalid output"); exit(1) }
            response(executionID, result); exit(0)
        }
    }
}
