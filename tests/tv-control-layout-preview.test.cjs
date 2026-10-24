const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {stripTypeScriptTypes} = require('node:module');
const vm = require('node:vm');
const tokens = readFileSync('tv/overlay/entry/src/main/ets/theme/TvControlLayoutPreviewTokens.ets','utf8').replace(/^export /gm,'');
const geometry = readFileSync('tv/overlay/entry/src/main/ets/services/TvControlLayoutPreviewGeometry.ets','utf8')
  .replace(/^import .*;\n/gm,'').replace(/^export /gm,'');
const context = vm.createContext({});
vm.runInContext(stripTypeScriptTypes(tokens+'\nconst Preview = TvControlLayoutPreviewTokens;\n'+geometry+
  '\nglobalThis.layout = tvControlLayoutPreviewGeometry;globalThis.size=[Preview.width,Preview.height];'),context);
const layout = (corner,horizontal,count) => JSON.parse(JSON.stringify(context.layout(corner,horizontal,count)));

test('Four-corner preview preserves the established 360 by 172 layout and second-line joystick alignment',()=>{
  assert.deepEqual(Array.from(context.size),[360,172]);
  const expected = [
    [0,true, 8,8,186,24,8,38],
    [1,true, 166,8,186,24,322,38],
    [2,true, 8,140,186,24,8,104],
    [3,true, 166,140,186,24,322,104],
    [0,false, 8,8,42,114,56,8],
    [1,false, 310,8,42,114,274,8],
    [2,false, 8,50,42,114,56,134],
    [3,false, 310,50,42,114,274,134],
  ];
  for(const [corner,horizontal,x,y,width,height,joystickX,joystickY] of expected) {
    assert.deepEqual(layout(corner,horizontal,4),{x,y,width,height,joystickX,joystickY});
  }
});

test('Changing visible controls keeps the preview inside its canvas without overlapping the joystick',()=>{
  for(const count of [2,3,4]) for(const corner of [0,1,2,3]) for(const horizontal of [true,false]) {
    const p=layout(corner,horizontal,count);
    assert.ok(p.x>=8 && p.y>=8 && p.x+p.width<=352 && p.y+p.height<=164);
    assert.ok(p.joystickX>=8 && p.joystickY>=8 && p.joystickX+30<=352 && p.joystickY+30<=164);
    assert.ok(p.joystickX+30<=p.x || p.joystickX>=p.x+p.width ||
      p.joystickY+30<=p.y || p.joystickY>=p.y+p.height);
  }
});
