import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:net';
import {scan,ping,MAX_BYTES} from '../src/clamav.mjs';
async function daemon(response,run){const server=createServer(socket=>socket.once('data',()=>{if(response!==null)socket.write(response);}));await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));try{await run(server.address().port);}finally{await new Promise(resolve=>server.close(resolve));}}
test('only an explicit ClamAV OK verdict releases quarantine',async()=>{await daemon('stream: OK\0',async port=>assert.equal(await scan(Buffer.from('document'),{host:'127.0.0.1',port}),'clean'));});
test('infection is recorded without exposing the signature or file contents',async()=>{await daemon('stream: Eicar-Signature FOUND\0',async port=>assert.equal(await scan(Buffer.from('test'),{host:'127.0.0.1',port}),'infected'));});
test('malformed, failed and incomplete verdicts never become clean',async()=>{for(const response of ['OK\0','stream: size limit exceeded ERROR\0','stream: OK'])await daemon(response,async port=>assert.rejects(scan(Buffer.from('test'),{host:'127.0.0.1',port,timeout:50})));});
test('unavailable scanner and oversized files fail closed',async()=>{await assert.rejects(scan(Buffer.alloc(MAX_BYTES+1),{host:'127.0.0.1',port:1}));await assert.rejects(scan(Buffer.from('test'),{host:'127.0.0.1',port:1,timeout:100}));});
test('health requires the daemon PONG response before claiming guest files',async()=>{await daemon('PONG\0',async port=>assert.equal(await ping({host:'127.0.0.1',port}),true));await daemon('ERROR\0',async port=>assert.rejects(ping({host:'127.0.0.1',port})));});
