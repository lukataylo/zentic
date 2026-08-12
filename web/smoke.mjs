import { JSDOM } from "jsdom";
const dom = new JSDOM("<body>", { url: "https://x.test/" });
const doc = dom.window.document;
const t = doc.createElement("template");
t.innerHTML = '<td width="435"><font>a <br> <br> b</font></td>';
console.log("children:", [...t.content.childNodes].map(n => n.nodeName));
const t2 = doc.createElement("template");
t2.innerHTML = '<tr><td>a</td></tr>';
console.log("children2:", [...t2.content.childNodes].map(n => n.nodeName));
