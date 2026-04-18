// Phase 11B DO WebSocket e2e probe.
// Connects to /demo/do/ws, sends 3 text frames, prints echoed replies,
// then closes. Verifies that each frame round-trips through the DO's
// Hibernation handlers AND that the server-side counter increments.
import WebSocket from 'ws';

const ws = new WebSocket('ws://127.0.0.1:8787/demo/do/ws?name=ws-e2e');
let replies = [];
let timer;

ws.on('open', () => {
  console.log('open');
  ws.send('hello-1');
  setTimeout(() => ws.send('hello-2'), 200);
  setTimeout(() => ws.send('hello-3'), 400);
  timer = setTimeout(() => { ws.close(1000, 'done'); }, 1500);
});
ws.on('message', (data) => {
  const text = data.toString();
  console.log('reply:', text);
  replies.push(text);
});
ws.on('close', (code, reason) => {
  clearTimeout(timer);
  console.log('close:', code, String(reason));
  console.log('total_replies:', replies.length);
  process.exit(0);
});
ws.on('error', (err) => {
  console.error('ws-error:', err.message);
  process.exit(1);
});
