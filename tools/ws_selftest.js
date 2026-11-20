// 用 Node 自带的 WebSocket 客户端验证 droidbridge 协议
const fs = require('fs');

const URL = process.argv[2] || 'ws://127.0.0.1:8771/ws';

async function main() {
  // 1) HTTP health
  const health = await fetch('http://127.0.0.1:8771/status').then(r => r.json());
  console.log('health:', JSON.stringify(health));

  const ws = new WebSocket(URL);
  ws.binaryType = 'arraybuffer';
  let frames = 0;
  let firstFrame = null;
  let tapOk = false;
  const texts = [];

  const done = new Promise((resolve, reject) => {
    const timer = setTimeout(() => resolve('timeout'), 9000);
    ws.addEventListener('open', () => {
      console.log('ws open');
      ws.send(JSON.stringify({ t: 'hello', code: '', client: 'node-test', v: 1 }));
      setTimeout(() => {
        ws.send(JSON.stringify({ t: 'tap', x: 0.5, y: 0.5 }));
      }, 500);
      setTimeout(() => {
        ws.send(JSON.stringify({ t: 'key', v: 'BACK' }));
      }, 900);
    });
    ws.addEventListener('message', (event) => {
      if (typeof event.data === 'string') {
        texts.push(event.data);
        const obj = JSON.parse(event.data);
        if (obj.t === 'meta') console.log('meta:', event.data);
        if (obj.t === 'ok') { console.log('ok:', obj.v); if (String(obj.v).startsWith('text') || String(obj.v).includes('tap')) tapOk = true; }
        if (obj.t === 'error') console.log('error:', obj.v);
      } else {
        frames += 1;
        if (!firstFrame) firstFrame = Buffer.from(event.data);
      }
      if (frames >= 4) { clearTimeout(timer); resolve('ok'); }
    });
    ws.addEventListener('error', (e) => { clearTimeout(timer); reject(new Error('ws error')); });
  });

  const result = await done;
  console.log('frames:', frames, 'result:', result);
  if (firstFrame) {
    fs.writeFileSync('frame-test.png', firstFrame);
    const sig = firstFrame.slice(0, 8).toString('hex');
    console.log('frame bytes:', firstFrame.length, 'sig:', sig, 'valid png:', sig === '89504e470d0a1a0a');
  }
  const png = await fetch('http://127.0.0.1:8771/screen.png');
  console.log('screen.png status:', png.status, 'len:', (await png.arrayBuffer()).byteLength);
  ws.close();
  if (!firstFrame || frames < 2) { console.error('FAIL: 没有收到画面帧'); process.exit(1); }
  if (!tapOk) { console.error('FAIL: 控制指令没有回执'); process.exit(1); }
  console.log('PASS');
}

main().catch((e) => { console.error('FAIL', e); process.exit(1); });
