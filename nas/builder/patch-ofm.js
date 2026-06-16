// 修补 obsidian-flavored-markdown（Quartz v5 社区插件）的三个问题。
// 改其未压缩的 dist/index.js；用 Node 比 sed 处理特殊字符更稳。
// 每处替换都必须命中，否则（插件升级导致失配）退出码 1 让构建失败提醒。
const fs = require("fs");
const F = "/quartz/.quartz/plugins/obsidian-flavored-markdown/dist/index.js";
let s = fs.readFileSync(F, "utf8");
const done = [];

// 1) ![[x.svg]]：原渲染成 <object data="裸名">（路径不被 crawl-links 解析 → 404）。
//    把 .svg 并入「栅格图」扩展名列表 → 走 <img>，路径被正确解析。
const arr = '[".jxl", ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp"]';
if (s.includes(arr)) {
  s = s.replace(arr, '[".jxl", ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".svg"]');
  done.push("svg");
}

// 2) ![[x.html]]：原被丢弃。把上面并入 svg 后「已废弃」的 svg 分支改成 .html/.htm → <iframe>
//    （crawl-links 会解析 img/video/audio/iframe 的 src）。
if (s.includes('} else if (ext === ".svg") {')) {
  s = s.replace('} else if (ext === ".svg") {', '} else if (ext === ".html" || ext === ".htm") {');
}
const objTpl = '`<object data="${url}" type="image/svg+xml" width="${width}" height="${height}" aria-label="${alt}"></object>`';
const ifrTpl = '`<iframe src="${url}" width="${width}" height="${height}" loading="lazy" style="border:0;width:100%;min-height:480px" title="${alt}"></iframe>`';
if (s.includes(objTpl)) {
  s = s.replace(objTpl, ifrTpl);
  done.push("html");
}

// 3) Obsidian 把任意 $$..$$ 当行间公式；remark-math 只把「围栏独占整行」的当 display，
//    单行/贴文字的 $$..$$ 被当行内（于是 \begin{align}、\tag 报错）。
//    在 textTransform 里把 $$..$$ 规范成块级（围栏独占行、前后空行）。
//    —— 关键：blockquote/callout 感知：先脱去一层 ">"，规范化，再逐行加回 ">"，
//       否则插入的裸行会把 callout 截断成正文。
//    —— 内含奇数个 $ 的当作「相邻行内公式误配的假 $$」原样保留（\tag{$\star$} 这种偶数才规范化）。
const helper = [
  "function __obsMathNorm(src) {",
  "  function wrap(s) {",
  "    return s.replace(/\\$\\$([\\s\\S]*?)\\$\\$/g, function (m, x) {",
  "      if (((x.match(/\\$/g) || []).length % 2) === 1) return m;",
  '      return "\\n\\n$$\\n" + x.trim() + "\\n$$\\n\\n";',
  "    });",
  "  }",
  "  function prose(text) {",
  '    var lines = text.split("\\n"), out = [], run = [], rq = null;',
  "    function flush() {",
  "      if (!run.length) return;",
  "      if (rq) {",
  '        var st = run.map(function (l) { return l.replace(/^\\s*>[ \\t]?/, ""); }).join("\\n");',
  '        wrap(st).split("\\n").forEach(function (l) { out.push(l.length ? "> " + l : ">"); });',
  "      } else {",
  '        out.push(wrap(run.join("\\n")));',
  "      }",
  "      run = [];",
  "    }",
  "    for (var i = 0; i < lines.length; i++) {",
  "      var q = /^\\s*>/.test(lines[i]);",
  "      if (rq === null) rq = q;",
  "      if (q !== rq) { flush(); rq = q; }",
  "      run.push(lines[i]);",
  "    }",
  "    flush();",
  '    return out.join("\\n");',
  "  }",
  "  var parts = src.split(/(```[\\s\\S]*?```|~~~[\\s\\S]*?~~~)/g);",
  "  for (var i = 0; i < parts.length; i += 2) parts[i] = prose(parts[i]);",
  '  return parts.join("");',
  "}",
].join("\n");

if (!s.includes("__obsMathNorm")) {
  s = helper + "\n" + s;
  // 用函数式替换：字符串式替换里 $$ 会被当成转义的字面 $（这里没有，但保持一致）
  s = s.replace("textTransform(_ctx, src) {", () => "textTransform(_ctx, src) { src = __obsMathNorm(src);");
  done.push("math");
}

fs.writeFileSync(F, s);
for (const k of ["svg", "html", "math"]) {
  if (!done.includes(k)) {
    console.error("patch-ofm: 替换失配 ->", k, "(插件结构可能变了)");
    process.exit(1);
  }
}
console.log("patch-ofm: OK (" + done.join(", ") + ")");
