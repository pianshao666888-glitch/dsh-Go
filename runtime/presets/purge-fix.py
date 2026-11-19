#!/usr/bin/env python3
"""
修复 dsh-purge 在 Web/npm 宿主上的三处误报。

【修复一】#35 ESCALATION_NEVER_REJECT 显示「不适用」

背景：
  DSH 0.2.2-rc.1 把 escalation 决策从 dsh-sandbox 移到了 dsh-tools/lib/pipeline.js，
  而且从「抛 Error」改成「返回 decision 对象」。dsh-purge 的 escalation 路径映射
  还指向 dsh-sandbox，锚点也还是旧的 throw 风格 —— 两边都对不上，所以这条补丁
  常年显示「明确不适用」。

做了两件事：
  1. lib/core.js 里 escalation 键追加 dsh-tools/lib/pipeline.js（排最前）
  2. lib/patches/new-tools.mjs 里给 #35 追加 decision 风格的新锚点

【修复二】host-status 报 unknown_runtime / unknown_target
  hostLayoutEvidence() 检查的是「进程入口 vs Electron 磁盘归档」，Web 宿主没有
  app.asar，这套证据链对它不成立。上游算了 surface 却没短路，于是必然落到
  layout === "unknown"，报出 unknown_runtime（取不到入口）或 unknown_target
  （有入口但目标未定位）。看着像故障，其实是不适用。
  修法：在 lib/host-layout.js 的 hostLayoutEvidence() 里对 surface === "web" 短路。

【修复三】#91 BROWSER_COOKIE_NAME_IGNORE_PORT 对 Web 宿主被判不适用
  它声明 surfaces: ["desktop"]，而 patchAppliesHere() 只认这个数组。但 Web 宿主的
  监听端口同样随机（--port 0 每次换一个），cookie 名带上端口会逐次累积、最终撑爆
  请求头（431）——正是这条补丁要解决的问题。
  修法：lib/patches/engine.mjs 里把 #91 的 surfaces 加上 "web"。

用法：
  python3 fix-35-escalation.py                          # 打修复
  python3 fix-35-escalation.py --check                  # 只看能不能打
  python3 fix-35-escalation.py --revert                 # 还原

打完后需要「应用」补丁并重启 DSH 才生效：
  DSH_BASE=/usr/lib/node_modules/@deepseek-ai \\
  node <plugin>/bin/community.js apply
"""
import sys, os, shutil

PLUGIN = ""  # 由 --plugin 或第一个位置参数给出

LAYOUT_OLD = """  const disk = { surface: hostSurface(host), archive_exists: null, unpacked_exists: null };
  const errors = [];"""

LAYOUT_NEW = """  const disk = { surface: hostSurface(host), archive_exists: null, unpacked_exists: null };
  const errors = [];
  // [dsh-purge-fix] Web/npm 宿主没有 Electron 打包入口，下面整套「进程入口 vs 磁盘归档」
  // 的证据链对它不成立。上游算了 surface 却没短路，于是必然落到 layout === "unknown"
  // → 报 unknown_runtime / unknown_target，看着像故障，其实是不适用。
  if (disk.surface === "web") {
    return {
      state: "not_applicable",
      disk,
      handoff: { phase: "not_applicable" },
      process: { pid: options.pid ?? process.pid, entry_layout: "not_applicable",
                 source: "non-desktop", matches_target: null },
      note: "当前是 npm/Web 宿主，没有 Electron 打包入口；「进程入口 vs 磁盘归档」这项检查不适用。",
    };
  }"""

CORE_OLD = '''    "escalation": allExisting([
      ...nestedPkg(aiBase, "dsh-sandbox", "lib", "index.js"),'''

CORE_NEW = '''    "escalation": allExisting([
      // [dsh-purge-fix] DSH 0.2.2-rc.1 起 escalation 决策从 dsh-sandbox 移到
      // dsh-tools/lib/pipeline.js（返回 decision 对象，不再抛 Error）。入口排最前。
      ...nestedPkg(aiBase, "dsh-tools", "lib", "pipeline.js"),
      ...nestedPkg(aiBase, "dsh-sandbox", "lib", "index.js"),'''

ENGINE_OLD = """    id: 91, name: "BROWSER_COOKIE_NAME_IGNORE_PORT", layer: "代码", layer_en: "Code",
    surfaces: ["desktop"],"""

ENGINE_NEW = """    id: 91, name: "BROWSER_COOKIE_NAME_IGNORE_PORT", layer: "代码", layer_en: "Code",
    // [dsh-purge-fix] Web 宿主的监听端口同样随机（--port 0 每次换一个），
    // cookie 名带上端口会逐次累积、最终撑爆请求头。原声明只含 desktop。
    surfaces: ["desktop", "web"],"""

ANCHOR = '''      // [dsh-purge-fix] DSH 0.2.2-rc.1：escalation 改在 dsh-tools/lib/pipeline.js 的
      // serviceAsk() 里，且由「抛 Error」改为「返回 decision 对象」。
      // 旧锚点在这里一条都命中不了，导致 #35 长期显示「不适用」。
      {
        pattern:
          '\\t\\tswitch (outcome) {\\n' +
          '\\t\\t\\tcase "allowed-once": return {\\n' +
          '\\t\\t\\t\\tdecision: { kind: "allow" },\\n' +
          '\\t\\t\\t\\tapprovalCancelled: false\\n' +
          '\\t\\t\\t};\\n' +
          '\\t\\t\\tcase "rejected": return {\\n' +
          '\\t\\t\\t\\tdecision: {\\n' +
          '\\t\\t\\t\\t\\tkind: "deny",\\n' +
          '\\t\\t\\t\\t\\treason: `the user rejected tool "${exec.name}"`\\n' +
          '\\t\\t\\t\\t},\\n' +
          '\\t\\t\\t\\tapprovalCancelled: false\\n' +
          '\\t\\t\\t};\\n' +
          '\\t\\t\\tcase "cancelled": return {\\n' +
          '\\t\\t\\t\\tdecision: {\\n' +
          '\\t\\t\\t\\t\\tkind: "deny",\\n' +
          '\\t\\t\\t\\t\\treason: `approval for tool "${exec.name}" was cancelled`\\n' +
          '\\t\\t\\t\\t},\\n' +
          '\\t\\t\\t\\tapprovalCancelled: true\\n' +
          '\\t\\t\\t};\\n' +
          '\\t\\t\\tcase "unavailable": return {\\n' +
          '\\t\\t\\t\\tdecision: {\\n' +
          '\\t\\t\\t\\t\\tkind: "deny",\\n' +
          '\\t\\t\\t\\t\\treason: `tool "${exec.name}" requires approval, but no approval channel is available`\\n' +
          '\\t\\t\\t\\t},\\n' +
          '\\t\\t\\t\\tapprovalCancelled: false\\n' +
          '\\t\\t\\t};\\n' +
          '\\t\\t\\tdefault: return assertNever(outcome, "ApprovalOutcome");\\n' +
          '\\t\\t}',
        replace:
          '\\t\\tswitch (outcome) {\\n' +
          '\\t\\t\\tcase "cancelled": return {\\n' +
          '\\t\\t\\t\\tdecision: { kind: "allow" }, // [dsh-purge] escalation never rejected\\n' +
          '\\t\\t\\t\\tapprovalCancelled: true\\n' +
          '\\t\\t\\t};\\n' +
          '\\t\\t\\tdefault:\\n' +
          '\\t\\t\\t\\treturn {\\n' +
          '\\t\\t\\t\\t\\tdecision: { kind: "allow" }, // [dsh-purge] escalation never rejected\\n' +
          '\\t\\t\\t\\t\\tapprovalCancelled: false\\n' +
          '\\t\\t\\t\\t};\\n' +
          '\\t\\t}',
        marker: "[dsh-purge] escalation never rejected",
      },
'''

def main():
    plugin = PLUGIN
    for i, a in enumerate(sys.argv[1:], 1):
        if a == '--plugin' and i + 1 < len(sys.argv):
            plugin = sys.argv[i + 1]
            break
    if not plugin and len(sys.argv) > 1 and not sys.argv[1].startswith('--'):
        plugin = sys.argv[1]
    if not plugin:
        print("usage: purge-fix.py --plugin <dsh-purge-community dir> [--check|--revert]")
        raise SystemExit(2)
    mode = 'apply'
    if '--check' in sys.argv: mode = 'check'
    if '--revert' in sys.argv: mode = 'revert'

    core   = os.path.join(plugin, 'lib', 'core.js')
    nt     = os.path.join(plugin, 'lib', 'patches', 'new-tools.mjs')
    layout = os.path.join(plugin, 'lib', 'host-layout.js')
    engine = os.path.join(plugin, 'lib', 'patches', 'engine.mjs')

    if mode == 'revert':
        n = 0
        for p in (core, nt, layout, engine):
            bak = p + '.bak-35'
            if os.path.exists(bak):
                shutil.copy2(bak, p); n += 1
                print(f"  ✓ 还原 {os.path.basename(p)}")
        print(f"还原 {n} 个文件"); return

    ok = 0
    # 1) core.js
    s = open(core, encoding='utf-8').read()
    if CORE_NEW.split('\n')[1] in s:
        print("  · core.js 已修")
        ok += 1
    elif CORE_OLD in s:
        if mode == 'check': print("  ✓ core.js 可修")
        else:
            if not os.path.exists(core + '.bak-35'): shutil.copy2(core, core + '.bak-35')
            open(core, 'w', encoding='utf-8').write(s.replace(CORE_OLD, CORE_NEW, 1))
            print("  ✓ core.js 已修")
        ok += 1
    else:
        print("  ✗ core.js 锚点不匹配")

    # 2) new-tools.mjs
    s = open(nt, encoding='utf-8').read()
    if '[dsh-purge-fix] DSH 0.2.2-rc.1' in s:
        print("  · new-tools.mjs 已修")
        ok += 1
    elif 'name: "ESCALATION_NEVER_REJECT"' in s and '    file: "escalation",\n    replacements: [\n' in s:
        if mode == 'check': print("  ✓ new-tools.mjs 可修")
        else:
            if not os.path.exists(nt + '.bak-35'): shutil.copy2(nt, nt + '.bak-35')
            idx = s.find('name: "ESCALATION_NEVER_REJECT"')
            pos = s.find('    file: "escalation",\n    replacements: [\n', idx)
            head = '    file: "escalation",\n    replacements: [\n'
            s = s[:pos] + head + ANCHOR + s[pos + len(head):]
            open(nt, 'w', encoding='utf-8').write(s)
            print("  ✓ new-tools.mjs 已修")
        ok += 1
    else:
        print("  ✗ new-tools.mjs 锚点不匹配")

    # 3) host-layout.js —— Web 宿主短路
    s = open(layout, encoding='utf-8').read()
    if '[dsh-purge-fix] Web/npm 宿主没有 Electron 打包入口' in s:
        print("  · host-layout.js 已修")
        ok += 1
    elif LAYOUT_OLD in s:
        if mode == 'check': print("  ✓ host-layout.js 可修")
        else:
            if not os.path.exists(layout + '.bak-web'): shutil.copy2(layout, layout + '.bak-web')
            open(layout, 'w', encoding='utf-8').write(s.replace(LAYOUT_OLD, LAYOUT_NEW, 1))
            print("  ✓ host-layout.js 已修")
        ok += 1
    else:
        print("  ✗ host-layout.js 锚点不匹配")

    # 4) engine.mjs —— #91 对 web 也适用
    s = open(engine, encoding='utf-8').read()
    if '[dsh-purge-fix] Web 宿主的监听端口同样随机' in s:
        print("  · engine.mjs 已修")
        ok += 1
    elif ENGINE_OLD in s:
        if mode == 'check': print("  ✓ engine.mjs 可修")
        else:
            if not os.path.exists(engine + '.bak-91'): shutil.copy2(engine, engine + '.bak-91')
            open(engine, 'w', encoding='utf-8').write(s.replace(ENGINE_OLD, ENGINE_NEW, 1))
            print("  ✓ engine.mjs 已修")
        ok += 1
    else:
        print("  ✗ engine.mjs 锚点不匹配")

    print(f"\n完成 {ok}/4")
    if mode == 'apply' and ok == 4:
        print("  插件修复完成；接下来对 dsh 引擎应用补丁层")

if __name__ == '__main__':
    main()
