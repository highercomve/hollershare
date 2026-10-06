import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import test from "node:test";

const source = readFileSync(new URL("../frontend/app.js", import.meta.url), "utf8");
const drop = source.slice(source.indexOf("async function drop_received(event)"), source.indexOf("if (drop_panel && window.oriel)"));
const send = source.slice(source.indexOf("async function send(address, name)"), source.indexOf("async function decision("));

for (const [label, resolved] of [["native path object", {path:"/tmp/example.apk"}], ["path string", "/tmp/example.apk"]]) {
  test(`dropped file sends a string path: ${label}`, async () => {
    const calls = [], errors = [];
    const elements = new Map();
    const context = vm.createContext({
      files: [], sending:false, share_mode:"files", drop_depth:1,
      window:{oriel:{drop:{path:async () => resolved}}},
      dropped_of:() => ({files:[{name:"example.apk",size:26}],text:null}),
      drop_panel:{classList:{remove(){}}},
      set_share_mode(){}, render_files(){},render_peers(){},
      ready_to_send:() => true,poll:async () => {},
      $:id => {if(!elements.has(id)) elements.set(id,{}); return elements.get(id);},
      error:message => errors.push(message),
      call:async (command,args) => calls.push({command,args}),
    });
    vm.runInContext(drop + send, context);
    await context.drop_received({preventDefault(){}});
    await context.send("192.168.68.190:46291", "Pixel 8");
    assert.equal(errors.length,0);
    assert.equal(calls.length,1);
    assert.equal(calls[0].command,"send_files");
    assert.equal(calls[0].args.paths.length,1);
    assert.equal(calls[0].args.paths[0],"/tmp/example.apk");
  });
}

for (const resolved of [null, {path:null}, {path:42}]) {
  test(`unresolvable dropped file is rejected: ${JSON.stringify(resolved)}`, async () => {
    const errors=[];
    const context=vm.createContext({files:[],drop_depth:1,
      window:{oriel:{drop:{path:async () => resolved}}},
      dropped_of:() => ({files:[{name:"example.apk",size:26}],text:null}),
      drop_panel:{classList:{remove(){}}},set_share_mode(){},
      render_files(){},render_peers(){},$:() => ({}),error:m => errors.push(m),
    });
    vm.runInContext(drop,context);
    await context.drop_received({preventDefault(){}});
    assert.equal(context.files.length,0);
    assert.equal(errors.length,1);
  });
}
